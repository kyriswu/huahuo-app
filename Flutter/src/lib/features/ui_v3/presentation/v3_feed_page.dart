import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../application/feed_aggregation_controller.dart';
import '../application/feed_composer_controller.dart';
import '../application/feed_graph_controller.dart';
import '../application/feed_view_mode_controller.dart';
import '../application/knowledge_library_controller.dart';
import '../domain/feed_item_models.dart';
import '../domain/ui_v3_models.dart';
import 'v3_graph_node_action_card.dart';
import 'v3_graph_node_detail_sheet.dart';
import 'v3_feed_aggregation_task_page.dart';
import 'v3_feed_note_filter_sheet.dart';
import 'v3_interactive_graph.dart';

class V3FeedPage extends ConsumerStatefulWidget {
  const V3FeedPage({
    this.active = true,
    this.isFeedMode = true,
    this.initiallyShowNotes = false,
    this.bottomOverlayInset = 80,
    this.onNotesVisibilityChanged,
    super.key,
  });

  final bool active;

  /// Compatibility flag for focused callers; the shell supplies `true` while
  /// this retained page is onstage in AI-feed mode.
  final bool isFeedMode;

  /// The V5 shell enters the canonical 1D note centre. Direct graph hosts keep
  /// their historical graph-first default for focused tests and tools.
  final bool initiallyShowNotes;

  /// Distance from the feed viewport bottom to the first safe overlay pixel.
  /// The home shell supplies a value that clears its safe-area-aware controls.
  final double bottomOverlayInset;

  /// Reports whether the 1D Note centre, rather than either graph, owns the
  /// Feed viewport so the shared shell can arbitrate horizontal gestures.
  final ValueChanged<bool>? onNotesVisibilityChanged;

  @override
  ConsumerState<V3FeedPage> createState() => _V3FeedPageState();
}

