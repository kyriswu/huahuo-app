import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../chat/domain/chat_models.dart';
import '../application/knowledge_library_controller.dart';
import '../application/knowledge_note_port.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';
import '../domain/ui_v3_models.dart';
import 'note/note_detail_surface.dart' show NoteDetailCreationDock;
import 'v3_note_chat.dart'
    show
        showV3NoteChatSheet,
        showV3NoteAgentCreationFlow,
        v3AgentAssistedCreationRoute;

/// Graph-free workbench body mounted by the shared home shell.
class V3WorkbenchHomeSurface extends ConsumerStatefulWidget {
  const V3WorkbenchHomeSurface({this.bottomContentInset = 0, super.key});

  final double bottomContentInset;

  @override
  ConsumerState<V3WorkbenchHomeSurface> createState() =>
      _V3WorkbenchHomeSurfaceState();
}

class V3WorkbenchRecommendationPage extends ConsumerStatefulWidget {
  const V3WorkbenchRecommendationPage({
    required this.recommendationId,
    this.initialTopicId,
    super.key,
  });

  final String recommendationId;
  final String? initialTopicId;

  @override
  ConsumerState<V3WorkbenchRecommendationPage> createState() =>
      _V3WorkbenchRecommendationPageState();
}

class _V3WorkbenchRecommendationPageState
    extends ConsumerState<V3WorkbenchRecommendationPage> {
  final _scrollController = ScrollController();
  DailyTopicRecommendation? _openedRecommendation;
  String? _openErrorCode;
  bool _openingRecommendation = true;
  bool _using = false;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadRecommendation);
  }

  @override
  void didUpdateWidget(covariant V3WorkbenchRecommendationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recommendationId == widget.recommendationId) return;
    _openedRecommendation = null;
    _openErrorCode = null;
    _openingRecommendation = true;
    Future<void>.microtask(_loadRecommendation);
  }

  Future<void> _loadRecommendation() async {
    final requestedId = widget.recommendationId;
    final detail = await ref
        .read(dailyTopicControllerProvider)
        .open(requestedId);
    if (!mounted || widget.recommendationId != requestedId) return;
    final controller = ref.read(dailyTopicControllerProvider);
    setState(() {
      if (detail?.recommendationId == requestedId) {
        _openedRecommendation = detail;
        _openErrorCode = null;
      } else {
        _openErrorCode = controller.state.errorCode;
      }
      _openingRecommendation = false;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _openChat(
    DailyTopicRecommendation recommendation,
    DailyTopicItem topic,
  ) async {
    final note = await _prepareReferencedNote(recommendation, topic);
    if (note == null || !mounted) return;
    await showV3NoteChatSheet(
      context: context,
      item: note,
      ordinaryEntryPoint: OrdinaryChatEntryPoint.dailyRecommendation(
        recommendationId: recommendation.recommendationId,
        topicId: topic.topicId,
      ),
    );
  }

  Future<void> _openAssistedCreation(
    DailyTopicRecommendation recommendation,
    DailyTopicItem topic,
  ) async {
    final note = await _prepareReferencedNote(recommendation, topic);
    if (note == null || !mounted) return;
    final selection = await showV3NoteAgentCreationFlow(context);
    if (!mounted || selection == null) return;
    context.push(
      v3AgentAssistedCreationRoute(item: note, selection: selection),
    );
  }

  Future<V3FeedItem?> _prepareReferencedNote(
    DailyTopicRecommendation recommendation,
    DailyTopicItem topic,
  ) async {
    if (_using) return null;
    setState(() => _using = true);
    final seed = _dailyTopicSeed(recommendation, topic);
    final note = await _depositDailyTopic(seed);
    if (!mounted) return null;
    setState(() => _using = false);
    if (note == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('选题暂时无法同步到资产，请稍后重试')));
      return null;
    }
    return note;
  }

  DailyTopicCanvasSeed _dailyTopicSeed(
    DailyTopicRecommendation recommendation,
    DailyTopicItem topic,
  ) => DailyTopicCanvasSeed(
    recommendationId: recommendation.recommendationId,
    topicId: topic.topicId,
    title: topic.title,
    briefMarkdown: _dailyTopicCreatorMarkdown(topic),
    sourceRefs: topic.sourceRefs.map(
      (sourceRef) => DailyTopicCanvasSourceRef(
        hotspotId: sourceRef.sourceId,
        label: sourceRef.label,
      ),
    ),
  );

  Future<V3FeedItem?> _depositDailyTopic(DailyTopicCanvasSeed seed) async {
    final library = ref.read(knowledgeLibraryControllerProvider);
    await library.restore();
    final title = seed.title.trim();
    final body = seed.editableMarkdown.trim();
    V3FeedItem? note;
    for (final candidate in library.notes) {
      if (candidate.ownership == V3NoteOwnership.mine &&
          candidate.source == V3MaterialSource.note &&
          candidate.title == title &&
          candidate.rawBody.trim() == body) {
        note = candidate;
        break;
      }
    }
    var deposited =
        note ??
        library.createManualNoteDraft(V3NoteDraft(title: title, rawBody: body));

    for (var attempt = 0; attempt < 3; attempt++) {
      final current = library.noteForId(deposited.id) ?? deposited;
      if (_isCanonicalChatReference(current)) return current;
      final result = await library.syncNote(current.id);
      deposited = result.note ?? library.noteForId(current.id) ?? current;
      if (result.outcome == KnowledgeNoteSyncOutcome.synced &&
          _isCanonicalChatReference(deposited)) {
        return deposited;
      }
      if (result.outcome != KnowledgeNoteSyncOutcome.superseded) return null;
    }
    return null;
  }

  bool _isCanonicalChatReference(V3FeedItem note) =>
      note.syncState == NoteSyncState.synced &&
      note.remoteNoteId?.trim().isNotEmpty == true &&
      note.rawPartRevisionId?.trim().isNotEmpty == true;

  void _openCreation(
    DailyTopicRecommendation recommendation,
    DailyTopicItem topic,
  ) {
    if (_using) return;
    context.push(
      AppRoutePaths.canvas,
      extra: CanvasEntryIntent.dailyTopic(
        _dailyTopicSeed(recommendation, topic),
      ),
    );
  }

  Future<void> _openSource(DailyTopicSourceRef source) => switch (source) {
    DailyTopicHotspotSourceRef() => _openHotspotSource(source),
    DailyTopicWorkspaceNoteSourceRef() => _openWorkspaceNoteSource(source),
  };

  Future<void> _openHotspotSource(DailyTopicHotspotSourceRef source) async {
    final uri = _dailyTopicExternalSourceUri(source.sourceUrl);
    if (uri == null) {
      _showSourceFeedback('该热点原文链接不可用');
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) _showSourceFeedback('暂时无法打开热点原文');
    } on PlatformException {
      _showSourceFeedback('暂时无法打开热点原文');
    }
  }

  Future<void> _openWorkspaceNoteSource(
    DailyTopicWorkspaceNoteSourceRef source,
  ) async {
    final library = ref.read(knowledgeLibraryControllerProvider);
    await library.restore();
    if (!mounted) return;
    var note = _workspaceSourceNote(library, source.noteId);
    if (note == null) {
      await library.synchronizeWorkspaceContent();
      if (!mounted) return;
      note = _workspaceSourceNote(library, source.noteId);
    }
    if (note == null) {
      _showSourceFeedback('该来源笔记尚未同步到我的资产');
      return;
    }
    context.push(AppRoutePaths.feedItem(note.id));
  }

  V3FeedItem? _workspaceSourceNote(
    KnowledgeLibraryController library,
    String noteId,
  ) {
    for (final note in library.notes) {
      if (note.id == noteId || note.remoteNoteId?.trim() == noteId) return note;
    }
    return null;
  }

  void _showSourceFeedback(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dailyTopicControllerProvider).state;
    final current = state.recommendation;
    final recommendation =
        _openedRecommendation ??
        (current?.recommendationId == widget.recommendationId ? current : null);
    if (recommendation == null) {
      return V3PageScaffold(
        title: '选题推荐',
        centerTitle: true,
        fallbackRoute: '/v3/workbench',
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 96),
            child: Center(
              child: _openingRecommendation || state.isLoading
                  ? const CircularProgressIndicator.adaptive()
                  : Text(
                      (_openErrorCode ?? state.errorCode) ==
                              'DAILY_TOPIC_SERVICE_UNAVAILABLE'
                          ? '每日推荐服务暂不可用'
                          : '该推送暂时无法读取',
                    ),
            ),
          ),
        ],
      );
    }
    final colors = HuahuoV3Theme.tokensOf(context);
    final topic =
        recommendation.topics
            .where((item) => item.topicId == widget.initialTopicId)
            .firstOrNull ??
        recommendation.topics.firstOrNull;
    if (topic == null) {
      return V3PageScaffold(
        title: '选题推荐',
        centerTitle: true,
        fallbackRoute: '/v3/workbench',
        padding: const EdgeInsets.fromLTRB(22, 6, 22, 30),
        children: [
          _WorkbenchEmptyRecommendationExplanation(
            reason: recommendation.summaryMarkdown,
            dateLabel: _workbenchRecommendationDateLabel(recommendation),
            onOpenPositioning: () =>
                _pushWorkbenchRoute(context, AppRoutePaths.positioningReport),
          ),
        ],
      );
    }
    return V3PageScaffold(
      title: '选题推荐',
      centerTitle: true,
      fallbackRoute: '/v3/workbench',
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 30),
      scrollController: _scrollController,
      showScrollbar: true,
      bottomBarPadding: const EdgeInsets.fromLTRB(22, 8, 22, 10),
      bottomBar: IgnorePointer(
        ignoring: _using,
        child: Opacity(
          opacity: _using ? .56 : 1,
          child: NoteDetailCreationDock(
            readOnly: false,
            onChat: () => unawaited(_openChat(recommendation, topic)),
            onAssistant: () =>
                unawaited(_openAssistedCreation(recommendation, topic)),
            onFreeCreation: () => _openCreation(recommendation, topic),
          ),
        ),
      ),
      children: [
        Text(
          topic.title,
          key: const ValueKey('workbench-recommendation-title'),
          style: TextStyle(
            color: colors.ink,
            fontSize: 20,
            height: 1.4,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _workbenchRecommendationDateLabel(recommendation),
          key: const ValueKey('workbench-recommendation-date-context'),
          style: TextStyle(
            color: colors.muted,
            fontSize: 12,
            height: 1.5,
            letterSpacing: 0,
          ),
        ),
        if (topic.sourceRefs.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(
            '内容来源',
            style: TextStyle(
              color: colors.ink,
              fontSize: 16,
              height: 1.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          for (final source in topic.sourceRefs)
            _RecommendationSourceLink(
              source: source,
              onTap: () => unawaited(_openSource(source)),
            ),
          const SizedBox(height: 18),
        ] else
          const SizedBox(height: 18),
        V3AssistantReplyMarkdown(
          key: const ValueKey('workbench-recommendation-topic-content'),
          source: _dailyTopicCreatorMarkdown(topic),
        ),
      ],
    );
  }
}

