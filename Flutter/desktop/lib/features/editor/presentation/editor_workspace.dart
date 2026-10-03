import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:huahuo_editor/huahuo_editor.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:huahuo_product/huahuo_product.dart';

import '../../../shared/markdown/markdown_preview.dart';
import '../../../shared/services/desktop_service_result.dart';
import '../../../shared/theme/desktop_theme.dart';
import '../../../shared/widgets/desktop_ambient_background.dart';
import '../../agent/application/desktop_agent_controller.dart';
import '../../assets/domain/desktop_assets_port.dart';
import '../../auth/domain/desktop_auth_port.dart';
import '../../book_work/application/desktop_book_work_controller.dart';
import '../../book_work/domain/desktop_book_work_port.dart';
import '../../calendar/application/desktop_activity_calendar_controller.dart';
import '../../calendar/domain/desktop_activity_calendar_port.dart';
import '../../calendar/widgets/desktop_activity_calendar_workspace.dart';
import '../../chat/application/desktop_chat_note_creator.dart';
import '../../chat/application/desktop_chat_task_tracker.dart';
import '../../chat/domain/desktop_chat_port.dart';
import '../../chat/domain/desktop_chat_recovery_models.dart';
import '../../chat/domain/desktop_resource_image_cache.dart';
import '../../creations/widgets/desktop_creation_workspace.dart';
import '../../digital_twin/widgets/desktop_digital_twin_workspace.dart';
import '../../documents/domain/desktop_document_sync_port.dart';
import '../../documents/domain/desktop_document_import_port.dart';
import '../../documents/domain/desktop_raw_note_creator.dart';
import '../../integration/domain/desktop_api_domains_port.dart';
import '../../home/widgets/desktop_home_workspace.dart';
import '../../notifications/application/desktop_notifications_controller.dart';
import '../../notifications/domain/desktop_notifications_port.dart';
import '../../notifications/widgets/desktop_notifications_workspace.dart';
import '../../navigation/widgets/desktop_feature_command_palette.dart';
import '../../positioning/widgets/desktop_positioning_dashboard.dart';
import '../../proposals/widgets/desktop_document_proposals_workspace.dart';
import '../../recordings/domain/desktop_recordings_port.dart';
import '../../recordings/widgets/desktop_recording_library_workspace.dart';
import '../../support/widgets/desktop_support_workspace.dart';
import '../../topics/domain/desktop_topics_port.dart';
import '../../workspaces/widgets/desktop_workspace_management_workspace.dart';
import '../application/desktop_graph_preferences.dart';
import '../application/desktop_seed_documents.dart';
import '../domain/document_media_store.dart';
import '../domain/document_store.dart';
import 'desktop_knowledge_graph.dart';
import 'desktop_graph_settings_controls.dart';
import 'rich_text_formatting_toolbar.dart';

part 'editor_product_navigation.dart';

Widget _buildDesktopQuillContextMenu(
  BuildContext context,
  QuillRawEditorState editorState,
) => HuahuoTextEditing.buildRawContextMenu(
  context,
  anchors: editorState.contextMenuAnchors,
  buttonItems: editorState.contextMenuButtonItems,
  useTextFieldTapRegion: true,
);

enum _PrimaryWorkspaceMode { creation, chat }

enum _ContextKind { outline, knowledge, projects, relations }

enum _WorkspaceSection {
  brain,
  creation,
  chat,
  capture,
  tools,
  externalKnowledge,
  assets,
  notifications,
  account,
  settings,
}

enum _WorkspaceTabKind { graph, document, chat, feature }

enum _DocumentWorkspaceView {
  writing,
  preview,
  outline,
  references,
  annotations,
}

// At this width each writing surface stays comfortably readable beside its
// live reader. Narrower layouts keep one uninterrupted writing canvas.
const double _markdownCompanionBreakpoint = 1120;

enum _EditorImageSource { localFile, remoteUrl }

const XTypeGroup _editorImageFileTypes = XTypeGroup(
  label: '图像',
  extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp'],
);

const XTypeGroup _captureAudioFileTypes = XTypeGroup(
  label: '音频',
  extensions: <String>['wav', 'mp3', 'm4a', 'mp4'],
);

final XTypeGroup _documentFileTypes = XTypeGroup(
  label: '文档',
  extensions: DesktopDocumentImportFormat.supportedExtensions,
);

const EventChannel _incomingDocumentEventChannel = EventChannel(
  'huahuo_desktop/incoming_documents',
);

enum _CaptureMode { monologue, quickRecord, meeting, text, link, media }

enum _ExternalKnowledgeView { subscriptions, square }

enum _KnowledgeSquareCategory {
  treasure,
  history,
  socialScience,
  art,
  literature,
  audio,
  culture,
  city,
  bookstore,
  all,
}

enum _KnowledgeSquareAction { open, share, copyToEdit, export, deposit }

extension on _KnowledgeSquareCategory {
  String get label => switch (this) {
    _KnowledgeSquareCategory.treasure => '镇馆之宝',
    _KnowledgeSquareCategory.history => '历史',
    _KnowledgeSquareCategory.socialScience => '社科',
    _KnowledgeSquareCategory.art => '艺术',
    _KnowledgeSquareCategory.literature => '文学',
    _KnowledgeSquareCategory.audio => '必听',
    _KnowledgeSquareCategory.culture => '文创',
    _KnowledgeSquareCategory.city => '城市漫游',
    _KnowledgeSquareCategory.bookstore => '书店',
    _KnowledgeSquareCategory.all => '全部',
  };

  IconData get icon => switch (this) {
    _KnowledgeSquareCategory.treasure => LucideIcons.award,
    _KnowledgeSquareCategory.history => LucideIcons.history,
    _KnowledgeSquareCategory.socialScience => LucideIcons.bookOpenText,
    _KnowledgeSquareCategory.art => LucideIcons.palette,
    _KnowledgeSquareCategory.literature => LucideIcons.bookOpenCheck,
    _KnowledgeSquareCategory.audio => LucideIcons.headphones,
    _KnowledgeSquareCategory.culture => LucideIcons.lightbulb,
    _KnowledgeSquareCategory.city => LucideIcons.building2,
    _KnowledgeSquareCategory.bookstore => LucideIcons.libraryBig,
    _KnowledgeSquareCategory.all => LucideIcons.grid2x2,
  };
}

enum _SettingsSection {
  appearance,
  graph,
  writing,
  assistant,
  sync,
  notifications,
  privacy,
  shortcuts,
  about,
}

enum _AssetSourceFilter { all, mine, external }

final class _WorkspaceTab {
  const _WorkspaceTab({
    required this.id,
    required this.title,
    required this.kind,
    this.section,
    this.documentId,
    this.noteStage,
  });

  final String id;
  final String title;
  final _WorkspaceTabKind kind;
  final _WorkspaceSection? section;
  final String? documentId;
  final HuahuoNoteStage? noteStage;

  bool get closeable => kind != _WorkspaceTabKind.graph;
}

final class _AiMessage {
  const _AiMessage({required this.text, required this.fromUser, this.source});

  factory _AiMessage.fromDesktop(DesktopChatMessage message) => _AiMessage(
    text: message.text,
    fromUser: message.role == 'user',
    source: message,
  );

  final String text;
  final bool fromUser;
  final DesktopChatMessage? source;
}

String? _localDesktopAgentOpeningMessage(String? agentProfileId) =>
    switch (agentProfileId?.trim()) {
      'renshe_content' => _desktopPersonaAgentOpening,
      'huoke_content' => _desktopLeadAgentOpening,
      'video_analysis' => _desktopVideoAnalysisAgentOpening,
      _ => null,
    };

const _desktopPersonaAgentOpening = '''你好，欢迎来到花火 AI。✨

这里不是让你填表，也不是让你从零想选题。
这里是陪你把一个模糊想法、一段经历、一条新闻、一份纪要，甚至一句“我不知道拍什么”，加工成一条能拍出来的人设短视频。

你可以从任何一种方式开始：

🪄 完全没想法：直接说“我不知道拍什么”，我会从你的经历、行业、案例和表达习惯里，帮你找 2-3 个值得拍的方向。

💭 有一点模糊想法：比如“我想讲一个新闻”“我今天接待了一个客户”“我最近有个感受”，我会判断它更适合做资讯、观点、方法还是故事。

📎 有明确材料：可以发会议纪要、录音文字、新闻链接、客户案例、行业资料、朋友圈文案、旧稿子，我会先拆解它有没有可拍价值。

🎬 想直接出内容：你可以说“帮我做成能拍的视频”，我会尽量推进到选题、结构、大纲和逐字稿。

我会重点帮你判断四件事：

这件事有没有信息差：是不是外行不知道、同行一看就懂价值，或者是最近刚发生的新信息。

有没有观点价值：是不是能撕开一个认知缺口，而不是一句正确废话。

有没有方法价值：别人是不是愿意花时间学，能不能解决一个具体问题。

有没有故事价值：开头有没有好奇、反差、未闻感，能不能把人带进去。

但我不会硬编你的经历。
公共信息、行业背景、事实资料，我可以帮你补；
但你亲身经历过什么、为什么你能讲这件事、你怎么看它，这些必须来自你本人。🌱

你可以先随便发一句很粗糙的话，比如：

“我最近想讲一个客户案例。”

“我看到一个新闻，不知道能不能拍。”

“我做这个行业很多年，但不知道讲什么。”

“我有一段录音/纪要，你帮我看看能不能变成视频。”

“我想做一个有人设感的短视频，但没方向。”

我会先判断这份材料最适合走哪条路：资讯、观点、方法，还是故事。
如果材料够，我会直接往下做；如果还差关键内容，我只问最有价值的一两个问题。
最后目标不是写一篇文章，而是做出一条 有价值、有你本人位置、能直接开拍的 60-90 秒人设短视频。🎥''';

const _desktopVideoAnalysisAgentOpening = '''你好，我可以陪你一起看视频、拆结构，也可以先聊你的判断。

发视频链接、上传视频，或者直接说你想解决的问题都可以。只有答案确实依赖画面和声音时，我才会读取视频；读取完成后，我会结合你的问题继续判断，而不是把工具底稿原样丢给你。''';

const _desktopLeadAgentOpening = '''你好，欢迎来到花火 AI。🎯

这里可以一起判断：你现在最值得先做哪一个获客选题，应该对谁讲、从哪个真实问题切入，才能让内容既有人愿意看，也能自然靠近你的业务。

你不用先准备完整资料。可以直接说说：

你这次具体想推广什么产品或服务？

你最想吸引哪一类客户？他们现在最常卡在哪里？

你现在有哪些真实案例、现场、结果或客户问题可以讲？

你已经想过但拿不准的选题是什么？

我会根据你补充的事实，逐步收敛一个最值得先验证的获客选题。''';

final class _DesktopChatResourceImage extends StatefulWidget {
  const _DesktopChatResourceImage({
    required this.cache,
    required this.attachment,
    super.key,
  });

  final DesktopResourceImageCache cache;
  final DesktopChatImageAttachment attachment;

  @override
  State<_DesktopChatResourceImage> createState() =>
      _DesktopChatResourceImageState();
}

final class _DesktopChatResourceImageState
    extends State<_DesktopChatResourceImage> {
  late Future<DesktopCachedResourceImage> _image;

  @override
  void initState() {
    super.initState();
    _image = widget.cache.load(widget.attachment.resourceId);
  }

  @override
  void didUpdateWidget(covariant _DesktopChatResourceImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache ||
        oldWidget.attachment.resourceId != widget.attachment.resourceId) {
      _image = widget.cache.load(widget.attachment.resourceId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FutureBuilder<DesktopCachedResourceImage>(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Container(
            height: 170,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(HuahuoRadii.control),
            ),
            child: const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
          );
        }
        final image = snapshot.data;
        if (snapshot.hasError || image == null) {
          return Container(
            height: 96,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(HuahuoRadii.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.imageOff,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  '图片暂时无法加载',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth.clamp(0, 720.0).toDouble()
                : 720.0;
            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 480),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(HuahuoRadii.control),
                child: Image.memory(
                  image.bytes,
                  width: width,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => Container(
                    height: 96,
                    alignment: Alignment.center,
                    color: colors.surfaceContainerLow,
                    child: Text(
                      '图片无法显示',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

final class _DesktopProfileAvatar extends StatefulWidget {
  const _DesktopProfileAvatar({
    required this.cache,
    required this.resourceId,
    required this.fallback,
  });

  final DesktopResourceImageCache cache;
  final String resourceId;
  final Widget fallback;

  @override
  State<_DesktopProfileAvatar> createState() => _DesktopProfileAvatarState();
}

final class _DesktopProfileAvatarState extends State<_DesktopProfileAvatar> {
  late Future<DesktopCachedResourceImage> _image;

  @override
  void initState() {
    super.initState();
    _image = widget.cache.load(widget.resourceId);
  }

  @override
  void didUpdateWidget(covariant _DesktopProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache ||
        oldWidget.resourceId != widget.resourceId) {
      _image = widget.cache.load(widget.resourceId);
    }
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<DesktopCachedResourceImage>(
        future: _image,
        builder: (context, snapshot) {
          final image = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done ||
              image == null) {
            return widget.fallback;
          }
          return ClipOval(
            child: Image.memory(
              image.bytes,
              width: 60,
              height: 60,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) => widget.fallback,
            ),
          );
        },
      );
}

final class _ChatContextItem {
  const _ChatContextItem({
    required this.id,
    required this.title,
    required this.source,
    this.payload,
  });

  final String id;
  final String title;
  final String source;
  final String? payload;
}

final class _CaptureRecord {
  const _CaptureRecord({
    required this.id,
    required this.title,
    required this.detail,
    required this.mode,
    this.recordingId,
    this.noteId,
    this.isRunning = false,
  });

  final String id;
  final String title;
  final String detail;
  final _CaptureMode mode;
  final String? recordingId;
  final String? noteId;
  final bool isRunning;
}

final class _ExternalKnowledgeItem {
  const _ExternalKnowledgeItem({
    required this.id,
    required this.title,
    required this.detail,
    required this.kind,
    required this.summary,
    this.subscribed = false,
    this.topics = const <String>[],
    this.sourceLabel = '知识广场',
    this.author = '花火知识共创者',
    this.subscriberCount = 0,
    this.updatedLabel = '今天',
    this.publicationId,
    this.articleId,
    this.currentArticleRevisionId,
  });

  final String id;
  final String title;
  final String detail;
  final IconData kind;
  final String summary;
  final bool subscribed;
  final List<String> topics;
  final String sourceLabel;
  final String author;
  final int subscriberCount;
  final String updatedLabel;
  final String? publicationId;
  final String? articleId;
  final String? currentArticleRevisionId;

  bool get isRemoteArticle =>
      publicationId != null &&
      articleId != null &&
      currentArticleRevisionId != null;

  _ExternalKnowledgeItem copyWith({
    bool? subscribed,
    List<String>? topics,
    String? sourceLabel,
    String? summary,
  }) => _ExternalKnowledgeItem(
    id: id,
    title: title,
    detail: detail,
    kind: kind,
    summary: summary ?? this.summary,
    subscribed: subscribed ?? this.subscribed,
    topics: topics ?? this.topics,
    sourceLabel: sourceLabel ?? this.sourceLabel,
    author: author,
    subscriberCount: subscriberCount,
    updatedLabel: updatedLabel,
    publicationId: publicationId,
    articleId: articleId,
    currentArticleRevisionId: currentArticleRevisionId,
  );
}

final class _RemoteSubscriptionSnapshot {
  const _RemoteSubscriptionSnapshot({
    required this.publications,
    required this.library,
    required this.articles,
  });

  final List<SharedSubscriptionPublication> publications;
  final List<SharedSubscriptionLibraryPublication> library;
  final List<SharedSubscriptionArticle> articles;
}

class EditorWorkspace extends StatefulWidget {
  const EditorWorkspace({
    required this.documentStore,
    required this.themeMode,
    required this.palette,
    required this.onThemeModeChanged,
    required this.onPaletteChanged,
    required this.authPort,
    required this.assetsPort,
    required this.documentSyncPort,
    required this.documentMediaStore,
    required this.graphPreferencesStore,
    this.documentImporter = const UnavailableDesktopDocumentImportPort(),
    this.rawNoteCreator = const UnavailableDesktopRawNoteCreator(),
    required this.chatPort,
    required this.demoMode,
    this.chatRecoveryStore = const UnavailableDesktopChatRecoveryStore(),
    this.chatNoteCreator = const UnavailableDesktopChatNoteCreator(),
    this.resourceImageCache = const UnavailableDesktopResourceImageCache(),
    this.workspacePort = const UnavailableDesktopApiDomains(),
    this.catalogPort = const UnavailableDesktopApiDomains(),
    this.subscriptionPort = const UnavailableDesktopApiDomains(),
    this.accountUsagePort = const UnavailableDesktopApiDomains(),
    this.bookWorkPort = const UnavailableDesktopBookWorkPort(),
    this.topicsPort = const UnavailableDesktopTopicsPort(),
    this.topicsCache = const UnavailableDesktopTopicsCache(),
    this.notificationsPort = const UnavailableDesktopNotificationsPort(),
    this.recordingsPort = const UnavailableDesktopRecordingsPort(),
    this.recordingLibraryRepository =
        const UnavailableProductRecordingsRepository(),
    this.activityCalendarPort = const UnavailableDesktopActivityCalendarPort(),
    this.workspaceManagementRepository =
        const UnavailableWorkspaceManagementRepository(),
    this.homeRepository = const UnavailableProductHomeRepository(),
    this.supportRepository = const UnavailableProductSupportRepository(),
    this.creationsRepository = const UnavailableProductCreationsRepository(),
    this.proposalsRepository =
        const UnavailableProductDocumentProposalsRepository(),
    this.digitalTwinRepository =
        const UnavailableProductDigitalTwinRepository(),
    this.incomingDocumentPaths = const <String>[],
    this.initialLocation = '/brain',
    this.featureEntries = const <FeatureEntry>[],
    this.onNavigateLocation,
    super.key,
  });

  final DocumentStore documentStore;
  final ThemeMode themeMode;
  final DesktopAccentPalette palette;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ValueChanged<DesktopAccentPalette> onPaletteChanged;
  final DesktopGraphPreferencesStore graphPreferencesStore;
  final DesktopAuthPort authPort;
  final DesktopAssetsPort assetsPort;
  final DesktopDocumentSyncPort documentSyncPort;
  final DesktopDocumentImportPort documentImporter;
  final DesktopRawNoteCreator rawNoteCreator;
  final DesktopChatPort chatPort;
  final DesktopChatRecoveryStore chatRecoveryStore;
  final DesktopChatNoteCreator chatNoteCreator;
  final DesktopResourceImageCache resourceImageCache;
  final DesktopWorkspacePort workspacePort;
  final DesktopCatalogPort catalogPort;
  final DesktopSubscriptionPort subscriptionPort;
  final DesktopAccountUsagePort accountUsagePort;
  final DesktopBookWorkPort bookWorkPort;
  final DesktopTopicsPort topicsPort;
  final DesktopTopicsCache topicsCache;
  final DesktopNotificationsPort notificationsPort;
  final DesktopRecordingsPort recordingsPort;
  final ProductRecordingsRepository recordingLibraryRepository;
  final DesktopActivityCalendarPort activityCalendarPort;
  final WorkspaceManagementRepository workspaceManagementRepository;
  final ProductHomeRepository homeRepository;
  final ProductSupportRepository supportRepository;
  final ProductCreationsRepository creationsRepository;
  final ProductDocumentProposalsRepository proposalsRepository;
  final ProductDigitalTwinRepository digitalTwinRepository;
  final DocumentMediaStore documentMediaStore;
  final List<String> incomingDocumentPaths;
  final bool demoMode;
  final String initialLocation;
  final List<FeatureEntry> featureEntries;
  final ValueChanged<String>? onNavigateLocation;

  @override
  State<EditorWorkspace> createState() => _EditorWorkspaceState();
}

class _EditorWorkspaceState extends State<EditorWorkspace> {
  late List<HuahuoDocumentSnapshot> _documents;
  late HuahuoEditorController _editor;
  late final DesktopAgentController _agentController;
  late final DesktopBookWorkController _bookWorkController;
  late final DesktopChatTaskTracker _chatTaskTracker;
  late final DesktopNotificationsController _notificationsController;
  late final DesktopActivityCalendarController _activityCalendarController;
  late final WorkspaceManagementController _workspaceManagementController;
  late final ProductHomeController _homeController;
  DocumentMediaStore get _documentMediaStore => widget.documentMediaStore;
  final FocusNode _bodyFocus = FocusNode(debugLabel: 'desktop-editor-body');
  final FocusNode _chatFocus = FocusNode(debugLabel: 'desktop-chat-composer');
  final ScrollController _bodyScroll = ScrollController();
  final TextEditingController _chatInput = TextEditingController();
  final TextEditingController _searchInput = TextEditingController();
  final TextEditingController _externalSearchInput = TextEditingController();
  final TextEditingController _knowledgeSquareSearchInput =
      TextEditingController();
  final TextEditingController _captureTextInput = TextEditingController();
  final TextEditingController _captureImportInput = TextEditingController();
  bool _documentImporting = false;
  bool _drainingIncomingDocuments = false;
  final List<String> _pendingIncomingDocumentPaths = <String>[];
  StreamSubscription<Object?>? _incomingDocumentSubscription;
  bool _captureTextSaving = false;
  bool _linkCaptureSaving = false;
  Timer? _workspaceSearchDebounce;
  Timer? _workspaceStatusPoll;
  Timer? _topicCollisionPoll;
  final List<_AiMessage> _chatMessages = <_AiMessage>[
    const _AiMessage(text: '想写什么、整理什么，直接告诉我。你也可以引用知识库里的材料。', fromUser: false),
  ];

  bool _loading = true;
  bool _sidebarExpanded = true;
  bool _showNoteDrafts = true;
  bool _contextPanelOpen = false;
  bool _chatRailCollapsed = false;
  bool _generating = false;
  _PrimaryWorkspaceMode? _generatingMode;
  bool _focusMode = false;
  _PrimaryWorkspaceMode _primaryMode = _PrimaryWorkspaceMode.creation;
  _ContextKind _contextKind = _ContextKind.outline;
  _DocumentWorkspaceView _documentWorkspaceView =
      _DocumentWorkspaceView.writing;
  _WorkspaceSection _activeSection = _WorkspaceSection.brain;
  final List<_WorkspaceTab> _tabs = <_WorkspaceTab>[
    const _WorkspaceTab(
      id: 'graph',
      title: '思想图谱',
      kind: _WorkspaceTabKind.graph,
      section: _WorkspaceSection.brain,
    ),
  ];
  String _activeTabId = 'graph';
  final Set<String> _expandedFolders = <String>{'我的创作', '最新创作', '我的会议', '我的订阅'};
  final List<String> _customFolders = <String>[];
  final Set<String> _depositedExternalKnowledge = <String>{};
  final Set<String> _savedSubscriptionArticleRevisions = <String>{};
  // Explicitly added material remains until the user removes it. Dynamic focus
  // lives in the two slots below so browsing never turns into an ever-growing
  // context list.
  final List<_ChatContextItem> _chatContexts = <_ChatContextItem>[];
  final Map<String, _ChatContextItem> _referenceContexts =
      <String, _ChatContextItem>{};
  _ChatContextItem? _focusedDocumentContext;
  _ChatContextItem? _focusedSelectionContext;
  final List<_ExternalKnowledgeItem> _externalKnowledgeItems =
      <_ExternalKnowledgeItem>[
        const _ExternalKnowledgeItem(
          id: 'industry-weekly',
          title: '行业研究周报',
          detail: 'PDF · 24 页 · 已解析',
          kind: LucideIcons.fileText,
          summary: '本周内容行业的渠道变化、平台规则和可复用案例摘要。',
          topics: <String>['行业', '社科', '社会'],
          sourceLabel: 'PDF 文档',
          author: '内容研究共创组',
          subscriberCount: 1842,
          updatedLabel: '今天',
        ),
        const _ExternalKnowledgeItem(
          id: 'customer-interview',
          title: '客户访谈原文',
          detail: '链接 · 8 段访谈 · 可引用',
          kind: LucideIcons.link,
          summary: '围绕购买动机、真实阻碍和替代方案整理的访谈原话。',
          subscribed: true,
          topics: <String>['访谈', '音频', '声音'],
          sourceLabel: '链接采集',
          author: '用户声音计划',
          subscriberCount: 926,
          updatedLabel: '昨天',
        ),
        const _ExternalKnowledgeItem(
          id: 'creator-cases',
          title: '创作者案例库',
          detail: '网页采集 · 32 条案例',
          kind: LucideIcons.bookOpenText,
          summary: '来自创作者社区的选题、表达方式与数据复盘。',
          subscribed: true,
          topics: <String>['创作者', '艺术', '表达'],
          sourceLabel: '网页采集',
          author: '创作者案例共创组',
          subscriberCount: 2168,
          updatedLabel: '7 月 26 日',
        ),
        const _ExternalKnowledgeItem(
          id: 'launch-material',
          title: '产品发布资料',
          detail: '演示文稿 · 17 个文件',
          kind: LucideIcons.presentation,
          summary: '产品定位、发布节奏和原始视觉资料的集合。',
          topics: <String>['产品', '品牌', '文创'],
          sourceLabel: '演示文稿',
          author: '产品叙事档案',
          subscriberCount: 713,
          updatedLabel: '7 月 25 日',
        ),
        const _ExternalKnowledgeItem(
          id: 'city-walks',
          title: '城市漫游里的日常观察',
          detail: '图文专栏 · 12 篇文章',
          kind: LucideIcons.building2,
          summary: '从街区、空间与日常细节中提炼可写作的感受和观察。',
          topics: <String>['城市', '漫游', '空间'],
          sourceLabel: '图文专栏',
          author: '城市观察共创组',
          subscriberCount: 1260,
          updatedLabel: '7 月 24 日',
        ),
        const _ExternalKnowledgeItem(
          id: 'bookshop-notes',
          title: '独立书店的选书方法',
          detail: '知识卡片 · 18 条笔记',
          kind: LucideIcons.libraryBig,
          summary: '书店经营者如何建立选书判断，以及它如何影响内容品味。',
          topics: <String>['书店', '阅读', '书籍'],
          sourceLabel: '知识卡片',
          author: '阅读与书店计划',
          subscriberCount: 1584,
          updatedLabel: '7 月 22 日',
        ),
        const _ExternalKnowledgeItem(
          id: 'museum-objects',
          title: '一件器物如何讲述历史',
          detail: '展览笔记 · 9 个章节',
          kind: LucideIcons.landmark,
          summary: '从器物、展陈和叙事结构中理解历史内容的表达方法。',
          topics: <String>['博物', '器物', '展览', '历史'],
          sourceLabel: '展览笔记',
          author: '博物馆知识共创组',
          subscriberCount: 2046,
          updatedLabel: '7 月 20 日',
        ),
      ];
  _CaptureMode _captureMode = _CaptureMode.monologue;
  final List<_CaptureRecord> _captureRecords = <_CaptureRecord>[];
  final Set<String> _recordingProgressPolls = <String>{};
  String? _latestChatAnswer;
  String? _selectedContentTitle;
  String? _selectedContentId;
  String? _selectedContentSource;
  String? _selectedContentPayload;
  int _activeAssetSection = 0;
  _AssetSourceFilter _assetSourceFilter = _AssetSourceFilter.all;
  int _activeKnowledgeAssetCategory = 0;
  String _activeProject = '个人创作';
  _ExternalKnowledgeView _externalKnowledgeView = _ExternalKnowledgeView.square;
  _KnowledgeSquareCategory _knowledgeSquareCategory =
      _KnowledgeSquareCategory.all;
  bool _showAllKnowledgeSquareUpdates = false;
  bool _selectionContextScheduled = false;
  _SettingsSection _settingsSection = _SettingsSection.appearance;
  bool _accountSignedIn = false;
  bool _workspacePreparing = false;
  bool _workspaceStatusRefreshing = false;
  bool _workspaceRetrying = false;
  String? _workspacePreparationError;
  DesktopAuthAccount? _workspaceAccount;
  String? _activeWorkspaceId;
  ProductCreationDocument? _proposalCreation;
  String _accountName = '花火创作者';
  String? _accountAvatarResourceId;
  DesktopServiceResult<ApiContractPage>? _workspaceFoldersResult;
  DesktopServiceResult<AgentProfileCatalog>? _catalogResult;
  DesktopServiceResult<_RemoteSubscriptionSnapshot>? _subscriptionLoadResult;
  DesktopServiceResult<SharedAccountMembershipResponse>? _membershipResult;
  DesktopServiceResult<SharedAccountCreditSummary>? _creditsResult;
  DesktopServiceResult<SharedRunUsage>? _runUsageResult;
  DesktopServiceResult<DesktopAgentFeatureSelection>? _sproutFeatureResult;
  DesktopServiceResult<SharedWorkspaceSearchOutput>? _workspaceSearchResult;
  DesktopServiceResult<SharedNoteRelationPage>? _noteRelationsResult;
  DesktopServiceResult<SharedBook>? _bookResult;
  DesktopServiceResult<List<SharedWork>>? _worksResult;
  DesktopServiceResult<SharedWork>? _workDetailResult;
  DesktopServiceResult<DailyTopicRecommendation>? _dailyTopicResult;
  bool _dailyTopicLoading = false;
  DateTime? _dailyTopicExpiresAt;
  String? _selectedDailyTopicId;
  bool _dailyTopicUsing = false;
  bool _dailyTopicDismissing = false;
  TopicCollisionRun? _topicCollisionRun;
  bool _topicCollisionPolling = false;
  String? _topicCollisionError;
  String? _activeDailyTopicTitle;
  final Map<String, String> _dailyTopicContextByThread = <String, String>{};
  bool _bookLoading = false;
  bool _worksLoading = false;
  bool _workDetailLoading = false;
  final Set<String> _bookWorkMutations = <String>{};
  bool _workspaceSearchLoading = false;
  bool _noteRelationsLoading = false;
  int _workspaceSearchSequence = 0;
  int _noteRelationsSequence = 0;
  final Set<String> _workspaceSearchPartLoads = <String>{};
  final Set<String> _noteRelationMutations = <String>{};
  final Map<String, String> _noteRelationActionKeys = <String, String>{};
  int _noteRelationMutationSequence = 0;
  bool _authLoading = true;
  DesktopServiceResult<DesktopAuthAccount?>? _authResult;
  DesktopServiceResult<DesktopAssetOverview>? _assetOverviewResult;
  DesktopServiceResult<DesktopAssetItem>? _assetResult;
  bool _assetsLoading = false;
  bool _assetsLoaded = false;
  DesktopServiceResult<DesktopDocumentPullBatch>? _documentPullResult;
  DesktopServiceResult<DesktopDocumentSyncState>? _documentSyncResult;
  bool _subscriptionLoading = false;
  bool _sproutGenerating = false;
  final Set<String> _subscriptionMutations = <String>{};
  final Set<String> _subscriptionArticleLoads = <String>{};
  final Set<String> _subscriptionDeposits = <String>{};
  final Map<String, String> _subscriptionActionKeys = <String, String>{};
  int _subscriptionMutationSequence = 0;
  final List<DesktopChatThread> _chatThreads = <DesktopChatThread>[];
  String? _activeChatThreadId;
  String? _newChatAgentProfileId;
  Future<DesktopServiceResult<DesktopChatThread>>? _chatThreadCreation;
  final Set<String> _chatNoteCreationIds = <String>{};
  late final Future<void> _documentsLoad;
  bool _autoSaveEnabled = true;
  bool _contextAutoAttach = true;
  bool _syncOnMeteredNetwork = false;
  bool _desktopNotifications = true;
  bool _usageAnalyticsEnabled = false;
  double _editorScale = 1;
  double _editorLineHeight = 1.76;
  late final DesktopGraphPreferencesController _graphPreferences;
  final MarkdownPreviewPreferencesController _markdownPreviewPreferences =
      MarkdownPreviewPreferencesController();
  bool _applyingExternalLocation = false;
  String? _pendingPublishedLocation;

  @override
  void initState() {
    super.initState();
    if (!widget.demoMode) _externalKnowledgeItems.clear();
    _documents = buildDesktopSeedDocuments();
    _editor = _createEditor(_documents.first);
    _agentController = DesktopAgentController(port: widget.catalogPort);
    _bookWorkController = DesktopBookWorkController(widget.bookWorkPort);
    _chatTaskTracker = DesktopChatTaskTracker(
      chatPort: widget.chatPort,
      store: widget.chatRecoveryStore,
    )..addListener(_handleChatTaskTrackerChanged);
    _notificationsController = DesktopNotificationsController(
      widget.notificationsPort,
    );
    _activityCalendarController = DesktopActivityCalendarController(
      widget.activityCalendarPort,
    );
    _workspaceManagementController = WorkspaceManagementController(
      widget.workspaceManagementRepository,
    );
    _homeController = ProductHomeController(widget.homeRepository);
    _graphPreferences = DesktopGraphPreferencesController(
      store: widget.graphPreferencesStore,
    );
    _documentsLoad = _loadDocuments();
    _pendingIncomingDocumentPaths.addAll(
      widget.incomingDocumentPaths.where(_isAbsoluteFilePath),
    );
    _incomingDocumentSubscription = _incomingDocumentEventChannel
        .receiveBroadcastStream()
        .listen(_handleIncomingDocumentEvent, onError: (_, __) {});
    unawaited(_documentsLoad);
    unawaited(_restoreAuthSession());
    unawaited(_graphPreferences.load());
    unawaited(_markdownPreviewPreferences.load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyProductLocation(widget.initialLocation);
    });
  }

  @override
  void didUpdateWidget(covariant EditorWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialLocation != widget.initialLocation) {
      if (_pendingPublishedLocation == widget.initialLocation) {
        _pendingPublishedLocation = null;
        return;
      }
      _pendingPublishedLocation = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyProductLocation(widget.initialLocation);
      });
    }
  }

  HuahuoEditorController _createEditor(HuahuoDocumentSnapshot snapshot) {
    final controller = HuahuoEditorController(
      initial: snapshot,
      onSave: _persistSnapshot,
    );
    controller.addListener(_refresh);
    controller.body.addListener(_handleEditorBodyChanged);
    return controller;
  }

  void _disposeEditor(HuahuoEditorController controller) {
    controller
      ..removeListener(_refresh)
      ..body.removeListener(_handleEditorBodyChanged)
      ..dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _handleEditorBodyChanged() {
    _refresh();
    _scheduleParagraphContextAttachment();
  }

  Future<void> _loadDocuments() async {
    List<HuahuoDocumentSnapshot> loaded;
    try {
      loaded = await widget.documentStore.loadAll();
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showSnack('本地文稿版本无法读取，原文件未被覆盖');
      });
      return;
    }
    if (!mounted) return;
    if (loaded.isEmpty) {
      for (final snapshot in _documents) {
        unawaited(widget.documentStore.save(snapshot));
      }
      setState(() => _loading = false);
      return;
    }
    final previous = _editor;
    setState(() {
      _documents = loaded;
      _editor = _createEditor(loaded.first);
      _loading = false;
    });
    _disposeEditor(previous);
  }

  Future<void> _persistSnapshot(HuahuoDocumentSnapshot snapshot) async {
    await widget.documentStore.save(snapshot);
    final index = _documents.indexWhere((item) => item.id == snapshot.id);
    if (index >= 0) {
      _documents[index] = snapshot;
    } else {
      _documents.insert(0, snapshot);
    }
    unawaited(_enqueueDocumentSync(snapshot));
    if (mounted) setState(() {});
  }

  Future<void> _enqueueDocumentSync(HuahuoDocumentSnapshot snapshot) async {
    final result = await widget.documentSyncPort.enqueue(snapshot);
    if (!mounted) return;
    setState(() => _documentSyncResult = result);
  }

  Future<DesktopServiceResult<DesktopDocumentPullBatch>>
  _pullRemoteDocuments() async {
    final result = await widget.documentSyncPort.pullRemote(
      apply: _applyRemoteDocumentPull,
    );
    if (mounted) setState(() => _documentPullResult = result);
    return result;
  }

  Future<void> _applyRemoteDocumentPull(DesktopDocumentPullBatch batch) async {
    final localById = <String, HuahuoDocumentSnapshot>{
      for (final document in _documents) document.id: document,
    };
    final remoteDocuments = <HuahuoDocumentSnapshot>[];
    for (final remote in batch.documents) {
      final merged = _mergeRemoteDocument(localById[remote.id], remote);
      await widget.documentStore.save(merged);
      remoteDocuments.add(merged);
    }
    for (final documentId in batch.deletedDocumentIds) {
      await widget.documentStore.delete(documentId);
    }
    if (!mounted) return;

    final nextById = <String, HuahuoDocumentSnapshot>{...localById};
    final remoteById = <String, HuahuoDocumentSnapshot>{
      for (final document in remoteDocuments) document.id: document,
    };
    for (final documentId in batch.deletedDocumentIds) {
      nextById.remove(documentId);
    }
    for (final remote in remoteDocuments) {
      nextById[remote.id] = remote;
    }
    final nextDocuments = nextById.values.toList(growable: true)
      ..sort((left, right) => right.modifiedAt.compareTo(left.modifiedAt));
    if (nextDocuments.isEmpty) {
      nextDocuments.addAll(buildDesktopSeedDocuments());
    }

    final currentId = _editor.snapshot.id;
    final replacement = remoteById[currentId];
    final currentDeleted = batch.deletedDocumentIds.contains(currentId);
    HuahuoEditorController? previous;
    setState(() {
      _documents = nextDocuments;
      if (replacement != null || currentDeleted) {
        previous = _editor;
        _editor = _createEditor(replacement ?? nextDocuments.first);
      }
      _tabs.removeWhere(
        (tab) =>
            tab.documentId != null &&
            batch.deletedDocumentIds.contains(tab.documentId),
      );
      if (_tabs.every((tab) => tab.id != _activeTabId)) {
        _activeTabId = 'graph';
        _activeSection = _WorkspaceSection.brain;
      }
    });
    if (previous != null) _disposeEditor(previous!);
  }

  HuahuoDocumentSnapshot _mergeRemoteDocument(
    HuahuoDocumentSnapshot? local,
    HuahuoDocumentSnapshot remote,
  ) {
    if (local == null) return remote;
    return HuahuoDocumentSnapshot(
      id: remote.id,
      title: remote.title,
      deltaJson: remote.deltaJson,
      markdownProjection: remote.markdownProjection,
      revision: remote.revision,
      createdAt: local.createdAt,
      modifiedAt: remote.modifiedAt,
      linkedMaterials: local.linkedMaterials,
      sourceTopicId: local.sourceTopicId,
      sourceTopicTitle: local.sourceTopicTitle,
      summaryMarkdown: remote.summaryMarkdown,
      sproutMarkdown: remote.sproutMarkdown,
      aiAnnotations: local.aiAnnotations,
    );
  }

  Future<void> _restoreAuthSession() async {
    final result = await widget.authPort.restoreSession();
    if (!mounted) return;
    final account = result.data;
    setState(() {
      _authLoading = false;
      _authResult = result;
      _accountSignedIn = result.isSuccess && account != null;
      if (account != null) {
        _accountName = account.displayName;
        _workspaceAccount = account;
      }
    });
    if (result.isSuccess && account != null) {
      await _activateAuthenticatedAccount(account);
      unawaited(_drainIncomingDocumentPaths());
    }
  }

  Future<void> _activateAuthenticatedAccount(DesktopAuthAccount account) async {
    if (!_isReadyWorkspaceAccount(account)) {
      await _enterWorkspacePreparation(account);
      return;
    }
    _stopWorkspaceStatusPolling();
    if (mounted) {
      setState(() {
        _workspaceAccount = account;
        _workspacePreparing = false;
        _workspacePreparationError = null;
      });
    }
    await _documentsLoad;
    if (!mounted) return;
    final workspaceId = account.workspaceId;
    if (workspaceId == null || workspaceId.trim().isEmpty) {
      await _enterWorkspacePreparation(account);
      return;
    }
    await _chatTaskTracker.bindAccount(
      userId: account.userId,
      workspaceId: workspaceId,
    );
    _notificationsController.bindAccount(account.userId);
    unawaited(_workspaceManagementController.reload());
    try {
      await widget.resourceImageCache.bindAccount(
        userId: account.userId,
        workspaceId: workspaceId,
      );
    } on Object {
      // Image cache availability must not block account activation or Chat.
    }
    unawaited(_refreshAccountProfile());
    if (!mounted) return;
    _restoreCachedChatSnapshot(_chatTaskTracker.snapshot);
    if (_activeWorkspaceId != workspaceId) _proposalCreation = null;
    _activeWorkspaceId = workspaceId;
    unawaited(_activityCalendarController.bindWorkspace(workspaceId));
    unawaited(_homeController.bindWorkspace(workspaceId));
    _agentController.bindAccount(
      userId: account.userId,
      workspaceId: workspaceId,
    );
    _bookWorkController.bindAccount(
      userId: account.userId,
      workspaceId: workspaceId,
    );
    await widget.documentSyncPort.bindAccount(
      userId: account.userId,
      workspaceId: workspaceId,
    );
    await _restoreTopicsCache(account, workspaceId);
    if (!mounted) return;
    final pull = await _pullRemoteDocuments();
    if (!mounted) return;
    if (pull.isSuccess) {
      final flush = await widget.documentSyncPort.retryPending();
      if (mounted) setState(() => _documentSyncResult = flush);
    }
    await _loadRemoteDomains(workspaceId);
    unawaited(_loadDailyTopic());
    _resumeTopicCollisionPolling();
    if (_searchInput.text.trim().isNotEmpty) {
      _scheduleWorkspaceSearch(immediate: true);
    }
    await _loadChatSession();
    unawaited(_drainIncomingDocumentPaths());
  }

  bool _isReadyWorkspaceAccount(DesktopAuthAccount account) =>
      account.workspaceStatus.trim().toLowerCase() == 'ready' &&
      account.workspaceId?.trim().isNotEmpty == true;

  bool get _workspaceIsReady {
    final account = _workspaceAccount;
    return _accountSignedIn &&
        account != null &&
        _isReadyWorkspaceAccount(account) &&
        !_workspacePreparing;
  }

  bool get _workspaceCanRetry =>
      _workspaceAccount?.workspaceStatus.trim().toLowerCase() == 'sync_failed';

  Future<void> _enterWorkspacePreparation(DesktopAuthAccount account) async {
    final resetScopes =
        !_workspacePreparing || _workspaceAccount?.userId != account.userId;
    if (resetScopes) {
      await Future.wait<void>(<Future<void>>[
        widget.documentSyncPort.clearAccount(),
        _chatTaskTracker.clearCurrentAccount(),
        widget.resourceImageCache.clearAccount(),
      ]);
      _notificationsController.clearAccount();
      _homeController.reset();
    }
    if (!mounted) return;
    setState(() {
      _workspaceAccount = account;
      _workspacePreparing = true;
      _activeWorkspaceId = null;
      _workspacePreparationError = null;
      _agentController.clearAccount();
      _bookWorkController.clearAccount();
      _sproutFeatureResult =
          const DesktopServiceResult<DesktopAgentFeatureSelection>.unavailable(
            code: 'DESKTOP_AGENT_WORKSPACE_REQUIRED',
            message: 'Workspace 正在初始化',
          );
    });
    if (_workspaceCanRetry) {
      _stopWorkspaceStatusPolling();
    } else {
      _startWorkspaceStatusPolling();
    }
  }

  void _startWorkspaceStatusPolling() {
    if (_workspaceStatusPoll != null) return;
    _workspaceStatusPoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshWorkspaceStatus()),
    );
    unawaited(_refreshWorkspaceStatus());
  }

  void _stopWorkspaceStatusPolling() {
    _workspaceStatusPoll?.cancel();
    _workspaceStatusPoll = null;
  }

  Future<void> _refreshWorkspaceStatus() async {
    if (_workspaceStatusRefreshing ||
        !_workspacePreparing ||
        _workspaceCanRetry) {
      return;
    }
    if (mounted) setState(() => _workspaceStatusRefreshing = true);
    final result = await widget.authPort.restoreSession();
    if (!mounted) return;
    final account = result.data;
    setState(() {
      _workspaceStatusRefreshing = false;
      if (!result.isSuccess || account == null) {
        _workspacePreparationError = result.message;
        return;
      }
      _authResult = result;
      _accountSignedIn = true;
      _accountName = account.displayName;
      _workspaceAccount = account;
    });
    if (result.isSuccess && account != null) {
      await _activateAuthenticatedAccount(account);
    }
  }

  Future<void> _retryWorkspacePreparation() async {
    if (_workspaceRetrying || !_workspaceCanRetry) return;
    final account = _workspaceAccount;
    setState(() {
      _workspaceRetrying = true;
      _workspacePreparationError = null;
    });
    final result = await widget.authPort.retryWorkspaceCreation();
    if (!mounted) return;
    setState(() {
      _workspaceRetrying = false;
      if (!result.isSuccess) _workspacePreparationError = result.message;
    });
    if (!result.isSuccess) return;
    if (account != null && mounted) {
      setState(() {
        _workspaceAccount = DesktopAuthAccount(
          userId: account.userId,
          displayName: account.displayName,
          workspaceStatus: 'creating',
          workspaceId: account.workspaceId,
        );
      });
    }
    _startWorkspaceStatusPolling();
    await _refreshWorkspaceStatus();
  }

  Future<void> _refreshAccountProfile() async {
    final profile = await widget.authPort.loadProfile();
    if (!mounted || !profile.isSuccess) return;
    final next = profile.data!;
    if (next.displayName == _accountName &&
        next.avatarResourceId == _accountAvatarResourceId) {
      return;
    }
    setState(() {
      _accountName = next.displayName;
      _accountAvatarResourceId = next.avatarResourceId;
    });
  }

  Future<void> _loadRemoteDomains(String workspaceId) async {
    if (mounted) setState(() => _subscriptionLoading = true);
    final folders = widget.workspacePort.loadFolders(workspaceId);
    final catalog = widget.catalogPort.loadProfiles();
    final subscriptions = _fetchRemoteSubscriptions(workspaceId);
    final membership = widget.accountUsagePort.loadMembership();
    final credits = _loadCreditSummary();
    final sproutFeature = _agentController.resolveFeature('note.sprout');
    final results = await (
      folders,
      catalog,
      subscriptions,
      membership,
      credits,
      sproutFeature,
    ).wait;
    if (!mounted) return;
    setState(() {
      _workspaceFoldersResult = results.$1;
      _catalogResult = results.$2;
      _subscriptionLoading = false;
      _subscriptionLoadResult = results.$3;
      if (results.$3.isSuccess) {
        _externalKnowledgeItems
          ..clear()
          ..addAll(_subscriptionItems(results.$3.data!));
      } else if (!widget.demoMode) {
        _externalKnowledgeItems.clear();
      }
      _membershipResult = results.$4;
      _creditsResult = results.$5;
      _sproutFeatureResult = results.$6;
    });
  }

  Future<void> _restoreTopicsCache(
    DesktopAuthAccount account,
    String workspaceId,
  ) async {
    try {
      final snapshot = await widget.topicsCache.load(
        userId: account.userId,
        workspaceId: workspaceId,
      );
      if (!mounted) return;
      final recommendation = snapshot.dailyRecommendation;
      final collisionRun = snapshot.topicCollisionRun;
      setState(() {
        if (recommendation != null &&
            recommendation.workspaceId == workspaceId) {
          _dailyTopicResult =
              DesktopServiceResult<DailyTopicRecommendation>.success(
                recommendation,
              );
          _dailyTopicExpiresAt = snapshot.dailyExpiresAt;
          _selectedDailyTopicId ??= recommendation.topics.firstOrNull?.topicId;
        }
        _dailyTopicContextByThread.addAll(snapshot.dailyTopicContextsByThread);
        if (collisionRun != null) _topicCollisionRun = collisionRun;
      });
    } on Object {
      // A malformed optimization cache cannot block formal Workspace reads.
    }
  }

  bool get _hasFreshDailyTopic {
    final expiresAt = _dailyTopicExpiresAt;
    return _dailyTopicResult?.isSuccess == true &&
        expiresAt != null &&
        DateTime.now().toUtc().isBefore(expiresAt);
  }

  Future<void> _loadDailyTopic({bool force = false}) async {
    final workspaceId = _activeWorkspaceId;
    if (!_workspaceIsReady || workspaceId == null || _dailyTopicLoading) return;
    if (!force && _hasFreshDailyTopic) return;
    setState(() => _dailyTopicLoading = true);
    final result = await widget.topicsPort.listDailyTopics(workspaceId);
    if (!mounted) return;
    final page = result.data;
    if (!result.isSuccess || page == null) {
      setState(() {
        _dailyTopicLoading = false;
        if (_dailyTopicResult?.isSuccess != true) {
          _dailyTopicResult =
              DesktopServiceResult<DailyTopicRecommendation>.failure(
                code: result.code,
                message: result.message,
                retryable: result.retryable,
              );
        }
      });
      return;
    }
    final recommendation = _selectDailyRecommendation(page.items);
    setState(() {
      _dailyTopicLoading = false;
      _dailyTopicExpiresAt = DateTime.now().toUtc().add(
        const Duration(minutes: 5),
      );
      _dailyTopicResult = recommendation == null
          ? const DesktopServiceResult<DailyTopicRecommendation>.failure(
              code: 'DAILY_TOPIC_EMPTY',
              message: '今日暂无可用选题',
            )
          : DesktopServiceResult<DailyTopicRecommendation>.success(
              recommendation,
            );
      if (recommendation != null) {
        _selectedDailyTopicId ??= recommendation.topics.firstOrNull?.topicId;
      }
    });
    unawaited(_persistTopicsCache());
  }

  DailyTopicRecommendation? _selectDailyRecommendation(
    Iterable<DailyTopicRecommendation> items,
  ) {
    final ready = items.where((item) => item.isReady).toList(growable: false)
      ..sort((left, right) {
        final date = right.businessDate.compareTo(left.businessDate);
        if (date != 0) return date;
        return (right.generatedAt?.millisecondsSinceEpoch ?? 0).compareTo(
          left.generatedAt?.millisecondsSinceEpoch ?? 0,
        );
      });
    for (final item in ready) {
      if (item.recommendationKind == 'daily_topic_report') return item;
    }
    return ready.firstOrNull;
  }

  Future<void> _openDailyTopicWorkspace() async {
    if (!_workspaceIsReady) {
      _showSnack('Workspace 正在准备，暂时无法读取每日推荐');
      return;
    }
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.tools;
      _contextPanelOpen = false;
      _upsertTab(
        const _WorkspaceTab(
          id: 'daily-topic',
          title: '今日推送',
          kind: _WorkspaceTabKind.feature,
          section: _WorkspaceSection.tools,
        ),
      );
    });
    await _loadDailyTopic();
    await _readDailyTopicDetail();
  }

  Future<void> _readDailyTopicDetail() async {
    final workspaceId = _activeWorkspaceId;
    final recommendation = _dailyTopicResult?.data;
    if (!_workspaceIsReady || workspaceId == null || recommendation == null) {
      return;
    }
    final detail = await widget.topicsPort.getDailyTopic(
      workspaceId,
      recommendation.recommendationId,
    );
    if (!mounted || !detail.isSuccess || detail.data == null) return;
    var current = detail.data!;
    if (current.readAt == null) {
      final marked = await _markDesktopDailyTopicRead(workspaceId, current);
      if (!mounted) return;
      if (marked != null) current = marked;
    }
    if (!mounted) return;
    setState(() {
      _dailyTopicResult =
          DesktopServiceResult<DailyTopicRecommendation>.success(current);
      _dailyTopicExpiresAt = DateTime.now().toUtc().add(
        const Duration(minutes: 5),
      );
      _selectedDailyTopicId ??= current.topics.firstOrNull?.topicId;
    });
    unawaited(_persistTopicsCache());
  }

  Future<DailyTopicRecommendation?> _markDesktopDailyTopicRead(
    String workspaceId,
    DailyTopicRecommendation recommendation,
  ) async {
    var current = recommendation;
    final idempotencyKey =
        'desktop-daily-topic-read-${recommendation.recommendationId}-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final marked = await widget.topicsPort.markDailyTopicRead(
        workspaceId,
        current.recommendationId,
        etag: current.etag,
        idempotencyKey: idempotencyKey,
      );
      if (marked.isSuccess && marked.data != null) return marked.data!;
      if (attempt == 0 && _isDailyTopicEtagConflict(marked.code)) {
        final reread = await widget.topicsPort.getDailyTopic(
          workspaceId,
          current.recommendationId,
        );
        if (!reread.isSuccess || reread.data == null) break;
        current = reread.data!;
        if (current.readAt != null) return current;
        continue;
      }
      _showSnack(marked.message.isEmpty ? '无法更新每日推荐状态' : marked.message);
      return null;
    }
    _showSnack('每日推荐状态已变化，请重新打开后再试');
    return null;
  }

  bool _isDailyTopicEtagConflict(String code) =>
      code == 'PRECONDITION_FAILED' ||
      code == 'HTTP_412' ||
      code == 'PRECONDITION_REQUIRED';

  Future<void> _useDailyTopic() async {
    if (_dailyTopicUsing || _dailyTopicDismissing || !_workspaceIsReady) {
      return;
    }
    final workspaceId = _activeWorkspaceId;
    final recommendation = _dailyTopicResult?.data;
    if (workspaceId == null || recommendation == null) return;
    final topic =
        recommendation.topics
            .where((item) => item.topicId == _selectedDailyTopicId)
            .firstOrNull ??
        recommendation.topics.firstOrNull;
    if (topic == null) return;
    setState(() => _dailyTopicUsing = true);
    final result = await widget.topicsPort.useDailyTopic(
      workspaceId,
      recommendation.recommendationId,
      topicId: topic.topicId,
      idempotencyKey:
          'desktop-daily-topic-use-${recommendation.recommendationId}-${topic.topicId}-${DateTime.now().toUtc().microsecondsSinceEpoch}',
    );
    if (!mounted) return;
    setState(() => _dailyTopicUsing = false);
    if (!result.isSuccess || result.data == null) {
      _showSnack(result.message);
      return;
    }
    setState(() {
      final title = _dailyTopicContextByThread.putIfAbsent(
        result.data!.threadId,
        () => topic.title,
      );
      _activeDailyTopicTitle = title;
    });
    unawaited(_persistTopicsCache());
    await _openRemoteChatThread(result.data!.threadId);
    if (!mounted) return;
    _showSnack('已打开选题对话，输入消息后才会开始分析');
  }

  Future<void> _dismissDailyTopic() async {
    if (_dailyTopicUsing || _dailyTopicDismissing || !_workspaceIsReady) {
      return;
    }
    final workspaceId = _activeWorkspaceId;
    final recommendation = _dailyTopicResult?.data;
    if (workspaceId == null || recommendation == null) return;
    setState(() => _dailyTopicDismissing = true);
    final dismissed = await _dismissDesktopDailyTopic(
      workspaceId,
      recommendation,
    );
    if (!mounted) return;
    setState(() => _dailyTopicDismissing = false);
    if (!dismissed) return;
    setState(() {
      _dailyTopicResult = null;
      _dailyTopicExpiresAt = null;
      _selectedDailyTopicId = null;
    });
    await _persistTopicsCache();
    if (!mounted) return;
    unawaited(_loadDailyTopic(force: true));
    _showSnack('已忽略今日推送');
  }

  Future<bool> _dismissDesktopDailyTopic(
    String workspaceId,
    DailyTopicRecommendation recommendation,
  ) async {
    var current = recommendation;
    final idempotencyKey =
        'desktop-daily-topic-dismiss-${recommendation.recommendationId}-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final dismissed = await widget.topicsPort.dismissDailyTopic(
        workspaceId,
        current.recommendationId,
        etag: current.etag,
        idempotencyKey: idempotencyKey,
      );
      if (dismissed.isSuccess) return true;
      if (attempt == 0 && _isDailyTopicEtagConflict(dismissed.code)) {
        final reread = await widget.topicsPort.getDailyTopic(
          workspaceId,
          current.recommendationId,
        );
        if (!reread.isSuccess || reread.data == null) break;
        current = reread.data!;
        if (!current.isReady) return true;
        continue;
      }
      _showSnack(dismissed.message.isEmpty ? '无法忽略今日推送' : dismissed.message);
      return false;
    }
    _showSnack('每日推荐状态已变化，请重新打开后再试');
    return false;
  }

  Future<void> _startTopicCollision() async {
    final workspaceId = _activeWorkspaceId;
    if (!_workspaceIsReady || workspaceId == null) {
      _showSnack('Workspace 正在准备，暂时不能聚合');
      return;
    }
    final current = _topicCollisionRun;
    if (current != null && !current.isTerminal) {
      _showSnack('聚合任务仍在运行');
      return;
    }
    setState(() {
      _topicCollisionError = null;
      _topicCollisionPolling = true;
    });
    final result = await widget.topicsPort.createTopicCollision(
      workspaceId,
      idempotencyKey:
          'desktop-topic-collision-${DateTime.now().toUtc().microsecondsSinceEpoch}',
    );
    if (!mounted) return;
    if (!result.isSuccess ||
        result.data == null ||
        result.data!.selectedNoteCount != 4) {
      setState(() {
        _topicCollisionPolling = false;
        _topicCollisionError = result.isSuccess
            ? 'TOPIC_COLLISION_SOURCE_COUNT_INVALID'
            : result.code;
      });
      _showSnack(result.isSuccess ? '聚合来源不符合要求' : result.message);
      return;
    }
    setState(() {
      _topicCollisionRun = result.data;
      _topicCollisionPolling = false;
    });
    unawaited(_persistTopicsCache());
    _resumeTopicCollisionPolling();
  }

  void _resumeTopicCollisionPolling() {
    if (!_workspaceIsReady ||
        _topicCollisionRun == null ||
        _topicCollisionRun!.isTerminal ||
        _topicCollisionPoll != null) {
      return;
    }
    _topicCollisionPoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollTopicCollision()),
    );
    unawaited(_pollTopicCollision());
  }

  void _stopTopicCollisionPolling() {
    _topicCollisionPoll?.cancel();
    _topicCollisionPoll = null;
  }

  Future<void> _pollTopicCollision() async {
    if (_topicCollisionPolling || !_workspaceIsReady) return;
    final workspaceId = _activeWorkspaceId;
    final runId = _topicCollisionRun?.topicCollisionRunId;
    if (workspaceId == null || runId == null) return;
    setState(() => _topicCollisionPolling = true);
    try {
      final result = await widget.topicsPort.getTopicCollision(
        workspaceId,
        runId,
      );
      if (!mounted || !result.isSuccess || result.data == null) return;
      final run = result.data!;
      if (run.topicCollisionRunId != runId) return;
      if (!run.isTerminal) {
        setState(() => _topicCollisionRun = run);
        unawaited(_persistTopicsCache());
        return;
      }
      if (!run.isSuccessful || run.outputNoteId == null) {
        setState(() {
          _topicCollisionRun = run;
          _topicCollisionError = run.failureCode ?? 'TOPIC_COLLISION_FAILED';
        });
        _stopTopicCollisionPolling();
        unawaited(_persistTopicsCache());
        return;
      }
      final pull = await _pullRemoteDocuments();
      if (!mounted || !pull.isSuccess) return;
      setState(() {
        _topicCollisionRun = run;
        _topicCollisionError = null;
      });
      _stopTopicCollisionPolling();
      unawaited(_persistTopicsCache(clearCollision: true));
      _showSnack('聚合内容已写入资产');
    } finally {
      if (mounted) setState(() => _topicCollisionPolling = false);
    }
  }

  Future<void> _persistTopicsCache({bool clearCollision = false}) async {
    final account = _workspaceAccount;
    final workspaceId = _activeWorkspaceId;
    if (account == null || workspaceId == null || !_workspaceIsReady) return;
    try {
      await widget.topicsCache.save(
        userId: account.userId,
        workspaceId: workspaceId,
        snapshot: DesktopTopicsCacheSnapshot(
          dailyRecommendation: _dailyTopicResult?.data,
          dailyExpiresAt: _dailyTopicExpiresAt,
          dailyTopicContextsByThread: _dailyTopicContextByThread,
          topicCollisionRun: clearCollision
              ? null
              : _topicCollisionRun?.isTerminal == false
              ? _topicCollisionRun
              : null,
          topicCollisionCreatedAt: _topicCollisionRun == null
              ? null
              : DateTime.now().toUtc(),
        ),
      );
    } on Object {
      // Cache writes are not a prerequisite for public Run tracking.
    }
  }

  Future<DesktopServiceResult<_RemoteSubscriptionSnapshot>>
  _fetchRemoteSubscriptions(String workspaceId) async {
    final publications = <SharedSubscriptionPublication>[];
    String? publicationCursor;
    final publicationCursors = <String>{};
    do {
      final result = await widget.subscriptionPort.loadPublications(
        cursor: publicationCursor,
        limit: 100,
      );
      if (!result.isSuccess || result.data == null) {
        return _subscriptionFailure(result);
      }
      publications.addAll(result.data!.items);
      publicationCursor = result.data!.nextCursor;
      if (publicationCursor != null &&
          !publicationCursors.add(publicationCursor)) {
        return const DesktopServiceResult<_RemoteSubscriptionSnapshot>.failure(
          code: 'SUBSCRIPTION_CURSOR_REPEATED',
          message: '订阅目录分页游标无效',
        );
      }
    } while (publicationCursor != null);

    final library = <SharedSubscriptionLibraryPublication>[];
    String? libraryCursor;
    final libraryCursors = <String>{};
    do {
      final result = await widget.subscriptionPort.loadLibrary(
        workspaceId,
        cursor: libraryCursor,
        limit: 100,
      );
      if (!result.isSuccess || result.data == null) {
        return _subscriptionFailure(result);
      }
      library.addAll(result.data!.items);
      libraryCursor = result.data!.nextCursor;
      if (libraryCursor != null && !libraryCursors.add(libraryCursor)) {
        return const DesktopServiceResult<_RemoteSubscriptionSnapshot>.failure(
          code: 'SUBSCRIPTION_CURSOR_REPEATED',
          message: '订阅库分页游标无效',
        );
      }
    } while (libraryCursor != null);

    final articles = <SharedSubscriptionArticle>[];
    for (final publication in publications) {
      String? articleCursor;
      final articleCursors = <String>{};
      do {
        final result = await widget.subscriptionPort.loadArticles(
          publicationId: publication.publicationId,
          cursor: articleCursor,
          limit: 100,
        );
        if (!result.isSuccess || result.data == null) {
          if (result.code == 'SUBSCRIPTION_CATALOG_UNAVAILABLE') break;
          return _subscriptionFailure(result);
        }
        articles.addAll(result.data!.items);
        articleCursor = result.data!.nextCursor;
        if (articleCursor != null && !articleCursors.add(articleCursor)) {
          return const DesktopServiceResult<
            _RemoteSubscriptionSnapshot
          >.failure(
            code: 'SUBSCRIPTION_CURSOR_REPEATED',
            message: '订阅文章分页游标无效',
          );
        }
      } while (articleCursor != null);
    }
    return DesktopServiceResult<_RemoteSubscriptionSnapshot>.success(
      _RemoteSubscriptionSnapshot(
        publications: List<SharedSubscriptionPublication>.unmodifiable(
          publications,
        ),
        library: List<SharedSubscriptionLibraryPublication>.unmodifiable(
          library,
        ),
        articles: List<SharedSubscriptionArticle>.unmodifiable(articles),
      ),
    );
  }

  DesktopServiceResult<_RemoteSubscriptionSnapshot> _subscriptionFailure<T>(
    DesktopServiceResult<T> result,
  ) => result.isUnavailable
      ? DesktopServiceResult<_RemoteSubscriptionSnapshot>.unavailable(
          code: result.code,
          message: result.message,
        )
      : DesktopServiceResult<_RemoteSubscriptionSnapshot>.failure(
          code: result.code,
          message: result.message,
          retryable: result.retryable,
        );

  DesktopServiceResult<T> _forwardFailure<T, S>(
    DesktopServiceResult<S> result,
  ) => result.isUnavailable
      ? DesktopServiceResult<T>.unavailable(
          code: result.code,
          message: result.message,
        )
      : DesktopServiceResult<T>.failure(
          code: result.code,
          message: result.message,
          retryable: result.retryable,
        );

  Future<DesktopServiceResult<SharedAccountCreditSummary>>
  _loadCreditSummary() async {
    final lots = <SharedPermanentCreditLot>[];
    final cursors = <String>{};
    SharedAccountCreditSummary? latest;
    String? cursor;
    do {
      final result = await widget.accountUsagePort.loadCredits(
        cursor: cursor,
        limit: 100,
      );
      if (!result.isSuccess || result.data == null) {
        return _forwardFailure(result);
      }
      latest = result.data!;
      lots.addAll(latest.permanentCredit.lots);
      cursor = latest.permanentCredit.nextCursor;
      if (cursor != null && !cursors.add(cursor)) {
        return const DesktopServiceResult<SharedAccountCreditSummary>.failure(
          code: 'ACCOUNT_CREDIT_CURSOR_REPEATED',
          message: '额度分页游标无效',
        );
      }
    } while (cursor != null);
    return DesktopServiceResult<SharedAccountCreditSummary>.success(
      SharedAccountCreditSummary(
        monthlyCredit: latest.monthlyCredit,
        permanentCredit: SharedPermanentCreditPage(
          availableCredits: latest.permanentCredit.availableCredits,
          reservedCredits: latest.permanentCredit.reservedCredits,
          lots: List<SharedPermanentCreditLot>.unmodifiable(lots),
        ),
        account: latest.account,
      ),
    );
  }

  Future<void> _reloadRemoteSubscriptions({
    bool preserveOnFailure = false,
  }) async {
    final workspaceId = _activeWorkspaceId;
    if (workspaceId == null || _subscriptionLoading) return;
    if (mounted) setState(() => _subscriptionLoading = true);
    final result = await _fetchRemoteSubscriptions(workspaceId);
    if (!mounted) return;
    setState(() {
      _subscriptionLoading = false;
      _subscriptionLoadResult = result;
      if (result.isSuccess) {
        _externalKnowledgeItems
          ..clear()
          ..addAll(_subscriptionItems(result.data!));
      } else if (!widget.demoMode && !preserveOnFailure) {
        _externalKnowledgeItems.clear();
      }
    });
  }

  List<_ExternalKnowledgeItem> _subscriptionItems(
    _RemoteSubscriptionSnapshot snapshot,
  ) {
    final publicationById = <String, SharedSubscriptionPublication>{
      for (final publication in snapshot.publications)
        publication.publicationId: publication,
    };
    final subscribedPublicationIds = snapshot.library
        .where((item) => item.availability == 'available')
        .map((item) => item.publication.publicationId)
        .toSet();
    return snapshot.articles
        .map((article) {
          final publication = publicationById[article.publicationId];
          final summary = article.summary?.trim();
          return _ExternalKnowledgeItem(
            id: article.articleId,
            title: article.title,
            detail: '${publication?.title ?? '知识广场'} · 订阅文章',
            kind: LucideIcons.bookOpenText,
            summary: summary == null || summary.isEmpty ? '打开后读取文章正文' : summary,
            subscribed: subscribedPublicationIds.contains(
              article.publicationId,
            ),
            topics: <String>[
              if (publication != null) publication.title,
              if (article.sectionId != null) article.sectionId!,
            ],
            sourceLabel: publication?.title ?? '知识广场',
            author: article.author ?? publication?.title ?? '花火知识广场',
            updatedLabel: _subscriptionDateLabel(
              article.publishedAt ?? publication?.updatedAt,
            ),
            publicationId: article.publicationId,
            articleId: article.articleId,
            currentArticleRevisionId: article.currentArticleRevisionId,
          );
        })
        .toList(growable: false);
  }

  String _subscriptionDateLabel(DateTime? value) => value == null
      ? '近期'
      : '${value.toLocal().month} 月 ${value.toLocal().day} 日';

  Future<void> _loadRemoteAssets({bool force = false}) async {
    if (_assetsLoading || (_assetsLoaded && !force)) return;
    setState(() => _assetsLoading = true);
    final overviewFuture = widget.assetsPort.loadOverview();
    final result = await widget.assetsPort.loadMarkdownDocument();
    final overview = await overviewFuture;
    if (!mounted) return;
    setState(() {
      _assetsLoading = false;
      _assetsLoaded = true;
      _assetResult = result;
      _assetOverviewResult = overview;
    });
  }

  Future<void> _openRemoteAssetDetail(DesktopAssetSummary summary) async {
    final result = await widget.assetsPort.loadDetail(
      assetType: summary.assetType,
      assetId: summary.assetId,
    );
    if (!mounted) return;
    if (!result.isSuccess) {
      _showSnack(result.message);
      return;
    }
    final detail = result.data!;
    await _showFeatureAction(
      title: summary.title,
      detail: detail.asset.entries
          .map((entry) => '${entry.key}: ${entry.value}')
          .join('\n'),
    );
  }

  Future<void> _loadChatSession() async {
    if (!_workspaceIsReady) return;
    final result = await widget.chatPort.listThreads();
    if (!mounted || !result.isSuccess) return;
    final listedThreads = _mergeChatThreads(result.data!.items);
    final threads = await _hydrateChatThreadAgentProfiles(listedThreads);
    if (!mounted) return;
    final activeThreadId = _activeChatThreadId;
    setState(() {
      _chatThreads
        ..clear()
        ..addAll(threads);
    });
    unawaited(_chatTaskTracker.updateThreads(threads));
    final targetThreadId =
        activeThreadId != null &&
            threads.any((thread) => thread.threadId == activeThreadId)
        ? activeThreadId
        : threads.isEmpty
        ? null
        : threads.first.threadId;
    if (targetThreadId != null) {
      await _openRemoteChatThread(targetThreadId);
    }
  }

  Future<List<DesktopChatThread>> _hydrateChatThreadAgentProfiles(
    List<DesktopChatThread> threads,
  ) async {
    final missingAgentThreads = threads
        .where((thread) => thread.agentProfileId?.trim().isNotEmpty != true)
        .toList(growable: false);
    if (missingAgentThreads.isEmpty) return threads;
    final details = await Future.wait(<Future<DesktopChatThreadDetail?>>[
      for (final thread in missingAgentThreads)
        () async {
          final result = await widget.chatPort.getThreadDetail(thread.threadId);
          final detail = result.data;
          if (!result.isSuccess ||
              detail == null ||
              detail.thread.threadId != thread.threadId ||
              detail.thread.agentProfileId?.trim().isNotEmpty != true) {
            return null;
          }
          return detail;
        }(),
    ]);
    final detailsById = <String, DesktopChatThreadDetail>{
      for (final detail in details)
        if (detail != null) detail.thread.threadId: detail,
    };
    if (detailsById.isEmpty) return threads;
    for (final detail in detailsById.values) {
      unawaited(_chatTaskTracker.recordThreadDetail(detail));
    }
    return <DesktopChatThread>[
      for (final thread in threads)
        if (detailsById[thread.threadId] case final detail?)
          DesktopChatThread(
            threadId: thread.threadId,
            title: thread.title == '未命名会话' ? detail.thread.title : thread.title,
            updatedAt: thread.updatedAt ?? detail.thread.updatedAt,
            agentProfileId: detail.thread.agentProfileId,
            activeRuns: thread.activeRuns.isEmpty
                ? detail.thread.activeRuns
                : thread.activeRuns,
          )
        else
          thread,
    ];
  }

  Future<void> _openRemoteChatThread(String threadId) async {
    if (!_workspaceIsReady) return;
    if (mounted) {
      setState(
        () => _activeDailyTopicTitle = _dailyTopicContextByThread[threadId],
      );
    }
    final result = await widget.chatPort.getThreadDetail(threadId);
    if (!mounted) return;
    if (!result.isSuccess) {
      final cached = _chatTaskTracker.detailFor(threadId);
      if (cached != null) {
        _applyChatDetail(cached);
        return;
      }
      _finishChatFailure(result.message);
      return;
    }
    final detail = result.data!;
    _applyChatDetail(detail);
    unawaited(_chatTaskTracker.recordThreadDetail(detail, activate: true));
  }

  Future<void> _openNotificationTarget(DesktopNotification notification) async {
    if (notification.targetType == 'thread') {
      _openSection(_WorkspaceSection.chat);
      await _openRemoteChatThread(notification.targetId);
      return;
    }
    if (notification.targetType == 'note') {
      final pulled = await _pullRemoteDocuments();
      if (!mounted) return;
      final document = _documents
          .where((item) => item.id == notification.targetId)
          .firstOrNull;
      if (pulled.isSuccess && document != null) {
        await _activateDocument(
          document,
          stage: _notificationNoteStage(notification),
        );
        return;
      }
      _openAssetsPage(0);
      _showSnack('资产已更新，请在我的资产中查看详情');
      return;
    }
    if (notification.targetType == 'asset') {
      _openAssetsPage(0);
      await _loadRemoteAssets(force: true);
      return;
    }
    if (_isPositioningNotification(notification)) {
      final positioningThread = _chatThreads
          .where((thread) => thread.agentProfileId == 'positioning_lv2')
          .firstOrNull;
      if (positioningThread != null) {
        await _openRemoteChatThread(positioningThread.threadId);
      }
      if (!mounted) return;
      _openDesktopPositioningReport();
      return;
    }
    if (notification.targetType == 'recording') {
      _openSection(_WorkspaceSection.capture);
      _showSnack('已打开采集与独白，可在我的资产查看转写结果');
      return;
    }
    _showSnack('通知已标记为已读，请在对应工作区查看内容');
  }

  HuahuoNoteStage _notificationNoteStage(DesktopNotification notification) {
    final event = '${notification.eventType}.${notification.scene}'
        .toLowerCase();
    if (event.contains('germination') || event.contains('sprout')) {
      return HuahuoNoteStage.sprout;
    }
    if (event.contains('outline') ||
        event.contains('summary') ||
        event.contains('minutes')) {
      return HuahuoNoteStage.summary;
    }
    return HuahuoNoteStage.raw;
  }

  bool _isPositioningNotification(DesktopNotification notification) {
    final descriptor = '${notification.scene}.${notification.eventType}'
        .toLowerCase();
    return descriptor.contains('positioning') ||
        descriptor.contains('定位') ||
        notification.targetType == 'positioning_report';
  }

  void _restoreCachedChatSnapshot(DesktopChatSessionSnapshot snapshot) {
    if (!mounted) return;
    final activeThreadId = snapshot.activeThreadId;
    setState(() {
      _chatThreads
        ..clear()
        ..addAll(snapshot.threads);
    });
    if (activeThreadId == null) return;
    final detail = snapshot.detailFor(activeThreadId);
    if (detail != null) _applyChatDetail(detail);
  }

  List<DesktopChatThread> _mergeChatThreads(
    Iterable<DesktopChatThread> remoteThreads,
  ) {
    final cachedById = <String, DesktopChatThread>{
      for (final thread in _chatThreads) thread.threadId: thread,
    };
    final merged = <DesktopChatThread>[];
    final seen = <String>{};
    for (final remote in remoteThreads) {
      final cached = cachedById.remove(remote.threadId);
      merged.add(
        DesktopChatThread(
          threadId: remote.threadId,
          title: remote.title == '未命名会话' && cached != null
              ? cached.title
              : remote.title,
          updatedAt: remote.updatedAt ?? cached?.updatedAt,
          agentProfileId: remote.agentProfileId ?? cached?.agentProfileId,
          activeRuns: remote.activeRuns.isEmpty && cached != null
              ? cached.activeRuns
              : remote.activeRuns,
        ),
      );
      seen.add(remote.threadId);
    }
    for (final cached in cachedById.values) {
      if (seen.add(cached.threadId)) merged.add(cached);
    }
    return merged;
  }

  void _applyChatDetail(DesktopChatThreadDetail detail) {
    final messages = detail.messages;
    setState(() {
      final existing = _chatThreads
          .where((thread) => thread.threadId == detail.thread.threadId)
          .firstOrNull;
      final thread = DesktopChatThread(
        threadId: detail.thread.threadId,
        title: detail.thread.title == '未命名会话' && existing != null
            ? existing.title
            : detail.thread.title,
        updatedAt: detail.thread.updatedAt ?? existing?.updatedAt,
        agentProfileId:
            detail.thread.agentProfileId ?? existing?.agentProfileId,
        activeRuns: detail.thread.activeRuns.isEmpty && existing != null
            ? existing.activeRuns
            : detail.thread.activeRuns,
      );
      _activeChatThreadId = thread.threadId;
      _newChatAgentProfileId = thread.agentProfileId;
      _chatThreads.removeWhere(
        (candidate) => candidate.threadId == thread.threadId,
      );
      _chatThreads.insert(0, thread);
      _latestChatAnswer = messages
          .where((message) => message.role == 'assistant')
          .lastOrNull
          ?.text;
      _chatMessages.clear();
      final opening = _localDesktopAgentOpeningMessage(thread.agentProfileId);
      if (opening != null) {
        _chatMessages.add(_AiMessage(text: opening, fromUser: false));
      }
      _chatMessages.addAll(messages.map(_AiMessage.fromDesktop));
      if (_chatMessages.isEmpty) {
        _chatMessages.add(
          const _AiMessage(text: '这是一个新对话。把正在思考的问题发给我就可以。', fromUser: false),
        );
      }
    });
  }

  void _handleChatTaskTrackerChanged() {
    if (!mounted) return;
    final activeThreadId = _activeChatThreadId;
    if (activeThreadId == null) {
      setState(() {});
      return;
    }
    final detail = _chatTaskTracker.detailFor(activeThreadId);
    if (detail != null) {
      _applyChatDetail(detail);
    } else {
      setState(() {});
    }
  }

  bool get _hasActiveChatTask {
    final threadId = _activeChatThreadId;
    return threadId != null &&
        _chatTaskTracker
            .tasksForThread(threadId)
            .any((task) => !task.isTerminal);
  }

  Future<void> _openChatTaskReminder(String taskKey) async {
    DesktopChatPendingTask? task;
    for (final candidate in _chatTaskTracker.tasks) {
      if (candidate.taskKey == taskKey) {
        task = candidate;
        break;
      }
    }
    if (task == null) return;
    await _openRemoteChatThread(task.threadId);
    if (!mounted || !task.isTerminal || _activeChatThreadId != task.threadId) {
      return;
    }
    await _chatTaskTracker.acknowledgeTerminalTask(task.taskKey);
  }

  Future<void> _syncRemoteAssets() async {
    final result = await widget.assetsPort.requestSync();
    if (!mounted) return;
    if (!result.isSuccess) {
      _showSnack(result.message);
      return;
    }
    _showSnack('云端资产同步任务已提交');
    await _loadRemoteAssets(force: true);
  }

  String _noteStageLabel(HuahuoNoteStage stage) => switch (stage) {
    HuahuoNoteStage.raw => '原始内容',
    HuahuoNoteStage.summary => 'AI 纲要',
    HuahuoNoteStage.sprout => '发芽洞见',
  };

  IconData _noteStageIcon(HuahuoNoteStage stage) => switch (stage) {
    HuahuoNoteStage.raw => LucideIcons.filePenLine,
    HuahuoNoteStage.summary => LucideIcons.listTree,
    HuahuoNoteStage.sprout => LucideIcons.lightbulb,
  };

  String _noteStageTabId(
    HuahuoDocumentSnapshot snapshot,
    HuahuoNoteStage stage,
  ) => 'document-${snapshot.id}-${stage.name}';

  String _noteStagePayload(
    HuahuoDocumentSnapshot snapshot,
    HuahuoNoteStage stage,
  ) {
    if (stage == HuahuoNoteStage.raw) {
      return snapshot.toDocument().toPlainText().trim();
    }
    return snapshot.stageContent(stage)?.content.trim() ?? '';
  }

  String _noteStageMarkdown(
    HuahuoDocumentSnapshot snapshot,
    HuahuoNoteStage stage,
  ) {
    final content = snapshot.stageContent(stage);
    if (content == null) return '';
    if (content.isMarkdown) return content.content;

    // Raw notes remain Quill Delta in storage. Preview gets a pure derived
    // Markdown projection, so opening it never changes the canonical source.
    try {
      return HuahuoDocumentCodec.documentToMarkdown(
        snapshot.toDocument(),
      ).trimRight();
    } on Object {
      return snapshot.toDocument().toPlainText().trimRight();
    }
  }

  MarkdownPreviewSource _noteStagePreviewSource(
    HuahuoDocumentSnapshot snapshot,
    HuahuoNoteStage stage,
  ) => MarkdownPreviewSource(
    title: snapshot.title,
    markdown: _noteStageMarkdown(snapshot, stage),
    stage: _noteStageLabel(stage),
  );

  String _noteStageContextTitle(
    HuahuoDocumentSnapshot snapshot,
    HuahuoNoteStage stage,
  ) {
    final title = snapshot.title.trim().isEmpty ? '未命名文稿' : snapshot.title;
    return '$title · ${_noteStageLabel(stage)}';
  }

  Future<void> _activateDocument(
    HuahuoDocumentSnapshot snapshot, {
    HuahuoNoteStage stage = HuahuoNoteStage.raw,
  }) async {
    if (_editor.snapshot.id == snapshot.id) {
      _openDocumentTab(_editor.snapshot, stage: stage);
      if (stage == HuahuoNoteStage.raw) _bodyFocus.requestFocus();
      return;
    }
    await _editor.saveNow();
    if (!mounted) return;
    final previous = _editor;
    setState(() {
      _editor = _createEditor(snapshot);
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.creation;
      _documentWorkspaceView = _DocumentWorkspaceView.writing;
      _setSelectedContentInState(
        title: _noteStageContextTitle(snapshot, stage),
        id: _noteStageTabId(snapshot, stage),
        source: '我的创作 · ${_noteStageLabel(stage)}',
        payload: _noteStagePayload(snapshot, stage),
      );
      _attachDocumentContextInState(snapshot, stage: stage);
      _upsertTab(
        _WorkspaceTab(
          id: _noteStageTabId(snapshot, stage),
          title: _noteStageContextTitle(snapshot, stage),
          kind: _WorkspaceTabKind.document,
          section: _WorkspaceSection.creation,
          documentId: snapshot.id,
          noteStage: stage,
        ),
      );
    });
    _disposeEditor(previous);
    if (stage == HuahuoNoteStage.raw) _bodyFocus.requestFocus();
    if (_contextPanelOpen && _contextKind == _ContextKind.relations) {
      unawaited(_loadActiveNoteRelations());
    }
  }

  _WorkspaceTab get _activeTab => _tabs.firstWhere(
    (tab) => tab.id == _activeTabId,
    orElse: () => _tabs.first,
  );

  bool get _activeTabIsDocument =>
      _activeTab.kind == _WorkspaceTabKind.document;

  HuahuoNoteStage get _activeNoteStage =>
      _activeTab.noteStage ?? HuahuoNoteStage.raw;

  bool get _activeNoteStageIsEditable =>
      _activeNoteStage == HuahuoNoteStage.raw;

  void _upsertTab(_WorkspaceTab tab) {
    final index = _tabs.indexWhere((candidate) => candidate.id == tab.id);
    if (index < 0) {
      _tabs.add(tab);
    } else {
      _tabs[index] = tab;
    }
    _activeTabId = tab.id;
  }

  void _openDocumentTab(
    HuahuoDocumentSnapshot snapshot, {
    HuahuoNoteStage stage = HuahuoNoteStage.raw,
  }) {
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.creation;
      _documentWorkspaceView = _DocumentWorkspaceView.writing;
      _setSelectedContentInState(
        title: _noteStageContextTitle(snapshot, stage),
        id: _noteStageTabId(snapshot, stage),
        source: '我的创作 · ${_noteStageLabel(stage)}',
        payload: _noteStagePayload(snapshot, stage),
      );
      _attachDocumentContextInState(snapshot, stage: stage);
      _upsertTab(
        _WorkspaceTab(
          id: _noteStageTabId(snapshot, stage),
          title: _noteStageContextTitle(snapshot, stage),
          kind: _WorkspaceTabKind.document,
          section: _WorkspaceSection.creation,
          documentId: snapshot.id,
          noteStage: stage,
        ),
      );
    });
  }

  void _openSection(_WorkspaceSection section) {
    if (!_applyingExternalLocation) {
      final location = _locationForSection(section);
      final navigate = widget.onNavigateLocation;
      if (navigate != null) {
        _pendingPublishedLocation = location;
        navigate(location);
      }
    }
    switch (section) {
      case _WorkspaceSection.brain:
        _selectTab('graph');
        return;
      case _WorkspaceSection.creation:
        _openDocumentTab(_editor.snapshot);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _bodyFocus.requestFocus();
        });
        return;
      case _WorkspaceSection.chat:
        setState(() {
          _activeSection = section;
          _chatRailCollapsed = false;
          if (_contextAutoAttach) {
            _attachSelectedContentInState();
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _chatFocus.requestFocus();
        });
        return;
      case _WorkspaceSection.capture:
        _openFeatureTab(_WorkspaceSection.capture, title: '采集与独白');
        return;
      case _WorkspaceSection.notifications:
        _openFeatureTab(_WorkspaceSection.notifications);
        return;
      case _WorkspaceSection.tools:
      case _WorkspaceSection.externalKnowledge:
        _openFeatureTab(section);
        return;
      case _WorkspaceSection.assets:
        _openAssetsPage(_activeAssetSection);
        return;
      case _WorkspaceSection.account:
      case _WorkspaceSection.settings:
        _openFeatureTab(section);
        return;
    }
  }

  void _applyProductLocation(String location) {
    final path = Uri.tryParse(location)?.path ?? '/brain';
    _applyingExternalLocation = true;
    try {
      if (path == '/home') {
        _openHomeWorkspace();
      } else if (path == '/chat' || path == '/chat/agent') {
        _openSection(_WorkspaceSection.chat);
      } else if (path == '/creation/book-work') {
        _openBookWorkspace();
      } else if (path == '/creation/proposals') {
        _openProposalWorkspace(_proposalCreation);
      } else if (path == '/creation') {
        _openCreationWorkspace();
      } else if (path.startsWith('/capture/')) {
        final mode = switch (path.split('/').last) {
          'link' => _CaptureMode.link,
          'document' || 'media' => _CaptureMode.media,
          _ => _CaptureMode.text,
        };
        setState(() => _captureMode = mode);
        _openSection(_WorkspaceSection.capture);
      } else if (path.startsWith('/recordings')) {
        _openRecordingsWorkspace();
      } else if (path == '/knowledge/subscriptions') {
        _openSection(_WorkspaceSection.externalKnowledge);
      } else if (path.startsWith('/knowledge/') || path == '/assets') {
        _openSection(_WorkspaceSection.assets);
      } else if (path == '/notifications') {
        _openSection(_WorkspaceSection.notifications);
      } else if (path == '/support') {
        _openSupportWorkspace();
      } else if (path == '/settings') {
        _openSection(_WorkspaceSection.settings);
      } else if (path == '/account/workspaces') {
        _openWorkspaceManagement();
      } else if (path == '/account/calendar') {
        _openActivityCalendarWorkspace();
      } else if (path == '/account/digital-twin') {
        _openDigitalTwinWorkspace();
      } else if (path.startsWith('/account/') ||
          path == '/runtime' ||
          path == '/auth') {
        _openSection(_WorkspaceSection.account);
      } else {
        _openSection(_WorkspaceSection.brain);
        if (path == '/search') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _searchInput.selection = TextSelection.collapsed(
                offset: _searchInput.text.length,
              );
            }
          });
        }
      }
    } finally {
      _applyingExternalLocation = false;
    }
  }

  void _openFeatureTab(_WorkspaceSection section, {String? id, String? title}) {
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = section;
      _contextPanelOpen = false;
      _upsertTab(
        _WorkspaceTab(
          id: id ?? 'feature-${section.name}',
          title: title ?? _sectionTitle(section),
          kind: _WorkspaceTabKind.feature,
          section: section,
        ),
      );
    });
  }

  void _openAssetsPage(int section) {
    setState(() => _activeAssetSection = section);
    _openFeatureTab(_WorkspaceSection.assets);
    unawaited(_loadRemoteAssets());
  }

  void _selectTab(String id) {
    final tab = _tabs.firstWhere((candidate) => candidate.id == id);
    if (tab.kind == _WorkspaceTabKind.document &&
        tab.documentId != _editor.snapshot.id) {
      final document = _documents.firstWhere(
        (candidate) => candidate.id == tab.documentId,
      );
      unawaited(
        _activateDocument(
          document,
          stage: tab.noteStage ?? HuahuoNoteStage.raw,
        ),
      );
      return;
    }
    setState(() {
      _activeTabId = id;
      _activeSection = tab.section ?? _WorkspaceSection.brain;
      _primaryMode = tab.kind == _WorkspaceTabKind.chat
          ? _PrimaryWorkspaceMode.chat
          : _PrimaryWorkspaceMode.creation;
      if (tab.kind == _WorkspaceTabKind.document) {
        final stage = tab.noteStage ?? HuahuoNoteStage.raw;
        final snapshot = _editor.snapshot.id == tab.documentId
            ? _editor.snapshot
            : _documents.firstWhere(
                (document) => document.id == tab.documentId,
              );
        _setSelectedContentInState(
          title: _noteStageContextTitle(snapshot, stage),
          id: _noteStageTabId(snapshot, stage),
          source: '我的创作 · ${_noteStageLabel(stage)}',
          payload: _noteStagePayload(snapshot, stage),
        );
        _attachDocumentContextInState(snapshot, stage: stage);
      }
      if (tab.kind != _WorkspaceTabKind.document) _contextPanelOpen = false;
    });
    if (tab.kind == _WorkspaceTabKind.document &&
        tab.noteStage == HuahuoNoteStage.raw) {
      _bodyFocus.requestFocus();
    }
  }

  void _closeTab(_WorkspaceTab tab) {
    if (!tab.closeable) return;
    final index = _tabs.indexOf(tab);
    setState(() {
      _tabs.remove(tab);
      if (_activeTabId == tab.id) {
        final nextIndex = (index - 1).clamp(0, _tabs.length - 1);
        final next = _tabs[nextIndex];
        _activeTabId = next.id;
        _activeSection = next.section ?? _WorkspaceSection.brain;
        _primaryMode = next.kind == _WorkspaceTabKind.chat
            ? _PrimaryWorkspaceMode.chat
            : _PrimaryWorkspaceMode.creation;
        if (next.kind != _WorkspaceTabKind.document) {
          _contextPanelOpen = false;
        }
      }
    });
  }

  Future<void> _createDocument() async {
    await _editor.saveNow();
    if (!mounted) return;
    final now = DateTime.now().toUtc();
    final snapshot = HuahuoDocumentSnapshot(
      id: 'document-${now.microsecondsSinceEpoch}',
      title: '',
      deltaJson: '[{"insert":"\\n"}]',
      revision: 0,
      createdAt: now,
      modifiedAt: now,
    );
    _documents.insert(0, snapshot);
    await _activateDocument(snapshot);
  }

  void _openContext(_ContextKind kind) {
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _contextKind = kind;
      _contextPanelOpen = true;
    });
    if (kind == _ContextKind.relations) {
      unawaited(_loadActiveNoteRelations());
    }
  }

  void _handleExplorerSearchChanged(String _) {
    setState(() {});
    _scheduleWorkspaceSearch();
  }

  void _scheduleWorkspaceSearch({bool immediate = false}) {
    _workspaceSearchDebounce?.cancel();
    final sequence = ++_workspaceSearchSequence;
    final query = _searchInput.text.trim();
    if (query.isEmpty) {
      setState(() {
        _workspaceSearchLoading = false;
        _workspaceSearchResult = null;
      });
      return;
    }
    final workspaceId = _activeWorkspaceId;
    if (workspaceId == null) {
      setState(() {
        _workspaceSearchLoading = false;
        _workspaceSearchResult = null;
      });
      return;
    }
    setState(() {
      _workspaceSearchLoading = true;
      _workspaceSearchResult = null;
    });
    void run() => unawaited(
      _executeWorkspaceSearch(
        workspaceId: workspaceId,
        query: query,
        sequence: sequence,
      ),
    );
    if (immediate) {
      run();
    } else {
      _workspaceSearchDebounce = Timer(const Duration(milliseconds: 320), run);
    }
  }

  Future<void> _executeWorkspaceSearch({
    required String workspaceId,
    required String query,
    required int sequence,
  }) async {
    DesktopServiceResult<SharedWorkspaceSearchOutput> result;
    try {
      result = await widget.workspacePort.searchWorkspace(
        workspaceId,
        SharedWorkspaceSearchRequest.keyword(
          query: query,
          ownerKinds: const <String>['hnote'],
          noteParts: const <String>['raw', 'outline', 'germination'],
          limit: 20,
        ),
      );
    } on Object {
      result = const DesktopServiceResult<SharedWorkspaceSearchOutput>.failure(
        code: 'DESKTOP_WORKSPACE_SEARCH_INVALID',
        message: 'Workspace 搜索请求无效',
      );
    }
    if (!mounted || sequence != _workspaceSearchSequence) return;
    if (_searchInput.text.trim() != query ||
        _activeWorkspaceId != workspaceId) {
      return;
    }
    setState(() {
      _workspaceSearchLoading = false;
      _workspaceSearchResult = result;
    });
  }

  Future<void> _openWorkspaceSearchResult(
    SharedWorkspaceSearchResult result,
  ) async {
    final workspaceId = _activeWorkspaceId;
    final part = result.part;
    if (workspaceId == null ||
        result.ownerRef.workspaceId != workspaceId ||
        result.ownerRef.kind != 'hnote' ||
        part == null) {
      _showSnack('该搜索结果没有可读取的 HNote 精确版本');
      return;
    }
    await _openExactWorkspaceNote(
      workspaceId: workspaceId,
      noteId: result.ownerRef.id,
      part: part,
      revisionId: result.revisionId,
      title: result.title ?? 'Workspace 笔记',
      source: 'Workspace 搜索',
    );
  }

  Future<void> _openExactWorkspaceNote({
    required String workspaceId,
    required String noteId,
    required String part,
    required String revisionId,
    required String title,
    required String source,
  }) async {
    final loadKey = '$noteId:$revisionId';
    if (!_workspaceSearchPartLoads.add(loadKey)) return;
    if (mounted) setState(() {});
    final result = await widget.workspacePort.loadNote(
      workspaceId,
      noteId,
      revisionId: revisionId,
    );
    if (!mounted) return;
    setState(() => _workspaceSearchPartLoads.remove(loadKey));
    final note = result.data;
    if (!result.isSuccess ||
        note == null ||
        note.noteId != noteId ||
        note.noteRevisionId != revisionId ||
        (note.workspaceId != null && note.workspaceId != workspaceId)) {
      _showSnack(result.isSuccess ? '服务未返回请求的 HNote 精确版本' : result.message);
      return;
    }
    final selectedPart = switch (part) {
      'raw' => note.raw,
      'outline' => note.outline,
      'germination' => note.germination,
      _ => null,
    };
    if (selectedPart == null) {
      _showSnack('搜索结果包含不支持的 HNote part');
      return;
    }
    _openReferenceTab(
      title.trim().isEmpty ? note.title : title,
      section: _WorkspaceSection.creation,
      contextId:
          'workspace-note-$noteId-$revisionId-$part-${selectedPart.partRevisionId}',
      contextSource: source,
      contextPayload: selectedPart.markdown,
    );
  }

  Future<void> _openExactWorkspaceNotePart({
    required String workspaceId,
    required String noteId,
    required String part,
    required String partRevisionId,
    required String title,
    required String source,
  }) async {
    final loadKey = '$noteId:$part:$partRevisionId';
    if (!_workspaceSearchPartLoads.add(loadKey)) return;
    if (mounted) setState(() {});
    final result = await widget.workspacePort.loadNotePart(
      workspaceId,
      noteId,
      part,
      partRevisionId: partRevisionId,
    );
    if (!mounted) return;
    setState(() => _workspaceSearchPartLoads.remove(loadKey));
    final view = result.data;
    if (!result.isSuccess ||
        view == null ||
        view.noteId != noteId ||
        view.part != part ||
        view.partRevisionId != partRevisionId) {
      _showSnack(result.isSuccess ? '服务未返回请求的精确笔记版本' : result.message);
      return;
    }
    _openReferenceTab(
      title,
      section: _WorkspaceSection.creation,
      contextId: 'workspace-part-$loadKey',
      contextSource: source,
      contextPayload: view.markdown,
    );
  }

  Future<void> _loadActiveNoteRelations() async {
    final sequence = ++_noteRelationsSequence;
    final workspaceId = _activeWorkspaceId;
    if (!_activeTabIsDocument || workspaceId == null) {
      setState(() {
        _noteRelationsLoading = false;
        _noteRelationsResult =
            const DesktopServiceResult<SharedNoteRelationPage>.unavailable(
              code: 'DESKTOP_NOTE_RELATIONS_LOCAL_ONLY',
              message: '当前文稿尚未同步到 Workspace',
            );
      });
      return;
    }
    setState(() {
      _noteRelationsLoading = true;
      _noteRelationsResult = null;
    });
    final remote = await widget.documentSyncPort.remoteReferenceFor(
      localDocumentId: _editor.snapshot.id,
      part: 'raw',
    );
    if (!mounted || sequence != _noteRelationsSequence) return;
    if (remote == null) {
      setState(() {
        _noteRelationsLoading = false;
        _noteRelationsResult =
            const DesktopServiceResult<SharedNoteRelationPage>.unavailable(
              code: 'DESKTOP_NOTE_RELATIONS_LOCAL_ONLY',
              message: '当前文稿只有本机版本',
            );
      });
      return;
    }
    final items = <SharedNoteRelation>[];
    final cursors = <String>{};
    DesktopServiceResult<SharedNoteRelationPage>? failure;
    String? cursor;
    do {
      final page = await widget.workspacePort.loadNoteRelations(
        workspaceId,
        remote.noteId,
        cursor: cursor,
        limit: 100,
      );
      if (!page.isSuccess || page.data == null) {
        failure = _forwardFailure(page);
        break;
      }
      items.addAll(page.data!.items);
      cursor = page.data!.nextCursor;
      if (cursor != null && !cursors.add(cursor)) {
        failure = const DesktopServiceResult<SharedNoteRelationPage>.failure(
          code: 'NOTE_RELATION_CURSOR_REPEATED',
          message: '关系分页游标无效',
        );
        break;
      }
    } while (cursor != null);
    if (!mounted || sequence != _noteRelationsSequence) return;
    setState(() {
      _noteRelationsLoading = false;
      _noteRelationsResult =
          failure ??
          DesktopServiceResult<SharedNoteRelationPage>.success(
            SharedNoteRelationPage(
              items: List<SharedNoteRelation>.unmodifiable(items),
            ),
          );
    });
  }

  Future<void> _openNoteRelationTarget(SharedNoteRelation relation) async {
    final workspaceId = _activeWorkspaceId;
    if (workspaceId == null) return;
    await _openExactWorkspaceNotePart(
      workspaceId: workspaceId,
      noteId: relation.target.noteId,
      part: relation.target.part,
      partRevisionId: relation.target.partRevisionId,
      title: '关联笔记 · ${_noteRelationTypeLabel(relation.relationType)}',
      source: '笔记关系',
    );
  }

  Future<void> _deleteNoteRelation(SharedExplicitNoteRelation relation) async {
    final workspaceId = _activeWorkspaceId;
    if (workspaceId == null ||
        !_noteRelationMutations.add(relation.relationId)) {
      return;
    }
    setState(() {});
    final result = await widget.workspacePort.deleteNoteRelation(
      workspaceId,
      relation.relationId,
      etag: relation.etag,
      idempotencyKey: _noteRelationActionKey('delete', relation.relationId),
    );
    if (!mounted) return;
    setState(() => _noteRelationMutations.remove(relation.relationId));
    if (!result.isSuccess) {
      _showSnack(
        result.code == 'PRECONDITION_FAILED' || result.code == 'HTTP_412'
            ? '关系版本已变化，请刷新后重试'
            : result.message,
      );
      return;
    }
    _noteRelationActionKeys.remove('delete:${relation.relationId}');
    _showSnack('显式关系已删除');
    await _loadActiveNoteRelations();
  }

  String _noteRelationActionKey(String action, String relationId) {
    final scope = '$action:$relationId';
    return _noteRelationActionKeys.putIfAbsent(scope, () {
      _noteRelationMutationSequence++;
      final safeId = relationId.replaceAll(RegExp(r'[^A-Za-z0-9._:-]'), '_');
      return 'desktop-note-relation-$action-$safeId-$_noteRelationMutationSequence';
    });
  }

  String _noteRelationTypeLabel(String relationType) => switch (relationType) {
    'causal' => '因果',
    'supports' => '支持',
    'contradicts' => '反驳',
    'similar' => '相似',
    _ => relationType,
  };

  void _focusPrimaryComposer() {
    setState(() => _chatRailCollapsed = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _chatFocus.requestFocus();
    });
  }

  void _prepareChatPrompt(String prompt) {
    _chatInput.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
    _focusPrimaryComposer();
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  List<_ChatContextItem> get _activeChatContexts {
    final contexts = <_ChatContextItem>[];
    final seenIds = <String>{};

    void add(_ChatContextItem? item) {
      if (item != null && seenIds.add(item.id)) contexts.add(item);
    }

    add(_focusedDocumentContext);
    add(_focusedSelectionContext);
    for (final item in _chatContexts) {
      add(item);
    }
    return contexts;
  }

  bool _replaceFocusedDocumentContextInState(_ChatContextItem item) {
    final previous = _focusedDocumentContext;
    final changed =
        previous == null ||
        previous.id != item.id ||
        previous.title != item.title ||
        previous.source != item.source ||
        previous.payload != item.payload;
    _focusedDocumentContext = item;
    // A paragraph selection belongs to the previously viewed document or
    // stage. A new document should not carry that stale selection forward.
    _focusedSelectionContext = null;
    return changed;
  }

  bool _replaceFocusedSelectionContextInState(_ChatContextItem item) {
    final previous = _focusedSelectionContext;
    final changed =
        previous == null ||
        previous.id != item.id ||
        previous.title != item.title ||
        previous.source != item.source ||
        previous.payload != item.payload;
    _focusedSelectionContext = item;
    return changed;
  }

  bool _addChatContextInState(
    String title, {
    String? id,
    String source = '内容',
    String? payload,
  }) {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) return false;
    final contextId = id ?? normalizedTitle.toLowerCase();
    final existingIndex = _chatContexts.indexWhere(
      (item) => item.id == contextId,
    );
    if (existingIndex >= 0) {
      final existing = _chatContexts[existingIndex];
      if (existing.title != normalizedTitle ||
          existing.source != source ||
          existing.payload != payload) {
        _chatContexts[existingIndex] = _ChatContextItem(
          id: existing.id,
          title: normalizedTitle,
          source: source,
          payload: payload,
        );
      }
      return false;
    }
    _chatContexts.add(
      _ChatContextItem(
        id: contextId,
        title: normalizedTitle,
        source: source,
        payload: payload,
      ),
    );
    return true;
  }

  void _addChatContext(
    String title, {
    String? id,
    String source = '内容',
    String? payload,
    bool revealChat = false,
  }) {
    setState(() {
      _addChatContextInState(title, id: id, source: source, payload: payload);
      if (revealChat) _chatRailCollapsed = false;
    });
  }

  void _removeChatContext(String id) {
    setState(() {
      _chatContexts.removeWhere((item) => item.id == id);
    });
  }

  void _clearFocusedChatContext({required bool isDocument}) {
    setState(() {
      if (isDocument) {
        _focusedDocumentContext = null;
      } else {
        _focusedSelectionContext = null;
      }
    });
  }

  void _setSelectedContentInState({
    required String title,
    required String id,
    required String source,
    String? payload,
  }) {
    _selectedContentTitle = title;
    _selectedContentId = id;
    _selectedContentSource = source;
    _selectedContentPayload = payload;
  }

  _ChatContextItem? get _selectedContentContext {
    final title = _selectedContentTitle?.trim();
    if (title == null || title.isEmpty) return null;
    return _ChatContextItem(
      id: _selectedContentId ?? 'selected-${title.toLowerCase()}',
      title: title,
      source: _selectedContentSource ?? '当前内容',
      payload: _selectedContentPayload,
    );
  }

  bool _attachSelectedContentInState() {
    if (!_contextAutoAttach) return false;
    final selected = _selectedContentContext;
    if (selected == null) return false;
    if (selected.id.startsWith('document-')) {
      return _replaceFocusedDocumentContextInState(selected);
    }
    return _replaceFocusedSelectionContextInState(selected);
  }

  void _attachDocumentContextInState(
    HuahuoDocumentSnapshot snapshot, {
    HuahuoNoteStage stage = HuahuoNoteStage.raw,
  }) {
    if (!_contextAutoAttach) return;
    _replaceFocusedDocumentContextInState(
      _ChatContextItem(
        id: _noteStageTabId(snapshot, stage),
        title: _noteStageContextTitle(snapshot, stage),
        source: '我的创作 · ${_noteStageLabel(stage)}',
        payload: _noteStagePayload(snapshot, stage),
      ),
    );
  }

  void _scheduleParagraphContextAttachment() {
    if (!_activeTabIsDocument ||
        !_bodyFocus.hasFocus ||
        _selectionContextScheduled) {
      return;
    }
    _selectionContextScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionContextScheduled = false;
      if (!mounted || !_activeTabIsDocument || !_bodyFocus.hasFocus) {
        return;
      }
      final context = _selectedParagraphContext();
      if (context == null) return;
      setState(() {
        _setSelectedContentInState(
          title: context.$2,
          id: context.$1,
          source: '文稿段落',
          payload: context.$3,
        );
        if (_contextAutoAttach) {
          _replaceFocusedSelectionContextInState(
            _ChatContextItem(
              id: context.$1,
              title: context.$2,
              source: '文稿段落',
              payload: context.$3,
            ),
          );
        }
      });
    });
  }

  (String, String, String)? _selectedParagraphContext() {
    final plainText = _editor.body.document.toPlainText();
    if (plainText.trim().isEmpty) return null;
    final selection = _editor.body.selection;
    if (selection.start < 0 || selection.end < 0) return null;

    final selectionStart = selection.start.clamp(0, plainText.length).toInt();
    final selectionEnd = selection.end
        .clamp(selectionStart, plainText.length)
        .toInt();
    late int start;
    late int end;
    if (selectionStart != selectionEnd) {
      start = selectionStart;
      end = selectionEnd;
    } else {
      final cursor = selectionStart == plainText.length && selectionStart > 0
          ? selectionStart - 1
          : selectionStart;
      start = plainText.lastIndexOf('\n', cursor == 0 ? 0 : cursor - 1) + 1;
      end = plainText.indexOf('\n', cursor);
      if (end < 0) end = plainText.length;
    }
    final content = plainText
        .substring(start, end)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (content.isEmpty) return null;
    final documentTitle = _editor.title.text.trim().isEmpty
        ? '未命名文稿'
        : _editor.title.text.trim();
    final preview = content.length <= 34
        ? content
        : '${content.substring(0, 34)}...';
    final paragraphOrdinal =
        plainText.substring(0, start).split('\n').length - 1;
    return (
      'paragraph-${_editor.snapshot.id}-$paragraphOrdinal',
      '$documentTitle · $preview',
      content,
    );
  }

  Future<void> _generateSproutInsight() async {
    if (!_activeTabIsDocument || !_activeNoteStageIsEditable) {
      _showSnack('请先切换到原始内容');
      return;
    }
    final availability = _sproutFeatureResult;
    if (availability == null || !availability.isSuccess) {
      _showSnack(availability?.message ?? '正在校验 AI 能力');
      return;
    }
    if (_sproutGenerating) return;
    final source = _editor.snapshot;
    final remote = await widget.documentSyncPort.remoteReferenceFor(
      localDocumentId: source.id,
      part: 'raw',
    );
    final germinationTarget = await widget.documentSyncPort.remoteReferenceFor(
      localDocumentId: source.id,
      part: 'germination',
    );
    if (!mounted) return;
    if (remote == null ||
        remote.part != 'raw' ||
        germinationTarget == null ||
        germinationTarget.part != 'germination' ||
        germinationTarget.noteId != remote.noteId) {
      _showSnack('当前文稿尚未完成云端同步');
      return;
    }
    if (remote.localRevision != source.revision ||
        germinationTarget.localRevision != source.revision) {
      _showSnack('当前文稿还有未同步修改');
      return;
    }
    setState(() => _sproutGenerating = true);
    final result = await _agentController.runFeature(
      featureId: 'note.sprout',
      actionId: 'sprout:${source.id}:${remote.partRevisionId}',
      instruction: '请基于引用的原始内容生成发芽洞见。',
      document: DesktopAgentDocumentReference(
        ownerId: remote.noteId,
        part: remote.part,
        partRevisionId: remote.partRevisionId,
        targetPartRevisionId: germinationTarget.partRevisionId,
      ),
    );
    if (!mounted) return;
    if (!result.isSuccess || result.data == null) {
      setState(() => _sproutGenerating = false);
      _showSnack(result.message);
      return;
    }
    final outputPartRevisionId = result.data!.outputPartRevisionId;
    final workspaceId = _activeWorkspaceId;
    if (outputPartRevisionId == null || workspaceId == null) {
      setState(() => _sproutGenerating = false);
      _showSnack('发芽结果缺少服务端写入版本');
      return;
    }
    final partResult = await widget.workspacePort.loadNotePart(
      workspaceId,
      remote.noteId,
      'germination',
      partRevisionId: outputPartRevisionId,
    );
    if (!mounted) return;
    final sproutMarkdown = partResult.data?.markdown.trim();
    if (!partResult.isSuccess ||
        sproutMarkdown == null ||
        sproutMarkdown.isEmpty) {
      setState(() => _sproutGenerating = false);
      _showSnack('发芽结果暂时无法读取，请稍后重试');
      return;
    }
    final current = _editor.snapshot;
    if (current.id != source.id || current.revision != source.revision) {
      setState(() => _sproutGenerating = false);
      _showSnack('文稿已变化，未应用旧版本生成结果');
      return;
    }
    final updated = HuahuoDocumentSnapshot(
      id: current.id,
      title: current.title,
      deltaJson: current.deltaJson,
      markdownProjection: current.markdownProjection,
      revision: current.revision + 1,
      createdAt: current.createdAt,
      modifiedAt: DateTime.now().toUtc(),
      linkedMaterials: current.linkedMaterials,
      sourceTopicId: current.sourceTopicId,
      sourceTopicTitle: current.sourceTopicTitle,
      summaryMarkdown: current.summaryMarkdown,
      sproutMarkdown: sproutMarkdown,
      aiAnnotations: current.aiAnnotations,
    );
    await _persistSnapshot(updated);
    if (!mounted) return;
    final previous = _editor;
    setState(() {
      _editor = _createEditor(updated);
      _sproutGenerating = false;
      _documentWorkspaceView = _DocumentWorkspaceView.writing;
      _setSelectedContentInState(
        title: _noteStageContextTitle(updated, HuahuoNoteStage.sprout),
        id: _noteStageTabId(updated, HuahuoNoteStage.sprout),
        source: '我的创作 · ${_noteStageLabel(HuahuoNoteStage.sprout)}',
        payload: sproutMarkdown,
      );
      _attachDocumentContextInState(updated, stage: HuahuoNoteStage.sprout);
      _upsertTab(
        _WorkspaceTab(
          id: _noteStageTabId(updated, HuahuoNoteStage.sprout),
          title: _noteStageContextTitle(updated, HuahuoNoteStage.sprout),
          kind: _WorkspaceTabKind.document,
          section: _WorkspaceSection.creation,
          documentId: updated.id,
          noteStage: HuahuoNoteStage.sprout,
        ),
      );
    });
    _disposeEditor(previous);
    unawaited(_loadRunUsage(result.data!.agentRunId));
    _showSnack('发芽洞见已生成');
  }

  Future<void> _removeAiAnnotation(String annotationId) async {
    final remaining = _editor.snapshot.aiAnnotations
        .where((annotation) => annotation.id != annotationId)
        .toList(growable: false);
    _editor.replaceAiAnnotations(remaining);
    await _editor.saveNow();
    if (mounted) _showSnack('已移除 AI 注解');
  }

  Future<void> _sendPrompt() async {
    final prompt = _chatInput.text.trim();
    if (prompt.isEmpty || _generating) return;
    if (!_workspaceIsReady) {
      _showSnack(_accountSignedIn ? 'Workspace 正在准备，完成后才能开始聊天' : '请先登录后再开始聊天');
      return;
    }
    _chatInput.clear();
    setState(() {
      _chatMessages.add(_AiMessage(text: prompt, fromUser: true));
      _latestChatAnswer = null;
      _generating = true;
      _generatingMode = _PrimaryWorkspaceMode.chat;
    });
    final thread = await _ensureRemoteChatThread();
    if (!thread.isSuccess) {
      _finishChatFailure(thread.message);
      return;
    }
    final threadId = thread.data!.threadId;
    final agentProfileId =
        thread.data!.agentProfileId ?? _newChatAgentProfileId;
    final references = await _remoteChatReferences();
    if (!mounted) return;
    if (references.length < _activeChatContexts.length) {
      _showSnack('未同步的本地上下文未发送');
    }
    final asyncPort = widget.chatPort is DesktopChatAsyncSubmissionPort
        ? widget.chatPort as DesktopChatAsyncSubmissionPort
        : null;
    final result = await (asyncPort == null
        ? widget.chatPort.sendText(
            threadId: threadId,
            content: prompt,
            agentProfileId: agentProfileId,
            references: references,
          )
        : asyncPort.sendAcceptedText(
            threadId: threadId,
            content: prompt,
            agentProfileId: agentProfileId,
            references: references,
          ));
    if (!result.isSuccess) {
      _finishChatFailure(result.message);
      return;
    }
    final accepted = result.data!;
    await _chatTaskTracker.recordThreadDetail(
      DesktopChatThreadDetail(
        thread: thread.data!,
        messages: <DesktopChatMessage>[accepted.userMessage],
      ),
      activate: true,
    );
    final response = accepted.assistantMessage?.text;
    final agentRunId = accepted.agentRunId;
    if (response == null || response.trim().isEmpty) {
      if (accepted.taskId != null || accepted.agentRunId != null) {
        await _chatTaskTracker.registerAccepted(accepted);
        if (mounted) {
          setState(() {
            _generating = false;
            _generatingMode = null;
          });
        }
        return;
      }
      _finishChatFailure('消息已提交，服务暂未返回可显示的回复');
      return;
    }
    if (!mounted) return;
    setState(() {
      _generating = false;
      _generatingMode = null;
      _latestChatAnswer = response;
      _chatMessages.add(_AiMessage.fromDesktop(accepted.assistantMessage!));
    });
    unawaited(
      _chatTaskTracker.recordThreadDetail(
        DesktopChatThreadDetail(
          thread: thread.data!,
          messages: <DesktopChatMessage>[
            accepted.userMessage,
            accepted.assistantMessage!,
          ],
        ),
        activate: true,
      ),
    );
    if (agentRunId != null) unawaited(_loadRunUsage(agentRunId));
  }

  Future<void> _loadRunUsage(String runId) async {
    final result = await widget.accountUsagePort.loadRunUsage(runId);
    if (!mounted) return;
    setState(() => _runUsageResult = result);
  }

  void _finishChatFailure(String message) {
    if (!mounted) return;
    setState(() {
      _generating = false;
      _generatingMode = null;
      _latestChatAnswer = null;
      _chatMessages.add(
        _AiMessage(
          text: message.trim().isEmpty ? '聊天服务暂不可用' : message,
          fromUser: false,
        ),
      );
    });
  }

  Future<List<DesktopChatContextReference>> _remoteChatReferences() async {
    final references = <DesktopChatContextReference>[];
    for (final context in _activeChatContexts) {
      for (final document in _documents) {
        for (final stage in HuahuoNoteStage.values) {
          if (context.id != _noteStageTabId(document, stage)) continue;
          final part = switch (stage) {
            HuahuoNoteStage.raw => 'raw',
            HuahuoNoteStage.summary => 'outline',
            HuahuoNoteStage.sprout => 'germination',
          };
          final remote = await widget.documentSyncPort.remoteReferenceFor(
            localDocumentId: document.id,
            part: part,
          );
          if (remote != null && remote.localRevision == document.revision) {
            references.add(
              DesktopChatContextReference.workspaceDocument(
                ownerId: remote.noteId,
                part: remote.part,
                partRevisionId: remote.partRevisionId,
              ),
            );
          }
        }
      }
    }
    return references;
  }

  void _moveChatAnswerToCreation() {
    final answer = _latestChatAnswer;
    if (answer == null) return;
    _appendToDocument(answer, confirmation: '已转到创作空间');
  }

  Future<void> _createChatNote(_AiMessage message) async {
    final assistant = message.source;
    final workspaceId = _activeWorkspaceId;
    if (assistant == null ||
        assistant.role != 'assistant' ||
        workspaceId == null ||
        workspaceId.isEmpty) {
      _showSnack('当前回复还不能创建为资产');
      return;
    }
    final messageId = assistant.messageId;
    if (_chatNoteCreationIds.contains(messageId)) return;
    setState(() => _chatNoteCreationIds.add(messageId));
    try {
      final result = await widget.chatNoteCreator.create(
        workspaceId: workspaceId,
        assistantMessage: assistant,
      );
      if (!mounted) return;
      if (!result.isSuccess || result.data == null) {
        _showSnack(result.message);
        return;
      }
      final pull = await _pullRemoteDocuments();
      if (!mounted) return;
      setState(() => _assetsLoaded = false);
      if (!pull.isSuccess) {
        _showSnack('资产已创建，刷新本地资产缓存失败：${pull.message}');
        return;
      }
      _showCreatedChatAssetSnack(result.data!.title);
    } finally {
      if (mounted) setState(() => _chatNoteCreationIds.remove(messageId));
    }
  }

  void _showCreatedChatAssetSnack(String title) {
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('已创建资产「$title」'),
        action: SnackBarAction(
          label: '查看资产',
          onPressed: () {
            if (!mounted) return;
            setState(() {
              _activeSection = _WorkspaceSection.assets;
              _primaryMode = _PrimaryWorkspaceMode.creation;
              _contextPanelOpen = false;
            });
            unawaited(_loadRemoteAssets(force: true));
          },
        ),
      ),
    );
  }

  void _appendToDocument(String text, {required String confirmation}) {
    final prefix = _editor.body.document.toPlainText().trim().isEmpty
        ? ''
        : '\n\n';
    _editor.insertAtCursor('$prefix$text');
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.creation;
      _contextPanelOpen = false;
      _upsertTab(
        _WorkspaceTab(
          id: _noteStageTabId(_editor.snapshot, HuahuoNoteStage.raw),
          title: _editor.title.text.trim().isEmpty
              ? '未命名文稿'
              : _editor.title.text.trim(),
          kind: _WorkspaceTabKind.document,
          section: _WorkspaceSection.creation,
          documentId: _editor.snapshot.id,
          noteStage: HuahuoNoteStage.raw,
        ),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bodyFocus.requestFocus();
    });
    _showSnack(confirmation);
  }

  void _openAgentConversation(String agentProfileId) {
    if (!_workspaceIsReady) {
      _showSnack(_accountSignedIn ? 'Workspace 正在准备，完成后才能开始聊天' : '请先登录后再开始聊天');
      return;
    }
    final normalized = agentProfileId.trim();
    final existing = _chatThreads
        .where((thread) => thread.agentProfileId == normalized)
        .firstOrNull;
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.chat;
      _activeSection = _WorkspaceSection.chat;
      _chatRailCollapsed = false;
    });
    if (existing != null) {
      unawaited(_openRemoteChatThread(existing.threadId));
    } else {
      _startNewChat(agentProfileId: normalized);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _chatFocus.requestFocus();
    });
  }

  void _startNewChat({String? agentProfileId}) {
    if (!_workspaceIsReady) {
      _showSnack('Workspace 正在准备，暂时不能创建新对话');
      return;
    }
    final selectedAgentProfileId = agentProfileId?.trim();
    final opening = _localDesktopAgentOpeningMessage(selectedAgentProfileId);
    setState(() {
      _chatMessages
        ..clear()
        ..add(
          _AiMessage(
            text: opening ?? '这是一个新对话。把正在思考的问题发给我就可以。',
            fromUser: false,
          ),
        );
      _latestChatAnswer = null;
      _activeChatThreadId = null;
      _newChatAgentProfileId =
          selectedAgentProfileId == null || selectedAgentProfileId.isEmpty
          ? null
          : selectedAgentProfileId;
      _activeDailyTopicTitle = null;
      _chatContexts.clear();
      _chatInput.clear();
    });
    unawaited(_chatTaskTracker.setActiveThread(null));
    _chatFocus.requestFocus();
    unawaited(_createRemoteChatThread());
  }

  Future<void> _createRemoteChatThread() async {
    final result = await _ensureRemoteChatThread();
    if (!mounted) return;
    if (!result.isSuccess) {
      _finishChatFailure(result.message);
      return;
    }
  }

  Future<DesktopServiceResult<DesktopChatThread>> _ensureRemoteChatThread() {
    if (!_workspaceIsReady) {
      return Future.value(
        const DesktopServiceResult<DesktopChatThread>.failure(
          code: 'WORKSPACE_NOT_READY',
          message: 'Workspace 正在初始化，请稍后再试',
          retryable: true,
        ),
      );
    }
    final activeId = _activeChatThreadId;
    if (activeId != null) {
      final existing = _chatThreads
          .where((thread) => thread.threadId == activeId)
          .firstOrNull;
      if (existing != null) {
        return Future.value(
          DesktopServiceResult<DesktopChatThread>.success(existing),
        );
      }
    }
    final pending = _chatThreadCreation;
    if (pending != null) return pending;
    final future = widget.chatPort
        .createThread()
        .then((result) {
          if (mounted && result.isSuccess) {
            final thread = _withChatAgentProfile(
              result.data!,
              _newChatAgentProfileId,
            );
            setState(() {
              _activeChatThreadId = thread.threadId;
              _chatThreads.removeWhere(
                (candidate) => candidate.threadId == thread.threadId,
              );
              _chatThreads.insert(0, thread);
            });
            unawaited(_chatTaskTracker.updateThreads(_chatThreads));
            return DesktopServiceResult<DesktopChatThread>.success(thread);
          }
          return result;
        })
        .whenComplete(() => _chatThreadCreation = null);
    _chatThreadCreation = future;
    return future;
  }

  DesktopChatThread _withChatAgentProfile(
    DesktopChatThread thread,
    String? requestedAgentProfileId,
  ) => DesktopChatThread(
    threadId: thread.threadId,
    title: thread.title,
    updatedAt: thread.updatedAt,
    agentProfileId: thread.agentProfileId ?? requestedAgentProfileId,
    activeRuns: thread.activeRuns,
  );

  Future<void> _createFolder() async {
    var draftName = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          key: const ValueKey<String>('new-folder-input'),
          contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onChanged: (value) => draftName = value,
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
          decoration: const InputDecoration(
            labelText: '文件夹名称',
            hintText: '例如：播客脚本',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draftName.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (!mounted || name == null || name.isEmpty) return;
    setState(() {
      _customFolders.add(name);
      _expandedFolders.add(name);
    });
    _showSnack('已创建文件夹「$name」');
  }

  @override
  void dispose() {
    _incomingDocumentSubscription?.cancel();
    _workspaceSearchDebounce?.cancel();
    _stopWorkspaceStatusPolling();
    _stopTopicCollisionPolling();
    _recordingProgressPolls.clear();
    _chatTaskTracker
      ..removeListener(_handleChatTaskTrackerChanged)
      ..dispose();
    _notificationsController.dispose();
    _activityCalendarController.dispose();
    _workspaceManagementController.dispose();
    _homeController.dispose();
    widget.resourceImageCache.dispose();
    _disposeEditor(_editor);
    _bodyFocus.dispose();
    _chatFocus.dispose();
    _bodyScroll.dispose();
    _chatInput.dispose();
    _searchInput.dispose();
    _externalSearchInput.dispose();
    _knowledgeSquareSearchInput.dispose();
    _captureTextInput.dispose();
    _captureImportInput.dispose();
    _graphPreferences.dispose();
    _markdownPreviewPreferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            unawaited(_editor.saveNow()),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
            unawaited(_editor.saveNow()),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            unawaited(_showCommandPalette()),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            unawaited(_showCommandPalette()),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            _primaryMode == _PrimaryWorkspaceMode.creation
            ? _editor.toggleAttribute(Attribute.bold)
            : null,
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            _primaryMode == _PrimaryWorkspaceMode.creation
            ? _editor.toggleAttribute(Attribute.bold)
            : null,
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            _primaryMode == _PrimaryWorkspaceMode.creation
            ? _editor.toggleAttribute(Attribute.italic)
            : null,
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
            _primaryMode == _PrimaryWorkspaceMode.creation
            ? _editor.toggleAttribute(Attribute.italic)
            : null,
        const SingleActivator(LogicalKeyboardKey.backslash, control: true):
            _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.backslash, meta: true):
            _toggleSidebar,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const ValueKey<String>('desktop-workspace'),
          backgroundColor: Colors.transparent,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final chatRailAvailable =
                  !_focusMode &&
                  constraints.maxWidth >=
                      HuahuoDesktopMetrics.chatRailBreakpoint;
              final splitContext =
                  chatRailAvailable &&
                  constraints.maxWidth >=
                      HuahuoDesktopMetrics.contextSplitBreakpoint;
              final showExplorer =
                  _explorerIsAvailable &&
                  _showNoteDrafts &&
                  _sidebarExpanded &&
                  constraints.maxWidth >= 760 &&
                  !_focusMode;
              return Stack(
                children: [
                  Positioned.fill(
                    child: Row(
                      children: [
                        if (!_focusMode) _buildActivityBar(),
                        if (showExplorer) _buildExplorer(),
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: Column(
                                  children: [
                                    _buildTabBar(showExplorer),
                                    Expanded(
                                      child: _buildActiveWorkspace(
                                        showExplorer,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_contextPanelOpen && !splitContext) ...[
                                Positioned.fill(
                                  child: GestureDetector(
                                    onTap: () => setState(
                                      () => _contextPanelOpen = false,
                                    ),
                                    child: ColoredBox(
                                      color: Colors.black.withValues(
                                        alpha: 0.08,
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: HuahuoDesktopMetrics.tabBarHeight,
                                  right: 0,
                                  bottom: 0,
                                  width: HuahuoDesktopMetrics.contextPanel,
                                  child: _buildContextPanel(),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (_contextPanelOpen && splitContext)
                          _buildContextPanel(),
                        if (chatRailAvailable)
                          _chatRailCollapsed
                              ? _buildCollapsedChatRail()
                              : _buildChatRail(),
                      ],
                    ),
                  ),
                  if (_workspacePreparing)
                    Positioned.fill(child: _buildWorkspacePreparationSurface()),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  bool get _explorerIsAvailable =>
      _activeSection == _WorkspaceSection.creation ||
      _activeSection == _WorkspaceSection.assets;

  bool get _isAssetsExplorer => _activeSection == _WorkspaceSection.assets;

  Widget _buildWorkspacePreparationSurface() {
    final colors = Theme.of(context).colorScheme;
    final status = _workspaceAccount?.workspaceStatus.trim().toLowerCase();
    final failed = status == 'sync_failed';
    final message = failed
        ? 'Workspace 初始化未完成。重新初始化后，系统会继续准备文件和索引。'
        : '正在生成 Workspace 文件并建立索引，完成后才能开始聊天和运行 Agent。';
    return Material(
      color: colors.surface.withValues(alpha: .985),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!failed)
                  const SizedBox.square(
                    dimension: 30,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else
                  Icon(LucideIcons.circleAlert, size: 32, color: colors.error),
                const SizedBox(height: 18),
                Text(
                  failed ? 'Workspace 初始化需要重新开始' : '正在准备你的 Workspace',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    height: 1.55,
                  ),
                ),
                if (_workspacePreparationError?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 10),
                  Text(
                    _workspacePreparationError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.error, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 20),
                if (failed)
                  FilledButton.icon(
                    key: const ValueKey<String>('desktop-workspace-retry'),
                    onPressed: _workspaceRetrying
                        ? null
                        : () => unawaited(_retryWorkspacePreparation()),
                    icon: _workspaceRetrying
                        ? const SizedBox.square(
                            dimension: 15,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        : const Icon(LucideIcons.rotateCw, size: 16),
                    label: Text(_workspaceRetrying ? '正在重新初始化' : '重新初始化'),
                  )
                else
                  Text(
                    _workspaceStatusRefreshing ? '正在刷新状态' : '准备中',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => unawaited(_signOut()),
                  child: const Text('退出登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggleSidebar() {
    if (!_explorerIsAvailable) {
      _showSnack('思想图谱不显示资源侧栏');
      return;
    }
    setState(() {
      if (!_showNoteDrafts) {
        _showNoteDrafts = true;
        _sidebarExpanded = true;
        return;
      }
      _sidebarExpanded = !_sidebarExpanded;
    });
  }

  Widget _buildActiveWorkspace(bool explorerVisible) {
    final tab = _activeTab;
    return switch (tab.kind) {
      _WorkspaceTabKind.graph => _buildGraphWorkspace(),
      _WorkspaceTabKind.document => _buildEditorPane(explorerVisible),
      _WorkspaceTabKind.chat => _buildChatWorkspace(explorerVisible),
      _WorkspaceTabKind.feature => _buildFeatureWorkspace(tab),
    };
  }

  Widget _buildActivityBar() {
    final colors = Theme.of(context).colorScheme;
    const destinations = <(_WorkspaceSection, IconData, String, String)>[
      (_WorkspaceSection.brain, LucideIcons.network, '思想图谱', 'graph-mode'),
      (
        _WorkspaceSection.creation,
        LucideIcons.penLine,
        '创作空间',
        'creation-mode',
      ),
      (_WorkspaceSection.tools, LucideIcons.sparkles, '创作工具', 'tools-mode'),
      (
        _WorkspaceSection.externalKnowledge,
        LucideIcons.bookOpenText,
        '外部知识',
        'external-knowledge-mode',
      ),
      (
        _WorkspaceSection.assets,
        LucideIcons.folderKanban,
        '我的资产',
        'assets-mode',
      ),
    ];
    return Container(
      width: HuahuoDesktopMetrics.activityBar,
      decoration: BoxDecoration(color: colors.surfaceContainerLow),
      child: Column(
        children: [
          SizedBox(
            height: HuahuoDesktopMetrics.tabBarHeight,
            child: Center(
              child: Semantics(
                image: true,
                label: '花火 AI',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.asset(
                    'assets/images/huahuo_brand_mark.png',
                    width: 22,
                    height: 22,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          for (final destination in destinations)
            _ActivityButton(
              key: ValueKey<String>(destination.$4),
              icon: destination.$2,
              label: destination.$3,
              selected: _activeSection == destination.$1,
              onTap: () => _openSection(destination.$1),
            ),
          const Spacer(),
          _ActivityButton(
            key: const ValueKey<String>('capture-mode'),
            icon: LucideIcons.audioLines,
            label: '采集与独白',
            selected: _activeSection == _WorkspaceSection.capture,
            onTap: () => _openSection(_WorkspaceSection.capture),
          ),
          _ActivityButton(
            key: const ValueKey<String>('notifications-mode'),
            icon: LucideIcons.bell,
            label: '通知',
            selected: _activeSection == _WorkspaceSection.notifications,
            onTap: () => _openSection(_WorkspaceSection.notifications),
          ),
          const SizedBox(height: 4),
          _ActivityButton(
            key: const ValueKey<String>('settings-mode'),
            icon: LucideIcons.settings,
            label: '设置',
            selected: _activeSection == _WorkspaceSection.settings,
            onTap: () => _openSection(_WorkspaceSection.settings),
          ),
          _ActivityButton(
            key: const ValueKey<String>('account-mode'),
            icon: LucideIcons.circleUserRound,
            label: '个人账户',
            selected: _activeSection == _WorkspaceSection.account,
            onTap: () => _openSection(_WorkspaceSection.account),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildExplorer() {
    final colors = Theme.of(context).colorScheme;
    final isAssets = _isAssetsExplorer;
    final query = _searchInput.text.trim().toLowerCase();
    final filteredDocuments = _documents
        .where(
          (document) =>
              query.isEmpty || document.title.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final subscribedItems = _externalKnowledgeItems
        .where((item) => item.subscribed)
        .where(
          (item) =>
              query.isEmpty ||
              item.title.toLowerCase().contains(query) ||
              item.detail.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final meetingRecords = _captureRecords
        .where((record) => record.mode == _CaptureMode.meeting)
        .toList(growable: false);
    bool visible(String label) =>
        query.isEmpty || label.toLowerCase().contains(query);
    return Container(
      key: const ValueKey<String>('note-explorer'),
      width: HuahuoDesktopMetrics.sidebarExpanded,
      decoration: BoxDecoration(
        color: _translucentSurface(
          context,
          colors.surfaceContainerLow,
          lightAlpha: 0.96,
          darkAlpha: 0.97,
        ),
      ),
      child: Column(
        children: [
          SizedBox(
            height: HuahuoDesktopMetrics.tabBarHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: 13, right: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      isAssets ? '我的资产' : '我的创作',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('new-document'),
                    tooltip: '新建文稿',
                    onPressed: isAssets
                        ? null
                        : () => unawaited(_createDocument()),
                    icon: const Icon(LucideIcons.squarePen, size: 15),
                  ),
                  IconButton(
                    key: const ValueKey<String>('new-folder'),
                    tooltip: '新建文件夹',
                    onPressed: isAssets
                        ? null
                        : () => unawaited(_createFolder()),
                    icon: const Icon(LucideIcons.folder, size: 15),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 10, 9, 7),
            child: SizedBox(
              height: 32,
              child: TextField(
                key: const ValueKey<String>('explorer-search'),
                contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
                controller: _searchInput,
                onChanged: _handleExplorerSearchChanged,
                style: const TextStyle(fontSize: 12.5, letterSpacing: 0),
                decoration: InputDecoration(
                  hintText: isAssets ? '搜索资产' : '搜索创作',
                  prefixIcon: const Icon(LucideIcons.search, size: 15),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                if (query.isNotEmpty) ..._buildWorkspaceSearchExplorer(query),
                if (!isAssets) ...[
                  if (query.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(9, 2, 9, 8),
                      child: OutlinedButton.icon(
                        key: const ValueKey<String>('cloud-creations-entry'),
                        onPressed: _openCreationWorkspace,
                        icon: const Icon(LucideIcons.cloud, size: 15),
                        label: const Text('云端创作与历史'),
                      ),
                    ),
                  _buildFolderHeader('我的创作', count: filteredDocuments.length),
                  if (_expandedFolders.contains('我的创作'))
                    for (final document in filteredDocuments)
                      _buildNoteDocumentTree(document, source: '我的创作'),
                  _buildFolderHeader(
                    '最新创作',
                    count: filteredDocuments.take(3).length,
                  ),
                  if (_expandedFolders.contains('最新创作'))
                    for (final document in filteredDocuments.take(3))
                      _buildNoteDocumentTree(document, source: '最新创作'),
                  for (final folder in _customFolders)
                    if (visible(folder)) _buildFolderHeader(folder, count: 0),
                ] else ...[
                  _buildFolderHeader('我的创作', count: filteredDocuments.length),
                  if (_expandedFolders.contains('我的创作'))
                    for (final document in filteredDocuments)
                      _buildNoteDocumentTree(document, source: '我的创作'),
                  _buildFolderHeader('我的会议', count: meetingRecords.length),
                  if (_expandedFolders.contains('我的会议'))
                    if (meetingRecords.isEmpty)
                      _buildExplorerEmptyState('暂无会议记录', '从采集与独白开始一场会议录音。')
                    else
                      for (final record in meetingRecords)
                        _buildExplorerResourceRow(
                          icon: _captureModeIcon(record.mode),
                          title: record.title,
                          detail: record.detail,
                          onTap: () => _openReferenceTab(
                            record.title,
                            section: _WorkspaceSection.assets,
                            contextId: 'capture-${record.id}',
                            contextSource: '我的会议',
                          ),
                          onAddToContext: () => _addChatContext(
                            record.title,
                            id: 'capture-${record.id}',
                            source: '我的会议',
                            revealChat: true,
                          ),
                        ),
                  _buildFolderHeader('我的订阅', count: subscribedItems.length),
                  if (_expandedFolders.contains('我的订阅'))
                    if (subscribedItems.isEmpty)
                      _buildExplorerEmptyState('暂无订阅', '在外部知识中订阅来源后会显示在这里。')
                    else
                      for (final item in subscribedItems)
                        _buildExplorerResourceRow(
                          icon: item.kind,
                          title: item.title,
                          detail: item.detail,
                          onTap: () => _openExternalKnowledgeDetail(item),
                          onAddToContext: () => _addChatContext(
                            item.title,
                            id: 'external-${item.id}',
                            source: '我的订阅',
                            payload: item.summary,
                            revealChat: true,
                          ),
                        ),
                ],
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(10),
              child: LinearProgressIndicator(minHeight: 1),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildWorkspaceSearchExplorer(String query) {
    final workspaceId = _activeWorkspaceId;
    if (workspaceId == null) {
      return <Widget>[
        _buildFolderHeader('Workspace 搜索', count: 0),
        _workspaceSearchStateRow(
          key: 'workspace-search-local-only',
          title: '当前仅搜索本机文稿',
          detail: '登录并完成 Workspace 初始化后可搜索云端笔记。',
        ),
      ];
    }
    if (_workspaceSearchLoading) {
      return <Widget>[
        _buildFolderHeader('Workspace 搜索', count: 0),
        _workspaceSearchStateRow(
          key: 'workspace-search-loading',
          title: '正在搜索 Workspace',
          detail: '本机标题结果仍可继续使用。',
          loading: true,
        ),
      ];
    }
    final result = _workspaceSearchResult;
    if (result == null) {
      return <Widget>[
        _buildFolderHeader('Workspace 搜索', count: 0),
        _workspaceSearchStateRow(
          key: 'workspace-search-loading',
          title: '准备搜索 Workspace',
          detail: '本机标题结果仍可继续使用。',
          loading: true,
        ),
      ];
    }
    if (!result.isSuccess || result.data == null) {
      return <Widget>[
        _buildFolderHeader('Workspace 搜索', count: 0),
        _workspaceSearchStateRow(
          key: 'workspace-search-error',
          title: result.isUnavailable ? '云端搜索不可用' : '云端搜索失败',
          detail: '${result.message}，当前仅显示本机结果。',
          onRetry: () => _scheduleWorkspaceSearch(immediate: true),
        ),
      ];
    }
    final items = result.data!.results;
    return <Widget>[
      _buildFolderHeader('Workspace 搜索', count: items.length),
      if (items.isEmpty)
        _workspaceSearchStateRow(
          key: 'workspace-search-empty',
          title: '云端没有匹配笔记',
          detail: '仍可查看下方本机标题结果。',
        )
      else
        for (final item in items)
          KeyedSubtree(
            key: ValueKey<String>(
              'workspace-search-result-${item.ownerRef.id}-${item.revisionId}',
            ),
            child: _buildExplorerResourceRow(
              icon: LucideIcons.fileSearch,
              title: item.title ?? 'Workspace 笔记',
              detail:
                  '${item.part ?? 'raw'} · 精确版本${item.staleSource ? ' · 来源待复核' : ''}',
              onTap: () => unawaited(_openWorkspaceSearchResult(item)),
              onAddToContext: () => unawaited(_openWorkspaceSearchResult(item)),
            ),
          ),
    ];
  }

  Widget _workspaceSearchStateRow({
    required String key,
    required String title,
    required String detail,
    bool loading = false,
    VoidCallback? onRetry,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey<String>(key),
      padding: const EdgeInsets.fromLTRB(29, 6, 10, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (loading)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: SizedBox.square(
                dimension: 13,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            )
          else
            Icon(LucideIcons.cloud, size: 14, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 12.5)),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 10.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (onRetry != null)
            IconButton(
              key: const ValueKey<String>('workspace-search-retry'),
              tooltip: '重试云端搜索',
              onPressed: onRetry,
              icon: const Icon(LucideIcons.refreshCw, size: 14),
            ),
        ],
      ),
    );
  }

  Widget _buildNoteDocumentTree(
    HuahuoDocumentSnapshot document, {
    required String source,
  }) {
    final activeDocument =
        _activeTabIsDocument && document.id == _editor.snapshot.id;
    final activeStage = activeDocument ? _activeNoteStage : null;
    return _NoteDocumentTree(
      document: document,
      activeStage: activeStage,
      onOpenStage: (stage) =>
          unawaited(_activateDocument(document, stage: stage)),
      onAddStageToContext: (stage) => _addChatContext(
        _noteStageContextTitle(document, stage),
        id: _noteStageTabId(document, stage),
        source: '$source · ${_noteStageLabel(stage)}',
        payload: _noteStagePayload(document, stage),
      ),
      stageLabel: _noteStageLabel,
      stageIcon: _noteStageIcon,
    );
  }

  Widget _buildExplorerEmptyState(String title, String detail) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 5, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 3),
          Text(
            detail,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 11.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExplorerResourceRow({
    required IconData icon,
    required String title,
    required String detail,
    required VoidCallback onTap,
    required VoidCallback onAddToContext,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HuahuoRadii.control),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(29, 5, 4, 5),
          child: Row(
            children: [
              Icon(icon, size: 14, color: colors.onSurfaceVariant),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: '加入聊天上下文',
                child: IconButton(
                  onPressed: onAddToContext,
                  icon: const Icon(LucideIcons.plus, size: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFolderHeader(String title, {required int count}) {
    final colors = Theme.of(context).colorScheme;
    final expanded = _expandedFolders.contains(title);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('folder-$title'),
        onTap: () => setState(() {
          expanded
              ? _expandedFolders.remove(title)
              : _expandedFolders.add(title);
        }),
        child: SizedBox(
          height: 30,
          child: Padding(
            padding: const EdgeInsets.only(left: 8, right: 9),
            child: Row(
              children: [
                DesktopDisclosureChevron(
                  expanded: expanded,
                  size: 14,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 3),
                Icon(
                  expanded ? LucideIcons.folderOpen : LucideIcons.folder,
                  size: 15,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabBar(bool explorerVisible) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('editor-tab-bar'),
      height: HuahuoDesktopMetrics.tabBarHeight,
      decoration: BoxDecoration(color: colors.surfaceContainerLow),
      child: Row(
        children: [
          if (_explorerIsAvailable)
            IconButton(
              key: const ValueKey<String>('sidebar-toggle'),
              tooltip: explorerVisible ? '收起资源栏' : '展开资源栏',
              onPressed: _toggleSidebar,
              icon: Icon(
                explorerVisible
                    ? LucideIcons.panelLeftClose
                    : LucideIcons.panelLeftOpen,
                size: 16,
              ),
            )
          else
            const SizedBox(width: 8),
          const SizedBox(width: 2),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final tab in _tabs)
                  _WorkspaceTabButton(
                    key: ValueKey<String>('tab-${tab.id}'),
                    title: _tabTitle(tab),
                    icon: _tabIcon(tab),
                    selected: tab.id == _activeTabId,
                    closeable: tab.closeable,
                    onTap: () => _selectTab(tab.id),
                    onClose: () => _closeTab(tab),
                  ),
              ],
            ),
          ),
          if (_activeTabIsDocument)
            IconButton(
              key: const ValueKey<String>('chat-rail-focus'),
              tooltip: '聚焦聊天',
              onPressed: _focusPrimaryComposer,
              icon: Icon(
                LucideIcons.messagesSquare,
                size: 16,
                color: _chatRailCollapsed ? null : colors.primary,
              ),
            ),
          if (_activeTabIsDocument)
            IconButton(
              key: const ValueKey<String>('outline-panel-toggle'),
              tooltip: '我的内容大纲',
              onPressed: () {
                if (_contextPanelOpen && _contextKind == _ContextKind.outline) {
                  setState(() => _contextPanelOpen = false);
                } else {
                  _openContext(_ContextKind.outline);
                }
              },
              icon: Icon(
                LucideIcons.listTree,
                size: 16,
                color: _contextPanelOpen && _contextKind == _ContextKind.outline
                    ? colors.primary
                    : null,
              ),
            ),
          if (_activeTabIsDocument)
            IconButton(
              key: const ValueKey<String>('relations-panel-toggle'),
              tooltip: '笔记关系',
              onPressed: () {
                if (_contextPanelOpen &&
                    _contextKind == _ContextKind.relations) {
                  setState(() => _contextPanelOpen = false);
                } else {
                  _openContext(_ContextKind.relations);
                }
              },
              icon: Icon(
                LucideIcons.waypoints,
                size: 16,
                color:
                    _contextPanelOpen && _contextKind == _ContextKind.relations
                    ? colors.primary
                    : null,
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  String _tabTitle(_WorkspaceTab tab) {
    final stageSuffix =
        tab.noteStage == null || tab.noteStage == HuahuoNoteStage.raw
        ? ''
        : ' · ${_noteStageLabel(tab.noteStage!)}';
    if (tab.documentId == _editor.snapshot.id) {
      final title = _editor.title.text.trim();
      return '${title.isEmpty ? '未命名文稿' : title}$stageSuffix';
    }
    if (tab.documentId != null) {
      final index = _documents.indexWhere(
        (document) => document.id == tab.documentId,
      );
      if (index >= 0) {
        final title = _documents[index].title.trim();
        return '${title.isEmpty ? '未命名文稿' : title}$stageSuffix';
      }
    }
    return tab.title;
  }

  IconData _tabIcon(_WorkspaceTab tab) => switch (tab.kind) {
    _WorkspaceTabKind.graph => LucideIcons.network,
    _WorkspaceTabKind.document => _noteStageIcon(
      tab.noteStage ?? HuahuoNoteStage.raw,
    ),
    _WorkspaceTabKind.chat => LucideIcons.messagesSquare,
    _WorkspaceTabKind.feature => _sectionIcon(
      tab.section ?? _WorkspaceSection.assets,
    ),
  };

  Widget _buildGraphWorkspace() {
    final colors = Theme.of(context).colorScheme;
    final collisionRun = _topicCollisionRun;
    final collisionRunning =
        _topicCollisionPolling ||
        (collisionRun != null && !collisionRun.isTerminal);
    final collisionFailed =
        !collisionRunning &&
        (_topicCollisionError != null ||
            (collisionRun != null &&
                collisionRun.isTerminal &&
                !collisionRun.isSuccessful));
    final collisionSourceSummary = _topicCollisionSourceSummary(collisionRun);
    return ColoredBox(
      key: const ValueKey<String>('graph-workspace'),
      color: colors.surface,
      child: Column(
        children: [
          SizedBox(
            height: HuahuoDesktopMetrics.topBarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.network,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                  Text('思想图谱', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 10),
                  Text(
                    '${_documents.length} 篇文稿 · '
                    '${DesktopKnowledgeGraph.graphPointCountFor(_documents)} 个图谱点',
                    key: const ValueKey<String>('knowledge-graph-node-count'),
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 11.5,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey<String>('desktop-daily-topic-entry'),
                    tooltip: '今日推送',
                    onPressed: _workspaceIsReady
                        ? () => unawaited(_openDailyTopicWorkspace())
                        : null,
                    icon: const Icon(LucideIcons.lightbulb, size: 16),
                  ),
                  IconButton(
                    key: const ValueKey<String>('desktop-topic-collision'),
                    tooltip: collisionRunning
                        ? '聚合生成中'
                        : collisionFailed
                        ? '重新聚合 4 条资产'
                        : '聚合 4 条资产',
                    onPressed: _workspaceIsReady && !collisionRunning
                        ? () => unawaited(_startTopicCollision())
                        : null,
                    icon: collisionRunning
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        : Icon(
                            collisionFailed
                                ? LucideIcons.refreshCw
                                : LucideIcons.network,
                            size: 16,
                          ),
                  ),
                  if (collisionRunning)
                    Text(
                      '聚合生成中',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11.5,
                      ),
                    )
                  else if (collisionFailed)
                    Text(
                      '聚合失败，可重试',
                      key: const ValueKey<String>(
                        'desktop-topic-collision-failed',
                      ),
                      style: TextStyle(color: colors.error, fontSize: 11.5),
                    ),
                  if (collisionRunning && collisionSourceSummary != null) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: collisionSourceSummary,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Text(
                          collisionSourceSummary,
                          key: const ValueKey<String>(
                            'desktop-topic-collision-sources',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                  TextButton.icon(
                    onPressed: () => unawaited(_createDocument()),
                    icon: const Icon(LucideIcons.squarePen, size: 15),
                    label: const Text('新建文稿'),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<DesktopGraphPreferences>(
              valueListenable: _graphPreferences,
              builder: (context, preferences, _) => DesktopKnowledgeGraph(
                documents: _documents,
                preferences: preferences,
                onOpenDocument: (id) {
                  final document = _documents.firstWhere(
                    (candidate) => candidate.id == id,
                  );
                  unawaited(_activateDocument(document));
                },
                onOpenReference: _openReferenceTab,
                onSelectionChanged: _handleGraphSelection,
                onAddToContext: _handleGraphContextAdd,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _topicCollisionSourceSummary(TopicCollisionRun? run) {
    final sources = run?.sources;
    if (sources == null || sources.isEmpty) return null;
    final labels = sources
        .map((source) {
          final title = source.title?.trim();
          return title == null || title.isEmpty ? source.inputRef : title;
        })
        .toList(growable: false);
    return labels.isEmpty ? null : '来源：${labels.join('、')}';
  }

  void _openReferenceTab(
    String title, {
    _WorkspaceSection section = _WorkspaceSection.assets,
    String? contextId,
    String? contextSource,
    String? contextPayload,
  }) {
    final normalizedTitle = title.trim();
    final selectedId =
        contextId ?? 'reference-${normalizedTitle.toLowerCase()}';
    final tabId = 'reference-${title.hashCode}';
    setState(() {
      _referenceContexts[tabId] = _ChatContextItem(
        id: selectedId,
        title: normalizedTitle,
        source: contextSource ?? '知识内容',
        payload: contextPayload,
      );
      _activeSection = section;
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _setSelectedContentInState(
        title: normalizedTitle,
        id: selectedId,
        source: contextSource ?? '知识内容',
        payload: contextPayload,
      );
      if (_contextAutoAttach) {
        _attachSelectedContentInState();
      }
      _upsertTab(
        _WorkspaceTab(
          id: tabId,
          title: title,
          kind: _WorkspaceTabKind.feature,
          section: section,
        ),
      );
    });
  }

  _ChatContextItem _graphContextItem(DesktopGraphSelection selection) {
    final documentId = selection.id.startsWith('document-')
        ? selection.id.substring('document-'.length)
        : null;
    final documentIndex = documentId == null
        ? -1
        : _documents.indexWhere((document) => document.id == documentId);
    final document = documentId == _editor.snapshot.id
        ? _editor.snapshot
        : documentIndex < 0
        ? null
        : _documents[documentIndex];
    if (document != null) {
      return _ChatContextItem(
        id: _noteStageTabId(document, HuahuoNoteStage.raw),
        title: _noteStageContextTitle(document, HuahuoNoteStage.raw),
        source: '思想图谱 · ${_noteStageLabel(HuahuoNoteStage.raw)}',
        payload: _noteStagePayload(document, HuahuoNoteStage.raw),
      );
    }
    return _ChatContextItem(
      id: selection.id,
      title: selection.label,
      source: '思想图谱',
    );
  }

  void _handleGraphSelection(DesktopGraphSelection selection) {
    if (selection.isBrain) return;
    final context = _graphContextItem(selection);
    setState(() {
      _setSelectedContentInState(
        title: context.title,
        id: context.id,
        source: context.source,
        payload: context.payload,
      );
      if (_contextAutoAttach) {
        _attachSelectedContentInState();
      }
    });
  }

  void _handleGraphContextAdd(DesktopGraphSelection selection) {
    if (selection.isBrain) return;
    final context = _graphContextItem(selection);
    _addChatContext(
      context.title,
      id: context.id,
      source: context.source,
      payload: context.payload,
      revealChat: true,
    );
  }

  void _openBookWorkspace() {
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.assets;
      _contextPanelOpen = false;
      _upsertTab(
        const _WorkspaceTab(
          id: 'book-work-book',
          title: '典藏长文',
          kind: _WorkspaceTabKind.feature,
          section: _WorkspaceSection.assets,
        ),
      );
    });
    unawaited(_loadBook());
  }

  void _openHomeWorkspace() {
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.brain;
      _contextPanelOpen = false;
      _upsertTab(
        const _WorkspaceTab(
          id: 'product-home',
          title: '首页',
          kind: _WorkspaceTabKind.feature,
          section: _WorkspaceSection.brain,
        ),
      );
    });
    if (_workspaceIsReady &&
        _homeController.state.status == ProductHomeStatus.idle) {
      unawaited(_homeController.bindWorkspace(_activeWorkspaceId));
    }
  }

  void _handleHomePrimaryAction(ProductHomeAction action) {
    switch (action.type) {
      case ProductHomeActionType.openRunningTask:
        _openSection(_WorkspaceSection.chat);
        final threadId = action.threadId;
        if (threadId != null) {
          unawaited(_openRemoteChatThread(threadId));
        } else {
          _showSnack('任务正在运行，可在任务面板查看进度');
        }
      case ProductHomeActionType.viewHotspotSuggestion:
        final suggestion = _homeController.state.home?.suggestion;
        if (suggestion != null) _openHomeSuggestion(suggestion);
      case ProductHomeActionType.uploadRecording:
        setState(() => _captureMode = _CaptureMode.media);
        _openSection(_WorkspaceSection.capture);
    }
  }

  void _openHomeSuggestion(ProductHomeSuggestion suggestion) {
    final sections = <String>[
      if (suggestion.eventBrief case final value?) '## 事件概览\n\n$value',
      if (suggestion.summary case final value?) '## 推荐摘要\n\n$value',
      if (suggestion.discussionPoints.isNotEmpty)
        '## 讨论要点\n\n${suggestion.discussionPoints.map((item) => '- $item').join('\n')}',
      if (suggestion.topicAngles.isNotEmpty)
        '## 内容角度\n\n${suggestion.topicAngles.map((item) => '- $item').join('\n')}',
    ];
    _openReferenceTab(
      suggestion.title,
      section: _WorkspaceSection.externalKnowledge,
      contextId: 'home-hotspot-${suggestion.id}',
      contextSource: '首页推荐',
      contextPayload: sections.join('\n\n'),
    );
    if (!suggestion.acknowledged) {
      unawaited(_homeController.acknowledgeSuggestion());
    }
  }

  void _openWorksWorkspace() {
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.tools;
      _contextPanelOpen = false;
      _upsertTab(
        const _WorkspaceTab(
          id: 'book-work-history',
          title: '创作历史',
          kind: _WorkspaceTabKind.feature,
          section: _WorkspaceSection.tools,
        ),
      );
    });
    unawaited(_loadWorks());
  }

  void _openActivityCalendarWorkspace() {
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.assets;
      _contextPanelOpen = false;
      _upsertTab(
        const _WorkspaceTab(
          id: 'activity-calendar',
          title: '活动日历',
          kind: _WorkspaceTabKind.feature,
          section: _WorkspaceSection.assets,
        ),
      );
    });
    if (_activeWorkspaceId != null &&
        _activityCalendarController.state.status ==
            DesktopActivityCalendarStatus.idle) {
      unawaited(_activityCalendarController.reload());
    }
  }

  void _openWorkspaceManagement() {
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.account;
      _contextPanelOpen = false;
      _upsertTab(
        const _WorkspaceTab(
          id: 'workspace-management',
          title: 'Workspace',
          kind: _WorkspaceTabKind.feature,
          section: _WorkspaceSection.account,
        ),
      );
    });
    if (_accountSignedIn &&
        _workspaceManagementController.state.status ==
            WorkspaceManagementStatus.idle) {
      unawaited(_workspaceManagementController.reload());
    }
  }

  Future<void> _handleDefaultWorkspaceChanged(String workspaceId) async {
    if (_activeWorkspaceId == workspaceId) return;
    setState(() => _authLoading = true);
    await widget.documentSyncPort.clearAccount();
    await _chatTaskTracker.clearCurrentAccount();
    await widget.resourceImageCache.clearAccount();
    _notificationsController.clearAccount();
    await _activityCalendarController.bindWorkspace(null);
    _homeController.reset();
    _agentController.clearAccount();
    _bookWorkController.clearAccount();
    if (!mounted) return;
    setState(() {
      _activeWorkspaceId = null;
      _proposalCreation = null;
      _chatThreads.clear();
      _activeChatThreadId = null;
      _workspaceSearchSequence++;
      _noteRelationsSequence++;
    });
    await _restoreAuthSession();
  }

  Future<void> _loadBook() async {
    if (_bookLoading) return;
    setState(() {
      _bookLoading = true;
      _bookResult = null;
    });
    final result = await _bookWorkController.loadBook();
    if (!mounted) return;
    setState(() {
      _bookLoading = false;
      _bookResult = result;
    });
  }

  Future<void> _loadWorks({bool discardPending = false}) async {
    if (_worksLoading) return;
    if (discardPending) {
      for (final work in _worksResult?.data ?? const <SharedWork>[]) {
        _bookWorkController.discardWorkMutations(work.workId);
      }
    }
    setState(() {
      _worksLoading = true;
      _worksResult = null;
    });
    final result = await _bookWorkController.loadAllWorks();
    if (!mounted) return;
    setState(() {
      _worksLoading = false;
      _worksResult = result;
      final selectedId = _workDetailResult?.data?.workId;
      if (selectedId != null &&
          (result.data?.every((work) => work.workId != selectedId) ?? true)) {
        _workDetailResult = null;
      }
    });
  }

  Future<void> _loadWorkDetail(String workId) async {
    if (_workDetailLoading) return;
    setState(() {
      _workDetailLoading = true;
      _workDetailResult = null;
    });
    final result = await _bookWorkController.loadWork(workId);
    if (!mounted) return;
    setState(() {
      _workDetailLoading = false;
      _workDetailResult = result;
    });
  }

  Future<void> _openBookPart(SharedBookSection section, String part) async {
    final result = await _bookWorkController.loadBookSectionPart(
      section: section,
      part: part,
    );
    if (!mounted) return;
    final revision = result.data;
    if (!result.isSuccess || revision == null) {
      _showSnack(result.message);
      return;
    }
    _openReferenceTab(
      '${section.title} · ${_managedPartLabel(part)}',
      section: _WorkspaceSection.assets,
      contextId: 'book-${section.sectionKey}-$part-${revision.partRevisionId}',
      contextSource: '典藏章节',
      contextPayload: revision.contentMarkdown,
    );
  }

  Future<void> _openWorkPart(SharedWork work, String part) async {
    final result = await _bookWorkController.loadWorkPart(
      work: work,
      part: part,
    );
    if (!mounted) return;
    final revision = result.data;
    if (!result.isSuccess || revision == null) {
      _showSnack(result.message);
      return;
    }
    _openReferenceTab(
      '${work.title} · ${_managedPartLabel(part)}',
      section: _WorkspaceSection.tools,
      contextId: 'work-${work.workId}-$part-${revision.partRevisionId}',
      contextSource: '创作历史',
      contextPayload: revision.contentMarkdown,
    );
  }

  Future<void> _completeWork(SharedWork work) async {
    final mutationKey = 'complete:${work.workId}';
    if (!_bookWorkMutations.add(mutationKey)) return;
    setState(() {});
    final result = await _bookWorkController.completeWork(work);
    if (!mounted) return;
    setState(() => _bookWorkMutations.remove(mutationKey));
    if (!result.isSuccess) {
      _showSnack(
        result.code == 'PRECONDITION_FAILED' || result.code == 'HTTP_412'
            ? '创作版本已变化，请刷新后重试'
            : result.message,
      );
      return;
    }
    _showSnack('创作已完成');
    await _loadWorks();
    if (mounted) await _loadWorkDetail(work.workId);
  }

  Future<void> _promoteWork(SharedWork work) async {
    final mutationKey = 'promote:${work.workId}';
    if (!_bookWorkMutations.add(mutationKey)) return;
    setState(() {});
    final sectionKey = DesktopBookWorkController.sectionKeyForWorkId(
      work.workId,
    );
    DesktopServiceResult<SharedWorkspaceContentEvent> result;
    try {
      result = await _bookWorkController.promoteWorkToBookSection(
        work: work,
        part: 'raw',
        sectionKey: sectionKey,
        title: work.title,
      );
    } on ArgumentError {
      result = const DesktopServiceResult<SharedWorkspaceContentEvent>.failure(
        code: 'DESKTOP_WORK_PROMOTION_INVALID',
        message: '该创作无法生成合法的典藏章节',
      );
    }
    if (!mounted) return;
    setState(() => _bookWorkMutations.remove(mutationKey));
    if (!result.isSuccess) {
      _showSnack(
        result.code == 'PRECONDITION_FAILED' || result.code == 'HTTP_412'
            ? '创作版本已变化，请刷新后重试'
            : result.message,
      );
      return;
    }
    _showSnack('已收录到典藏长文');
    await _loadBook();
  }

  Widget _buildBookWorkspace() {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      key: const ValueKey<String>('book-work-book-workspace'),
      color: colors.surface,
      child: Column(
        children: [
          _buildBookWorkTopBar(
            icon: LucideIcons.bookOpenCheck,
            title: _bookResult?.data?.current.title ?? '典藏长文',
            onRefresh: _loadBook,
            refreshKey: 'book-work-book-refresh',
          ),
          Expanded(child: _buildBookBody()),
        ],
      ),
    );
  }

  Widget _buildBookBody() {
    if (_bookLoading) {
      return const Center(
        key: ValueKey<String>('book-work-book-loading'),
        child: CircularProgressIndicator(),
      );
    }
    final result = _bookResult;
    if (result == null) return const SizedBox.shrink();
    final book = result.data;
    if (!result.isSuccess || book == null) {
      return _buildBookWorkFailure(
        keyName: 'book-work-book-error',
        message: result.message,
        onRetry: _loadBook,
      );
    }
    if (book.sections.isEmpty) {
      return const Center(
        key: ValueKey<String>('book-work-book-empty'),
        child: Text('典藏长文尚无章节'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 36),
      itemCount: book.sections.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final section = book.sections[index];
        final availableParts = section.parts
            .where((head) => head.currentRevisionId != null)
            .toList(growable: false);
        return Padding(
          key: ValueKey<String>('book-work-section-${section.sectionKey}'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 38,
                child: Text(
                  '${section.ordinal + 1}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(section.title, style: const TextStyle(fontSize: 14)),
                    const SizedBox(height: 4),
                    Text(
                      _bookGroupLabel(section.group),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              for (final head in availableParts)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: TextButton(
                    key: ValueKey<String>(
                      'book-work-section-${section.sectionKey}-${head.part}',
                    ),
                    onPressed: () =>
                        unawaited(_openBookPart(section, head.part)),
                    child: Text(_managedPartLabel(head.part)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWorksWorkspace() {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      key: const ValueKey<String>('book-work-history-workspace'),
      color: colors.surface,
      child: Column(
        children: [
          _buildBookWorkTopBar(
            icon: LucideIcons.history,
            title: '创作历史',
            onRefresh: () => _loadWorks(discardPending: true),
            refreshKey: 'book-work-history-refresh',
          ),
          Expanded(child: _buildWorksBody()),
        ],
      ),
    );
  }

  Widget _buildWorksBody() {
    if (_worksLoading) {
      return const Center(
        key: ValueKey<String>('book-work-history-loading'),
        child: CircularProgressIndicator(),
      );
    }
    final result = _worksResult;
    if (result == null) return const SizedBox.shrink();
    if (!result.isSuccess || result.data == null) {
      return _buildBookWorkFailure(
        keyName: 'book-work-history-error',
        message: result.message,
        onRetry: _loadWorks,
      );
    }
    final works = result.data!;
    if (works.isEmpty) {
      return const Center(
        key: ValueKey<String>('book-work-history-empty'),
        child: Text('暂无创作历史'),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final list = _buildWorkList(works);
        final detail = _buildWorkDetail();
        if (compact) {
          return Column(
            children: [
              SizedBox(height: 210, child: list),
              const Divider(height: 1),
              Expanded(child: detail),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 310, child: list),
            const VerticalDivider(width: 1),
            Expanded(child: detail),
          ],
        );
      },
    );
  }

  Widget _buildWorkList(List<SharedWork> works) => ListView.separated(
    key: const ValueKey<String>('book-work-history-list'),
    padding: const EdgeInsets.symmetric(vertical: 8),
    itemCount: works.length,
    separatorBuilder: (_, __) => const Divider(height: 1),
    itemBuilder: (context, index) {
      final work = works[index];
      final selected = _workDetailResult?.data?.workId == work.workId;
      return Material(
        color: Colors.transparent,
        child: ListTile(
          key: ValueKey<String>('book-work-item-${work.workId}'),
          selected: selected,
          title: Text(work.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_workLifecycleLabel(work.lifecycle)),
          trailing: const Icon(LucideIcons.chevronRight, size: 15),
          onTap: () => unawaited(_loadWorkDetail(work.workId)),
        ),
      );
    },
  );

  Widget _buildWorkDetail() {
    if (_workDetailLoading) {
      return const Center(
        key: ValueKey<String>('book-work-detail-loading'),
        child: CircularProgressIndicator(),
      );
    }
    final result = _workDetailResult;
    if (result == null) {
      return const Center(child: Text('选择一条创作查看详情'));
    }
    final work = result.data;
    if (!result.isSuccess || work == null) {
      return _buildBookWorkFailure(
        keyName: 'book-work-detail-error',
        message: result.message,
        onRetry: () {
          final id = _worksResult?.data?.firstOrNull?.workId;
          if (id != null) unawaited(_loadWorkDetail(id));
        },
      );
    }
    final completing = _bookWorkMutations.contains('complete:${work.workId}');
    final promoting = _bookWorkMutations.contains('promote:${work.workId}');
    final rawAvailable = work.parts.any(
      (head) => head.part == 'raw' && head.currentRevisionId != null,
    );
    return ListView(
      key: ValueKey<String>('book-work-detail-${work.workId}'),
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 36),
      children: [
        Text(work.title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          _workLifecycleLabel(work.lifecycle),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final head in work.parts)
              OutlinedButton(
                key: ValueKey<String>(
                  'book-work-detail-${work.workId}-${head.part}',
                ),
                onPressed: head.currentRevisionId == null
                    ? null
                    : () => unawaited(_openWorkPart(work, head.part)),
                child: Text(_managedPartLabel(head.part)),
              ),
          ],
        ),
        const SizedBox(height: 28),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              key: const ValueKey<String>('book-work-complete'),
              onPressed: work.lifecycle == 'active' && !completing && !promoting
                  ? () => unawaited(_completeWork(work))
                  : null,
              icon: const Icon(LucideIcons.circleCheck, size: 16),
              label: Text(completing ? '提交中' : '完成'),
            ),
            OutlinedButton.icon(
              key: const ValueKey<String>('book-work-promote'),
              onPressed: rawAvailable && !completing && !promoting
                  ? () => unawaited(_promoteWork(work))
                  : null,
              icon: const Icon(LucideIcons.bookPlus, size: 16),
              label: Text(promoting ? '收录中' : '收录到典藏'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBookWorkTopBar({
    required IconData icon,
    required String title,
    required VoidCallback onRefresh,
    required String refreshKey,
  }) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: HuahuoDesktopMetrics.topBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            Icon(icon, size: 16, color: colors.onSurfaceVariant),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              key: ValueKey<String>(refreshKey),
              tooltip: '刷新',
              onPressed: onRefresh,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookWorkFailure({
    required String keyName,
    required String message,
    required VoidCallback onRetry,
  }) => Center(
    key: ValueKey<String>(keyName),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(LucideIcons.rotateCw, size: 15),
          label: const Text('重试'),
        ),
      ],
    ),
  );

  String _managedPartLabel(String part) => switch (part) {
    'raw' => '正文',
    'outline' => '纲要',
    'germination' => '发芽',
    _ => part,
  };

  String _bookGroupLabel(String group) => switch (group) {
    'front_matter' => '前言',
    'chapters' => '正文',
    'back_matter' => '附录',
    _ => group,
  };

  String _workLifecycleLabel(String lifecycle) => switch (lifecycle) {
    'active' => '进行中',
    'completed' => '已完成',
    'deleted' => '已删除',
    _ => lifecycle,
  };

  Widget _buildFeatureWorkspace(_WorkspaceTab tab) {
    final colors = Theme.of(context).colorScheme;
    if (tab.id.startsWith('reference-')) {
      return _buildReferenceWorkspace(tab);
    }
    if (tab.id == 'book-work-book') return _buildBookWorkspace();
    if (tab.id == 'book-work-history') return _buildWorksWorkspace();
    if (tab.id == 'daily-topic') return _buildDailyTopicWorkspace();
    if (tab.id == 'product-home') {
      return DesktopHomeWorkspace(
        controller: _homeController,
        onPrimaryAction: _handleHomePrimaryAction,
        onOpenSuggestion: _openHomeSuggestion,
        onOpenRecordings: _openRecordingsWorkspace,
        onOpenCredits: () => _openSection(_WorkspaceSection.account),
      );
    }
    if (tab.id == 'activity-calendar') {
      return DesktopActivityCalendarWorkspace(
        controller: _activityCalendarController,
      );
    }
    if (tab.id == 'recording-library') {
      return DesktopRecordingLibraryWorkspace(
        workspaceId: _workspaceIsReady ? _activeWorkspaceId : null,
        repository: widget.recordingLibraryRepository,
        onUploadAudio: () {
          setState(() => _captureMode = _CaptureMode.media);
          _openSection(_WorkspaceSection.capture);
        },
      );
    }
    if (tab.id == 'feature-creation') {
      return DesktopCreationWorkspace(
        workspaceId: _workspaceIsReady ? _activeWorkspaceId : null,
        repository: widget.creationsRepository,
        onOpenProposals: _openProposalForCreation,
      );
    }
    if (tab.id == 'proposal-workspace') {
      return DesktopDocumentProposalsWorkspace(
        workspaceId: _workspaceIsReady ? _activeWorkspaceId : null,
        repository: widget.proposalsRepository,
        initialCreation: _proposalCreation,
        onOpenCreations: _openCreationWorkspace,
      );
    }
    if (tab.id == 'support-center') {
      return DesktopSupportWorkspace(repository: widget.supportRepository);
    }
    if (tab.id == 'digital-twin-workspace') {
      return DesktopDigitalTwinWorkspace(
        workspaceId: _workspaceIsReady ? _activeWorkspaceId : null,
        repository: widget.digitalTwinRepository,
        proposalsRepository: widget.proposalsRepository,
      );
    }
    if (tab.id == 'workspace-management') {
      return DesktopWorkspaceManagementWorkspace(
        controller: _workspaceManagementController,
        onDefaultWorkspaceChanged: _handleDefaultWorkspaceChanged,
      );
    }
    if (tab.id == 'positioning-report') {
      return _buildDesktopPositioningReportWorkspace();
    }
    final section = tab.section ?? _WorkspaceSection.assets;
    if (section == _WorkspaceSection.externalKnowledge) {
      // External Knowledge owns its title row so its library navigation can
      // remain in the same compact toolbar.
      return _buildExternalKnowledgeWorkspace();
    }
    return ColoredBox(
      key: ValueKey<String>('feature-${section.name}'),
      color: colors.surface,
      child: Column(
        children: [
          SizedBox(
            height: HuahuoDesktopMetrics.topBarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Icon(
                    _sectionIcon(section),
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                  Text(
                    _sectionTitle(section),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: switch (section) {
              _WorkspaceSection.assets => _buildAssetsWorkspace(),
              _WorkspaceSection.capture => _buildCaptureWorkspace(),
              _WorkspaceSection.notifications => DesktopNotificationsWorkspace(
                controller: _notificationsController,
                onOpen: _openNotificationTarget,
              ),
              _WorkspaceSection.account => _buildAccountWorkspace(),
              _WorkspaceSection.settings => _buildSettingsWorkspace(),
              _ => _buildFeatureIndex(section),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureIndex(_WorkspaceSection section) {
    final colors = Theme.of(context).colorScheme;
    final items = _sectionItems(section);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(38, 38, 38, 48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _sectionTitle(section),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _sectionSubtitle(section),
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 14,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 28),
              LayoutBuilder(
                builder: (context, constraints) {
                  final twoColumns = constraints.maxWidth >= 680;
                  final width = twoColumns
                      ? (constraints.maxWidth - 24) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 24,
                    runSpacing: 0,
                    children: [
                      for (final item in items)
                        SizedBox(
                          width: width,
                          child: _FeatureIndexRow(
                            icon: item.$1,
                            title: item.$2,
                            detail: item.$3,
                            onTap: _featureIndexAction(
                              section,
                              item.$2,
                              item.$3,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  VoidCallback _featureIndexAction(
    _WorkspaceSection section,
    String title,
    String detail,
  ) {
    if (section == _WorkspaceSection.tools) {
      switch (title) {
        case '基础定位':
          return () => _openAgentConversation('positioning_lv1');
        case '人设':
          return () => _openAgentConversation('renshe_content');
        case '获客':
          return () => _openAgentConversation('huoke_content');
        case '影像':
          return () => _openAgentConversation('visual_chat');
        case '深度定位':
          return () => unawaited(_openPositioningExperience());
        case '创作历史':
          return _openWorksWorkspace;
      }
    }
    if (section == _WorkspaceSection.capture && title == '视频分析') {
      return () => _openAgentConversation('video_analysis');
    }
    if (section == _WorkspaceSection.assets && title == '通知') {
      return () => _openSection(_WorkspaceSection.notifications);
    }
    if (section == _WorkspaceSection.assets && title == '日历') {
      return _openActivityCalendarWorkspace;
    }
    return () => unawaited(_showFeatureAction(title: title, detail: detail));
  }

  Widget _buildDailyTopicWorkspace() {
    final colors = Theme.of(context).colorScheme;
    final result = _dailyTopicResult;
    final recommendation = result?.data;
    final selected =
        recommendation?.topics
            .where((topic) => topic.topicId == _selectedDailyTopicId)
            .firstOrNull ??
        recommendation?.topics.firstOrNull;
    return ColoredBox(
      key: const ValueKey<String>('desktop-daily-topic-workspace'),
      color: colors.surface,
      child: Column(
        children: [
          SizedBox(
            height: HuahuoDesktopMetrics.topBarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.lightbulb,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                  Text('今日推送', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey<String>('desktop-daily-topic-refresh'),
                    tooltip: '刷新每日推荐',
                    onPressed: _dailyTopicLoading
                        ? null
                        : () => unawaited(_loadDailyTopic(force: true)),
                    icon: _dailyTopicLoading
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        : const Icon(LucideIcons.refreshCw, size: 16),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: recommendation == null
                ? Center(
                    child: Text(
                      _dailyTopicLoading
                          ? '正在读取今日推荐'
                          : result?.message.isNotEmpty == true
                          ? result!.message
                          : '今日暂无可用选题',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(30, 24, 30, 38),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 860),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                recommendation.title,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${recommendation.businessDate} · 服务端每日选题',
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 12.5,
                                ),
                              ),
                              const SizedBox(height: 18),
                              SizedBox(
                                height: 240,
                                child:
                                    ValueListenableBuilder<
                                      MarkdownPreviewPreferences
                                    >(
                                      valueListenable:
                                          _markdownPreviewPreferences,
                                      builder: (context, preferences, _) =>
                                          MarkdownPreviewPane(
                                            source: MarkdownPreviewSource(
                                              title: recommendation.title,
                                              markdown: recommendation
                                                  .summaryMarkdown,
                                              stage: '每日推荐',
                                            ),
                                            preferences: preferences,
                                          ),
                                    ),
                              ),
                              const SizedBox(height: 22),
                              Text(
                                '选择一个选题',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 10),
                              for (final topic in recommendation.topics)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Material(
                                    color: topic.topicId == selected?.topicId
                                        ? colors.primaryContainer
                                        : colors.surfaceContainerLow,
                                    borderRadius: BorderRadius.circular(
                                      HuahuoRadii.control,
                                    ),
                                    child: InkWell(
                                      key: ValueKey<String>(
                                        'desktop-daily-topic-${topic.topicId}',
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        HuahuoRadii.control,
                                      ),
                                      onTap: () => setState(
                                        () => _selectedDailyTopicId =
                                            topic.topicId,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(14),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    topic.title,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 5),
                                                  ConstrainedBox(
                                                    constraints:
                                                        const BoxConstraints(
                                                          maxHeight: 72,
                                                        ),
                                                    child: SingleChildScrollView(
                                                      primary: false,
                                                      physics:
                                                          const NeverScrollableScrollPhysics(),
                                                      child: IgnorePointer(
                                                        child: HuahuoMarkdown(
                                                          source: topic
                                                              .briefMarkdown,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Icon(
                                              topic.topicId == selected?.topicId
                                                  ? LucideIcons.circleCheck
                                                  : Icons.circle_outlined,
                                              size: 18,
                                              color:
                                                  topic.topicId ==
                                                      selected?.topicId
                                                  ? colors.primary
                                                  : colors.onSurfaceVariant,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  FilledButton.icon(
                                    key: const ValueKey<String>(
                                      'desktop-daily-topic-use',
                                    ),
                                    onPressed:
                                        _dailyTopicUsing ||
                                            _dailyTopicDismissing ||
                                            selected == null
                                        ? null
                                        : () => unawaited(_useDailyTopic()),
                                    icon: _dailyTopicUsing
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.8,
                                            ),
                                          )
                                        : const Icon(
                                            LucideIcons.messageSquare,
                                            size: 16,
                                          ),
                                    label: Text(
                                      _dailyTopicUsing ? '正在打开对话' : '使用此选题',
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    key: const ValueKey<String>(
                                      'desktop-daily-topic-dismiss',
                                    ),
                                    onPressed:
                                        _dailyTopicUsing ||
                                            _dailyTopicDismissing
                                        ? null
                                        : () => unawaited(_dismissDailyTopic()),
                                    icon: _dailyTopicDismissing
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.8,
                                            ),
                                          )
                                        : const Icon(
                                            LucideIcons.eyeOff,
                                            size: 16,
                                          ),
                                    label: Text(
                                      _dailyTopicDismissing ? '正在忽略' : '忽略今日推送',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  void _openDesktopPositioningReport() {
    setState(() {
      _primaryMode = _PrimaryWorkspaceMode.creation;
      _activeSection = _WorkspaceSection.tools;
      _contextPanelOpen = false;
      _upsertTab(
        const _WorkspaceTab(
          id: 'positioning-report',
          title: '深度定位',
          kind: _WorkspaceTabKind.feature,
          section: _WorkspaceSection.tools,
        ),
      );
    });
  }

  Future<void> _openPositioningExperience() async {
    if (!_workspaceIsReady) {
      _showSnack(_accountSignedIn ? 'Workspace 正在准备，完成后才能开始定位' : '请先登录后再开始定位');
      return;
    }
    final existing = _chatThreads
        .where((thread) => thread.agentProfileId == 'positioning_lv2')
        .firstOrNull;
    if (existing == null) {
      _openAgentConversation('positioning_lv2');
      return;
    }
    await _openRemoteChatThread(existing.threadId);
    if (!mounted) return;
    _openDesktopPositioningReport();
  }

  PositioningProgressProfile? get _latestPositioningProgress {
    for (final message in _chatMessages.reversed) {
      if (message.fromUser) continue;
      final profile = parseLatestPositioningProgress(message.text);
      if (profile != null) return profile;
    }
    return null;
  }

  Widget _buildDesktopPositioningReportWorkspace() {
    final colors = Theme.of(context).colorScheme;
    final profile = _latestPositioningProgress;
    return ColoredBox(
      key: const ValueKey<String>('desktop-positioning-report-workspace'),
      color: colors.surface,
      child: Column(
        children: [
          SizedBox(
            height: HuahuoDesktopMetrics.topBarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.network,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                  Text('深度定位', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  TextButton.icon(
                    key: const ValueKey<String>(
                      'desktop-positioning-open-chat',
                    ),
                    onPressed: () {
                      setState(() {
                        _primaryMode = _PrimaryWorkspaceMode.chat;
                        _activeSection = _WorkspaceSection.chat;
                        _chatRailCollapsed = false;
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _chatFocus.requestFocus();
                      });
                    },
                    icon: const Icon(LucideIcons.messagesSquare, size: 15),
                    label: const Text('继续对话'),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: profile == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        '定位进度会在 Agent 返回公开定位报告后显示。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 24, 28, 36),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 960),
                        child: DesktopPositioningDashboard(profile: profile),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptureWorkspace() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final content = _buildCaptureCanvas();
        if (compact) {
          return Column(
            children: [
              _buildCaptureModeNavigation(horizontal: true),
              const Divider(height: 1),
              Expanded(child: content),
            ],
          );
        }
        return Row(
          children: [
            _buildCaptureModeNavigation(),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  Widget _buildCaptureModeNavigation({bool horizontal = false}) {
    final colors = Theme.of(context).colorScheme;
    const modes = _CaptureMode.values;
    if (horizontal) {
      return SizedBox(
        height: 48,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          scrollDirection: Axis.horizontal,
          itemCount: modes.length,
          separatorBuilder: (_, __) => const SizedBox(width: 4),
          itemBuilder: (context, index) {
            final mode = modes[index];
            final selected = mode == _captureMode;
            return TextButton.icon(
              key: ValueKey<String>('capture-mode-${mode.name}'),
              onPressed: () => setState(() => _captureMode = mode),
              icon: Icon(_captureModeIcon(mode), size: 15),
              label: Text(_captureModeLabel(mode)),
              style: TextButton.styleFrom(
                foregroundColor: selected
                    ? colors.onSurface
                    : colors.onSurfaceVariant,
                backgroundColor: selected
                    ? colors.primary.withValues(alpha: 0.11)
                    : Colors.transparent,
              ),
            );
          },
        ),
      );
    }
    return SizedBox(
      width: 196,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 14, 8, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(
              '采集方式',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          for (final mode in modes)
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey<String>('capture-mode-${mode.name}'),
                onTap: () => setState(() => _captureMode = mode),
                borderRadius: BorderRadius.circular(HuahuoRadii.control),
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    color: mode == _captureMode
                        ? colors.primary.withValues(alpha: 0.1)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(HuahuoRadii.control),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _captureModeIcon(mode),
                        size: 16,
                        color: mode == _captureMode
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          _captureModeLabel(mode),
                          style: TextStyle(
                            fontSize: 13,
                            color: mode == _captureMode
                                ? colors.onSurface
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCaptureCanvas() {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      key: const ValueKey<String>('capture-workspace'),
      padding: const EdgeInsets.fromLTRB(34, 30, 34, 46),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _captureModeTitle(_captureMode),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _captureModeDescription(_captureMode),
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 14,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 28),
              _buildCaptureAction(),
              const SizedBox(height: 38),
              Row(
                children: [
                  Text('最近处理', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  if (_captureRecords.isNotEmpty)
                    Text(
                      '${_captureRecords.length} 条',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 9),
              if (_captureRecords.isEmpty)
                _buildCaptureQueueEmpty()
              else
                for (final record in _captureRecords.take(6))
                  _buildCaptureRecordRow(record),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureAction() => switch (_captureMode) {
    _CaptureMode.monologue => _buildMonologueCaptureAction(),
    _CaptureMode.quickRecord => _buildQuickRecordAction(),
    _CaptureMode.meeting => _buildMeetingCaptureAction(),
    _CaptureMode.text => _buildTextCaptureAction(),
    _CaptureMode.link => _buildLinkCaptureAction(),
    _CaptureMode.media => _buildMediaCaptureAction(),
  };

  Widget _buildMonologueCaptureAction() => _buildDesktopAudioImportAction(
    key: const ValueKey<String>('monologue-import'),
    title: '导入独白音频',
    detail: '选择已有独白音频后会上传并开始转写；实时麦克风采集请使用移动端。',
    mode: _CaptureMode.monologue,
  );

  Widget _buildQuickRecordAction() => _buildCaptureTextAction(
    hint: '记下一个片段、观察或待验证的问题',
    actionLabel: '保存随录',
    onSave: () => unawaited(
      _saveTypedCapture(
        fallbackTitle: '随录素材',
        detail: '文字随录，等待继续整理',
        mode: _CaptureMode.quickRecord,
      ),
    ),
  );

  Widget _buildTextCaptureAction() => _buildCaptureTextAction(
    hint: '输入一条需要进入资产库的文字素材',
    actionLabel: '收录文字',
    onSave: () => unawaited(
      _saveTypedCapture(
        fallbackTitle: '文字素材',
        detail: '文字采集，等待继续整理',
        mode: _CaptureMode.text,
      ),
    ),
  );

  Widget _buildCaptureTextAction({
    required String hint,
    required String actionLabel,
    required VoidCallback onSave,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      TextField(
        key: const ValueKey<String>('capture-text-input'),
        contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
        controller: _captureTextInput,
        minLines: 5,
        maxLines: 8,
        decoration: InputDecoration(hintText: hint, alignLabelWithHint: true),
      ),
      const SizedBox(height: 10),
      FilledButton.icon(
        key: const ValueKey<String>('capture-text-save'),
        onPressed: _captureTextSaving ? null : onSave,
        icon: _captureTextSaving
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              )
            : const Icon(LucideIcons.arrowDownToLine, size: 16),
        label: Text(_captureTextSaving ? '正在沉淀' : actionLabel),
      ),
    ],
  );

  Widget _buildMeetingCaptureAction() => _buildDesktopAudioImportAction(
    key: const ValueKey<String>('meeting-import'),
    title: '导入会议音频',
    detail: '选择已有会议录音后会上传并在最近处理中显示服务端进度。',
    mode: _CaptureMode.meeting,
  );

  Widget _buildDesktopAudioImportAction({
    required Key key,
    required String title,
    required String detail,
    required _CaptureMode mode,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(
          mode == _CaptureMode.monologue || mode == _CaptureMode.media
              ? LucideIcons.audioLines
              : LucideIcons.usersRound,
          size: 34,
          color: colors.onSurfaceVariant,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                detail,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          key: key,
          onPressed: () => unawaited(_importCaptureAudio(mode)),
          icon: const Icon(LucideIcons.folderUp, size: 16),
          label: const Text('选择音频'),
        ),
      ],
    );
  }

  Future<void> _importCaptureAudio(_CaptureMode mode) async {
    final workspaceId = _activeWorkspaceId;
    if (!_workspaceIsReady || workspaceId == null || workspaceId.isEmpty) {
      _showSnack(_accountSignedIn ? 'Workspace 正在准备，完成后才能上传音频' : '请先登录后再上传音频');
      return;
    }
    final selected = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_captureAudioFileTypes],
    );
    if (!mounted || selected == null) return;
    final sourcePath = selected.path.trim();
    if (sourcePath.isEmpty) {
      _showSnack('无法读取所选音频');
      return;
    }
    final fileName = selected.name.trim();
    final mimeType = _captureAudioMimeType(fileName);
    if (fileName.isEmpty || mimeType == null) {
      _showSnack('请选择 WAV、MP3 或 M4A 音频文件');
      return;
    }
    final recordId = _addCaptureRecord(
      title: fileName,
      detail: '正在校验并准备上传音频',
      mode: mode,
      isRunning: true,
      announce: false,
    );
    final result = await widget.recordingsPort.submitLocalAudio(
      DesktopLocalAudioRequest(
        filePath: sourcePath,
        fileName: fileName,
        mimeType: mimeType,
        workspaceId: workspaceId,
      ),
      onStage: (stage) {
        if (!mounted) return;
        _updateCaptureRecord(
          recordId,
          detail: _captureUploadStageLabel(stage),
          isRunning: true,
        );
      },
    );
    if (!mounted) return;
    if (!result.isSuccess || result.data == null) {
      _updateCaptureRecord(
        recordId,
        detail: '上传失败：${result.message}',
        isRunning: false,
      );
      _showSnack(result.message);
      return;
    }
    final submission = result.data!;
    _updateCaptureRecord(
      recordId,
      title: submission.title,
      recordingId: submission.recordingId,
      detail: _captureRecordingStatusLabel(submission.status),
      isRunning: true,
    );
    _showSnack('音频已提交，正在服务端转写');
    unawaited(_pollCaptureRecording(recordId, submission.recordingId));
  }

  String? _captureAudioMimeType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) return 'audio/mp4';
    return null;
  }

  String _captureUploadStageLabel(DesktopRecordingUploadStage stage) =>
      switch (stage) {
        DesktopRecordingUploadStage.hashing => '正在校验音频完整性',
        DesktopRecordingUploadStage.requestingUpload => '正在获取安全上传凭证',
        DesktopRecordingUploadStage.uploadingObject => '正在上传音频',
        DesktopRecordingUploadStage.completingUpload => '正在确认上传结果',
        DesktopRecordingUploadStage.creatingRecording => '正在提交转写任务',
      };

  Future<void> _pollCaptureRecording(
    String captureId,
    String recordingId,
  ) async {
    if (!_recordingProgressPolls.add(captureId)) return;
    try {
      for (var attempt = 0; attempt < 180; attempt++) {
        if (!mounted ||
            !_accountSignedIn ||
            !_captureRecords.any((record) => record.id == captureId)) {
          return;
        }
        final result = await widget.recordingsPort.loadProgress(recordingId);
        if (!mounted || !_recordingProgressPolls.contains(captureId)) return;
        if (!result.isSuccess || result.data == null) {
          _updateCaptureRecord(
            captureId,
            detail: '暂时无法读取转写进度：${result.message}',
            isRunning: false,
          );
          return;
        }
        final progress = result.data!;
        final status = progress.status;
        final terminal = _isCaptureTerminalStatus(status);
        final needsSpeakerLabels = const <String>{
          'transcribed',
          'speaker_labeling',
          'speaker_label_pending',
        }.contains(status);
        _updateCaptureRecord(
          captureId,
          detail: _captureRecordingStatusLabel(
            status,
            progress: progress.progress,
            message: progress.message,
          ),
          isRunning: !terminal && !needsSpeakerLabels,
        );
        if (terminal || needsSpeakerLabels) {
          if (status == 'final_transcript_generated' ||
              status == 'succeeded' ||
              status == 'completed') {
            unawaited(_loadRemoteAssets(force: true));
            _showSnack('转写结果已就绪，可在我的资产查看');
          }
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      if (mounted) {
        _updateCaptureRecord(
          captureId,
          detail: '服务端仍在转写，可稍后在我的资产查看结果',
          isRunning: false,
        );
      }
    } finally {
      _recordingProgressPolls.remove(captureId);
    }
  }

  bool _isCaptureTerminalStatus(String status) => const <String>{
    'final_transcript_generated',
    'succeeded',
    'completed',
    'failed',
    'timeout',
    'cancelled',
  }.contains(status);

  String _captureRecordingStatusLabel(
    String status, {
    int? progress,
    String? message,
  }) {
    final suffix = progress == null ? '' : ' $progress%';
    final publicMessage = message?.trim();
    if (publicMessage != null && publicMessage.isNotEmpty) {
      return publicMessage.length > 120
          ? '${publicMessage.substring(0, 120)}...'
          : publicMessage;
    }
    return switch (status) {
      'created' || 'queued' => '已提交，等待开始转写',
      'uploading' || 'uploaded' => '音频已上传，正在准备转写',
      'processing' || 'asr_running' || 'transcribing' => '正在转写$suffix',
      'transcribed' ||
      'speaker_labeling' ||
      'speaker_label_pending' => '转写已完成，需在移动端标注说话人后继续',
      'speaker_confirmed' => '说话人已确认，正在整理转写结果',
      'final_transcript_generated' ||
      'succeeded' ||
      'completed' => '转写完成，已沉淀到我的资产',
      'failed' => '转写失败，可重新选择文件重试',
      'timeout' => '转写超时，可稍后重试',
      'cancelled' => '转写已取消',
      _ => '正在处理音频',
    };
  }

  Widget _buildLinkCaptureAction() => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      TextField(
        key: const ValueKey<String>('capture-link-input'),
        contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
        controller: _captureImportInput,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          hintText: '粘贴网页、文章或视频链接',
          prefixIcon: Icon(LucideIcons.link, size: 16),
        ),
      ),
      const SizedBox(height: 10),
      FilledButton.icon(
        key: const ValueKey<String>('capture-link-save'),
        onPressed: _linkCaptureSaving
            ? null
            : () => unawaited(_saveLinkCapture()),
        icon: _linkCaptureSaving
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              )
            : const Icon(LucideIcons.download, size: 16),
        label: Text(_linkCaptureSaving ? '正在保存' : '收录链接'),
      ),
    ],
  );

  Widget _buildMediaCaptureAction() => _buildDesktopAudioImportAction(
    key: const ValueKey<String>('capture-media-import'),
    title: '导入录音音频',
    detail: '选择 MP3、M4A 或 WAV，上传后自动创建转写任务并显示服务端进度。',
    mode: _CaptureMode.media,
  );

  Widget _buildCaptureQueueEmpty() {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Text(
        '这里会显示等待转写、解析或继续整理的素材。',
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
      ),
    );
  }

  Widget _buildCaptureRecordRow(_CaptureRecord record) {
    final colors = Theme.of(context).colorScheme;
    final failed = record.detail.contains('失败') || record.detail.contains('超时');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_openCaptureRecord(record)),
        borderRadius: BorderRadius.circular(HuahuoRadii.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(
                _captureModeIcon(record.mode),
                size: 16,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      record.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (record.isRunning)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (record.recordingId != null || record.noteId != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(
                    failed ? LucideIcons.circleAlert : LucideIcons.circleCheck,
                    size: 16,
                    color: failed ? colors.error : colors.primary,
                  ),
                ),
              Tooltip(
                message: '加入聊天上下文',
                child: IconButton(
                  onPressed: () => _addChatContext(
                    record.title,
                    id: 'capture-${record.id}',
                    source: '采集与独白',
                    revealChat: true,
                  ),
                  icon: const Icon(LucideIcons.plus, size: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveTypedCapture({
    required String fallbackTitle,
    required String detail,
    required _CaptureMode mode,
  }) async {
    if (_captureTextSaving) return;
    final content = _captureTextInput.text.trim();
    if (content.isEmpty) {
      _showSnack('先输入一段素材');
      return;
    }
    final workspaceId = _activeWorkspaceId;
    if (!_workspaceIsReady || workspaceId == null || workspaceId.isEmpty) {
      _showSnack(_accountSignedIn ? 'Workspace 正在准备，完成后才能保存文字' : '请先登录后再保存文字');
      return;
    }
    final title = _captureTextTitle(content, fallbackTitle);
    setState(() => _captureTextSaving = true);
    final recordId = _addCaptureRecord(
      title: title,
      detail: '正在保存为原始资产',
      mode: mode,
      isRunning: true,
      announce: false,
    );
    final result = await widget.rawNoteCreator.createRawNote(
      DesktopRawNoteCreateRequest(
        workspaceId: workspaceId,
        title: title,
        rawMarkdown: content,
        idempotencyKey:
            'desktop-capture-${mode.name}-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      ),
    );
    if (!mounted || !_accountSignedIn || _activeWorkspaceId != workspaceId) {
      return;
    }
    setState(() => _captureTextSaving = false);
    if (!result.isSuccess || result.data == null) {
      _updateCaptureRecord(
        recordId,
        detail: '保存失败：${result.message}',
        isRunning: false,
      );
      _showSnack(result.message);
      return;
    }
    final created = result.data!;
    if (_captureTextInput.text.trim() == content) {
      _captureTextInput.clear();
    }
    _updateCaptureRecord(
      recordId,
      title: created.title,
      noteId: created.noteId,
      detail: '已保存为原始资产',
      isRunning: false,
    );
    final pull = await _pullRemoteDocuments();
    if (!mounted || !_accountSignedIn || _activeWorkspaceId != workspaceId) {
      return;
    }
    setState(() => _assetsLoaded = false);
    unawaited(_loadRemoteAssets(force: true));
    _showSnack(pull.isSuccess ? '文字已沉淀到我的资产' : '文字已保存到云端，可稍后刷新资产查看');
  }

  Future<void> _saveLinkCapture() async {
    final source = _captureImportInput.text.trim();
    if (source.isEmpty) {
      _showSnack('先粘贴一个链接');
      return;
    }
    final uri = Uri.tryParse(source);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      _showSnack('请输入有效的 http 或 https 链接');
      return;
    }
    await _importLinkAsRawAsset(uri, addCaptureRecord: true);
  }

  Future<void> _importLinkAsRawAsset(
    Uri uri, {
    required bool addCaptureRecord,
  }) async {
    if (_linkCaptureSaving) return;
    final workspaceId = _activeWorkspaceId;
    if (!_workspaceIsReady || workspaceId == null || workspaceId.isEmpty) {
      _showSnack(_accountSignedIn ? 'Workspace 正在准备，完成后才能保存链接' : '请先登录后再保存链接');
      return;
    }
    final source = uri.toString();
    final title = _captureTextTitle(uri.host, '链接素材');
    final rawMarkdown = '# $title\n\n来源链接：<$source>\n';
    setState(() => _linkCaptureSaving = true);
    final recordId = addCaptureRecord
        ? _addCaptureRecord(
            title: title,
            detail: '正在保存链接原始资产',
            mode: _CaptureMode.link,
            isRunning: true,
            announce: false,
          )
        : null;
    final result = await widget.rawNoteCreator.createRawNote(
      DesktopRawNoteCreateRequest(
        workspaceId: workspaceId,
        title: title,
        rawMarkdown: rawMarkdown,
        idempotencyKey:
            'desktop-link-capture-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      ),
    );
    if (!mounted || !_accountSignedIn || _activeWorkspaceId != workspaceId) {
      return;
    }
    setState(() => _linkCaptureSaving = false);
    if (!result.isSuccess || result.data == null) {
      if (recordId != null) {
        _updateCaptureRecord(
          recordId,
          detail: '保存失败：${result.message}',
          isRunning: false,
        );
      }
      _showSnack(result.message);
      return;
    }
    final created = result.data!;
    if (addCaptureRecord && _captureImportInput.text.trim() == source) {
      _captureImportInput.clear();
    }
    if (recordId != null) {
      _updateCaptureRecord(
        recordId,
        title: created.title,
        noteId: created.noteId,
        detail: '链接已保存为原始资产',
        isRunning: false,
      );
    }
    final pull = await _pullRemoteDocuments();
    if (!mounted || !_accountSignedIn || _activeWorkspaceId != workspaceId) {
      return;
    }
    setState(() {
      _assetsLoaded = false;
      _externalKnowledgeItems.removeWhere(
        (item) => item.id == 'link-${created.noteId}',
      );
      _externalKnowledgeItems.insert(
        0,
        _ExternalKnowledgeItem(
          id: 'link-${created.noteId}',
          title: created.title,
          detail: '链接 · 已保存为原始资产',
          kind: LucideIcons.link,
          summary: created.rawMarkdown,
          subscribed: true,
          sourceLabel: '链接导入',
        ),
      );
      _externalKnowledgeView = _ExternalKnowledgeView.subscriptions;
    });
    unawaited(_loadRemoteAssets(force: true));
    _showSnack(pull.isSuccess ? '链接已保存为原始资产' : '链接已保存到云端，可稍后刷新资产查看');
  }

  String _captureTextTitle(String content, String fallbackTitle) {
    final compact = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return fallbackTitle;
    final runes = compact.runes.toList(growable: false);
    return runes.length <= 80
        ? compact
        : '${String.fromCharCodes(runes.take(77))}...';
  }

  Future<void> _openCaptureRecord(_CaptureRecord record) async {
    final noteId = record.noteId;
    if (noteId != null) {
      var document = _documents.where((item) => item.id == noteId).firstOrNull;
      if (document == null) {
        await _pullRemoteDocuments();
        if (!mounted) return;
        document = _documents.where((item) => item.id == noteId).firstOrNull;
      }
      if (document != null) {
        await _activateDocument(document);
        return;
      }
    }
    _openReferenceTab(
      record.title,
      section: _WorkspaceSection.assets,
      contextId: 'capture-${record.id}',
      contextSource: '采集与独白',
    );
  }

  String _addCaptureRecord({
    required String title,
    required String detail,
    required _CaptureMode mode,
    String? recordingId,
    String? noteId,
    bool isRunning = false,
    bool announce = true,
  }) {
    final id = '${mode.name}-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _captureRecords.insert(
        0,
        _CaptureRecord(
          id: id,
          title: title,
          detail: detail,
          mode: mode,
          recordingId: recordingId,
          noteId: noteId,
          isRunning: isRunning,
        ),
      );
    });
    if (announce) _showSnack('已加入待处理素材');
    return id;
  }

  void _updateCaptureRecord(
    String id, {
    String? title,
    String? detail,
    String? recordingId,
    String? noteId,
    bool? isRunning,
  }) {
    final index = _captureRecords.indexWhere((record) => record.id == id);
    if (index < 0) return;
    final current = _captureRecords[index];
    setState(() {
      _captureRecords[index] = _CaptureRecord(
        id: current.id,
        title: title ?? current.title,
        detail: detail ?? current.detail,
        mode: current.mode,
        recordingId: recordingId ?? current.recordingId,
        noteId: noteId ?? current.noteId,
        isRunning: isRunning ?? current.isRunning,
      );
    });
  }

  String _captureModeLabel(_CaptureMode mode) => switch (mode) {
    _CaptureMode.monologue => '独白',
    _CaptureMode.quickRecord => '随录',
    _CaptureMode.meeting => '会议',
    _CaptureMode.text => '文字',
    _CaptureMode.link => '链接',
    _CaptureMode.media => '音频导入',
  };

  String _captureModeTitle(_CaptureMode mode) => switch (mode) {
    _CaptureMode.monologue => '独白',
    _CaptureMode.quickRecord => '随录',
    _CaptureMode.meeting => '会议',
    _CaptureMode.text => '文字采集',
    _CaptureMode.link => '链接导入',
    _CaptureMode.media => '导入录音音频',
  };

  String _captureModeDescription(_CaptureMode mode) => switch (mode) {
    _CaptureMode.monologue => '选择已有独白音频后上传转写；实时麦克风采集由移动端提供。',
    _CaptureMode.quickRecord => '快速保存灵感、观察和待验证的问题，不打断当前的创作节奏。',
    _CaptureMode.meeting => '选择已有会议音频后上传转写，不把未上传文件显示为已完成。',
    _CaptureMode.text => '把零散文字直接收录为待整理素材，稍后可以进入我的资产。',
    _CaptureMode.link => '保留网页和媒体来源为原始资产；链接全文解析以公开服务能力为准。',
    _CaptureMode.media => '选择已有录音音频，安全上传后自动创建转写任务。',
  };

  IconData _captureModeIcon(_CaptureMode mode) => switch (mode) {
    _CaptureMode.monologue => LucideIcons.audioLines,
    _CaptureMode.quickRecord => LucideIcons.mic,
    _CaptureMode.meeting => LucideIcons.usersRound,
    _CaptureMode.text => LucideIcons.notebookPen,
    _CaptureMode.link => LucideIcons.link,
    _CaptureMode.media => LucideIcons.audioLines,
  };

  Widget _buildAccountWorkspace() {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      key: const ValueKey<String>('account-workspace'),
      padding: const EdgeInsets.fromLTRB(30, 20, 30, 42),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: colors.surfaceContainer,
                      foregroundColor: colors.onSurface,
                      child: _accountAvatarResourceId == null
                          ? _accountAvatarFallback()
                          : _DesktopProfileAvatar(
                              cache: widget.resourceImageCache,
                              resourceId: _accountAvatarResourceId!,
                              fallback: _accountAvatarFallback(),
                            ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _accountSignedIn ? _accountName : '未登录',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _accountStatusText,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_accountSignedIn)
                      TextButton.icon(
                        key: const ValueKey<String>('account-edit-profile'),
                        onPressed: _showProfileEditor,
                        icon: const Icon(LucideIcons.pencil, size: 15),
                        label: const Text('编辑资料'),
                      )
                    else
                      FilledButton(
                        key: const ValueKey<String>('account-sign-in'),
                        onPressed: _authLoading ? null : _showAccountSignIn,
                        child: Text(_authLoading ? '检查中' : '登录'),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildAccountGroup(
                  title: '账户与服务',
                  children: [
                    _AccountActionRow(
                      icon: LucideIcons.userRound,
                      title: '个人资料',
                      detail: _accountSignedIn ? '头像、昵称、绑定手机号' : '登录后管理个人资料',
                      onTap: _accountSignedIn
                          ? _showProfileEditor
                          : _showAccountSignIn,
                    ),
                    _AccountActionRow(
                      icon: LucideIcons.panelsTopLeft,
                      title: 'Workspace',
                      detail: '创建、切换、重命名、停用与恢复',
                      onTap: _openWorkspaceManagement,
                    ),
                    _AccountActionRow(
                      icon: LucideIcons.badgeCheck,
                      title: '会员与额度',
                      detail: _membershipDetail,
                      onTap: () => _showFeatureAction(
                        title: '会员与额度',
                        detail: _membershipExpandedDetail,
                      ),
                    ),
                    _AccountActionRow(
                      icon: LucideIcons.gauge,
                      title: '最近一次 AI 运行',
                      detail: _runUsageDetail,
                      onTap: () => _showFeatureAction(
                        title: 'AI 运行用量',
                        detail: _runUsageExpandedDetail,
                      ),
                    ),
                    _AccountActionRow(
                      icon: LucideIcons.shieldCheck,
                      title: '账号与安全',
                      detail: '手机号、邮箱、登录设备与密码',
                      onTap: () => _showFeatureAction(
                        title: '账号与安全',
                        detail: '管理登录方式、绑定信息和设备授权。',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildAccountGroup(
                  title: '内容与支持',
                  children: [
                    _AccountActionRow(
                      icon: LucideIcons.cloud,
                      title: '同步状态',
                      detail: _accountSignedIn ? '全部内容已同步' : '登录后启用云端同步',
                      onTap: () => _showFeatureAction(
                        title: '同步状态',
                        detail: _accountSignedIn
                            ? '最近一次同步刚刚完成。'
                            : '登录后可在多设备间同步内容。',
                      ),
                    ),
                    _AccountActionRow(
                      icon: LucideIcons.fingerprint,
                      title: '数字分身',
                      detail: '长期档案、待确认修改、定期计划与版本',
                      onTap: _openDigitalTwinWorkspace,
                    ),
                    _AccountActionRow(
                      icon: LucideIcons.monitorSmartphone,
                      title: '登录设备',
                      detail: 'Windows 编辑器 · 当前设备',
                      onTap: () => _showFeatureAction(
                        title: '登录设备',
                        detail: '查看和管理已登录的桌面端与移动端设备。',
                      ),
                    ),
                    _AccountActionRow(
                      icon: LucideIcons.circleHelp,
                      title: '帮助与反馈',
                      detail: '使用指南、隐私协议与客服入口',
                      onTap: _openSupportWorkspace,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (_accountSignedIn)
                  OutlinedButton.icon(
                    key: const ValueKey<String>('account-sign-out'),
                    onPressed: _signOut,
                    icon: const Icon(LucideIcons.logOut, size: 16),
                    label: const Text('退出登录'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAccountGroup({
    required String title,
    required List<Widget> children,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(HuahuoRadii.control),
        child: Column(children: children),
      ),
    ],
  );

  String get _accountStatusText {
    if (_authLoading) return '正在检查安全会话';
    if (_accountSignedIn) return _remoteDomainStatusText;
    final result = _authResult;
    if (result?.isUnavailable ?? false) return result!.message;
    if (result?.isFailure ?? false) return '会话恢复失败 · ${result!.message}';
    return '登录后可同步文稿、资产与偏好设置';
  }

  String get _remoteDomainStatusText {
    final results = <DesktopServiceResult<Object?>?>[
      _asObjectResult(_workspaceFoldersResult),
      _asObjectResult(_catalogResult),
      _asObjectResult(_subscriptionLoadResult),
      _asObjectResult(_membershipResult),
      _asObjectResult(_creditsResult),
    ];
    if (results.any((result) => result?.isFailure == true)) {
      return '已登录 · 部分云端目录加载失败';
    }
    if (results.any((result) => result?.isUnavailable == true)) {
      return '已登录 · 部分云端能力尚未发布';
    }
    if (results.every((result) => result?.isSuccess == true)) {
      return '已登录 · Workspace 与账户目录已同步';
    }
    return '已登录 · 正在加载 Workspace 目录';
  }

  String get _membershipDetail {
    if (!_accountSignedIn) return '登录后查看权益';
    final membership = _membershipResult;
    if (membership?.isUnavailable == true) return '会员服务尚未发布';
    if (membership?.isFailure == true) return '会员信息加载失败';
    final tier = membership?.data?.levelCode;
    final credits = _creditsResult?.data;
    final available = credits == null
        ? null
        : credits.monthlyCredit.availableCredits +
              credits.permanentCredit.availableCredits;
    if (tier != null && available != null) {
      return '$tier · 可用 $available credits';
    }
    if (tier != null) return tier;
    if (available != null) return '可用 $available credits';
    return '正在读取会员与余额';
  }

  String get _membershipExpandedDetail {
    final membership = _membershipResult?.data;
    final credits = _creditsResult?.data;
    if (membership == null && credits == null) return _membershipDetail;
    final lines = <String>[];
    if (membership != null) {
      lines.add('会员：${membership.levelCode} · ${membership.status}');
      lines.add(
        '月额度：${membership.monthlyCredit.availableCredits} / ${membership.monthlyCredit.quotaCredits}',
      );
    }
    if (credits != null) {
      lines.add('永久额度：${credits.permanentCredit.availableCredits}');
      lines.add(
        credits.account.runAdmission == 'allowed'
            ? 'AI 运行可用'
            : '额度不足，新的 AI 运行将被阻止',
      );
    }
    return lines.join('\n');
  }

  String get _runUsageDetail {
    final result = _runUsageResult;
    if (result == null) return '完成一次 AI 对话后显示';
    if (result.isUnavailable) return '运行用量服务尚未发布';
    if (result.isFailure) return '运行用量读取失败';
    final usage = result.data;
    if (usage == null) return '运行用量响应无效';
    return '${usage.accountedCredits} credits · ${usage.settlementStatus}';
  }

  String get _runUsageExpandedDetail {
    final usage = _runUsageResult?.data;
    if (usage == null) return _runUsageDetail;
    return 'Run：${usage.runId}\n'
        '输入 ${usage.rawInputTokens} tokens · 输出 ${usage.rawOutputTokens} tokens\n'
        '计费 ${usage.accountedCredits} credits · ${usage.settlementStatus}';
  }

  DesktopServiceResult<Object?>? _asObjectResult<T>(
    DesktopServiceResult<T>? result,
  ) {
    if (result == null) return null;
    return switch (result.kind) {
      DesktopServiceResultKind.success => DesktopServiceResult<Object?>.success(
        result.data,
      ),
      DesktopServiceResultKind.unavailable =>
        DesktopServiceResult<Object?>.unavailable(
          code: result.code,
          message: result.message,
        ),
      DesktopServiceResultKind.queued => DesktopServiceResult<Object?>.queued(
        data: result.data,
        code: result.code,
        message: result.message,
      ),
      DesktopServiceResultKind.failure => DesktopServiceResult<Object?>.failure(
        code: result.code,
        message: result.message,
        retryable: result.retryable,
        data: result.data,
      ),
    };
  }

  Future<void> _showAccountSignIn() async {
    var phone = '';
    var code = '';
    var agreementAccepted = false;
    var sendingCode = false;
    DesktopSmsChallenge? challenge;
    String? feedback;
    final result =
        await showDialog<
          ({
            String phone,
            String smsRequestId,
            String code,
            bool agreementAccepted,
          })
        >(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('登录花火 AI'),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      key: const ValueKey<String>('account-sign-in-input'),
                      contextMenuBuilder:
                          HuahuoTextEditing.buildEditableContextMenu,
                      autofocus: true,
                      keyboardType: TextInputType.phone,
                      onChanged: (value) => setDialogState(() => phone = value),
                      decoration: const InputDecoration(
                        labelText: '手机号',
                        hintText: '输入登录手机号',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey<String>(
                              'account-sms-code-input',
                            ),
                            contextMenuBuilder:
                                HuahuoTextEditing.buildEditableContextMenu,
                            keyboardType: TextInputType.number,
                            onChanged: (value) =>
                                setDialogState(() => code = value),
                            decoration: const InputDecoration(labelText: '验证码'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          key: const ValueKey<String>('account-send-sms-code'),
                          onPressed: sendingCode || phone.trim().isEmpty
                              ? null
                              : () async {
                                  setDialogState(() {
                                    sendingCode = true;
                                    feedback = null;
                                  });
                                  final sms = await widget.authPort
                                      .requestSmsCode(phone);
                                  if (!dialogContext.mounted) return;
                                  setDialogState(() {
                                    sendingCode = false;
                                    challenge = sms.data;
                                    feedback = sms.isSuccess
                                        ? '验证码已发送，${sms.data!.cooldownSeconds} 秒后可重试'
                                        : sms.message;
                                  });
                                },
                          child: Text(sendingCode ? '发送中' : '发送验证码'),
                        ),
                      ],
                    ),
                    CheckboxListTile(
                      key: const ValueKey<String>('account-agreement'),
                      contentPadding: EdgeInsets.zero,
                      value: agreementAccepted,
                      onChanged: (value) => setDialogState(
                        () => agreementAccepted = value ?? false,
                      ),
                      title: const Text('同意用户协议与隐私政策'),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                    if (feedback != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          feedback!,
                          style: TextStyle(
                            color: challenge == null
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed:
                      challenge == null ||
                          code.trim().isEmpty ||
                          !agreementAccepted
                      ? null
                      : () => Navigator.pop(dialogContext, (
                          phone: phone.trim(),
                          smsRequestId: challenge!.smsRequestId,
                          code: code.trim(),
                          agreementAccepted: agreementAccepted,
                        )),
                  child: const Text('登录'),
                ),
              ],
            ),
          ),
        );
    if (!mounted || result == null) return;
    setState(() => _authLoading = true);
    final signedIn = await widget.authPort.signIn(
      phone: result.phone,
      smsRequestId: result.smsRequestId,
      code: result.code,
      agreementAccepted: result.agreementAccepted,
    );
    if (!mounted) return;
    setState(() {
      _authLoading = false;
      _authResult = signedIn.isSuccess
          ? DesktopServiceResult<DesktopAuthAccount?>.success(signedIn.data)
          : signedIn.isUnavailable
          ? DesktopServiceResult<DesktopAuthAccount?>.unavailable(
              code: signedIn.code,
              message: signedIn.message,
            )
          : DesktopServiceResult<DesktopAuthAccount?>.failure(
              code: signedIn.code,
              message: signedIn.message,
              retryable: signedIn.retryable,
            );
      _accountSignedIn = signedIn.isSuccess;
      if (signedIn.data != null) {
        _accountName = signedIn.data!.displayName;
        _workspaceAccount = signedIn.data;
      }
    });
    if (signedIn.isSuccess) {
      await _activateAuthenticatedAccount(signedIn.data!);
      unawaited(_drainIncomingDocumentPaths());
    }
    if (!mounted) return;
    _showSnack(signedIn.isSuccess ? '登录成功，已启用内容同步' : signedIn.message);
  }

  Future<void> _signOut() async {
    _stopWorkspaceStatusPolling();
    _stopTopicCollisionPolling();
    final currentAccount = _workspaceAccount;
    final currentWorkspaceId = _activeWorkspaceId;
    final result = await widget.authPort.signOut();
    if (!mounted) return;
    if (!result.isSuccess) {
      _showSnack(result.message);
      return;
    }
    await widget.documentSyncPort.clearAccount();
    await _chatTaskTracker.clearCurrentAccount();
    await widget.resourceImageCache.clearAccount();
    _notificationsController.clearAccount();
    unawaited(_activityCalendarController.bindWorkspace(null));
    _workspaceManagementController.reset();
    _homeController.reset();
    if (currentAccount != null && currentWorkspaceId != null) {
      try {
        await widget.topicsCache.clear(
          userId: currentAccount.userId,
          workspaceId: currentWorkspaceId,
        );
      } on Object {
        // Cache cleanup cannot block an explicit sign-out.
      }
    }
    if (!mounted) return;
    _agentController.clearAccount();
    _bookWorkController.clearAccount();
    _workspaceSearchDebounce?.cancel();
    _workspaceSearchSequence++;
    _noteRelationsSequence++;
    final remoteReferenceTabs = _referenceContexts.entries
        .where(
          (entry) => const <String>{
            '云端资产',
            'Workspace 搜索',
            '笔记关系',
            '典藏章节',
            '创作历史',
          }.contains(entry.value.source),
        )
        .map((entry) => entry.key)
        .toSet();
    setState(() {
      _accountSignedIn = false;
      _workspacePreparing = false;
      _workspaceStatusRefreshing = false;
      _workspaceRetrying = false;
      _workspacePreparationError = null;
      _workspaceAccount = null;
      _accountAvatarResourceId = null;
      _authResult = const DesktopServiceResult<DesktopAuthAccount?>.success(
        null,
      );
      _assetsLoaded = false;
      _assetsLoading = false;
      _assetResult = null;
      _assetOverviewResult = null;
      _documentPullResult = null;
      _documentSyncResult = null;
      _chatThreads.clear();
      _activeChatThreadId = null;
      _newChatAgentProfileId = null;
      _chatThreadCreation = null;
      _chatMessages.clear();
      _chatContexts.clear();
      _captureRecords.clear();
      _recordingProgressPolls.clear();
      _captureTextSaving = false;
      _activeDailyTopicTitle = null;
      _dailyTopicContextByThread.clear();
      _workspaceFoldersResult = null;
      _catalogResult = null;
      _subscriptionLoadResult = null;
      _subscriptionLoading = false;
      _activeWorkspaceId = null;
      _subscriptionMutations.clear();
      _subscriptionArticleLoads.clear();
      _subscriptionDeposits.clear();
      _subscriptionActionKeys.clear();
      _savedSubscriptionArticleRevisions.clear();
      if (!widget.demoMode) _externalKnowledgeItems.clear();
      _membershipResult = null;
      _creditsResult = null;
      _runUsageResult = null;
      _sproutFeatureResult = null;
      _sproutGenerating = false;
      _workspaceSearchResult = null;
      _workspaceSearchLoading = false;
      _noteRelationsResult = null;
      _noteRelationsLoading = false;
      _bookResult = null;
      _worksResult = null;
      _workDetailResult = null;
      _bookLoading = false;
      _worksLoading = false;
      _workDetailLoading = false;
      _dailyTopicResult = null;
      _dailyTopicLoading = false;
      _dailyTopicExpiresAt = null;
      _selectedDailyTopicId = null;
      _dailyTopicUsing = false;
      _documentImporting = false;
      _linkCaptureSaving = false;
      _topicCollisionRun = null;
      _topicCollisionPolling = false;
      _topicCollisionError = null;
      _bookWorkMutations.clear();
      _workspaceSearchPartLoads.clear();
      _noteRelationMutations.clear();
      _noteRelationActionKeys.clear();
      _focusedDocumentContext = null;
      _focusedSelectionContext = null;
      _latestChatAnswer = null;
      _referenceContexts.removeWhere(
        (key, value) => remoteReferenceTabs.contains(key),
      );
      _tabs.removeWhere((tab) => remoteReferenceTabs.contains(tab.id));
      if (_tabs.every((tab) => tab.id != _activeTabId)) {
        _activeTabId = 'graph';
        _activeSection = _WorkspaceSection.brain;
      }
    });
  }

  Future<void> _showProfileEditor() async {
    var draft = _accountName;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑个人资料'),
        content: TextField(
          key: const ValueKey<String>('account-name-input'),
          contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
          controller: TextEditingController(text: _accountName),
          autofocus: true,
          onChanged: (value) => draft = value,
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
          decoration: const InputDecoration(labelText: '昵称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final name = result?.trim();
    if (!mounted || name == null || name.isEmpty) return;
    final updated = await widget.authPort.updateProfile(displayName: name);
    if (!mounted) return;
    if (!updated.isSuccess) {
      _showSnack(updated.message);
      return;
    }
    setState(() {
      _accountName = updated.data!.displayName;
      _accountAvatarResourceId = updated.data!.avatarResourceId;
    });
    _showSnack('个人资料已同步');
  }

  Widget _accountAvatarFallback() => Text(
    _accountName.isEmpty ? '花' : _accountName.characters.first,
    style: const TextStyle(fontSize: 22),
  );

  Widget _buildSettingsWorkspace() {
    return Row(
      key: const ValueKey<String>('settings-workspace'),
      children: [
        Container(
          width: 206,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 13, 8, 16),
            children: [
              for (final section in _SettingsSection.values)
                _SettingsNavigationRow(
                  icon: _settingsIcon(section),
                  title: _settingsTitle(section),
                  selected: section == _settingsSection,
                  onTap: () => setState(() => _settingsSection = section),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 42),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: _buildSettingsSection(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsSection() {
    final colors = Theme.of(context).colorScheme;
    final title = _settingsTitle(_settingsSection);
    final subtitle = switch (_settingsSection) {
      _SettingsSection.appearance => '选择桌面端的明暗模式和一套低饱和强调色。',
      _SettingsSection.graph => '调整图谱的节点比例、动态布局和独立配色。',
      _SettingsSection.writing => '调整长期写作时的字号、行距和自动保存。',
      _SettingsSection.assistant => '管理聊天上下文和创作辅助的默认行为。',
      _SettingsSection.sync => '控制本地内容、云端同步和网络使用方式。',
      _SettingsSection.notifications => '选择处理完成和同步状态的提醒方式。',
      _SettingsSection.privacy => '管理诊断数据、内容权限与本地隐私。',
      _SettingsSection.shortcuts => '查看编辑器和工作区的常用快捷键。',
      _SettingsSection.about => '查看版本、更新和诊断信息。',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13.5),
        ),
        const SizedBox(height: 26),
        switch (_settingsSection) {
          _SettingsSection.appearance => _buildAppearanceSettings(),
          _SettingsSection.graph => _buildGraphSettings(),
          _SettingsSection.writing => _buildWritingSettings(),
          _SettingsSection.assistant => _buildAssistantSettings(),
          _SettingsSection.sync => _buildSyncSettings(),
          _SettingsSection.notifications => _buildNotificationSettings(),
          _SettingsSection.privacy => _buildPrivacySettings(),
          _SettingsSection.shortcuts => _buildShortcutSettings(),
          _SettingsSection.about => _buildAboutSettings(),
        },
      ],
    );
  }

  Widget _buildAppearanceSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _buildSettingsGroup(
        title: '显示模式',
        children: [
          SegmentedButton<ThemeMode>(
            key: const ValueKey<String>('settings-theme-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
              ButtonSegment(value: ThemeMode.light, label: Text('明亮')),
              ButtonSegment(value: ThemeMode.dark, label: Text('暗黑')),
            ],
            selected: <ThemeMode>{widget.themeMode},
            onSelectionChanged: (value) =>
                widget.onThemeModeChanged(value.first),
          ),
        ],
      ),
      const SizedBox(height: 18),
      _buildSettingsGroup(
        title: '强调色',
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final palette in DesktopAccentPalette.values)
                _PaletteOption(
                  palette: palette,
                  selected: palette == widget.palette,
                  onTap: () => widget.onPaletteChanged(palette),
                ),
            ],
          ),
        ],
      ),
    ],
  );

  Widget _buildWritingSettings() => Column(
    children: [
      _buildSettingsGroup(
        title: '编辑器',
        children: [
          _SettingsSliderRow(
            label: '文字大小',
            valueLabel: '${(_editorScale * 100).round()}%',
            value: _editorScale,
            min: 0.88,
            max: 1.22,
            divisions: 17,
            onChanged: (value) => setState(() => _editorScale = value),
          ),
          _SettingsSliderRow(
            label: '正文行距',
            valueLabel: _editorLineHeight.toStringAsFixed(2),
            value: _editorLineHeight,
            min: 1.5,
            max: 2.0,
            divisions: 10,
            onChanged: (value) => setState(() => _editorLineHeight = value),
          ),
          SwitchListTile(
            key: const ValueKey<String>('settings-auto-save'),
            contentPadding: EdgeInsets.zero,
            title: const Text('自动保存'),
            subtitle: const Text('编辑内容会持续保存到本地'),
            value: _autoSaveEnabled,
            onChanged: (value) => setState(() => _autoSaveEnabled = value),
          ),
          SwitchListTile(
            key: const ValueKey<String>('settings-note-drafts'),
            contentPadding: EdgeInsets.zero,
            title: const Text('显示创作侧栏'),
            subtitle: const Text('在创作空间和我的资产中保留左侧资源栏'),
            value: _showNoteDrafts,
            onChanged: (value) => setState(() {
              _showNoteDrafts = value;
              if (value) _sidebarExpanded = true;
            }),
          ),
          SwitchListTile(
            key: const ValueKey<String>('settings-focus-mode'),
            contentPadding: EdgeInsets.zero,
            title: const Text('聚焦模式'),
            subtitle: const Text('隐藏导航和聊天栏，保留写作画布'),
            value: _focusMode,
            onChanged: (value) => setState(() {
              _focusMode = value;
              if (value) _contextPanelOpen = false;
            }),
          ),
        ],
      ),
      const SizedBox(height: 18),
      _buildSettingsGroup(
        title: 'Markdown 预览',
        children: [
          MarkdownPreviewSettingsControls(
            controller: _markdownPreviewPreferences,
          ),
        ],
      ),
    ],
  );

  Widget _buildGraphSettings() =>
      DesktopGraphSettingsControls(controller: _graphPreferences);

  Widget _buildAssistantSettings() => _buildSettingsGroup(
    title: '聊天与上下文',
    children: [
      SwitchListTile(
        key: const ValueKey<String>('settings-context-auto-attach'),
        contentPadding: EdgeInsets.zero,
        title: const Text('上下文动态聚焦'),
        subtitle: const Text('当前文稿和选区会在聊天框上方的动态槽位中更新'),
        value: _contextAutoAttach,
        onChanged: (value) => setState(() {
          _contextAutoAttach = value;
          if (value) {
            _attachSelectedContentInState();
          } else {
            _focusedDocumentContext = null;
            _focusedSelectionContext = null;
          }
        }),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('聊天栏'),
        subtitle: Text(_chatRailCollapsed ? '当前已折叠' : '当前已展开'),
        trailing: TextButton(
          onPressed: () =>
              setState(() => _chatRailCollapsed = !_chatRailCollapsed),
          child: Text(_chatRailCollapsed ? '展开' : '折叠'),
        ),
      ),
    ],
  );

  Widget _buildSyncSettings() => _buildSettingsGroup(
    title: '同步',
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('同步状态'),
        subtitle: Text(_documentSyncStatusText),
        trailing: TextButton(
          onPressed: _accountSignedIn ? _retryDocumentSync : _showAccountSignIn,
          child: Text(_accountSignedIn ? '立即同步' : '登录'),
        ),
      ),
      SwitchListTile(
        key: const ValueKey<String>('settings-metered-sync'),
        contentPadding: EdgeInsets.zero,
        title: const Text('允许按流量网络同步'),
        subtitle: const Text('关闭后仅在非计费网络下上传媒体'),
        value: _syncOnMeteredNetwork,
        onChanged: (value) => setState(() => _syncOnMeteredNetwork = value),
      ),
    ],
  );

  String get _documentSyncStatusText {
    final pull = _documentPullResult;
    if (pull != null && !pull.isSuccess) {
      return '${pull.message} · 本地文稿未变更';
    }
    final result = _documentSyncResult;
    if (result == null) {
      return _accountSignedIn ? '本地保存已开启，尚无待同步变更' : '请登录后启用云端同步';
    }
    final state = result.data;
    if (result.isSuccess) return '全部本地变更已同步';
    if (state != null && state.pendingCount > 0) {
      return '${result.message} · ${state.pendingCount} 项待处理';
    }
    return result.message;
  }

  Future<void> _retryDocumentSync() async {
    final pull = await _pullRemoteDocuments();
    if (!mounted) return;
    if (!pull.isSuccess) {
      _showSnack(pull.message);
      return;
    }
    final result = await widget.documentSyncPort.retryPending();
    if (!mounted) return;
    setState(() => _documentSyncResult = result);
    _showSnack(result.isSuccess ? '文稿同步已完成' : result.message);
  }

  Widget _buildNotificationSettings() => _buildSettingsGroup(
    title: '通知',
    children: [
      SwitchListTile(
        key: const ValueKey<String>('settings-notifications'),
        contentPadding: EdgeInsets.zero,
        title: const Text('桌面通知'),
        subtitle: const Text('在转写、沉淀与生成任务完成时提醒'),
        value: _desktopNotifications,
        onChanged: (value) => setState(() => _desktopNotifications = value),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('通知偏好'),
        subtitle: const Text('处理完成、协作提及与同步异常'),
        trailing: const Icon(LucideIcons.chevronRight, size: 16),
        onTap: () => _showFeatureAction(
          title: '通知偏好',
          detail: '已为处理完成、协作提及和同步异常准备独立提醒通道。',
        ),
      ),
    ],
  );

  Widget _buildPrivacySettings() => _buildSettingsGroup(
    title: '隐私与诊断',
    children: [
      SwitchListTile(
        key: const ValueKey<String>('settings-analytics'),
        contentPadding: EdgeInsets.zero,
        title: const Text('发送匿名诊断数据'),
        subtitle: const Text('只用于改进稳定性，不包含文稿正文'),
        value: _usageAnalyticsEnabled,
        onChanged: (value) => setState(() => _usageAnalyticsEnabled = value),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('本地数据与权限'),
        subtitle: const Text('管理麦克风、文件、媒体和缓存权限'),
        trailing: const Icon(LucideIcons.chevronRight, size: 16),
        onTap: () => _showFeatureAction(
          title: '本地数据与权限',
          detail: '你可以查看缓存使用情况并管理麦克风、文件和媒体权限。',
        ),
      ),
    ],
  );

  Widget _buildShortcutSettings() => _buildSettingsGroup(
    title: '快捷键',
    children: const [
      _ShortcutRow(keys: 'Ctrl / Cmd + S', label: '保存当前文稿'),
      _ShortcutRow(keys: 'Ctrl / Cmd + K', label: '打开功能命令面板'),
      _ShortcutRow(keys: 'Ctrl / Cmd + B', label: '切换粗体'),
      _ShortcutRow(keys: 'Ctrl / Cmd + I', label: '切换斜体'),
      _ShortcutRow(keys: 'Ctrl / Cmd + \\', label: '展开或收起笔记栏'),
    ],
  );

  Widget _buildAboutSettings() => _buildSettingsGroup(
    title: '关于花火 AI',
    children: [
      const ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('花火 AI 创作桌面端'),
        subtitle: Text('Windows / macOS 编辑器 · 本地调试版本'),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('检查更新'),
        trailing: TextButton(
          onPressed: () => _showSnack('当前已是最新版本'),
          child: const Text('检查'),
        ),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('导出诊断信息'),
        trailing: TextButton(
          onPressed: () => _showSnack('诊断信息已准备好'),
          child: const Text('导出'),
        ),
      ),
    ],
  );

  Widget _buildSettingsGroup({
    required String title,
    required List<Widget> children,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 9),
      Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(HuahuoRadii.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(children: children),
        ),
      ),
    ],
  );

  String _settingsTitle(_SettingsSection section) => switch (section) {
    _SettingsSection.appearance => '外观',
    _SettingsSection.graph => '图谱',
    _SettingsSection.writing => '写作',
    _SettingsSection.assistant => '聊天与助手',
    _SettingsSection.sync => '同步',
    _SettingsSection.notifications => '通知',
    _SettingsSection.privacy => '隐私与诊断',
    _SettingsSection.shortcuts => '快捷键',
    _SettingsSection.about => '关于',
  };

  IconData _settingsIcon(_SettingsSection section) => switch (section) {
    _SettingsSection.appearance => LucideIcons.palette,
    _SettingsSection.graph => LucideIcons.network,
    _SettingsSection.writing => LucideIcons.type,
    _SettingsSection.assistant => LucideIcons.botMessageSquare,
    _SettingsSection.sync => LucideIcons.refreshCw,
    _SettingsSection.notifications => LucideIcons.bell,
    _SettingsSection.privacy => LucideIcons.shieldCheck,
    _SettingsSection.shortcuts => LucideIcons.keyboard,
    _SettingsSection.about => LucideIcons.info,
  };

  Widget _buildAssetsWorkspace() {
    const sections = <String>[
      '已沉淀',
      '经历',
      '知识',
      '洞察',
      '表达',
      '创作',
      '资讯',
      '影像资源',
    ];
    const demoSectionDetails = <List<(String, String)>>[
      [('一周访谈摘录', '录音沉淀 · 7 月 27 日'), ('高频观点', '文字沉淀 · 7 月 25 日')],
      [('第一次完成百万营收', '经历资产 · 已连接 4 条内容'), ('从产品经理到创作者', '经历资产 · 已连接 6 条内容')],
      [
        ('城市观察笔记', '知识资产 · 12 条摘录'),
        ('品牌表达手册', '知识资产 · 5 个章节'),
        ('创作者案例库', '知识资产 · 32 条案例'),
      ],
      [('低成本沉淀可复用经验', '洞察资产 · 已验证'), ('内容不是热点的搬运', '洞察资产 · 访谈来源')],
      [('用真实场景建立信任', '表达资产 · 适合图文'), ('先说问题，再给判断', '表达资产 · 适合短视频')],
      [('咨询顾问内容选题', '创作资产 · 正在使用'), ('访谈复盘长文', '创作资产 · 文稿关联')],
      [('创作者平台新规则', '资讯资产 · 外部来源'), ('内容行业周报', '资讯资产 · 已归档')],
      [('客户访谈视频片段', '影像资源 · 12:48'), ('产品发布现场照片', '影像资源 · 17 个文件')],
    ];
    final sectionDetails = widget.demoMode
        ? demoSectionDetails
        : List<List<(String, String)>>.filled(
            sections.length,
            const <(String, String)>[],
          );
    final colors = Theme.of(context).colorScheme;
    final selected = _activeAssetSection.clamp(0, sections.length - 1);
    final remoteDetailItems =
        selected == 0 && (_assetOverviewResult?.isSuccess ?? false)
        ? _assetOverviewResult!.data!.items
        : const <DesktopAssetSummary>[];
    final remoteDetailByTitle = <String, DesktopAssetSummary>{
      for (final item in remoteDetailItems) item.title: item,
    };
    final externalTitles = <String>{
      if (widget.demoMode) '创作者平台新规则',
      if (widget.demoMode) '内容行业周报',
      ..._depositedExternalKnowledge,
    };
    final allItems = <(String, String)>[
      ...sectionDetails[selected],
      if (selected == 0 && (_assetResult?.isSuccess ?? false))
        (_assetResult!.data!.title, '云端资产 · 版本 ${_assetResult!.data!.version}'),
      if (selected == 0)
        for (final item in remoteDetailItems) (item.title, '云端定位资产 · 可查看详情'),
      if (selected == 0)
        for (final title in _depositedExternalKnowledge)
          (title, '外部知识 · 已收录到我的资产'),
    ];
    final categorizedItems = selected != 2 || _activeKnowledgeAssetCategory == 0
        ? allItems
        : allItems
              .skip(_activeKnowledgeAssetCategory - 1)
              .take(1)
              .toList(growable: false);
    final filteredItems = <(String, String)>[
      for (final item in categorizedItems)
        if (_assetSourceFilter == _AssetSourceFilter.all ||
            (_assetSourceFilter == _AssetSourceFilter.external) ==
                externalTitles.contains(item.$1))
          item,
    ];
    final documentItems =
        selected == 0 && _assetSourceFilter != _AssetSourceFilter.external
        ? _documents
        : const <HuahuoDocumentSnapshot>[];
    return ColoredBox(
      key: const ValueKey<String>('assets-workspace'),
      color: colors.surface,
      child: Column(
        children: [
          SizedBox(
            height: HuahuoDesktopMetrics.topBarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.folderKanban,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                  Text('我的资产', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey<String>('book-work-open-book'),
                    tooltip: '典藏长文',
                    onPressed: _openBookWorkspace,
                    icon: const Icon(LucideIcons.bookOpenCheck, size: 16),
                  ),
                  PopupMenuButton<_AssetSourceFilter>(
                    key: const ValueKey<String>('asset-source-filter'),
                    tooltip: '来源筛选',
                    onSelected: (value) =>
                        setState(() => _assetSourceFilter = value),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _AssetSourceFilter.all,
                        child: Text('全部来源'),
                      ),
                      PopupMenuItem(
                        value: _AssetSourceFilter.mine,
                        child: Text('我的内容'),
                      ),
                      PopupMenuItem(
                        value: _AssetSourceFilter.external,
                        child: Text('外部来源'),
                      ),
                    ],
                    icon: Icon(
                      LucideIcons.slidersHorizontal,
                      size: 16,
                      color: _assetSourceFilter == _AssetSourceFilter.all
                          ? colors.onSurfaceVariant
                          : colors.primary,
                    ),
                  ),
                  IconButton(
                    tooltip: '将当前分类加入聊天上下文',
                    onPressed: () {
                      _addChatContext(
                        sections[selected],
                        id: 'asset-section-$selected',
                        source: '我的资产',
                        revealChat: true,
                      );
                    },
                    icon: const Icon(LucideIcons.plus, size: 16),
                  ),
                ],
              ),
            ),
          ),
          _buildRemoteAssetStatus(),
          SizedBox(
            height: 42,
            child: ListView.separated(
              key: const ValueKey<String>('asset-section-tabs'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: sections.length,
              separatorBuilder: (_, __) => const SizedBox(width: 2),
              itemBuilder: (context, index) {
                final active = selected == index;
                return TextButton(
                  key: ValueKey<String>('asset-section-$index'),
                  onPressed: () => setState(() => _activeAssetSection = index),
                  style: TextButton.styleFrom(
                    foregroundColor: active
                        ? colors.onSurface
                        : colors.onSurfaceVariant,
                    backgroundColor: active
                        ? colors.surfaceContainer
                        : Colors.transparent,
                  ),
                  child: Text(sections[index]),
                );
              },
            ),
          ),
          if (selected == 2 && widget.demoMode)
            SizedBox(
              height: 38,
              child: ListView.separated(
                key: const ValueKey<String>('asset-knowledge-categories'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                itemCount: 4,
                separatorBuilder: (_, __) => const SizedBox(width: 4),
                itemBuilder: (context, index) {
                  const labels = <String>['全部', '观点', '方法', '案例'];
                  return ChoiceChip(
                    label: Text(labels[index]),
                    selected: _activeKnowledgeAssetCategory == index,
                    onSelected: (_) =>
                        setState(() => _activeKnowledgeAssetCategory = index),
                  );
                },
              ),
            ),
          Expanded(
            child: filteredItems.isEmpty && documentItems.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        selected == 0
                            ? '暂无云端资产。可从采集、聊天或导入 Markdown 创建。'
                            : '当前分类暂无可用资产。',
                        key: const ValueKey<String>('desktop-assets-empty'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(28, 22, 28, 36),
                    itemCount: filteredItems.length + documentItems.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 2),
                    itemBuilder: (context, index) {
                      if (index < documentItems.length) {
                        final document = documentItems[index];
                        final title = document.title.trim().isEmpty
                            ? '未命名文稿'
                            : document.title.trim();
                        return _buildAssetRow(
                          title: title,
                          detail: '我的创作 · 最近编辑',
                          icon: LucideIcons.fileText,
                          onTap: () => unawaited(_activateDocument(document)),
                          onAddToContext: () => _addChatContext(
                            title,
                            id: 'document-${document.id}',
                            source: '我的资产',
                            revealChat: true,
                          ),
                        );
                      }
                      final itemIndex = index - documentItems.length;
                      final item = filteredItems[itemIndex];
                      final remoteDetail = remoteDetailByTitle[item.$1];
                      return _buildAssetRow(
                        title: item.$1,
                        detail: item.$2,
                        icon: selected == 7
                            ? LucideIcons.image
                            : LucideIcons.fileText,
                        onTap: remoteDetail == null
                            ? () {
                                final remote = _assetResult?.data;
                                _openReferenceTab(
                                  item.$1,
                                  contextId: remote?.title == item.$1
                                      ? remote!.id
                                      : null,
                                  contextSource: remote?.title == item.$1
                                      ? '云端资产'
                                      : null,
                                  contextPayload: remote?.title == item.$1
                                      ? remote!.markdown
                                      : null,
                                );
                              }
                            : () => unawaited(
                                _openRemoteAssetDetail(remoteDetail),
                              ),
                        onAddToContext: () => _addChatContext(
                          item.$1,
                          id: 'asset-$selected-${item.$1}',
                          source: '我的资产',
                          revealChat: true,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteAssetStatus() {
    final colors = Theme.of(context).colorScheme;
    if (_assetsLoading) {
      return const SizedBox(
        key: ValueKey<String>('remote-assets-loading'),
        height: 32,
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    final result = _assetResult;
    if (result == null) return const SizedBox.shrink();
    final isReady = result.isSuccess;
    final overview = _assetOverviewResult?.data;
    final message = isReady
        ? overview == null
              ? '云端资产已加载'
              : '云端资产已加载 · ${overview.recordingCount} 段录音 · '
                    '${overview.transcriptWordCount} 字转写'
        : result.message;
    return Container(
      key: ValueKey<String>(
        result.isUnavailable
            ? 'remote-assets-unavailable'
            : 'remote-assets-status',
      ),
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      color: isReady
          ? colors.surfaceContainerLow
          : colors.errorContainer.withValues(alpha: 0.42),
      child: Row(
        children: [
          Icon(
            isReady ? LucideIcons.cloudCheck : LucideIcons.cloudOff,
            size: 15,
            color: isReady ? colors.onSurfaceVariant : colors.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: isReady ? colors.onSurfaceVariant : colors.error,
                fontSize: 12,
              ),
            ),
          ),
          if (isReady)
            TextButton.icon(
              key: const ValueKey<String>('remote-assets-sync'),
              onPressed: _syncRemoteAssets,
              icon: const Icon(LucideIcons.refreshCw, size: 14),
              label: const Text('同步'),
            )
          else
            TextButton.icon(
              key: const ValueKey<String>('remote-assets-retry'),
              onPressed: () => _loadRemoteAssets(force: true),
              icon: const Icon(LucideIcons.rotateCw, size: 14),
              label: const Text('重试'),
            ),
        ],
      ),
    );
  }

  Widget _buildAssetRow({
    required String title,
    required String detail,
    required IconData icon,
    required VoidCallback onTap,
    required VoidCallback onAddToContext,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HuahuoRadii.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
          child: Row(
            children: [
              Icon(icon, size: 16, color: colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14)),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: '加入聊天上下文',
                child: IconButton(
                  key: ValueKey<String>('add-asset-context-$title'),
                  onPressed: onAddToContext,
                  icon: const Icon(LucideIcons.plus, size: 16),
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExternalKnowledgeWorkspace() {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      key: const ValueKey<String>('external-knowledge-workspace'),
      color: colors.surface,
      child: Column(
        children: [
          _buildExternalKnowledgeToolbar(),
          Expanded(
            child: _externalKnowledgeView == _ExternalKnowledgeView.square
                ? _buildKnowledgeSquare()
                : _buildExternalKnowledgeSubscriptions(),
          ),
        ],
      ),
    );
  }

  Widget _buildExternalKnowledgeSubscriptions() {
    final query = _externalSearchInput.text.trim().toLowerCase();
    final visibleItems = _externalKnowledgeItems
        .where((item) => item.subscribed)
        .where(
          (item) =>
              query.isEmpty ||
              item.title.toLowerCase().contains(query) ||
              item.detail.toLowerCase().contains(query) ||
              item.summary.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
          child: TextField(
            key: const ValueKey<String>('external-knowledge-search'),
            contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
            controller: _externalSearchInput,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '搜索我的订阅',
              prefixIcon: Icon(LucideIcons.search, size: 16),
            ),
          ),
        ),
        Expanded(
          child: visibleItems.isEmpty
              ? _buildExternalKnowledgeEmptyState(square: false)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 34),
                  itemCount: visibleItems.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 3),
                  itemBuilder: (context, index) =>
                      _buildExternalKnowledgeRow(visibleItems[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildExternalKnowledgeToolbar() {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(
            children: [
              _ExternalKnowledgeTab(
                key: const ValueKey<String>('external-knowledge-subscriptions'),
                icon: LucideIcons.rss,
                label: '我的订阅',
                selected:
                    _externalKnowledgeView ==
                    _ExternalKnowledgeView.subscriptions,
                onTap: () => setState(
                  () => _externalKnowledgeView =
                      _ExternalKnowledgeView.subscriptions,
                ),
              ),
              _ExternalKnowledgeTab(
                key: const ValueKey<String>('external-knowledge-square'),
                icon: LucideIcons.compass,
                label: '知识广场',
                selected:
                    _externalKnowledgeView == _ExternalKnowledgeView.square,
                onTap: () => setState(
                  () => _externalKnowledgeView = _ExternalKnowledgeView.square,
                ),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey<String>('external-knowledge-import'),
                tooltip: '导入外部知识',
                onPressed: _showExternalKnowledgeImport,
                icon: const Icon(LucideIcons.plus, size: 17),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExternalKnowledgeRow(_ExternalKnowledgeItem item) {
    final colors = Theme.of(context).colorScheme;
    final deposited = _isExternalKnowledgeDeposited(item);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('external-knowledge-row-${item.id}'),
        onTap: () => _openExternalKnowledgeDetail(item),
        borderRadius: BorderRadius.circular(HuahuoRadii.control),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 8, 12),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 32,
                child: Icon(
                  item.kind,
                  size: 17,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, style: const TextStyle(fontSize: 14)),
                    const SizedBox(height: 3),
                    Text(
                      item.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: '加入聊天上下文',
                child: IconButton(
                  key: ValueKey<String>('add-external-context-${item.id}'),
                  onPressed: () => _addChatContext(
                    item.title,
                    id: 'external-${item.id}',
                    source: '外部知识',
                    payload: item.summary,
                    revealChat: true,
                  ),
                  icon: const Icon(LucideIcons.plus, size: 16),
                ),
              ),
              PopupMenuButton<String>(
                key: ValueKey<String>('external-action-${item.id}'),
                tooltip: '更多操作',
                onSelected: (value) {
                  switch (value) {
                    case 'open':
                      _openExternalKnowledgeDetail(item);
                    case 'deposit':
                      unawaited(_depositExternalKnowledge(item.title));
                    case 'subscription':
                      _toggleExternalKnowledgeSubscription(item.id);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'open', child: Text('查看详情')),
                  PopupMenuItem(
                    value: 'subscription',
                    child: Text(item.subscribed ? '取消订阅' : '订阅'),
                  ),
                  PopupMenuItem(
                    value: 'deposit',
                    enabled: !deposited,
                    child: Text(deposited ? '已收录到我的资产' : '收录到我的资产'),
                  ),
                ],
                icon: const Icon(LucideIcons.ellipsis, size: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExternalKnowledgeEmptyState({required bool square}) {
    final result = _subscriptionLoadResult;
    if (_subscriptionLoading) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final failed = !widget.demoMode && result != null && !result.isSuccess;
    final message = failed
        ? result.message
        : !_accountSignedIn && !widget.demoMode
        ? '登录后读取知识广场与我的订阅'
        : square
        ? '知识广场暂无可用文章'
        : '还没有订阅内容，可以去知识广场看看';
    return Center(
      key: ValueKey<String>(
        failed ? 'subscription-remote-error' : 'subscription-remote-empty',
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(failed ? LucideIcons.cloudOff : LucideIcons.inbox, size: 26),
          const SizedBox(height: 10),
          Text(message),
          if (failed && _activeWorkspaceId != null) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              key: const ValueKey<String>('subscription-remote-retry'),
              onPressed: () => _reloadRemoteSubscriptions(),
              icon: const Icon(LucideIcons.rotateCw, size: 15),
              label: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildKnowledgeSquare() {
    if (_externalKnowledgeItems.isEmpty && !widget.demoMode) {
      return _buildExternalKnowledgeEmptyState(square: true);
    }
    final colors = Theme.of(context).colorScheme;
    final query = _knowledgeSquareSearchInput.text.trim().toLowerCase();
    final queryItems = _externalKnowledgeItems
        .where((item) => _matchesKnowledgeSquareQuery(item, query))
        .toList(growable: false);
    final categoryItems = queryItems
        .where(
          (item) =>
              _matchesKnowledgeSquareCategory(item, _knowledgeSquareCategory),
        )
        .toList(growable: false);
    final squareItems = categoryItems;
    final visibleItems = _showAllKnowledgeSquareUpdates
        ? squareItems
        : squareItems.take(3).toList(growable: false);
    final featuredItem = _externalKnowledgeItems.isEmpty
        ? null
        : _externalKnowledgeItems.first;
    void selectCategory(_KnowledgeSquareCategory category) {
      setState(() {
        _knowledgeSquareCategory = category;
        _showAllKnowledgeSquareUpdates = false;
      });
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth >= 900 ? 30.0 : 22.0;
        return ListView(
          key: const ValueKey<String>('knowledge-square-workspace'),
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            14,
            horizontalPadding,
            32,
          ),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: _buildKnowledgeSquareFeed(
                  colors: colors,
                  featuredItem: featuredItem,
                  squareItems: squareItems,
                  visibleItems: visibleItems,
                  onSelectCategory: selectCategory,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildKnowledgeSquareFeed({
    required ColorScheme colors,
    required _ExternalKnowledgeItem? featuredItem,
    required List<_ExternalKnowledgeItem> squareItems,
    required List<_ExternalKnowledgeItem> visibleItems,
    required ValueChanged<_KnowledgeSquareCategory> onSelectCategory,
  }) {
    final search = SizedBox(
      height: 38,
      child: TextField(
        key: const ValueKey<String>('knowledge-square-search'),
        contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
        controller: _knowledgeSquareSearchInput,
        onChanged: (_) => setState(() {
          _showAllKnowledgeSquareUpdates = false;
        }),
        decoration: const InputDecoration(
          hintText: '搜索知识广场',
          prefixIcon: Icon(LucideIcons.search, size: 16),
          contentPadding: EdgeInsets.symmetric(vertical: 8),
        ),
      ),
    );
    final discovery = _buildKnowledgeSquareDiscoveryArea(
      featuredItem: featuredItem,
    );
    final updates = visibleItems
        .map(
          (item) => _KnowledgeSquareUpdateCard(
            item: item,
            category: _knowledgeSquareCategoryForItem(item),
            isDeposited: _isExternalKnowledgeDeposited(item),
            onOpen: () => _openExternalKnowledgeDetail(item),
            onAddToContext: () => _addChatContext(
              item.title,
              id: 'external-${item.id}',
              source: '知识广场',
              payload: item.summary,
              revealChat: true,
            ),
            onSubscription: () => _toggleExternalKnowledgeSubscription(item.id),
            onAction: (action) => _handleKnowledgeSquareAction(item, action),
          ),
        )
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        search,
        const SizedBox(height: 14),
        discovery,
        const SizedBox(height: 18),
        _KnowledgeSquareTopicGrid(
          selected: _knowledgeSquareCategory,
          onSelected: onSelectCategory,
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                _knowledgeSquareCategory == _KnowledgeSquareCategory.all
                    ? '最近更新'
                    : '${_knowledgeSquareCategory.label} · 最近更新',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (squareItems.length > 3)
              TextButton(
                key: const ValueKey<String>('knowledge-square-more'),
                onPressed: () => setState(
                  () => _showAllKnowledgeSquareUpdates =
                      !_showAllKnowledgeSquareUpdates,
                ),
                child: Text(_showAllKnowledgeSquareUpdates ? '收起' : '更多'),
              ),
          ],
        ),
        const SizedBox(height: 3),
        if (updates.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 64),
            child: Center(
              child: Text(
                '知识广场暂时没有匹配内容',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
          )
        else
          Column(children: updates),
      ],
    );
  }

  Widget _buildKnowledgeSquareDiscoveryArea({
    required _ExternalKnowledgeItem? featuredItem,
  }) => _KnowledgeSquareDiscoveryBanner(
    item: featuredItem,
    onOpen: _openExternalKnowledgeDetail,
  );

  bool _matchesKnowledgeSquareQuery(_ExternalKnowledgeItem item, String query) {
    if (query.isEmpty) return true;
    return <String>[
      item.title,
      item.detail,
      item.summary,
      item.author,
      ...item.topics,
    ].join(' ').toLowerCase().contains(query);
  }

  bool _matchesKnowledgeSquareCategory(
    _ExternalKnowledgeItem item,
    _KnowledgeSquareCategory category,
  ) {
    if (category == _KnowledgeSquareCategory.all) return true;
    final searchable = <String>[
      item.title,
      item.detail,
      item.summary,
      item.author,
      ...item.topics,
    ].join(' ').toLowerCase();
    final keywords = switch (category) {
      _KnowledgeSquareCategory.treasure => const ['藏', '博物', '文物', '展览'],
      _KnowledgeSquareCategory.history => const ['历史', '史学', '古', '朝代'],
      _KnowledgeSquareCategory.socialScience => const ['社科', '社会', '人文', '经济'],
      _KnowledgeSquareCategory.art => const ['艺术', '设计', '绘画', '音乐'],
      _KnowledgeSquareCategory.literature => const ['文学', '写作', '小说', '诗'],
      _KnowledgeSquareCategory.audio => const ['播客', '音频', '听', '声音'],
      _KnowledgeSquareCategory.culture => const ['文创', '文化', '创意', '品牌'],
      _KnowledgeSquareCategory.city => const ['城市', '旅行', '漫游', '空间'],
      _KnowledgeSquareCategory.bookstore => const ['书店', '阅读', '图书', '书籍'],
      _KnowledgeSquareCategory.all => const <String>[],
    };
    return keywords.any(searchable.contains);
  }

  _KnowledgeSquareCategory _knowledgeSquareCategoryForItem(
    _ExternalKnowledgeItem item,
  ) {
    return _KnowledgeSquareCategory.values.firstWhere(
      (category) =>
          category != _KnowledgeSquareCategory.all &&
          _matchesKnowledgeSquareCategory(item, category),
      orElse: () => _KnowledgeSquareCategory.all,
    );
  }

  void _handleKnowledgeSquareAction(
    _ExternalKnowledgeItem item,
    _KnowledgeSquareAction action,
  ) {
    switch (action) {
      case _KnowledgeSquareAction.open:
        _openExternalKnowledgeDetail(item);
      case _KnowledgeSquareAction.share:
        _showSnack('已准备分享「${item.title}」');
      case _KnowledgeSquareAction.copyToEdit:
        _appendToDocument(
          '引用「${item.title}」：${item.summary}',
          confirmation: '已复制到当前文稿，可继续编辑',
        );
      case _KnowledgeSquareAction.export:
        _showSnack('已准备导出「${item.title}」');
      case _KnowledgeSquareAction.deposit:
        unawaited(_depositKnowledgeSquareItem(item));
    }
  }

  Future<void> _depositKnowledgeSquareItem(_ExternalKnowledgeItem item) async {
    if (!item.subscribed) {
      _showSnack('请先订阅后再沉淀到我的资产');
      return;
    }
    if (!item.isRemoteArticle) {
      if (widget.demoMode) await _depositExternalKnowledge(item.title);
      return;
    }
    final workspaceId = _activeWorkspaceId;
    final articleId = item.articleId!;
    final articleRevisionId = item.currentArticleRevisionId?.trim();
    if (workspaceId == null) {
      _showSnack('请先登录并完成 Workspace 初始化');
      return;
    }
    if (articleRevisionId == null || articleRevisionId.isEmpty) {
      _showSnack('文章版本信息缺失，请刷新后重试');
      return;
    }
    final actionResourceId = '$articleId:$articleRevisionId';
    if (!_subscriptionDeposits.add(articleId)) return;
    if (mounted) setState(() {});
    final result = await widget.subscriptionPort.saveArticleAsNote(
      workspaceId,
      articleId,
      articleRevisionId: articleRevisionId,
      idempotencyKey: _subscriptionActionKey('save', actionResourceId),
    );
    if (!mounted) return;
    if (!result.isSuccess || result.data == null) {
      setState(() => _subscriptionDeposits.remove(articleId));
      _showSnack(
        result.code == 'SUBSCRIPTION_NOTE_TOMBSTONED'
            ? '这篇文章对应的笔记位于回收站，请先恢复'
            : result.message,
      );
      return;
    }
    _subscriptionActionKeys.remove('save:$actionResourceId');
    final pull = await widget.documentSyncPort.pullRemote(
      apply: _applyRemoteDocumentPull,
    );
    if (!mounted) return;
    setState(() {
      _subscriptionDeposits.remove(articleId);
      _documentPullResult = pull;
      if (pull.isSuccess) {
        _savedSubscriptionArticleRevisions.add(_subscriptionDepositKey(item));
      }
    });
    _showSnack(
      pull.isSuccess ? '已保存为正式笔记' : '文章已保存到云端，但本地文稿刷新失败：${pull.message}',
    );
  }

  void _openExternalKnowledgeDetail(_ExternalKnowledgeItem item) {
    if (item.isRemoteArticle) {
      unawaited(_openRemoteSubscriptionArticle(item));
      return;
    }
    _openReferenceTab(
      item.title,
      section: _WorkspaceSection.externalKnowledge,
      contextId: 'external-${item.id}',
      contextSource: '外部知识',
      contextPayload: item.summary,
    );
  }

  Future<void> _openRemoteSubscriptionArticle(
    _ExternalKnowledgeItem item,
  ) async {
    final articleId = item.articleId!;
    if (!_subscriptionArticleLoads.add(articleId)) return;
    if (mounted) setState(() {});
    final result = await widget.subscriptionPort.loadArticle(articleId);
    if (!mounted) return;
    setState(() => _subscriptionArticleLoads.remove(articleId));
    final revision = result.data;
    if (!result.isSuccess || revision == null) {
      if (result.code == 'SUBSCRIPTION_CATALOG_UNAVAILABLE') {
        unawaited(_reloadRemoteSubscriptions());
        _showSnack('这篇文章已下架或暂不可用');
      } else {
        _showSnack(result.message);
      }
      return;
    }
    final index = _externalKnowledgeItems.indexWhere(
      (candidate) => candidate.id == item.id,
    );
    if (index >= 0) {
      setState(() {
        _externalKnowledgeItems[index] = _externalKnowledgeItems[index]
            .copyWith(summary: revision.contentMarkdown);
      });
    }
    _openReferenceTab(
      revision.title,
      section: _WorkspaceSection.externalKnowledge,
      contextId: 'subscription-${revision.articleId}',
      contextSource: '订阅文章',
      contextPayload: revision.contentMarkdown,
    );
  }

  void _toggleExternalKnowledgeSubscription(String id) {
    unawaited(_toggleExternalKnowledgeSubscriptionAsync(id));
  }

  Future<void> _toggleExternalKnowledgeSubscriptionAsync(String id) async {
    final index = _externalKnowledgeItems.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final item = _externalKnowledgeItems[index];
    if (!item.isRemoteArticle) {
      if (!widget.demoMode) return;
      setState(() {
        _externalKnowledgeItems[index] = item.copyWith(
          subscribed: !item.subscribed,
        );
      });
      _showSnack(item.subscribed ? '已取消订阅' : '已订阅 ${item.title}');
      return;
    }
    final workspaceId = _activeWorkspaceId;
    final publicationId = item.publicationId!;
    if (workspaceId == null) {
      _showSnack('请先登录并完成 Workspace 初始化');
      return;
    }
    if (!_subscriptionMutations.add(publicationId)) return;
    final desired = !item.subscribed;
    final previous = <String, bool>{
      for (final candidate in _externalKnowledgeItems)
        if (candidate.publicationId == publicationId)
          candidate.id: candidate.subscribed,
    };
    setState(() {
      for (
        var candidateIndex = 0;
        candidateIndex < _externalKnowledgeItems.length;
        candidateIndex++
      ) {
        final candidate = _externalKnowledgeItems[candidateIndex];
        if (candidate.publicationId == publicationId) {
          _externalKnowledgeItems[candidateIndex] = candidate.copyWith(
            subscribed: desired,
          );
        }
      }
    });
    final action = desired ? 'follow' : 'unfollow';
    final key = _subscriptionActionKey(action, publicationId);
    final result = desired
        ? await widget.subscriptionPort.followPublication(
            workspaceId,
            publicationId,
            idempotencyKey: key,
          )
        : await widget.subscriptionPort.unfollowPublication(
            workspaceId,
            publicationId,
            idempotencyKey: key,
          );
    if (!mounted) return;
    final acceptedLifecycle = desired ? 'following' : 'unfollowed';
    if (!result.isSuccess || result.data?.lifecycle != acceptedLifecycle) {
      setState(() {
        _subscriptionMutations.remove(publicationId);
        for (
          var candidateIndex = 0;
          candidateIndex < _externalKnowledgeItems.length;
          candidateIndex++
        ) {
          final candidate = _externalKnowledgeItems[candidateIndex];
          final old = previous[candidate.id];
          if (old != null) {
            _externalKnowledgeItems[candidateIndex] = candidate.copyWith(
              subscribed: old,
            );
          }
        }
      });
      _showSnack(result.message.isEmpty ? '订阅状态更新失败' : result.message);
      return;
    }
    setState(() => _subscriptionMutations.remove(publicationId));
    _subscriptionActionKeys.remove('$action:$publicationId');
    _showSnack(desired ? '已订阅 ${item.sourceLabel}' : '已取消订阅');
    await _reloadRemoteSubscriptions(preserveOnFailure: true);
  }

  String _subscriptionActionKey(String action, String resourceId) {
    final scope = '$action:$resourceId';
    return _subscriptionActionKeys.putIfAbsent(scope, () {
      _subscriptionMutationSequence++;
      final safeId = resourceId.replaceAll(RegExp(r'[^A-Za-z0-9._:-]'), '_');
      return 'desktop-subscription-$action-$safeId-$_subscriptionMutationSequence';
    });
  }

  bool _isExternalKnowledgeDeposited(_ExternalKnowledgeItem item) =>
      item.isRemoteArticle
      ? _savedSubscriptionArticleRevisions.contains(
          _subscriptionDepositKey(item),
        )
      : _depositedExternalKnowledge.contains(item.title);

  String _subscriptionDepositKey(_ExternalKnowledgeItem item) =>
      '${item.articleId}:${item.currentArticleRevisionId}';

  Future<void> _showExternalKnowledgeImport() async {
    if (_documentImporting) return;
    const pickDocument = '__desktop_pick_document__';
    var draft = '';
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入外部知识'),
        content: SizedBox(
          width: 410,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('粘贴网页链接，或选择文档作为原始资产。'),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('external-knowledge-import-input'),
                contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
                autofocus: true,
                onChanged: (value) => draft = value,
                onSubmitted: (value) => Navigator.pop(dialogContext, value),
                decoration: const InputDecoration(
                  hintText: 'https://example.com/article',
                  prefixIcon: Icon(LucideIcons.link, size: 16),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, pickDocument),
            icon: const Icon(LucideIcons.fileText, size: 16),
            label: const Text('选择文档'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    final title = result?.trim();
    if (!mounted || title == null || title.isEmpty) return;
    if (title == pickDocument) {
      await _importSelectedDocument();
      return;
    }
    final link = Uri.tryParse(title);
    if (link == null ||
        !link.hasAuthority ||
        (link.scheme != 'https' && link.scheme != 'http')) {
      _showSnack('请输入有效网页链接，或选择文档');
      return;
    }
    await _importLinkAsRawAsset(link, addCaptureRecord: false);
  }

  Future<void> _importSelectedDocument() async {
    final workspaceId = _activeWorkspaceId;
    if (!_workspaceIsReady || workspaceId == null || workspaceId.isEmpty) {
      _showSnack(_accountSignedIn ? 'Workspace 正在准备，完成后才能导入文档' : '请先登录后再导入文档');
      return;
    }
    final selected = await openFile(
      acceptedTypeGroups: <XTypeGroup>[_documentFileTypes],
    );
    if (!mounted || selected == null) return;
    final sourcePath = selected.path.trim();
    final fileName = selected.name.trim();
    await _importDocumentAtPath(sourcePath, fileName);
  }

  void _handleIncomingDocumentEvent(Object? event) {
    if (event is! String) return;
    _queueIncomingDocumentPath(event);
  }

  void _queueIncomingDocumentPath(String rawPath) {
    final path = rawPath.trim();
    if (!_isAbsoluteFilePath(path) ||
        _pendingIncomingDocumentPaths.contains(path)) {
      return;
    }
    _pendingIncomingDocumentPaths.add(path);
    unawaited(_drainIncomingDocumentPaths());
  }

  bool _isAbsoluteFilePath(String path) =>
      path.trim().isNotEmpty && File(path.trim()).isAbsolute;

  Future<void> _drainIncomingDocumentPaths() async {
    if (_drainingIncomingDocuments ||
        _documentImporting ||
        !_workspaceIsReady ||
        !mounted) {
      return;
    }
    _drainingIncomingDocuments = true;
    try {
      while (mounted &&
          _workspaceIsReady &&
          !_documentImporting &&
          _pendingIncomingDocumentPaths.isNotEmpty) {
        final sourcePath = _pendingIncomingDocumentPaths.removeAt(0);
        if (!FileSystemEntity.isFileSync(sourcePath)) {
          _showSnack('外部文档已不可读取');
          continue;
        }
        final fileName = File(sourcePath).uri.pathSegments.last.trim();
        if (fileName.isEmpty) {
          _showSnack('无法读取外部文档名称');
          continue;
        }
        await _importDocumentAtPath(sourcePath, fileName);
      }
    } finally {
      _drainingIncomingDocuments = false;
    }
    if (mounted &&
        _workspaceIsReady &&
        !_documentImporting &&
        _pendingIncomingDocumentPaths.isNotEmpty) {
      unawaited(_drainIncomingDocumentPaths());
    }
  }

  Future<void> _importDocumentAtPath(String sourcePath, String fileName) async {
    final workspaceId = _activeWorkspaceId;
    if (!_workspaceIsReady || workspaceId == null || workspaceId.isEmpty) {
      _showSnack(_accountSignedIn ? 'Workspace 正在准备，完成后才能导入文档' : '请先登录后再导入文档');
      return;
    }
    if (sourcePath.isEmpty || fileName.isEmpty) {
      _showSnack('无法读取所选文档');
      return;
    }
    setState(() => _documentImporting = true);
    try {
      final result = await widget.documentImporter.importDocument(
        DesktopDocumentImportRequest(
          filePath: sourcePath,
          fileName: fileName,
          workspaceId: workspaceId,
        ),
      );
      if (!mounted || !_accountSignedIn || _activeWorkspaceId != workspaceId) {
        return;
      }
      if (!result.isSuccess || result.data == null) {
        _showSnack(result.message);
        return;
      }
      final imported = result.data!;
      final pull = await _pullRemoteDocuments();
      if (!mounted || !_accountSignedIn || _activeWorkspaceId != workspaceId) {
        return;
      }
      setState(() {
        _assetsLoaded = false;
        _externalKnowledgeItems.insert(
          0,
          _ExternalKnowledgeItem(
            id: 'document-${imported.noteId}',
            title: imported.title,
            detail: '${imported.format.displayLabel} · ${imported.fileName}',
            kind: LucideIcons.fileText,
            summary: imported.rawMarkdown,
            subscribed: true,
            sourceLabel: '${imported.format.displayLabel} 导入',
          ),
        );
      });
      _openReferenceTab(
        imported.title,
        section: _WorkspaceSection.assets,
        contextId: 'document-${imported.noteId}',
        contextSource: '${imported.format.displayLabel} 导入',
        contextPayload: imported.rawMarkdown,
      );
      unawaited(_loadRemoteAssets(force: true));
      _showSnack(
        pull.isSuccess
            ? '${imported.format.displayLabel} 已保存为原始资产'
            : '${imported.format.displayLabel} 已保存到云端，可稍后刷新资产查看',
      );
    } finally {
      if (mounted && _documentImporting) {
        setState(() => _documentImporting = false);
      }
    }
  }

  Future<void> _depositExternalKnowledge(String title) async {
    if (_depositedExternalKnowledge.contains(title)) {
      _showSnack('这条外部知识已经在我的资产中');
      return;
    }
    final now = DateTime.now().toUtc();
    final snapshot = HuahuoDocumentSnapshot(
      id: 'external-${now.microsecondsSinceEpoch}',
      title: title,
      deltaJson: '[{"insert":"来自外部知识库的内容：$title。\\n\\n等待继续整理和创作。\\n"}]',
      revision: 0,
      createdAt: now,
      modifiedAt: now,
    );
    await widget.documentStore.save(snapshot);
    if (!mounted) return;
    setState(() {
      _documents.insert(0, snapshot);
      _depositedExternalKnowledge.add(title);
      _expandedFolders.add('已沉淀');
    });
    _showSnack('已收录到我的资产');
  }

  Widget _buildReferenceWorkspace(_WorkspaceTab tab) {
    final title = tab.title;
    final reference = _referenceContexts[tab.id];
    if ((reference?.source == '云端资产' ||
            reference?.source == '订阅文章' ||
            reference?.source == 'Workspace 搜索' ||
            reference?.source == '笔记关系' ||
            reference?.source == '典藏章节' ||
            reference?.source == '创作历史') &&
        reference?.payload != null) {
      return ValueListenableBuilder<MarkdownPreviewPreferences>(
        valueListenable: _markdownPreviewPreferences,
        builder: (context, preferences, _) => MarkdownPreviewPane(
          key: const ValueKey<String>('remote-asset-markdown-preview'),
          source: MarkdownPreviewSource(
            title: title,
            markdown: reference!.payload!,
            stage: reference.source,
          ),
          preferences: preferences,
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final externalIndex = _externalKnowledgeItems.indexWhere(
      (item) => item.title == title,
    );
    final external = externalIndex < 0
        ? null
        : _externalKnowledgeItems[externalIndex];
    final sourceLabel = external?.sourceLabel ?? '来自知识素材';
    final body =
        external?.summary ?? '这条素材记录了真实场景中的观察、原话和判断。它可以被引用到聊天，也可以直接进入当前文稿继续整理。';
    return ColoredBox(
      key: const ValueKey<String>('reference-workspace'),
      color: colors.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(36, 42, 36, 48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 12),
                Text(
                  sourceLabel,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 48),
                SelectionArea(
                  contextMenuBuilder:
                      HuahuoTextEditing.buildSelectableContextMenu,
                  child: HuahuoMarkdown(
                    source: body,
                    contextMenuBuilder:
                        HuahuoTextEditing.buildEditableContextMenu,
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    TextButton.icon(
                      key: ValueKey<String>('add-reference-context-$title'),
                      onPressed: () => _addChatContext(
                        title,
                        id: external == null ? null : 'external-${external.id}',
                        source: sourceLabel,
                        payload: external?.summary,
                        revealChat: true,
                      ),
                      icon: const Icon(LucideIcons.plus, size: 16),
                      label: const Text('加入聊天上下文'),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => _appendToDocument(
                        '引用「$title」：这条素材记录了真实场景中的观察、原话和判断。',
                        confirmation: '已添加到当前文稿',
                      ),
                      icon: const Icon(LucideIcons.fileOutput, size: 16),
                      label: const Text('添加到当前文稿'),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => unawaited(
                        external == null
                            ? _depositExternalKnowledge(title)
                            : _depositKnowledgeSquareItem(external),
                      ),
                      icon: const Icon(LucideIcons.download, size: 16),
                      label: const Text('收录到我的资产'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFeatureAction({
    required String title,
    required String detail,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _showSnack('已打开$title');
            },
            child: const Text('打开'),
          ),
        ],
      ),
    );
  }

  List<(IconData, String, String)> _sectionItems(_WorkspaceSection section) =>
      switch (section) {
        _WorkspaceSection.capture => const [
          (LucideIcons.audioLines, '独白', '导入已有独白音频，实时录音请使用移动端'),
          (LucideIcons.notebookPen, '随录', '快速记录一条文字灵感'),
          (LucideIcons.usersRound, '会议', '导入已有会议音频，实时转写请使用移动端'),
          (LucideIcons.notebookPen, '文字笔记', '直接写下一条待沉淀素材'),
          (LucideIcons.link, '链接导入', '解析网页链接并保留来源'),
          (LucideIcons.fileUp, '文档与媒体', '导入文档、本地录音、图片或视频'),
          (LucideIcons.video, '视频分析', '生成视频内容分析与可引用文档'),
        ],
        _WorkspaceSection.tools => const [
          (LucideIcons.mapPinned, '基础定位', '通过对话梳理起点、目标与内容方向'),
          (LucideIcons.circleUserRound, '人设', '围绕个人表达和专业身份生成内容'),
          (LucideIcons.messagesSquare, '获客', '从真实问题出发组织成交内容'),
          (LucideIcons.video, '影像', '规划适合镜头表达的选题与结构'),
          (LucideIcons.network, '深度定位', '梳理差异、受众和长期内容方向'),
          (LucideIcons.history, '创作历史', '回到过去的任务、结果和文稿'),
        ],
        _WorkspaceSection.assets => const [
          (LucideIcons.library, '知识库', '检索已经沉淀的笔记和来源'),
          (LucideIcons.folderKanban, '我的资产', '管理经历、观点、案例和方法'),
          (LucideIcons.calendarDays, '日历', '按时间查看记录和内容活动'),
          (LucideIcons.bell, '通知', '查看处理完成、协作和系统消息'),
        ],
        _ => const [],
      };

  String _sectionTitle(_WorkspaceSection section) => switch (section) {
    _WorkspaceSection.brain => '思想图谱',
    _WorkspaceSection.creation => '创作空间',
    _WorkspaceSection.chat => '聊天',
    _WorkspaceSection.capture => '采集与独白',
    _WorkspaceSection.tools => '创作工具',
    _WorkspaceSection.externalKnowledge => '外部知识',
    _WorkspaceSection.assets => '我的资产',
    _WorkspaceSection.notifications => '通知',
    _WorkspaceSection.account => '个人账户',
    _WorkspaceSection.settings => '设置',
  };

  String _sectionSubtitle(_WorkspaceSection section) => switch (section) {
    _WorkspaceSection.capture => '从文字、链接和本地文件收集素材；实时音频采集与转写由移动端提供。',
    _WorkspaceSection.tools => '从定位、选题到表达，按目标进入对应创作流程。',
    _WorkspaceSection.externalKnowledge => '从外部文件、链接和原始资料中建立可引用的知识来源。',
    _WorkspaceSection.assets => '统一查看知识、个人内容资产、日历和通知。',
    _WorkspaceSection.notifications => '查看内容、创作和系统状态通知。',
    _WorkspaceSection.account => '管理个人资料、会员、同步和账号安全。',
    _WorkspaceSection.settings => '调整外观、图谱、写作偏好、聊天、同步和隐私设置。',
    _ => '',
  };

  IconData _sectionIcon(_WorkspaceSection section) => switch (section) {
    _WorkspaceSection.brain => LucideIcons.network,
    _WorkspaceSection.creation => LucideIcons.penLine,
    _WorkspaceSection.chat => LucideIcons.messagesSquare,
    _WorkspaceSection.capture => LucideIcons.audioLines,
    _WorkspaceSection.tools => LucideIcons.sparkles,
    _WorkspaceSection.externalKnowledge => LucideIcons.bookOpenText,
    _WorkspaceSection.assets => LucideIcons.folderKanban,
    _WorkspaceSection.notifications => LucideIcons.bell,
    _WorkspaceSection.account => LucideIcons.circleUserRound,
    _WorkspaceSection.settings => LucideIcons.settings,
  };

  Widget _buildEditorPane(bool sidebarExpanded) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: _translucentSurface(
        context,
        colors.surface,
        lightAlpha: 0.99,
        darkAlpha: 0.985,
      ),
      child: Column(
        children: [
          _buildTopBar(sidebarExpanded),
          Expanded(
            child: switch (_documentWorkspaceView) {
              _DocumentWorkspaceView.writing => _buildWritingWorkspace(),
              _DocumentWorkspaceView.preview =>
                _buildMarkdownPreviewWorkspace(),
              _DocumentWorkspaceView.outline =>
                _buildDocumentOutlineWorkspace(),
              _DocumentWorkspaceView.references =>
                _buildDocumentReferencesWorkspace(),
              _DocumentWorkspaceView.annotations =>
                _buildDocumentAnnotationsWorkspace(),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildWritingWorkspace() => LayoutBuilder(
    builder: (context, constraints) {
      final showCompanion =
          _activeNoteStageIsEditable &&
          constraints.maxWidth >= _markdownCompanionBreakpoint;
      if (!showCompanion) return _buildDocumentEditor();

      final colors = Theme.of(context).colorScheme;
      return Row(
        key: const ValueKey<String>('markdown-live-writing-split'),
        children: [
          Expanded(flex: 11, child: _buildDocumentEditor()),
          Container(
            width: 1,
            color: colors.outlineVariant.withValues(alpha: 0.52),
          ),
          Expanded(
            flex: 9,
            child: KeyedSubtree(
              key: const ValueKey<String>('markdown-live-companion'),
              child: _buildMarkdownPreviewWorkspace(
                surface: MarkdownPreviewSurface.companion,
              ),
            ),
          ),
        ],
      );
    },
  );

  bool get _isChatProcessing =>
      _generatingMode == _PrimaryWorkspaceMode.chat || _hasActiveChatTask;

  Widget _buildChatTaskStatusStrip({bool compact = false}) {
    final threadId = _activeChatThreadId;
    if (threadId == null) return const SizedBox.shrink();
    final tasks = _chatTaskTracker.tasksForThread(threadId);
    if (tasks.isEmpty) return const SizedBox.shrink();
    final latest = tasks.first;
    final colors = Theme.of(context).colorScheme;
    final running = !latest.isTerminal;
    final succeeded = latest.lifecycle == DesktopChatTaskLifecycle.succeeded;
    final title = running
        ? 'Agent 正在处理这条对话'
        : succeeded
        ? 'Agent 回复已写入会话'
        : 'Agent 任务未完成';
    final detail = running
        ? '离开当前页面后仍会在桌面端前台同步。'
        : succeeded
        ? '打开此会话后会自动从提醒中移除。'
        : '可打开会话查看状态后重新发起。';
    return Material(
      color: colors.surfaceContainerLow,
      child: InkWell(
        key: const ValueKey<String>('desktop-chat-task-status'),
        onTap: running
            ? () => unawaited(_openRemoteChatThread(threadId))
            : () => unawaited(_openChatTaskReminder(latest.taskKey)),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 14 : 30,
            vertical: compact ? 7 : 9,
          ),
          child: Row(
            children: [
              if (running)
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              else
                Icon(
                  succeeded ? LucideIcons.circleCheck : LucideIcons.circleAlert,
                  size: 15,
                  color: succeeded ? colors.primary : colors.error,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  compact ? title : '$title · $detail',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 14,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatWorkspace(bool sidebarExpanded) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      key: const ValueKey<String>('chat-workspace'),
      color: _translucentSurface(
        context,
        colors.surface,
        lightAlpha: 0.99,
        darkAlpha: 0.985,
      ),
      child: Column(
        children: [
          _buildChatTopBar(showCollapse: false),
          _buildChatTaskStatusStrip(),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: HuahuoDesktopMetrics.chatMaxWidth,
                      ),
                      child: ListView.separated(
                        key: const ValueKey<String>('chat-message-list'),
                        padding: const EdgeInsets.fromLTRB(34, 38, 34, 28),
                        itemCount:
                            _chatMessages.length + (_isChatProcessing ? 1 : 0),
                        separatorBuilder: (_, __) => const SizedBox(height: 26),
                        itemBuilder: (context, index) {
                          if (_isChatProcessing &&
                              index == _chatMessages.length) {
                            return const Padding(
                              padding: EdgeInsets.only(left: 44),
                              child: _ThinkingMessage(),
                            );
                          }
                          final message = _chatMessages[index];
                          final canTransfer =
                              !message.fromUser &&
                              message.text == _latestChatAnswer &&
                              index == _chatMessages.length - 1;
                          return _buildChatMessage(
                            message,
                            canTransfer: canTransfer,
                          );
                        },
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 22),
                  child: Center(child: _buildChatComposer()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatRail() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('fixed-chat-panel'),
      width: HuahuoDesktopMetrics.chatPanel,
      color: _translucentSurface(
        context,
        colors.surfaceContainerLow,
        lightAlpha: 0.985,
        darkAlpha: 0.98,
      ),
      child: Column(
        children: [
          _buildChatTopBar(showCollapse: true),
          _buildChatTaskStatusStrip(compact: true),
          Expanded(
            child: ListView.separated(
              key: const ValueKey<String>('chat-message-list'),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
              itemCount: _chatMessages.length + (_isChatProcessing ? 1 : 0),
              separatorBuilder: (_, __) => const SizedBox(height: 17),
              itemBuilder: (context, index) {
                if (_isChatProcessing && index == _chatMessages.length) {
                  return const _ThinkingMessage();
                }
                final message = _chatMessages[index];
                final canTransfer =
                    !message.fromUser &&
                    message.text == _latestChatAnswer &&
                    index == _chatMessages.length - 1;
                return _buildChatMessage(message, canTransfer: canTransfer);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
            child: _buildChatComposer(),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsedChatRail() {
    final colors = Theme.of(context).colorScheme;
    final activeContextCount = _activeChatContexts.length;
    return Container(
      key: const ValueKey<String>('collapsed-chat-rail'),
      width: HuahuoDesktopMetrics.collapsedChatRail,
      color: _translucentSurface(
        context,
        colors.surfaceContainerLow,
        lightAlpha: 0.97,
        darkAlpha: 0.96,
      ),
      child: Column(
        children: [
          const SizedBox(height: 7),
          Tooltip(
            message: '展开聊天',
            child: IconButton(
              key: const ValueKey<String>('chat-rail-expand'),
              onPressed: () => setState(() => _chatRailCollapsed = false),
              icon: Badge(
                isLabelVisible: activeContextCount > 0,
                smallSize: 6,
                backgroundColor: colors.primary,
                child: const Icon(LucideIcons.messagesSquare, size: 18),
              ),
            ),
          ),
          const Spacer(),
          if (activeContextCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 13),
              child: Text(
                '$activeContextCount',
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChatTopBar({required bool showCollapse}) {
    final colors = Theme.of(context).colorScheme;
    final activeAgentProfileId = _activeChatAgentProfileId;
    final activeAgentLabel = _chatAgentLabel(activeAgentProfileId);
    final agentProfiles = _availableChatAgentProfiles;
    final threadAgentLocked = _activeChatThread?.agentProfileId != null;
    final taskReminders = _chatTaskTracker.tasks;
    final activeTaskCount = taskReminders
        .where((task) => !task.isTerminal)
        .length;
    return SizedBox(
      height: HuahuoDesktopMetrics.topBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              LucideIcons.messagesSquare,
              size: 16,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: 9),
            Text('聊天', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            Tooltip(
              message: threadAgentLocked
                  ? '此历史会话固定使用 $activeAgentLabel'
                  : '选择新会话使用的 Agent',
              child: PopupMenuButton<String>(
                key: const ValueKey<String>('chat-agent-profile-selector'),
                tooltip: '聊天 Agent',
                enabled:
                    !threadAgentLocked &&
                    _workspaceIsReady &&
                    agentProfiles.isNotEmpty,
                onSelected: (agentProfileId) {
                  setState(() {
                    _newChatAgentProfileId =
                        agentProfileId == _defaultChatAgentProfileId
                        ? null
                        : agentProfileId;
                  });
                },
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  for (final profile in agentProfiles)
                    CheckedPopupMenuItem<String>(
                      value: profile.agentProfileId,
                      checked:
                          profile.agentProfileId ==
                          (activeAgentProfileId ?? _defaultChatAgentProfileId),
                      child: Text(
                        profile.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                child: Container(
                  key: const ValueKey<String>('chat-agent-profile-label'),
                  constraints: BoxConstraints(
                    maxWidth: showCollapse ? 70 : 156,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer.withValues(alpha: 0.68),
                    borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
                    border: Border.all(
                      color: colors.outlineVariant.withValues(alpha: 0.62),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        threadAgentLocked
                            ? LucideIcons.lockKeyhole
                            : LucideIcons.bot,
                        size: 12,
                        color: colors.onSecondaryContainer,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          activeAgentLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSecondaryContainer,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!showCollapse &&
                _activeDailyTopicTitle?.trim().isNotEmpty == true) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: '当前会话引用的每日选题',
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 150),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
                  ),
                  child: Text(
                    _activeDailyTopicTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onPrimaryContainer,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
            if (widget.demoMode && widget.chatPort is DesktopDemoChatPort) ...[
              const SizedBox(width: 7),
              const Tooltip(
                message: 'Demo 模式',
                child: Icon(LucideIcons.flaskConical, size: 14),
              ),
            ],
            PopupMenuButton<String>(
              key: const ValueKey<String>('chat-thread-picker'),
              tooltip: '历史对话',
              enabled: _chatThreads.isNotEmpty,
              onSelected: (threadId) =>
                  unawaited(_openRemoteChatThread(threadId)),
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                for (final thread in _chatThreads)
                  PopupMenuItem<String>(
                    value: thread.threadId,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                thread.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                thread.agentProfileId?.trim().isNotEmpty == true
                                    ? _chatAgentLabel(thread.agentProfileId)
                                    : 'Agent 信息待同步',
                                key: ValueKey<String>(
                                  'desktop-chat-history-agent-${thread.threadId}',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (thread.activeRuns.any((run) => !run.isTerminal) ||
                            _chatTaskTracker
                                .tasksForThread(thread.threadId)
                                .any((task) => !task.isTerminal)) ...[
                          const SizedBox(width: 8),
                          const SizedBox.square(
                            dimension: 13,
                            child: CircularProgressIndicator(strokeWidth: 1.6),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
              icon: const Icon(LucideIcons.history, size: 15),
            ),
            PopupMenuButton<String>(
              key: const ValueKey<String>('desktop-chat-task-reminders'),
              tooltip: '聊天任务提醒',
              enabled: taskReminders.isNotEmpty,
              onSelected: (taskKey) =>
                  unawaited(_openChatTaskReminder(taskKey)),
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                for (final task in taskReminders)
                  PopupMenuItem<String>(
                    value: task.taskKey,
                    child: Row(
                      children: [
                        if (!task.isTerminal)
                          const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.7),
                          )
                        else
                          Icon(
                            task.lifecycle == DesktopChatTaskLifecycle.succeeded
                                ? LucideIcons.circleCheck
                                : LucideIcons.circleAlert,
                            size: 15,
                            color:
                                task.lifecycle ==
                                    DesktopChatTaskLifecycle.succeeded
                                ? colors.primary
                                : colors.error,
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            task.isTerminal
                                ? task.lifecycle ==
                                          DesktopChatTaskLifecycle.succeeded
                                      ? '聊天回复已完成'
                                      : '聊天任务未完成'
                                : 'Agent 正在处理聊天',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              icon: Badge(
                isLabelVisible: taskReminders.isNotEmpty,
                label: Text('$activeTaskCount'),
                child: const Icon(LucideIcons.bell, size: 15),
              ),
            ),
            const Spacer(),
            IconButton(
              key: const ValueKey<String>('new-chat'),
              tooltip: '新对话',
              onPressed: _workspaceIsReady ? _startNewChat : null,
              icon: const Icon(LucideIcons.messageSquarePlus, size: 16),
            ),
            if (showCollapse)
              IconButton(
                key: const ValueKey<String>('chat-rail-collapse'),
                tooltip: '折叠聊天',
                onPressed: () => setState(() => _chatRailCollapsed = true),
                icon: const Icon(LucideIcons.panelRightClose, size: 16),
              ),
          ],
        ),
      ),
    );
  }

  static const _defaultChatAgentProfileId = 'self_media_creation_standard';

  static const Map<String, String> _knownChatAgentLabels = <String, String>{
    'book_writing': '写书',
    'positioning_lv1': '基础定位',
    'positioning_lv2': '深度定位',
    'faya_germination': '发芽',
    'huoke_content': '获客营销',
    'self_media_creation_standard': '普通聊一聊',
    'renshe_content': '人设内容',
    'self_media_creation': '自由创作',
    'video_analysis': '视频分析',
    'visual_chat': '视觉设计',
  };

  DesktopChatThread? get _activeChatThread => _chatThreads
      .where((thread) => thread.threadId == _activeChatThreadId)
      .firstOrNull;

  String? get _activeChatAgentProfileId =>
      _activeChatThread?.agentProfileId ?? _newChatAgentProfileId;

  List<AgentProfileCatalogItem> get _availableChatAgentProfiles {
    final catalog = _catalogResult;
    if (catalog != null && catalog.isSuccess && catalog.data != null) {
      return catalog.data!.items;
    }
    return const <AgentProfileCatalogItem>[
      AgentProfileCatalogItem(
        agentProfileId: _defaultChatAgentProfileId,
        displayName: '普通聊一聊',
      ),
    ];
  }

  String _chatAgentLabel(String? agentProfileId) {
    final normalized = agentProfileId?.trim();
    if (normalized == null || normalized.isEmpty) return '普通聊一聊';
    final fromCatalog = _availableChatAgentProfiles
        .where((profile) => profile.agentProfileId == normalized)
        .firstOrNull;
    return fromCatalog?.displayName ??
        _knownChatAgentLabels[normalized] ??
        '普通聊一聊';
  }

  Widget _buildChatMessage(_AiMessage message, {required bool canTransfer}) {
    final colors = Theme.of(context).colorScheme;
    if (message.fromUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 640),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            borderRadius: BorderRadius.circular(HuahuoRadii.panel),
          ),
          child: SelectableText(
            message.text,
            contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
            style: const TextStyle(fontSize: 14, height: 1.65),
          ),
        ),
      );
    }
    final positioningProgress = parseLatestPositioningProgress(message.text);
    final visibleText = positioningProgress == null
        ? message.text
        : stripPositioningProgressBlocks(message.text);
    final source = message.source;
    final attachments =
        source?.imageAttachments ?? const <DesktopChatImageAttachment>[];
    final canCreateAsset = source?.role == 'assistant';
    final creatingAsset =
        source != null && _chatNoteCreationIds.contains(source.messageId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            borderRadius: BorderRadius.circular(HuahuoRadii.control),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(HuahuoRadii.control),
            child: Image.asset(
              'assets/images/chat_brand_mark.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (positioningProgress != null) ...[
                DesktopPositioningDashboard(
                  profile: positioningProgress,
                  compact: true,
                ),
                if (visibleText.trim().isNotEmpty) const SizedBox(height: 12),
              ],
              if (visibleText.trim().isNotEmpty)
                SelectionArea(
                  contextMenuBuilder:
                      HuahuoTextEditing.buildSelectableContextMenu,
                  child: HuahuoMarkdown(
                    source: visibleText,
                    contextMenuBuilder:
                        HuahuoTextEditing.buildEditableContextMenu,
                  ),
                ),
              for (final attachment in attachments) ...[
                if (visibleText.trim().isNotEmpty ||
                    positioningProgress != null)
                  const SizedBox(height: 12),
                _DesktopChatResourceImage(
                  key: ValueKey<String>(
                    'desktop-chat-image-${source?.messageId}-${attachment.resourceId}',
                  ),
                  cache: widget.resourceImageCache,
                  attachment: attachment,
                ),
              ],
              if (canTransfer || canCreateAsset) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (canTransfer)
                      TextButton.icon(
                        key: const ValueKey<String>('chat-to-creation'),
                        onPressed: _moveChatAnswerToCreation,
                        icon: const Icon(LucideIcons.fileOutput, size: 16),
                        label: const Text('转到创作空间'),
                      ),
                    if (canCreateAsset)
                      TextButton.icon(
                        key: ValueKey<String>(
                          'create-chat-note-${source!.messageId}',
                        ),
                        onPressed: creatingAsset
                            ? null
                            : () => unawaited(_createChatNote(message)),
                        icon: creatingAsset
                            ? const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                ),
                              )
                            : const Icon(LucideIcons.notebookPen, size: 16),
                        label: Text(creatingAsset ? '正在创建资产' : '创建资产'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<_ChatContextItem> _availableChatContextCandidates() {
    final candidates = <_ChatContextItem>[];
    final seen = <String>{};
    final activeContextIds = _activeChatContexts.map((item) => item.id).toSet();
    void add(_ChatContextItem item) {
      if (seen.add(item.id)) candidates.add(item);
    }

    void addDocumentStages(HuahuoDocumentSnapshot document) {
      for (final stage in document.availableNoteStages) {
        add(
          _ChatContextItem(
            id: _noteStageTabId(document, stage),
            title: _noteStageContextTitle(document, stage),
            source: '我的创作 · ${_noteStageLabel(stage)}',
            payload: _noteStagePayload(document, stage),
          ),
        );
      }
    }

    if (_activeTabIsDocument) {
      addDocumentStages(_editor.snapshot);
    }
    final selected = _selectedContentContext;
    if (selected != null) add(selected);
    for (final document in _documents) {
      addDocumentStages(document);
    }
    return candidates
        .where((candidate) => !activeContextIds.contains(candidate.id))
        .toList(growable: false);
  }

  IconData _chatContextIcon(_ChatContextItem item) {
    if (item.source.contains('段落')) return LucideIcons.quote;
    if (item.source.contains('大脑')) return LucideIcons.network;
    if (item.source.contains('外部')) return LucideIcons.link;
    if (item.source.contains('资产')) return LucideIcons.folderKanban;
    return LucideIcons.fileText;
  }

  Widget _buildFocusedChatContextTag({
    required _ChatContextItem? item,
    required bool isDocument,
  }) {
    final colors = Theme.of(context).colorScheme;
    final label = isDocument ? '当前文稿' : '当前选区';
    final icon = isDocument ? LucideIcons.fileText : LucideIcons.quote;
    final tagKey = isDocument
        ? const ValueKey<String>('chat-context-focus-document')
        : const ValueKey<String>('chat-context-focus-selection');
    return Tooltip(
      message: item == null ? '$label会随浏览自动更新' : '$label：${item.title}',
      child: Container(
        key: tagKey,
        height: 28,
        constraints: const BoxConstraints(maxWidth: 210),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: item == null
              ? colors.surfaceContainerLow
              : isDocument
              ? colors.primaryContainer.withValues(alpha: 0.52)
              : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
          border: Border.all(
            color: isDocument
                ? colors.primary.withValues(alpha: item == null ? 0.14 : 0.3)
                : colors.outlineVariant.withValues(
                    alpha: item == null ? 0.48 : 0.78,
                  ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: item == null ? colors.outline : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                item?.title ?? label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: item == null ? colors.outline : colors.onSurface,
                  fontSize: 11.5,
                  height: 1,
                ),
              ),
            ),
            if (item != null)
              IconButton(
                key: isDocument
                    ? const ValueKey<String>(
                        'clear-chat-context-focus-document',
                      )
                    : const ValueKey<String>(
                        'clear-chat-context-focus-selection',
                      ),
                tooltip: '清除$label上下文',
                constraints: const BoxConstraints.tightFor(
                  width: 24,
                  height: 24,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    _clearFocusedChatContext(isDocument: isDocument),
                icon: const Icon(LucideIcons.x, size: 13),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatContextTag(_ChatContextItem item) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: '${item.source}：${item.title}',
      child: Container(
        height: 28,
        constraints: const BoxConstraints(maxWidth: 196),
        padding: const EdgeInsets.only(left: 8, right: 2),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _chatContextIcon(item),
              size: 13,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 11.5,
                  height: 1,
                ),
              ),
            ),
            IconButton(
              key: ValueKey<String>('remove-chat-context-${item.id}'),
              tooltip: '移除上下文',
              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              onPressed: () => _removeChatContext(item.id),
              icon: const Icon(LucideIcons.x, size: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatContextStrip() {
    final colors = Theme.of(context).colorScheme;
    final candidates = _availableChatContextCandidates();
    final dynamicContextIds = <String>{
      if (_focusedDocumentContext != null) _focusedDocumentContext!.id,
      if (_focusedSelectionContext != null) _focusedSelectionContext!.id,
    };
    final manualContexts = _chatContexts
        .where((item) => !dynamicContextIds.contains(item.id))
        .toList(growable: false);
    final tags = <Widget>[
      _buildFocusedChatContextTag(
        item: _focusedDocumentContext,
        isDocument: true,
      ),
      if (_focusedSelectionContext != null)
        _buildFocusedChatContextTag(
          item: _focusedSelectionContext,
          isDocument: false,
        ),
      for (final item in manualContexts) _buildChatContextTag(item),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(11, 8, 6, 0),
      child: SizedBox(
        height: 30,
        child: Row(
          children: [
            Expanded(
              child: ListView.separated(
                key: const ValueKey<String>('chat-context-tags'),
                scrollDirection: Axis.horizontal,
                itemCount: tags.length,
                padding: EdgeInsets.zero,
                separatorBuilder: (_, __) => const SizedBox(width: 5),
                itemBuilder: (context, index) => tags[index],
              ),
            ),
            PopupMenuButton<_ChatContextItem>(
              key: const ValueKey<String>('chat-context-add'),
              tooltip: '添加上下文',
              enabled: candidates.isNotEmpty,
              onSelected: (item) => _addChatContext(
                item.title,
                id: item.id,
                source: item.source,
                payload: item.payload,
              ),
              itemBuilder: (context) => [
                for (final item in candidates)
                  PopupMenuItem<_ChatContextItem>(
                    value: item,
                    child: Row(
                      children: [
                        Icon(
                          _chatContextIcon(item),
                          size: 15,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              icon: const Icon(LucideIcons.plus, size: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatComposer() {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: HuahuoDesktopMetrics.chatMaxWidth,
      ),
      child: DesktopGlassSurface(
        borderRadius: const BorderRadius.all(
          Radius.circular(HuahuoRadii.floating),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildChatContextStrip(),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey<String>('chat-input'),
                      contextMenuBuilder:
                          HuahuoTextEditing.buildEditableContextMenu,
                      controller: _chatInput,
                      focusNode: _chatFocus,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.send,
                      enabled: _workspaceIsReady,
                      onSubmitted: (_) => unawaited(_sendPrompt()),
                      decoration: const InputDecoration(
                        hintText: '输入消息，或粘贴一段素材',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    key: const ValueKey<String>('chat-send'),
                    tooltip: '发送',
                    style: _sendButtonStyle(colors),
                    onPressed: _generating || !_workspaceIsReady
                        ? null
                        : () => unawaited(_sendPrompt()),
                    icon: _generating
                        ? SizedBox.square(
                            dimension: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: colors.surface,
                            ),
                          )
                        : const Icon(LucideIcons.arrowUp, size: 17),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(bool _) {
    final colors = Theme.of(context).colorScheme;
    final segmentedView = switch (_documentWorkspaceView) {
      _DocumentWorkspaceView.writing ||
      _DocumentWorkspaceView.outline ||
      _DocumentWorkspaceView.references => _documentWorkspaceView,
      _DocumentWorkspaceView.preview ||
      _DocumentWorkspaceView.annotations => _DocumentWorkspaceView.writing,
    };
    return SizedBox(
      height: HuahuoDesktopMetrics.topBarHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 700;
          final showProjectPath = constraints.maxWidth >= 620;
          final showHistory = constraints.maxWidth >= 560;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (showProjectPath) ...[
                  Text(
                    _activeProject,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      LucideIcons.chevronRight,
                      size: 14,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                Flexible(
                  child: Text(
                    _editor.title.text.trim().isEmpty
                        ? '未命名文稿'
                        : _editor.title.text.trim(),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 12),
                  _SaveIndicator(state: _editor.saveState),
                ],
                const Spacer(),
                _DocumentWorkspaceSwitcher(
                  compact: compact,
                  selected: segmentedView,
                  onChanged: (view) {
                    setState(() => _documentWorkspaceView = view);
                    if (view == _DocumentWorkspaceView.writing &&
                        _activeNoteStageIsEditable) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _bodyFocus.requestFocus();
                      });
                    }
                  },
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey<String>('markdown-preview-toggle'),
                  tooltip:
                      _documentWorkspaceView == _DocumentWorkspaceView.preview
                      ? '返回写作'
                      : '阅读聚焦',
                  onPressed: () => setState(() {
                    _documentWorkspaceView == _DocumentWorkspaceView.preview
                        ? _documentWorkspaceView =
                              _DocumentWorkspaceView.writing
                        : _documentWorkspaceView =
                              _DocumentWorkspaceView.preview;
                  }),
                  icon: Icon(
                    _documentWorkspaceView == _DocumentWorkspaceView.preview
                        ? LucideIcons.filePenLine
                        : LucideIcons.eye,
                    size: 17,
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('ai-annotations-toggle'),
                  tooltip: 'AI 注解',
                  onPressed: () => setState(
                    () => _documentWorkspaceView =
                        _DocumentWorkspaceView.annotations,
                  ),
                  icon: Badge(
                    isLabelVisible: _editor.snapshot.aiAnnotations.isNotEmpty,
                    label: Text('${_editor.snapshot.aiAnnotations.length}'),
                    child: const Icon(LucideIcons.messageSquareText, size: 17),
                  ),
                ),
                if (showHistory) ...[
                  IconButton(
                    tooltip: '撤销',
                    onPressed:
                        _activeNoteStageIsEditable && _editor.body.hasUndo
                        ? _editor.undo
                        : null,
                    icon: const Icon(LucideIcons.undo2),
                  ),
                  IconButton(
                    tooltip: '重做',
                    onPressed:
                        _activeNoteStageIsEditable && _editor.body.hasRedo
                        ? _editor.redo
                        : null,
                    icon: const Icon(LucideIcons.redo2),
                  ),
                ],
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  icon: const Icon(LucideIcons.ellipsis),
                  onSelected: _handleDocumentMenu,
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'copy', child: Text('复制纯文本')),
                    PopupMenuItem(value: 'info', child: Text('文稿信息')),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleDocumentMenu(String value) async {
    final snapshot = _editor.snapshot;
    final stage = _activeNoteStage;
    if (value == 'copy') {
      await HuahuoTextEditing.writePlainText(
        stage == HuahuoNoteStage.raw
            ? _editor.body.document.toPlainText().trimRight()
            : _noteStageMarkdown(snapshot, stage),
      );
      if (mounted) _showSnack('已复制纯文本');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('文稿信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('修订版本 ${snapshot.revision}'),
            const SizedBox(height: 8),
            Text('字符数 ${_noteStagePayload(snapshot, stage).length}'),
            const SizedBox(height: 8),
            Text('最近保存 ${_formatTime(snapshot.modifiedAt.toLocal())}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildMarkdownPreviewWorkspace({
    MarkdownPreviewSurface surface = MarkdownPreviewSurface.reader,
  }) {
    final snapshot = _editor.snapshot;
    final stage = _activeNoteStage;
    return KeyedSubtree(
      key: ValueKey<String>('markdown-preview-workspace-${stage.name}'),
      child: ValueListenableBuilder<MarkdownPreviewPreferences>(
        valueListenable: _markdownPreviewPreferences,
        builder: (context, preferences, _) => MarkdownPreviewPane(
          source: _noteStagePreviewSource(snapshot, stage),
          preferences: preferences,
          mediaResolver: _resolveMarkdownPreviewMedia,
          surface: surface,
        ),
      ),
    );
  }

  Widget _buildDocumentOutlineWorkspace() {
    final colors = Theme.of(context).colorScheme;
    final paragraphs = _editor.body.document
        .toPlainText()
        .split('\n')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .take(6)
        .toList(growable: false);
    final outline = paragraphs.isEmpty
        ? const <String>['开场场景', '核心判断', '论据与结构', '结尾行动']
        : paragraphs;
    return ListView(
      key: const ValueKey<String>('document-outline-workspace'),
      padding: const EdgeInsets.fromLTRB(34, 30, 34, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('文稿大纲', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  '按当前文稿内容整理。点击任一项可以作为下一步写作提示。',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 22),
                for (var index = 0; index < outline.length; index++)
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        setState(
                          () => _documentWorkspaceView =
                              _DocumentWorkspaceView.writing,
                        );
                        _prepareChatPrompt('围绕“${outline[index]}”完善当前文稿：');
                      },
                      borderRadius: BorderRadius.circular(HuahuoRadii.control),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Text(
                              '${index + 1}',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                outline[index],
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            Tooltip(
                              message: '加入聊天上下文',
                              child: IconButton(
                                onPressed: () => _addChatContext(
                                  outline[index],
                                  id: 'outline-${_editor.snapshot.id}-$index',
                                  source: '文稿大纲',
                                  revealChat: true,
                                ),
                                icon: const Icon(LucideIcons.plus, size: 16),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDocumentReferencesWorkspace() {
    final colors = Theme.of(context).colorScheme;
    final references = _activeChatContexts.isNotEmpty
        ? _activeChatContexts
        : _availableChatContextCandidates().take(6).toList(growable: false);
    return ListView(
      key: const ValueKey<String>('document-references-workspace'),
      padding: const EdgeInsets.fromLTRB(34, 30, 34, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('关联素材', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  '在这里查看当前文稿已经关联或可加入聊天的内容。',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 22),
                if (references.isEmpty)
                  Text(
                    '暂无可用素材。可以从思想图谱、我的资产或聊天栏添加。',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  )
                else
                  for (final reference in references)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _openReferenceTab(
                          reference.title,
                          contextId: reference.id,
                          contextSource: reference.source,
                          contextPayload: reference.payload,
                        ),
                        borderRadius: BorderRadius.circular(
                          HuahuoRadii.control,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 11,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _chatContextIcon(reference),
                                size: 16,
                                color: colors.onSurfaceVariant,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      reference.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      reference.source,
                                      style: TextStyle(
                                        color: colors.onSurfaceVariant,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Tooltip(
                                message: '加入聊天上下文',
                                child: IconButton(
                                  onPressed: () => _addChatContext(
                                    reference.title,
                                    id: reference.id,
                                    source: reference.source,
                                    payload: reference.payload,
                                    revealChat: true,
                                  ),
                                  icon: const Icon(LucideIcons.plus, size: 16),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDocumentAnnotationsWorkspace() {
    final colors = Theme.of(context).colorScheme;
    final stage = _activeNoteStage;
    final annotations = _editor.snapshot.annotationsForStage(stage);
    return ListView(
      key: const ValueKey<String>('ai-annotations-workspace'),
      padding: const EdgeInsets.fromLTRB(34, 30, 34, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'AI 注解',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _noteStageLabel(stage),
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 13.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (stage == HuahuoNoteStage.raw)
                      FilledButton.tonalIcon(
                        key: const ValueKey<String>('generate-sprout-insight'),
                        onPressed:
                            _sproutFeatureResult?.isSuccess == true &&
                                !_sproutGenerating
                            ? () => unawaited(_generateSproutInsight())
                            : null,
                        icon: _sproutGenerating
                            ? const SizedBox.square(
                                dimension: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.7,
                                ),
                              )
                            : const Icon(LucideIcons.lightbulb, size: 16),
                        label: Text(_sproutGenerating ? '生成中' : '生成洞见'),
                      ),
                  ],
                ),
                if (stage == HuahuoNoteStage.raw &&
                    _sproutFeatureResult?.isSuccess != true) ...[
                  const SizedBox(height: 10),
                  Text(
                    _sproutFeatureResult?.message ??
                        (_accountSignedIn ? '正在校验 AI 能力' : '登录后可使用 AI 能力'),
                    key: const ValueKey<String>('sprout-feature-status'),
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12.5,
                    ),
                  ),
                ],
                const SizedBox(height: 26),
                if (annotations.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      stage == HuahuoNoteStage.raw ? '暂无注解' : '这个版本暂无注解',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                  )
                else
                  for (final annotation in annotations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Material(
                        color: colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(
                          HuahuoRadii.control,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(15, 14, 8, 13),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 2,
                                height: 42,
                                margin: const EdgeInsets.only(top: 2),
                                color: colors.primary,
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      annotation.quote,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: colors.onSurfaceVariant,
                                        fontSize: 12.5,
                                        height: 1.55,
                                      ),
                                    ),
                                    const SizedBox(height: 9),
                                    SelectableText(
                                      annotation.body,
                                      contextMenuBuilder: HuahuoTextEditing
                                          .buildEditableContextMenu,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1.65,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Tooltip(
                                message: '移除注解',
                                child: IconButton(
                                  key: ValueKey<String>(
                                    'remove-ai-annotation-${annotation.id}',
                                  ),
                                  onPressed: () => unawaited(
                                    _removeAiAnnotation(annotation.id),
                                  ),
                                  icon: const Icon(LucideIcons.x, size: 16),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDocumentEditor() {
    if (!_activeNoteStageIsEditable) {
      return _buildDerivedNoteStageWorkspace();
    }
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: HuahuoDesktopMetrics.editorMaxWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(34, 30, 34, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey<String>('editor-title'),
                contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
                controller: _editor.title,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _bodyFocus.requestFocus(),
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: '未命名文稿',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 13),
              Row(
                children: [
                  Expanded(
                    child: HuahuoRichTextFormattingToolbar(
                      controller: _editor,
                      focusNode: _bodyFocus,
                      imageEmbeddingEnabled: true,
                      onResolveImage: _resolveEditorImage,
                      onAction: (action) {
                        if (action == HuahuoEditorToolbarAction.image) {
                          _showSnack('图片已插入。本地图片可直接预览，远程图片可在写作设置开启。');
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_editor.body.document.toPlainText().trim().length} 字',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Expanded(
                child: QuillEditor(
                  key: const ValueKey<String>('editor-body'),
                  controller: _editor.body,
                  focusNode: _bodyFocus,
                  scrollController: _bodyScroll,
                  config: QuillEditorConfig(
                    expands: true,
                    scrollable: true,
                    contextMenuBuilder: _buildDesktopQuillContextMenu,
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 44),
                    placeholder: '从一个想法开始',
                    onTapOutsideEnabled: true,
                    customStyles: _quillStyles(colors),
                    embedBuilders: <EmbedBuilder>[
                      _EditorImageEmbedBuilder(
                        mediaStore: _documentMediaStore,
                        documentId: _editor.snapshot.id,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _resolveEditorImage(BuildContext context) async {
    final source = await showDialog<_EditorImageSource>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('插入图片'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('本地图片会安全保存到这篇文稿的私有媒体中。'),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(_EditorImageSource.localFile),
                icon: const Icon(LucideIcons.folderOpen, size: 17),
                label: const Text('选择本地图片'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(_EditorImageSource.remoteUrl),
                icon: const Icon(LucideIcons.link, size: 17),
                label: const Text('粘贴图片链接'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || source == null) return null;
    return switch (source) {
      _EditorImageSource.localFile => _importLocalEditorImage(),
      _EditorImageSource.remoteUrl => _resolveRemoteEditorImage(),
    };
  }

  Future<String?> _importLocalEditorImage() async {
    final selected = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_editorImageFileTypes],
    );
    if (!mounted || selected == null) return null;
    if (selected.path.trim().isEmpty) {
      _showSnack('无法读取所选图片');
      return null;
    }
    try {
      final asset = await _documentMediaStore.importFile(
        documentId: _editor.snapshot.id,
        source: File(selected.path),
      );
      return asset.uri.toString();
    } on LocalDocumentMediaException catch (error) {
      if (mounted) _showSnack(error.message);
      return null;
    } on Object {
      if (mounted) _showSnack('导入图片失败，请换一张图片重试');
      return null;
    }
  }

  Future<String?> _resolveRemoteEditorImage() async {
    final sourceController = TextEditingController();
    try {
      final source = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('插入图片'),
          content: SizedBox(
            width: 380,
            child: TextField(
              controller: sourceController,
              contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '图片地址',
                hintText: 'https://example.com/image.jpg',
                helperText: '仅支持 HTTPS 图片地址。',
              ),
              onSubmitted: (value) =>
                  Navigator.of(dialogContext).pop(value.trim()),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(sourceController.text.trim()),
              child: const Text('插入'),
            ),
          ],
        ),
      );
      final normalized = source?.trim();
      if (normalized == null || normalized.isEmpty) return null;
      final uri = Uri.tryParse(normalized);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        if (mounted) _showSnack('仅支持 HTTPS 图片地址');
        return null;
      }
      return normalized;
    } finally {
      sourceController.dispose();
    }
  }

  Future<MarkdownPreviewMedia?> _resolveMarkdownPreviewMedia(Uri uri) async {
    final data = await _documentMediaStore.read(
      documentId: _editor.snapshot.id,
      uri: uri,
    );
    if (data == null) return null;
    return MarkdownPreviewMedia(
      bytes: data.bytes,
      mimeType: data.asset.mimeType,
    );
  }

  Widget _buildDerivedNoteStageWorkspace() {
    final snapshot = _editor.snapshot;
    final stage = _activeNoteStage;
    return KeyedSubtree(
      key: ValueKey<String>('note-stage-reader-${stage.name}'),
      child: ValueListenableBuilder<MarkdownPreviewPreferences>(
        valueListenable: _markdownPreviewPreferences,
        builder: (context, preferences, _) => MarkdownPreviewPane(
          source: _noteStagePreviewSource(snapshot, stage),
          preferences: preferences,
          mediaResolver: _resolveMarkdownPreviewMedia,
        ),
      ),
    );
  }

  DefaultStyles _quillStyles(ColorScheme colors) {
    const horizontal = HorizontalSpacing.zero;
    const lineSpacing = VerticalSpacing.zero;
    DefaultTextBlockStyle block(
      double size,
      FontWeight weight, {
      double top = 4,
      double bottom = 4,
      double height = 1.7,
      Color? color,
    }) {
      return DefaultTextBlockStyle(
        TextStyle(
          color: color ?? colors.onSurface,
          fontSize: size,
          height: height,
          fontWeight: weight,
          fontFamily: HuahuoTypography.primaryFamily,
          fontFamilyFallback: HuahuoTypography.fallbacks,
          letterSpacing: 0,
        ),
        horizontal,
        VerticalSpacing(top, bottom),
        lineSpacing,
        null,
      );
    }

    return DefaultStyles(
      paragraph: block(
        16 * _editorScale,
        FontWeight.w400,
        top: 2,
        bottom: 3,
        height: _editorLineHeight,
      ),
      h1: block(
        27 * _editorScale,
        FontWeight.w600,
        top: 14,
        bottom: 6,
        height: 1.35,
      ),
      h2: block(
        22 * _editorScale,
        FontWeight.w600,
        top: 12,
        bottom: 5,
        height: 1.42,
      ),
      h3: block(
        18 * _editorScale,
        FontWeight.w600,
        top: 10,
        bottom: 4,
        height: 1.5,
      ),
      bold: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0),
      link: TextStyle(color: colors.primary, letterSpacing: 0),
      placeHolder: block(
        16 * _editorScale,
        FontWeight.w400,
        top: 2,
        bottom: 3,
        height: _editorLineHeight,
        color: colors.onSurfaceVariant.withValues(alpha: 0.58),
      ),
      color: colors.onSurface,
    );
  }

  Widget _buildContextPanel() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('context-panel'),
      width: HuahuoDesktopMetrics.contextPanel,
      decoration: BoxDecoration(
        color: _translucentSurface(
          context,
          colors.surfaceContainerLow,
          lightAlpha: 0.985,
          darkAlpha: 0.98,
        ),
      ),
      child: Column(
        children: [
          SizedBox(
            height: HuahuoDesktopMetrics.topBarHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Row(
                children: [
                  Icon(_contextIcon, size: 16, color: colors.onSurfaceVariant),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      _contextTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭面板',
                    onPressed: () => setState(() => _contextPanelOpen = false),
                    icon: const Icon(LucideIcons.x),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                if (_selectedContentTitle != null)
                  _buildSelectedContentContext(_selectedContentTitle!),
                Expanded(
                  child: switch (_contextKind) {
                    _ContextKind.outline => _buildOutlinePanel(),
                    _ContextKind.knowledge => _buildKnowledgePanel(),
                    _ContextKind.projects => _buildProjectsPanel(),
                    _ContextKind.relations => _buildRelationsPanel(),
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _contextTitle {
    if (_contextKind == _ContextKind.outline) return '我的内容大纲';
    if (_selectedContentTitle != null) return '内容上下文';
    return switch (_contextKind) {
      _ContextKind.outline => '我的内容大纲',
      _ContextKind.knowledge => '知识库',
      _ContextKind.projects => '项目',
      _ContextKind.relations => '关系索引',
    };
  }

  IconData get _contextIcon => switch (_contextKind) {
    _ContextKind.outline => LucideIcons.listTree,
    _ContextKind.knowledge => LucideIcons.library,
    _ContextKind.projects => LucideIcons.folderKanban,
    _ContextKind.relations => LucideIcons.network,
  };

  Widget _buildSelectedContentContext(String title) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(HuahuoRadii.control),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 9, 6, 8),
          child: Row(
            children: [
              Icon(
                LucideIcons.fileText,
                size: 15,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              IconButton(
                tooltip: '加入聊天上下文',
                onPressed: () {
                  final selected = _selectedContentContext;
                  if (selected == null) return;
                  _addChatContext(
                    selected.title,
                    id: selected.id,
                    source: selected.source,
                    payload: selected.payload,
                    revealChat: true,
                  );
                },
                icon: const Icon(LucideIcons.plus, size: 15),
              ),
              IconButton(
                tooltip: '打开内容',
                onPressed: () => _openReferenceTab(title),
                icon: const Icon(LucideIcons.arrowUpRight, size: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOutlinePanel() {
    final colors = Theme.of(context).colorScheme;
    final title = _editor.title.text.trim().isEmpty
        ? '未命名文稿'
        : _editor.title.text.trim();
    const outline = <(String, String)>[
      ('表达对象', '明确要和谁说话'),
      ('核心判断', '先写出这篇内容的结论'),
      ('真实场景', '用一段经历或原话进入'),
      ('论据与结构', '组织材料、冲突和方法'),
      ('结尾行动', '留下可以执行的一步'),
    ];
    return ListView.separated(
      key: const ValueKey<String>('content-outline-panel'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
      itemCount: outline.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 3),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12.5),
            ),
          );
        }
        final item = outline[index - 1];
        return _ContextRow(
          icon: LucideIcons.list,
          title: item.$1,
          detail: item.$2,
          onTap: () {
            _prepareChatPrompt('围绕“${item.$1}”完善当前大纲：');
            _showSnack('已在聊天栏准备提示');
          },
        );
      },
    );
  }

  Widget _buildKnowledgePanel() {
    const items = <(String, String)>[
      ('城市观察笔记', '12 条摘录'),
      ('用户访谈素材', '8 份记录'),
      ('品牌表达手册', '5 个章节'),
      ('产品发布资料', '17 个文件'),
    ];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const TextField(
          contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
          decoration: InputDecoration(
            hintText: '搜索知识',
            prefixIcon: Icon(LucideIcons.search, size: 16),
          ),
        ),
        const SizedBox(height: 14),
        for (final item in items)
          _ContextRow(
            icon: LucideIcons.fileText,
            title: item.$1,
            detail: item.$2,
            onTap: () {
              setState(() {
                _setSelectedContentInState(
                  title: item.$1,
                  id: 'knowledge-${item.$1.toLowerCase()}',
                  source: '知识库',
                );
              });
              _addChatContext(
                item.$1,
                id: 'knowledge-${item.$1.toLowerCase()}',
                source: '知识库',
              );
            },
          ),
      ],
    );
  }

  Widget _buildProjectsPanel() {
    const projects = <String>['个人创作', '花火桌面端', '七月内容计划', '访谈专题'];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final project in projects)
          _ContextRow(
            icon: LucideIcons.folder,
            title: project,
            detail: project == _activeProject ? '当前项目' : '切换到此项目',
            selected: project == _activeProject,
            onTap: () {
              setState(() => _activeProject = project);
              _showSnack('已切换到 $project');
            },
          ),
      ],
    );
  }

  Widget _buildRelationsPanel() {
    if (_noteRelationsLoading) {
      return const Center(
        child: SizedBox.square(
          key: ValueKey<String>('note-relations-loading'),
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final result = _noteRelationsResult;
    if (result == null || !result.isSuccess || result.data == null) {
      final message = result?.message ?? '正在准备当前文稿关系';
      return ListView(
        key: const ValueKey<String>('note-relations-unavailable'),
        padding: const EdgeInsets.all(12),
        children: [
          Text(message, style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey<String>('note-relations-retry'),
              onPressed: _loadActiveNoteRelations,
              icon: const Icon(LucideIcons.refreshCw, size: 14),
              label: const Text('刷新'),
            ),
          ),
        ],
      );
    }
    final relations = result.data!.items;
    return ListView(
      key: const ValueKey<String>('note-relations-list'),
      padding: const EdgeInsets.all(12),
      children: [
        if (relations.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('当前笔记还没有关系', style: TextStyle(fontSize: 12.5)),
          ),
        for (final relation in relations)
          Material(
            color: Colors.transparent,
            child: ListTile(
              key: ValueKey<String>('note-relation-${relation.relationId}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(LucideIcons.waypoints, size: 16),
              title: Text(
                '${_noteRelationTypeLabel(relation.relationType)} · ${relation.target.noteId}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
              subtitle: Text(
                relation is SharedExplicitNoteRelation
                    ? '${relation.rationale} · ${relation.target.part} 精确版本'
                    : '自动相似 · ${relation.target.part} 精确版本',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5),
              ),
              trailing: relation is SharedExplicitNoteRelation
                  ? _noteRelationMutations.contains(relation.relationId)
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        : IconButton(
                            key: ValueKey<String>(
                              'note-relation-delete-${relation.relationId}',
                            ),
                            tooltip: '删除显式关系',
                            onPressed: () =>
                                unawaited(_deleteNoteRelation(relation)),
                            icon: const Icon(LucideIcons.trash2, size: 14),
                          )
                  : const Tooltip(
                      message: '自动相似关系只读',
                      child: Icon(LucideIcons.lockKeyhole, size: 14),
                    ),
              onTap: () => unawaited(_openNoteRelationTarget(relation)),
            ),
          ),
      ],
    );
  }
}

final class _ActivityButton extends StatelessWidget {
  const _ActivityButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: SizedBox(
        width: HuahuoDesktopMetrics.activityBar,
        height: 46,
        child: Material(
          color: selected ? colors.surfaceContainer : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              children: [
                if (selected)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 2,
                      height: 24,
                      color: colors.primary,
                    ),
                  ),
                Center(
                  child: Icon(
                    icon,
                    size: 19,
                    color: selected
                        ? colors.onSurface
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _WorkspaceTabButton extends StatelessWidget {
  const _WorkspaceTabButton({
    required this.title,
    required this.icon,
    required this.selected,
    required this.closeable,
    required this.onTap,
    required this.onClose,
    super.key,
  });

  final String title;
  final IconData icon;
  final bool selected;
  final bool closeable;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.surfaceContainerHighest : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 112, maxWidth: 220),
          padding: EdgeInsets.only(left: 11, right: closeable ? 4 : 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? colors.onSurface : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? colors.onSurface
                        : colors.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
              if (closeable) ...[
                const SizedBox(width: 5),
                Tooltip(
                  message: '关闭标签页',
                  child: InkWell(
                    key: ValueKey<String>('close-tab-$title'),
                    onTap: onClose,
                    borderRadius: BorderRadius.circular(4),
                    child: const SizedBox.square(
                      dimension: 22,
                      child: Icon(LucideIcons.x, size: 13),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _FeatureIndexRow extends StatelessWidget {
  const _FeatureIndexRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 82,
          child: Row(
            children: [
              SizedBox.square(
                dimension: 34,
                child: Icon(icon, size: 18, color: colors.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 15,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ExternalKnowledgeTab extends StatelessWidget {
  const _ExternalKnowledgeTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: 15,
                        color: selected
                            ? colors.onSurface
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: TextStyle(
                          color: selected
                              ? colors.onSurface
                              : colors.onSurfaceVariant,
                          fontSize: 12.5,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedContainer(
                  duration: DesktopMotionTokens.standard,
                  height: 2,
                  width: selected ? 34 : 0,
                  color: selected ? colors.primary : Colors.transparent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _KnowledgeSquareDiscoveryBanner extends StatelessWidget {
  const _KnowledgeSquareDiscoveryBanner({
    required this.item,
    required this.onOpen,
  });

  final _ExternalKnowledgeItem? item;
  final ValueChanged<_ExternalKnowledgeItem> onOpen;

  static const _asset = 'assets/images/knowledge_square_banner.png';

  @override
  Widget build(BuildContext context) {
    final banner = Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey<String>('knowledge-square-featured'),
        onTap: item == null ? null : () => onOpen(item!),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              _asset,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => ColoredBox(
                color: const Color(0xFF7E8998),
                child: Center(
                  child: Icon(
                    LucideIcons.bookOpenText,
                    size: 34,
                    color: Colors.white.withValues(alpha: 0.78),
                  ),
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0x99000000)],
                  stops: [0.46, 1],
                ),
              ),
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: 18,
              child: Text(
                item?.title ?? '发现值得订阅的知识',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 5)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return ClipRRect(
      key: const ValueKey<String>('knowledge-square-banner'),
      borderRadius: BorderRadius.circular(HuahuoRadii.control),
      child: AspectRatio(aspectRatio: 647 / 305, child: banner),
    );
  }
}

final class _KnowledgeSquareTopicGrid extends StatelessWidget {
  const _KnowledgeSquareTopicGrid({
    required this.selected,
    required this.onSelected,
  });

  final _KnowledgeSquareCategory selected;
  final ValueChanged<_KnowledgeSquareCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    const categories = _KnowledgeSquareCategory.values;
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        key: const ValueKey<String>('knowledge-square-categories'),
        shrinkWrap: true,
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: categories.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          mainAxisSpacing: 10,
          crossAxisSpacing: 6,
          childAspectRatio: constraints.maxWidth >= 480 ? 1.65 : .82,
        ),
        itemBuilder: (context, index) {
          final category = categories[index];
          return _KnowledgeSquareCategoryTile(
            category: category,
            selected: category == selected,
            onTap: () => onSelected(category),
          );
        },
      ),
    );
  }
}

final class _KnowledgeSquareCategoryTile extends StatelessWidget {
  const _KnowledgeSquareCategoryTile({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final _KnowledgeSquareCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected ? colors.primary : colors.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: '${category.label}主题',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('knowledge-square-category-${category.name}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: DesktopMotionTokens.standard,
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? colors.primary.withValues(alpha: 0.12)
                      : colors.surfaceContainer,
                  border: Border.all(
                    color: selected
                        ? colors.primary.withValues(alpha: 0.42)
                        : colors.outlineVariant,
                  ),
                ),
                child: Icon(category.icon, size: 20, color: foreground),
              ),
              const SizedBox(height: 5),
              Text(
                category.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _KnowledgeSquareUpdateCard extends StatelessWidget {
  const _KnowledgeSquareUpdateCard({
    required this.item,
    required this.category,
    required this.isDeposited,
    required this.onOpen,
    required this.onAddToContext,
    required this.onSubscription,
    required this.onAction,
  });

  final _ExternalKnowledgeItem item;
  final _KnowledgeSquareCategory category;
  final bool isDeposited;
  final VoidCallback onOpen;
  final VoidCallback onAddToContext;
  final VoidCallback onSubscription;
  final ValueChanged<_KnowledgeSquareAction> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final thumbnail = ClipRRect(
      borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
      child: SizedBox(
        width: 70,
        height: 70,
        child: ColoredBox(
          color: colors.surfaceContainer,
          child: Icon(category.icon, size: 24, color: colors.onSurfaceVariant),
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            thumbnail,
            const SizedBox(width: 11),
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onOpen,
                  borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${item.sourceLabel} · ${item.updatedLabel} 更新',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.26,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.subscriberCount > 0
                              ? '${item.author} · ${item.subscriberCount} 人在用'
                              : item.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 96,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox(
                    height: 32,
                    child: TextButton(
                      key: ValueKey<String>(
                        'knowledge-square-subscribe-${item.id}',
                      ),
                      onPressed: onSubscription,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(56, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(item.subscribed ? '已订阅' : '+ 订阅'),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: '加入聊天上下文',
                        child: IconButton(
                          key: ValueKey<String>(
                            'knowledge-square-context-${item.id}',
                          ),
                          constraints: const BoxConstraints.tightFor(
                            width: 34,
                            height: 34,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: onAddToContext,
                          icon: const Icon(LucideIcons.plus, size: 16),
                        ),
                      ),
                      PopupMenuButton<_KnowledgeSquareAction>(
                        key: ValueKey<String>(
                          'knowledge-square-actions-${item.id}',
                        ),
                        tooltip: '内容操作 ${item.title}',
                        constraints: const BoxConstraints.tightFor(
                          width: 34,
                          height: 34,
                        ),
                        padding: EdgeInsets.zero,
                        onSelected: onAction,
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: _KnowledgeSquareAction.open,
                            child: Text('查看详情'),
                          ),
                          const PopupMenuItem(
                            value: _KnowledgeSquareAction.share,
                            child: Text('分享'),
                          ),
                          const PopupMenuItem(
                            value: _KnowledgeSquareAction.copyToEdit,
                            child: Text('复制并编辑'),
                          ),
                          const PopupMenuItem(
                            value: _KnowledgeSquareAction.export,
                            child: Text('导出'),
                          ),
                          PopupMenuItem(
                            value: _KnowledgeSquareAction.deposit,
                            enabled: item.subscribed && !isDeposited,
                            child: Text(
                              isDeposited
                                  ? '已收录到我的资产'
                                  : item.subscribed
                                  ? '收录到我的资产'
                                  : '订阅后可收录',
                            ),
                          ),
                        ],
                        icon: const Icon(LucideIcons.ellipsis, size: 16),
                      ),
                    ],
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

final class _AccountActionRow extends StatelessWidget {
  const _AccountActionRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 28,
                child: Icon(icon, size: 17, color: colors.onSurfaceVariant),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 13.5)),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SettingsNavigationRow extends StatelessWidget {
  const _SettingsNavigationRow({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? colors.surfaceContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
          child: SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: selected
                            ? colors.onSurface
                            : colors.onSurfaceVariant,
                        fontSize: 12.5,
                        fontWeight: selected
                            ? FontWeight.w500
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _SettingsSliderRow extends StatelessWidget {
  const _SettingsSliderRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                valueLabel,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

final class _PaletteOption extends StatelessWidget {
  const _PaletteOption({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final DesktopAccentPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = switch (palette) {
      DesktopAccentPalette.graphite => '石墨灰',
      DesktopAccentPalette.ocean => '雾蓝',
      DesktopAccentPalette.forest => '松绿',
      DesktopAccentPalette.warmGold => '暖金',
      DesktopAccentPalette.rose => '绯樱',
      DesktopAccentPalette.aurora => '极光',
    };
    final accent = palette.primaryFor(Theme.of(context).brightness);
    return Material(
      color: selected ? colors.surfaceContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(HuahuoRadii.control),
      child: InkWell(
        key: ValueKey<String>('settings-palette-${palette.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(HuahuoRadii.control),
        child: SizedBox(
          width: 108,
          height: 70,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 18,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                const Spacer(),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: selected
                        ? colors.onSurface
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keys, required this.label});

  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              keys,
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 11,
                fontFamily: 'Consolas',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _NoteDocumentTree extends StatelessWidget {
  const _NoteDocumentTree({
    required this.document,
    required this.activeStage,
    required this.onOpenStage,
    required this.onAddStageToContext,
    required this.stageLabel,
    required this.stageIcon,
  });

  final HuahuoDocumentSnapshot document;
  final HuahuoNoteStage? activeStage;
  final ValueChanged<HuahuoNoteStage> onOpenStage;
  final ValueChanged<HuahuoNoteStage> onAddStageToContext;
  final String Function(HuahuoNoteStage stage) stageLabel;
  final IconData Function(HuahuoNoteStage stage) stageIcon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = document.title.trim().isEmpty ? '未命名文稿' : document.title;
    final derivedStages = document.availableNoteStages
        .where((stage) => stage != HuahuoNoteStage.raw)
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      child: Column(
        children: [
          Material(
            color: activeStage == HuahuoNoteStage.raw
                ? colors.surfaceContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    key: ValueKey<String>('note-document-${document.id}'),
                    onTap: () => onOpenStage(HuahuoNoteStage.raw),
                    borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.fileText,
                            size: 15,
                            color: activeStage == HuahuoNoteStage.raw
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: activeStage == HuahuoNoteStage.raw
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: '将原始内容加入聊天上下文',
                  child: IconButton(
                    key: ValueKey<String>('add-note-context-${document.id}'),
                    constraints: const BoxConstraints.tightFor(
                      width: 29,
                      height: 32,
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onAddStageToContext(HuahuoNoteStage.raw),
                    icon: Icon(
                      LucideIcons.plus,
                      size: 15,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (derivedStages.isNotEmpty)
            Padding(
              key: ValueKey<String>('note-version-switcher-${document.id}'),
              padding: const EdgeInsets.fromLTRB(8, 2, 7, 5),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 5,
                runSpacing: 4,
                children: [
                  Text(
                    '版本',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  for (final stage in derivedStages)
                    Material(
                      color: activeStage == stage
                          ? colors.surfaceContainerHigh
                          : colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(HuahuoRadii.control),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            key: ValueKey<String>(
                              'note-stage-${document.id}-${stage.name}',
                            ),
                            onTap: () => onOpenStage(stage),
                            borderRadius: BorderRadius.circular(
                              HuahuoRadii.control,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: 7,
                                top: 5,
                                bottom: 5,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    stageIcon(stage),
                                    size: 13,
                                    color: activeStage == stage
                                        ? colors.primary
                                        : colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    stageLabel(stage),
                                    style: TextStyle(
                                      color: activeStage == stage
                                          ? colors.onSurface
                                          : colors.onSurfaceVariant,
                                      fontSize: 11,
                                      fontWeight: activeStage == stage
                                          ? FontWeight.w500
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Tooltip(
                            message: '加入聊天上下文',
                            child: IconButton(
                              key: ValueKey<String>(
                                'add-note-stage-context-${document.id}-${stage.name}',
                              ),
                              constraints: const BoxConstraints.tightFor(
                                width: 25,
                                height: 27,
                              ),
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => onAddStageToContext(stage),
                              icon: Icon(
                                LucideIcons.plus,
                                size: 13,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

final class _SaveIndicator extends StatelessWidget {
  const _SaveIndicator({required this.state});

  final HuahuoSaveState state;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (state) {
      HuahuoSaveState.saved => (
        '已保存',
        HuahuoColors.success,
        LucideIcons.cloudCheck,
      ),
      HuahuoSaveState.dirty => (
        '待保存',
        colors.onSurfaceVariant,
        LucideIcons.cloudUpload,
      ),
      HuahuoSaveState.saving => (
        '保存中',
        colors.onSurfaceVariant,
        LucideIcons.loaderCircle,
      ),
      HuahuoSaveState.failed => (
        '保存失败',
        HuahuoColors.danger,
        LucideIcons.cloudAlert,
      ),
    };
    return Semantics(
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: color, fontSize: 11.5)),
        ],
      ),
    );
  }
}

final class _DocumentWorkspaceSwitcher extends StatelessWidget {
  const _DocumentWorkspaceSwitcher({
    required this.compact,
    required this.selected,
    required this.onChanged,
  });

  final bool compact;
  final _DocumentWorkspaceView selected;
  final ValueChanged<_DocumentWorkspaceView> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final items = <(_DocumentWorkspaceView, IconData, String)>[
      (_DocumentWorkspaceView.writing, LucideIcons.penLine, '写作'),
      (_DocumentWorkspaceView.outline, LucideIcons.listTree, '大纲'),
      (_DocumentWorkspaceView.references, LucideIcons.library, '素材'),
    ];
    return SizedBox(
      key: const ValueKey<String>('document-workspace-tabs'),
      width: compact ? 138 : 276,
      height: 36,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            for (final item in items)
              Expanded(
                child: _DocumentWorkspaceSwitchItem(
                  view: item.$1,
                  icon: item.$2,
                  label: item.$3,
                  selected: selected == item.$1,
                  compact: compact,
                  onTap: () => onChanged(item.$1),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _DocumentWorkspaceSwitchItem extends StatelessWidget {
  const _DocumentWorkspaceSwitchItem({
    required this.view,
    required this.icon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final _DocumentWorkspaceView view;
  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected ? colors.primary : colors.onSurfaceVariant;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Material(
          color: selected ? colors.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            key: ValueKey<String>('document-workspace-tab-${view.name}'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Center(
              child: compact
                  ? Icon(icon, size: 16, color: foreground)
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 15, color: foreground),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: foreground,
                              fontSize: 12.5,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _EditorImageEmbedBuilder extends EmbedBuilder {
  const _EditorImageEmbedBuilder({
    required this.mediaStore,
    required this.documentId,
  });

  final DocumentMediaStore mediaStore;
  final String documentId;

  @override
  String get key => BlockEmbed.imageType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final source = embedContext.node.value.data?.toString() ?? '';
    final localUri = DocumentMediaUri.parse(source);
    if (localUri != null) {
      return _LocalEditorImage(
        mediaStore: mediaStore,
        documentId: documentId,
        uri: localUri,
      );
    }
    final uri = Uri.tryParse(source);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return const _EditorImagePlaceholder(message: '图片地址不可用');
    }
    return _EditorImageFrame(
      childBuilder: (width) => Image.network(
        source,
        width: width,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return const _EditorImagePlaceholder(message: '正在加载图片');
        },
        errorBuilder: (_, __, ___) =>
            const _EditorImagePlaceholder(message: '图片无法加载'),
      ),
    );
  }
}

final class _LocalEditorImage extends StatelessWidget {
  const _LocalEditorImage({
    required this.mediaStore,
    required this.documentId,
    required this.uri,
  });

  final DocumentMediaStore mediaStore;
  final String documentId;
  final Uri uri;

  @override
  Widget build(BuildContext context) => FutureBuilder<LocalDocumentMediaData?>(
    future: mediaStore.read(documentId: documentId, uri: uri),
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const _EditorImagePlaceholder(message: '正在加载图片');
      }
      final media = snapshot.data;
      if (snapshot.hasError || media == null) {
        return const _EditorImagePlaceholder(message: '本地图片不可用');
      }
      return _EditorImageFrame(
        childBuilder: (width) => Image.memory(
          media.bytes,
          width: width,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              const _EditorImagePlaceholder(message: '图片无法加载'),
        ),
      );
    },
  );
}

final class _EditorImageFrame extends StatelessWidget {
  const _EditorImageFrame({required this.childBuilder});

  final Widget Function(double width) childBuilder;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 680.0;
        final width = availableWidth > 680 ? 680.0 : availableWidth;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: childBuilder(width),
          ),
        );
      },
    ),
  );
}

final class _EditorImagePlaceholder extends StatelessWidget {
  const _EditorImagePlaceholder({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 360,
      height: 120,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.imageOff, size: 16, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            message,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

final class _ContextRow extends StatelessWidget {
  const _ContextRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.surfaceContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 15,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ThinkingMessage extends StatelessWidget {
  const _ThinkingMessage();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
        const SizedBox(width: 8),
        Text(
          '正在整理',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12.5,
          ),
        ),
      ],
    );
  }
}

ButtonStyle _sendButtonStyle(ColorScheme colors) {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size.square(34)),
    maximumSize: const WidgetStatePropertyAll(Size.square(34)),
    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    shape: const WidgetStatePropertyAll(CircleBorder()),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return colors.onSurface.withValues(alpha: 0.28);
      }
      return colors.onSurface;
    }),
    foregroundColor: WidgetStatePropertyAll(colors.surface),
    iconColor: WidgetStatePropertyAll(colors.surface),
    overlayColor: WidgetStatePropertyAll(colors.surface.withValues(alpha: 0.1)),
  );
}

Color _translucentSurface(
  BuildContext context,
  Color color, {
  required double lightAlpha,
  required double darkAlpha,
}) {
  if (MediaQuery.highContrastOf(context)) return color;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return color.withValues(alpha: dark ? darkAlpha : lightAlpha);
}

String _formatTime(DateTime value) {
  String twoDigits(int input) => input.toString().padLeft(2, '0');
  return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
}