class _V3FeedPageState extends ConsumerState<V3FeedPage>
    with AutomaticKeepAliveClientMixin {
  V3FeedNoteFilterSelection _noteFilter = const V3FeedNoteFilterSelection();

  @override
  void initState() {
    super.initState();
    ref
        .read(feedViewModeControllerProvider)
        .initialize(initiallyShowNotes: widget.initiallyShowNotes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onNotesVisibilityChanged?.call(
        ref.read(feedViewModeControllerProvider).mode == FeedViewMode.notes,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final showNotes = ref.watch(
      feedViewModeControllerProvider.select(
        (controller) => controller.mode == FeedViewMode.notes,
      ),
    );
    ref.listen<FeedViewMode>(
      feedViewModeControllerProvider.select((controller) => controller.mode),
      (previous, next) =>
          widget.onNotesVisibilityChanged?.call(next == FeedViewMode.notes),
    );
    final colors = HuahuoV3Theme.tokensOf(context);
    final overlay = ref.watch(
      feedGraphControllerProvider.select(
        (controller) => (
          contentId: controller.selectedNodeId == null
              ? null
              : controller.nodeForId(controller.selectedNodeId!)?.contentId ??
                    controller.selectedNodeId,
          searchOpen: controller.searchOpen,
          query: controller.searchQuery,
        ),
      ),
    );
    final selectedNote = ref.watch(
      knowledgeLibraryControllerProvider.select(
        (library) => overlay.contentId == null
            ? null
            : library.noteForId(overlay.contentId!),
      ),
    );
    return TickerMode(
      enabled: widget.active,
      child: V3GlassHomeScope(
        child: ColoredBox(
          color: colors.canvas,
          child: Stack(
            children: [
              Positioned.fill(
                child: showNotes
                    ? _FeedNotesCenter(
                        filter: _noteFilter,
                        bottomInset: widget.bottomOverlayInset,
                        onFilter: () => _chooseNoteFilter(context),
                        onStartAggregation: () =>
                            _startAggregation(context, ref),
                      )
                    : V3InteractiveGraph(
                        active: widget.active,
                        aggregated: false,
                        aggregating: false,
                        aggregationProgress: 0,
                        interactionsEnabled: true,
                        height: double.infinity,
                        onCanvasTap: () => ref
                            .read(feedGraphControllerProvider)
                            .clearSelection(),
                        onNodeTap: (node) => _handleNodeTap(context, ref, node),
                        onSelectedNodeTap: (node) =>
                            _openSelectedNodeDetail(context, ref, node),
                        onNodeLongPress: (node) =>
                            _handleNodeTap(context, ref, node),
                        onCreateContent: () => context.push('/v3/feed/note'),
                        showAggregationAction: widget.isFeedMode,
                        onStartAggregation: () =>
                            _startAggregation(context, ref),
                      ),
              ),
              if (widget.isFeedMode)
                Positioned(
                  top: 84,
                  left: 22,
                  child: _FeedViewModeSwitch(
                    notesSelected: showNotes,
                    enabled: true,
                    onChanged: (mode) => _selectFeedView(context, ref, mode),
                  ),
                ),
              if (overlay.searchOpen && overlay.query.trim().isNotEmpty)
                Positioned(
                  top: 70,
                  left: 22,
                  right: 22,
                  child: _GraphSearchResultsConnector(
                    onSelect: (node) {
                      final graph = ref.read(feedGraphControllerProvider);
                      graph.closeSearch();
                      FocusManager.instance.primaryFocus?.unfocus();
                      if (showNotes) {
                        _openSelectedNodeDetail(context, ref, node);
                      } else {
                        graph.selectNode(node.id);
                      }
                    },
                  ),
                ),
              if (widget.isFeedMode && !showNotes)
                Positioned(
                  left: 22,
                  right: 22,
                  bottom: widget.bottomOverlayInset,
                  child: _FeedBottomOverlay(
                    panel: selectedNote == null
                        ? null
                        : V3GraphNodeActionCard(
                            key: ValueKey('node-card-${selectedNote.id}'),
                            note: selectedNote,
                            onView: () => context.push(
                              '/v3/feed/items/${Uri.encodeComponent(selectedNote.id)}',
                            ),
                            onChat: () => context.push(
                              '/v3/feed/chat?itemId=${Uri.encodeComponent(selectedNote.id)}',
                            ),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;

  void _handleNodeTap(BuildContext context, WidgetRef ref, V3GraphNode node) {
    if (node.center) {
      ref.read(feedGraphControllerProvider).selectNode(null);
      return;
    }
    ref.read(feedComposerControllerProvider).closeAddMenu();
    final graph = ref.read(feedGraphControllerProvider)
      ..closeSearch()
      ..selectNode(node.id);
    FocusManager.instance.primaryFocus?.unfocus();
    if (ref
            .read(knowledgeLibraryControllerProvider)
            .noteForId(node.contentId ?? node.id) ==
        null) {
      showV3GraphNodeDetailSheet(
        context: context,
        node: node,
        edges: graph.semanticEdges,
        nodesById: {
          for (final candidate in graph.nodes) candidate.id: candidate,
        },
      );
    }
  }

  void _openSelectedNodeDetail(
    BuildContext context,
    WidgetRef ref,
    V3GraphNode node,
  ) {
    final contentId = node.contentId ?? node.id;
    if (ref.read(knowledgeLibraryControllerProvider).noteForId(contentId) ==
        null) {
      final graph = ref.read(feedGraphControllerProvider);
      showV3GraphNodeDetailSheet(
        context: context,
        node: node,
        edges: graph.semanticEdges,
        nodesById: <String, V3GraphNode>{
          for (final candidate in graph.nodes) candidate.id: candidate,
        },
      );
      return;
    }
    context.push('/v3/feed/items/${Uri.encodeComponent(contentId)}');
  }

  void _selectFeedView(BuildContext context, WidgetRef ref, FeedViewMode mode) {
    if (mode == FeedViewMode.notes) {
      ref.read(feedGraphControllerProvider).clearSelection();
    }
    ref.read(feedViewModeControllerProvider).select(mode);
  }

  Future<void> _chooseNoteFilter(BuildContext context) async {
    final selected = await showModalBottomSheet<V3FeedNoteFilterSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x1f17191b),
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final notes = ref
              .watch(knowledgeLibraryControllerProvider)
              .graphNotes;
          return V3FeedNoteFilterSheet(
            initialSelection: _noteFilter,
            matchingCount: (selection) =>
                notes.where(selection.includes).length,
            onClose: () => Navigator.of(sheetContext).pop(),
            onApply: (selection) => Navigator.of(sheetContext).pop(selection),
          );
        },
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _noteFilter = selected);
  }

  void _startAggregation(BuildContext context, WidgetRef ref) {
    if (!widget.active || ModalRoute.of(context)?.isCurrent != true) return;
    final aggregation = ref.read(feedAggregationControllerProvider);
    if (aggregation.hasUnresolvedTask &&
        aggregation.taskNotices.any((notice) => notice.isCurrent)) {
      showV3Snack(context, '已有聚合任务，请从消息中查看进度');
      return;
    }
    ref.read(feedComposerControllerProvider).closeAddMenu();
    ref.read(feedGraphControllerProvider)
      ..closeSearch()
      ..selectNode(null);
    FocusManager.instance.primaryFocus?.unfocus();
    context.push(V3FeedAggregationTaskPage.newTaskRoute);
  }
}

class _FeedNotesCenter extends ConsumerWidget {
  const _FeedNotesCenter({
    required this.filter,
    required this.bottomInset,
    required this.onFilter,
    required this.onStartAggregation,
  });

  final V3FeedNoteFilterSelection filter;
  final double bottomInset;
  final VoidCallback onFilter;
  final VoidCallback onStartAggregation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(knowledgeLibraryControllerProvider);
    final sourceState = library.graphReadModel.sourceState;
    final allNotes = library.graphNotes.toList(growable: false);
    final notes =
        library.graphNotes.where(filter.includes).toList(growable: false)
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return Stack(
      key: const ValueKey<String>('feed-notes-center'),
      children: [
        Positioned(
          top: 84,
          left: 22,
          right: 22,
          child: _FeedNotesOverview(
            count: allNotes.length,
            filter: filter,
            onFilter: onFilter,
            onStartAggregation: onStartAggregation,
          ),
        ),
        Positioned(
          top: 200,
          left: 22,
          right: 22,
          bottom: bottomInset + 8,
          child: allNotes.isEmpty
              ? _FeedNotesSourceStatus(
                  state: sourceState,
                  filter: filter,
                  onRetry: () => unawaited(
                    library.synchronizeWorkspaceContent(forceSnapshot: true),
                  ),
                )
              : Column(
                  children: [
                    if (sourceState == KnowledgeGraphSourceState.failure) ...[
                      _FeedNotesRefreshFailure(
                        onRetry: () => unawaited(
                          library.synchronizeWorkspaceContent(
                            forceSnapshot: true,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Expanded(
                      child: notes.isEmpty
                          ? _FeedNotesEmpty(filter: filter)
                          : ListView.separated(
                              key: const PageStorageKey<String>(
                                'feed-notes-scroll',
                              ),
                              padding: EdgeInsets.zero,
                              physics: const BouncingScrollPhysics(),
                              itemCount: notes.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) => _FeedNoteCard(
                                note: notes[index],
                                onTap: () => context.push(
                                  '/v3/feed/items/${Uri.encodeComponent(notes[index].id)}',
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _FeedNotesOverview extends StatelessWidget {
  const _FeedNotesOverview({
    required this.count,
    required this.filter,
    required this.onFilter,
    required this.onStartAggregation,
  });

  final int count;
  final V3FeedNoteFilterSelection filter;
  final VoidCallback onFilter;
  final VoidCallback onStartAggregation;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      height: 104,
      child: Stack(
        children: [
          Positioned(
            left: 112,
            right: 0,
            top: 6,
            child: Text(
              'Hi，今天想沉淀些什么？',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.ink.withValues(alpha: .94),
                fontSize: 14,
                height: 1.15,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
          ),
          Positioned(
            left: 112,
            right: 0,
            top: 27,
            child: Text(
              '你已经攒下 $count 条笔记',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.muted.withValues(alpha: .86),
                fontSize: 11,
                height: 1,
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 48,
            top: 52,
            height: 52,
            child: Semantics(
              button: true,
              label: '开始聚合',
              child: Material(
                color: HuahuoV3Theme.semanticSurface(
                  colors.accent,
                  colors.surface,
                ).withValues(alpha: .76),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: colors.accent.withValues(alpha: .42),
                    width: .8,
                  ),
                ),
                child: InkWell(
                  key: const ValueKey<String>('feed-notes-random-aggregation'),
                  onTap: onStartAggregation,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: Icon(
                            Icons.hub_outlined,
                            size: 22,
                            color: colors.accent,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '随机聚合',
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.2,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                '4 篇碰撞新观点',
                                style: TextStyle(
                                  color: colors.muted,
                                  fontSize: 11,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 17,
                          color: colors.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 58,
            right: 0,
            child: Tooltip(
              message: filter.label,
              child: Semantics(
                button: true,
                label: '筛选笔记：${filter.label}',
                child: Material(
                  color: colors.surface.withValues(alpha: .86),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: colors.accent.withValues(alpha: .24),
                    ),
                  ),
                  child: InkWell(
                    key: const ValueKey<String>('feed-notes-filter'),
                    onTap: onFilter,
                    borderRadius: BorderRadius.circular(10),
                    child: const SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(Icons.filter_alt_outlined, size: 20),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedNoteCard extends StatelessWidget {
  const _FeedNoteCard({required this.note, required this.onTap});

  final V3FeedItem note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final folder = note.folderName?.trim().isNotEmpty == true
        ? note.folderName!.trim()
        : note.contentLineName?.trim().isNotEmpty == true
        ? note.contentLineName!.trim()
        : '未归档';
    return V3NoteSummaryCard(
      title: note.title,
      preview: _feedNotePreview(note),
      sourceLabel: note.source.label,
      folderLabel: folder,
      timeLabel: _feedUpdatedAt(note.updatedAt),
      semanticLabel: '知识笔记：${note.title}',
      onTap: onTap,
    );
  }
}

class _FeedNotesEmpty extends StatelessWidget {
  const _FeedNotesEmpty({required this.filter});

  final V3FeedNoteFilterSelection filter;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.note_alt_outlined, size: 32),
        const SizedBox(height: 10),
        Text('${filter.label}暂无内容'),
      ],
    ),
  );
}

class _FeedNotesSourceStatus extends StatelessWidget {
  const _FeedNotesSourceStatus({
    required this.state,
    required this.filter,
    required this.onRetry,
  });

  final KnowledgeGraphSourceState state;
  final V3FeedNoteFilterSelection filter;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => switch (state) {
    KnowledgeGraphSourceState.loading => Center(
      child: Semantics(
        liveRegion: true,
        label: '正在加载笔记',
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(height: 12),
            Text('正在加载笔记'),
          ],
        ),
      ),
    ),
    KnowledgeGraphSourceState.failure => Center(
      child: Semantics(
        liveRegion: true,
        label: '笔记加载失败',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32),
            const SizedBox(height: 10),
            const Text('笔记加载失败'),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey<String>('feed-notes-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    ),
    KnowledgeGraphSourceState.ready => _FeedNotesEmpty(filter: filter),
  };
}

class _FeedNotesRefreshFailure extends StatelessWidget {
  const _FeedNotesRefreshFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      liveRegion: true,
      label: '笔记同步失败，当前显示上次同步内容',
      child: DecoratedBox(
        key: const ValueKey<String>('feed-notes-refresh-failure'),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.muted.withValues(alpha: .2)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: colors.muted),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '同步失败，当前显示上次同步内容',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, letterSpacing: 0),
                ),
              ),
              TextButton.icon(
                key: const ValueKey<String>('feed-notes-refresh-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeedViewModeSwitch extends StatelessWidget {
  const _FeedViewModeSwitch({
    required this.notesSelected,
    required this.enabled,
    required this.onChanged,
  });

  final bool notesSelected;
  final bool enabled;
  final ValueChanged<FeedViewMode> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 99,
    height: 48,
    child: Stack(
      children: [
        Positioned(
          top: 4,
          left: 0,
          right: 0,
          height: 39,
          child: ExcludeSemantics(
            child: IgnorePointer(
              child: Row(
                children: [
                  _FeedViewModeVisualChoice(
                    icon: Icons.account_tree_outlined,
                    label: '1D',
                    selected: notesSelected,
                  ),
                  _FeedViewModeVisualChoice(
                    icon: Icons.blur_circular_outlined,
                    label: '3D',
                    selected: !notesSelected,
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Row(
            children: [
              _FeedViewModeChoice(
                key: const ValueKey<String>('feed-home-mode-1d'),
                mode: FeedViewMode.notes,
                label: '1D',
                selected: notesSelected,
                enabled: enabled,
                onChanged: onChanged,
              ),
              _FeedViewModeChoice(
                key: const ValueKey<String>('feed-home-mode-3d'),
                mode: FeedViewMode.sphere,
                label: '3D',
                selected: !notesSelected,
                enabled: enabled,
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FeedViewModeVisualChoice extends StatelessWidget {
  const _FeedViewModeVisualChoice({
    required this.icon,
    required this.label,
    required this.selected,
  });

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Expanded(
      child: Center(
        child: Material(
          color: selected ? colors.surfaceMuted : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: colors.ink.withValues(alpha: .88),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    label,
                    style: TextStyle(
                      color: colors.ink.withValues(alpha: .88),
                      fontSize: 10.5,
                      height: 1,
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

class _FeedViewModeChoice extends StatelessWidget {
  const _FeedViewModeChoice({
    required this.mode,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final FeedViewMode mode;
  final String label;
  final bool selected;
  final bool enabled;
  final ValueChanged<FeedViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: selected,
        label: mode == FeedViewMode.notes ? '1D 笔记' : '$label 图谱',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: enabled && !selected ? () => onChanged(mode) : null,
            borderRadius: BorderRadius.circular(12),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

String _feedNotePreview(V3FeedItem note) {
  final source = note.summaryBody?.trim().isNotEmpty == true
      ? note.summaryBody!.trim()
      : note.rawBody.trim();
  final plain = source
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'[#>*_`\[\]()]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return plain.isEmpty ? '打开笔记查看完整内容。' : plain;
}

String _feedUpdatedAt(DateTime value) {
  final updated = value.toLocal();
  final now = DateTime.now();
  final day = DateTime(updated.year, updated.month, updated.day);
  final today = DateTime(now.year, now.month, now.day);
  final time =
      '${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}';
  if (day == today) return '今天 $time 更新';
  if (day == today.subtract(const Duration(days: 1))) {
    return '昨天 $time 更新';
  }
  return '${updated.month} 月 ${updated.day} 日更新';
}

class _FeedBottomOverlay extends StatelessWidget {
  const _FeedBottomOverlay({required this.panel});

  final Widget? panel;

  @override
  Widget build(BuildContext context) {
    final activePanel = panel;
    return Column(
      key: const ValueKey('feed-bottom-overlay-stack'),
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: V3MotionTokens.resolve(context, V3MotionTokens.emphasized),
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child:
              activePanel ??
              const SizedBox.shrink(key: ValueKey('feed-overlay-empty')),
        ),
      ],
    );
  }
}

class _GraphSearchResultsConnector extends ConsumerWidget {
  const _GraphSearchResultsConnector({required this.onSelect});

  final ValueChanged<V3GraphNode> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(
      feedGraphControllerProvider.select(
        (controller) => controller.searchResults,
      ),
    );
    return _GraphSearchResults(results: results, onSelect: onSelect);
  }
}

class V3GraphSearchControl extends StatefulWidget {
  const V3GraphSearchControl({
    required this.query,
    required this.enabled,
    required this.onToggle,
    required this.onQueryChanged,
    super.key,
  });

  final String query;
  final bool enabled;
  final VoidCallback onToggle;
  final ValueChanged<String> onQueryChanged;

  @override
  State<V3GraphSearchControl> createState() => _GraphSearchControlState();
}

class _GraphSearchControlState extends State<V3GraphSearchControl> {
  final _focusNode = FocusNode();
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.query);
  }

  @override
  void didUpdateWidget(covariant V3GraphSearchControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.text == widget.query) return;
    _controller.value = TextEditingValue(
      text: widget.query,
      selection: TextSelection.collapsed(offset: widget.query.length),
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final textStyle = TextStyle(
      color: colors.text,
      fontSize: 14,
      height: 1.2,
      letterSpacing: 0,
    );
    return _GraphSearchSurface(
      borderRadius: 22,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(LucideIcons.search, size: 17, color: colors.muted),
            const SizedBox(width: 7),
            Expanded(
              child: V3SearchTextField(
                key: const ValueKey('feed-graph-search-target'),
                fieldKey: const ValueKey('feed-graph-search-input'),
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                enabled: widget.enabled,
                onChanged: widget.onQueryChanged,
                onSubmitted: (_) => _focusNode.unfocus(),
                hintText: '搜索图谱',
                style: textStyle,
                hintStyle: textStyle.copyWith(color: colors.muted),
              ),
            ),
            V3CloseButton(
              key: const ValueKey('feed-graph-search-close'),
              tooltip: '关闭搜索',
              onPressed: widget.enabled ? widget.onToggle : null,
            ),
          ],
        ),
      ),
    );
  }
}

class V3GraphSearchIcon extends StatelessWidget {
  const V3GraphSearchIcon({
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: '搜索图谱',
      child: IgnorePointer(
        ignoring: !enabled,
        child: KeyedSubtree(
          key: const ValueKey('feed-graph-search-open'),
          child: V3LiquidGlassIconAction(
            tooltip: '搜索图谱',
            semanticLabel: '搜索图谱',
            onTap: onTap,
            icon: const Icon(LucideIcons.search, size: 22),
          ),
        ),
      ),
    );
  }
}

class _GraphSearchResults extends StatelessWidget {
  const _GraphSearchResults({required this.results, required this.onSelect});

  final List<V3GraphNode> results;
  final ValueChanged<V3GraphNode> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    if (results.isEmpty) {
      return const Center(
        child: _GraphSearchSurface(
          borderRadius: 14,
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Text(
            '未找到匹配笔记',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
      );
    }

    return Center(
      key: const ValueKey('feed-graph-search-results'),
      child: _GraphSearchSurface(
        borderRadius: 16,
        padding: EdgeInsets.zero,
        child: SizedBox(
          width: 330,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 9, 13, 6),
                child: Row(
                  children: [
                    Text(
                      '${results.length} 条匹配',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '选择笔记查看详情',
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 210),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                  physics: const BouncingScrollPhysics(),
                  itemCount: results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final note = results[index];
                    return Semantics(
                      container: true,
                      button: true,
                      excludeSemantics: true,
                      label: '选择笔记 ${note.label}',
                      hint: '${note.cluster.label}，${note.summary}',
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          onTap: () => onSelect(note),
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 9,
                            ),
                            child: Row(
                              children: [
                                Icon(note.cluster.icon, size: 17),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        note.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        note.summary,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: colors.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GraphSearchSurface extends StatelessWidget {
  const _GraphSearchSurface({
    required this.borderRadius,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: colors.surface,
      elevation: 2,
      shadowColor: colors.ink.withValues(alpha: .12),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}