class _RecommendationSourceLink extends StatelessWidget {
  const _RecommendationSourceLink({required this.source, required this.onTap});

  final DailyTopicSourceRef source;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final DailyTopicHotspotSourceRef? hotspot =
        source is DailyTopicHotspotSourceRef
        ? source as DailyTopicHotspotSourceRef
        : null;
    final sourceUri = _dailyTopicExternalSourceUri(hotspot?.sourceUrl);
    final isHotspot = hotspot != null;
    final platform = sourceUri == null
        ? null
        : _dailyTopicSourcePlatform(sourceUri);
    final label = isHotspot
        ? '${platform ?? '外部'}原文'
        : source.label?.trim().isNotEmpty == true
        ? source.label!.trim()
        : '来源笔记';
    final actionLabel = isHotspot ? '查看热点原文' : '查看来源笔记';
    return Semantics(
      button: true,
      label: '$actionLabel $label',
      child: InkWell(
        key: ValueKey(
          'workbench-recommendation-source-'
          '${source.kind.wireValue}-${source.sourceId}',
        ),
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: Color(0xFF2563EB),
                          fontSize: 14,
                          height: 22 / 14,
                          fontWeight: FontWeight.w500,
                          decoration: TextDecoration.underline,
                          letterSpacing: 0,
                        ),
                      ),
                      Text(
                        isHotspot ? sourceUri?.host ?? '外部链接' : '打开我的资产中的原始笔记',
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 12,
                          height: 18 / 12,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  isHotspot
                      ? LucideIcons.externalLink
                      : LucideIcons.chevronRight,
                  size: 18,
                  color: colors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _V3WorkbenchHomeSurfaceState
    extends ConsumerState<V3WorkbenchHomeSurface> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dailyTopics = ref.watch(dailyTopicControllerProvider).state;
    final colors = HuahuoV3Theme.tokensOf(context);
    final topics = _workbenchTopicsForRecommendation(
      dailyTopics.recommendation,
    );

    return ColoredBox(
      key: const ValueKey<String>('home-workbench-surface'),
      color: colors.canvas,
      child: V3InteractiveScrollbar(
        controller: _scrollController,
        child: ListView(
          key: const PageStorageKey<String>('workbench-home-scroll'),
          controller: _scrollController,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            22,
            92,
            22,
            16 + widget.bottomContentInset,
          ),
          children: [
            const _WorkbenchCreationPrompt(),
            const SizedBox(height: 26),
            _WorkbenchFreeCreationButton(
              onTap: () => _pushWorkbenchRoute(
                context,
                AppRoutePaths.canvas,
                extra: const CanvasEntryIntent.blank(),
              ),
            ),
            const SizedBox(height: 24),
            const _WorkbenchInlineTools(),
            const SizedBox(height: 30),
            _WorkbenchTopicSection(
              topics: topics,
              recommendation: dailyTopics.recommendation,
              errorCode: dailyTopics.errorCode,
              onOpenPositioning: () =>
                  _pushWorkbenchRoute(context, AppRoutePaths.positioningReport),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkbenchCreationPrompt extends StatelessWidget {
  const _WorkbenchCreationPrompt();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      key: const ValueKey<String>('workbench-creation-hero'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '今天想创作什么？',
          style: TextStyle(
            color: colors.ink,
            fontSize: 28,
            height: 1.14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '把零散灵感，整理成可以表达的内容。',
          style: TextStyle(
            color: colors.muted,
            fontSize: 15,
            height: 1.4,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _WorkbenchTopicSection extends StatelessWidget {
  const _WorkbenchTopicSection({
    required this.topics,
    required this.recommendation,
    required this.errorCode,
    required this.onOpenPositioning,
  });

  final List<_WorkbenchTodayTopic> topics;
  final DailyTopicRecommendation? recommendation;
  final String? errorCode;
  final VoidCallback onOpenPositioning;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      key: const ValueKey<String>('workbench-topic-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.local_fire_department_outlined, color: colors.ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '今日推送',
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${topics.length} 条',
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (topics.isEmpty &&
            errorCode == null &&
            recommendation != null &&
            recommendation!.topics.isEmpty)
          _WorkbenchEmptyRecommendationExplanation(
            reason: recommendation!.summaryMarkdown,
            dateLabel: _workbenchBusinessDateLabel(
              recommendation!.businessDate,
            ),
            onOpenPositioning: onOpenPositioning,
            compact: true,
          )
        else if (topics.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 26),
            child: Text(
              errorCode == 'DAILY_TOPIC_SERVICE_UNAVAILABLE'
                  ? '每日推荐服务暂不可用'
                  : errorCode == 'WORKSPACE_NOT_READY'
                  ? '工作区准备完成后即可查看每日推荐'
                  : '今天暂无可用选题',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted),
            ),
          )
        else
          for (var index = 0; index < topics.length; index++)
            _WorkbenchRecommendationCard(
              topic: topics[index],
              addBottomSpacing: index != topics.length - 1,
              onTap: () => _openWorkbenchTopic(context, topics[index]),
            ),
      ],
    );
  }
}

class _WorkbenchEmptyRecommendationExplanation extends StatelessWidget {
  const _WorkbenchEmptyRecommendationExplanation({
    required this.reason,
    required this.dateLabel,
    required this.onOpenPositioning,
    this.compact = false,
  });

  final String reason;
  final String dateLabel;
  final VoidCallback onOpenPositioning;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      container: true,
      label: '本期没有生成选题。${reason.trim()}',
      child: Padding(
        key: const ValueKey('workbench-empty-recommendation-explanation'),
        padding: EdgeInsets.symmetric(vertical: compact ? 18 : 64),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.info, size: 20, color: colors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '本期没有生成选题',
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 16,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              dateLabel,
              key: const ValueKey('workbench-empty-recommendation-date'),
              style: TextStyle(
                color: colors.muted,
                fontSize: 12,
                height: 1.5,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 12),
            V3AssistantReplyMarkdown(
              key: const ValueKey('workbench-empty-recommendation-reason'),
              source: reason,
              bodyStyle: TextStyle(
                color: colors.text,
                fontSize: 14,
                height: 1.6,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              key: const ValueKey('workbench-empty-recommendation-positioning'),
              onPressed: onOpenPositioning,
              icon: const Icon(LucideIcons.userRoundPen, size: 17),
              label: const Text('查看定位资料'),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkbenchInlineTools extends StatelessWidget {
  const _WorkbenchInlineTools();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      key: const ValueKey<String>('workbench-inline-tools'),
      height: 74,
      child: Row(
        children: [
          for (
            var index = 0;
            index < _WorkbenchToolDestination.all.length;
            index++
          ) ...[
            if (index > 0)
              SizedBox(
                height: 42,
                child: VerticalDivider(width: 1, color: colors.line),
              ),
            Expanded(
              child: _WorkbenchInlineTool(
                tool: _WorkbenchToolDestination.all[index],
                onTap: () => _pushWorkbenchRoute(
                  context,
                  _WorkbenchToolDestination.all[index].route,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WorkbenchInlineTool extends StatelessWidget {
  const _WorkbenchInlineTool({required this.tool, required this.onTap});

  final _WorkbenchToolDestination tool;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      button: true,
      label: tool.label,
      child: InkWell(
        key: ValueKey<String>('workbench-inline-tool-${tool.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _WorkbenchToolIcon(tool: tool),
              const SizedBox(height: 8),
              Text(
                tool.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                  color: colors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkbenchToolIcon extends StatelessWidget {
  const _WorkbenchToolIcon({required this.tool});

  final _WorkbenchToolDestination tool;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      tool.assetPath,
      width: 38,
      height: 38,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}

class _WorkbenchRecommendationCard extends StatelessWidget {
  const _WorkbenchRecommendationCard({
    required this.topic,
    required this.addBottomSpacing,
    required this.onTap,
  });

  final _WorkbenchTodayTopic topic;
  final bool addBottomSpacing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      button: true,
      label: '使用今日热点：${topic.title}',
      child: Padding(
        padding: EdgeInsets.only(bottom: addBottomSpacing ? 10 : 0),
        child: Material(
          color: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: colors.line, width: .8),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey<String>('workbench-today-topic-${topic.topicId}'),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 100),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          topic.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.ink,
                            fontSize: 15,
                            height: 20 / 15,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          topic.summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.muted,
                            fontSize: 13,
                            height: 18 / 13,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surfaceMuted,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              topic.sourceLabel,
                              style: TextStyle(
                                color: colors.muted,
                                fontSize: 9.5,
                                height: 1.2,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          topic.dateLabel,
                          style: TextStyle(
                            color: colors.muted,
                            fontSize: 11,
                            height: 14 / 11,
                            letterSpacing: 0,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          LucideIcons.chevronRight,
                          size: 18,
                          color: colors.muted,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkbenchFreeCreationButton extends StatelessWidget {
  const _WorkbenchFreeCreationButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      key: const ValueKey<String>('workbench-free-creation'),
      button: true,
      label: '自由创作',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 80),
            child: Row(
              children: [
                Icon(
                  LucideIcons.filePlus2,
                  key: const ValueKey('workbench-free-creation-icon'),
                  size: 26,
                  color: colors.ink,
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '开始自由创作',
                      maxLines: 1,
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 22,
                        height: 1,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ),
                Icon(LucideIcons.chevronRight, size: 22, color: colors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkbenchTodayTopic {
  const _WorkbenchTodayTopic({
    required this.recommendationId,
    required this.topicId,
    required this.title,
    required this.summary,
    required this.sourceLabel,
    required this.dateLabel,
  });

  final String recommendationId;
  final String topicId;
  final String title;
  final String summary;
  final String sourceLabel;
  final String dateLabel;
}

List<_WorkbenchTodayTopic> _workbenchTopicsForRecommendation(
  DailyTopicRecommendation? recommendation,
) => recommendation == null
    ? const <_WorkbenchTodayTopic>[]
    : recommendation.topics
          .map(
            (topic) => _WorkbenchTodayTopic(
              recommendationId: recommendation.recommendationId,
              topicId: topic.topicId,
              title: topic.title,
              summary: topic.briefMarkdown
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
              sourceLabel: '每日推荐',
              dateLabel: _workbenchBusinessDateLabel(
                recommendation.businessDate,
              ),
            ),
          )
          .toList(growable: false);

String _workbenchBusinessDateLabel(String businessDate) {
  final parts = businessDate.split('-');
  if (parts.length != 3) return businessDate;
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  return month == null || day == null ? businessDate : '$month月$day日素材';
}

Uri? _dailyTopicExternalSourceUri(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty || text.length > 4096) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme.toLowerCase() != 'https' &&
          uri.scheme.toLowerCase() != 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

String? _dailyTopicSourcePlatform(Uri uri) {
  final host = uri.host.toLowerCase();
  bool matches(String root) => host == root || host.endsWith('.$root');

  if (matches('weibo.com') || matches('weibo.cn') || host == 't.cn') {
    return '微博';
  }
  if (matches('kuaishou.com')) return '快手';
  if (matches('douyin.com')) return '抖音';
  if (matches('xiaohongshu.com') ||
      matches('xhslink.com') ||
      matches('xhslink.cn')) {
    return '小红书';
  }
  if (matches('bilibili.com') || host == 'b23.tv') return '哔哩哔哩';
  if (matches('toutiao.com')) return '今日头条';
  if (matches('weixin.qq.com')) return '微信';
  if (matches('zhihu.com')) return '知乎';
  return null;
}

String _workbenchRecommendationDateLabel(
  DailyTopicRecommendation recommendation,
) {
  final materialDate = _workbenchBusinessDateLabel(recommendation.businessDate);
  final generatedAt = recommendation.generatedAt;
  if (generatedAt == null) return '${recommendation.title} · $materialDate';
  final localGeneratedAt = generatedAt.toLocal();
  return '${localGeneratedAt.month}月${localGeneratedAt.day}日推荐 · '
      '$materialDate';
}

String _dailyTopicCreatorMarkdown(DailyTopicItem topic) {
  final sections = <String>[topic.briefMarkdown.trim()];
  final contentPromise = topic.contentPromise?.trim();
  final reasonMarkdown = topic.reasonMarkdown?.trim();
  final writingSketchMarkdown = topic.writingSketchMarkdown?.trim();
  if (contentPromise?.isNotEmpty == true) {
    sections.add('## 这条选题能讲什么\n\n$contentPromise');
  }
  if (reasonMarkdown?.isNotEmpty == true) {
    sections.add('## 为什么值得写\n\n$reasonMarkdown');
  }
  if (writingSketchMarkdown?.isNotEmpty == true) {
    sections.add('## 写作提纲\n\n$writingSketchMarkdown');
  }
  return sections.join('\n\n');
}

void _openWorkbenchTopic(BuildContext context, _WorkbenchTodayTopic topic) {
  _pushWorkbenchRoute(
    context,
    '/v3/workbench/recommendations/${Uri.encodeComponent(topic.recommendationId)}'
    '?topicId=${Uri.encodeComponent(topic.topicId)}',
  );
}

void _pushWorkbenchRoute(BuildContext context, String route, {Object? extra}) {
  context.push(route, extra: extra);
}

class _WorkbenchToolDestination {
  const _WorkbenchToolDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.assetPath,
    required this.route,
    required this.color,
  });

  final String id;
  final String label;
  final IconData icon;
  final String assetPath;
  final String route;
  final Color color;

  static const all = <_WorkbenchToolDestination>[
    _WorkbenchToolDestination(
      id: 'persona',
      label: '个人 IP',
      icon: LucideIcons.userRound,
      assetPath: 'assets/images/workbench_personal_ip.png',
      route: '/v3/feed/chat?agentProfileId=renshe_content',
      color: Color(0xFF527E93),
    ),
    _WorkbenchToolDestination(
      id: 'lead',
      label: '获客营销',
      icon: LucideIcons.messagesSquare,
      assetPath: 'assets/images/workbench_lead_marketing.png',
      route: '/v3/feed/chat?agentProfileId=huoke_content',
      color: Color(0xFF477E67),
    ),
    _WorkbenchToolDestination(
      id: 'influence',
      label: '视觉设计',
      icon: LucideIcons.megaphone,
      assetPath: 'assets/images/workbench_visual_design.png',
      route: '/v3/feed/chat?skill=visual-design',
      color: Color(0xFFB06D4F),
    ),
    _WorkbenchToolDestination(
      id: 'video',
      label: '视频分析',
      icon: LucideIcons.squarePlay,
      assetPath: 'assets/images/workbench_video_analysis.png',
      route: '/v3/feed/chat?skill=video-analysis',
      color: Color(0xFF2E8DAA),
    ),
  ];
}
