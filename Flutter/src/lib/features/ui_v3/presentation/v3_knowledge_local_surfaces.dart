import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/native_port_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/lifecycle/app_activity_coordinator.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../application/knowledge_library_controller.dart';
import '../application/knowledge_note_port.dart';
import '../application/profile_hub_controller.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_export_models.dart';
import '../domain/knowledge_library_models.dart';
import 'v3_deposit_picker.dart';

const _visibleKnowledgeTabs = <V3KnowledgeLibraryTab>[
  V3KnowledgeLibraryTab.subscribed,
  V3KnowledgeLibraryTab.square,
];

class V3KnowledgeTabStrip extends StatelessWidget {
  const V3KnowledgeTabStrip({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final V3KnowledgeLibraryTab selected;
  final ValueChanged<V3KnowledgeLibraryTab> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      height: 54,
      child: Row(
        children: [
          for (final tab in _visibleKnowledgeTabs)
            Expanded(
              child: InkWell(
                key: ValueKey('knowledge-tab-${tab.name}'),
                onTap: () => onSelected(tab),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      tab == V3KnowledgeLibraryTab.subscribed ? '我的订阅' : '知识广场',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: selected == tab
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: selected == tab ? colors.ink : colors.muted,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 9),
                    AnimatedContainer(
                      duration: V3MotionTokens.standard,
                      width: selected == tab ? 44 : 0,
                      height: 2,
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class V3KnowledgeEmptyState extends StatelessWidget {
  const V3KnowledgeEmptyState({this.tab, super.key});

  final V3KnowledgeLibraryTab? tab;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final message = switch (tab) {
      V3KnowledgeLibraryTab.mine => '还没有你创建的内容',
      V3KnowledgeLibraryTab.subscribed => '还没有订阅内容，可以去广场看看',
      V3KnowledgeLibraryTab.square => '知识世界暂时没有推荐',
      null => '当前条件下没有已沉淀内容',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 72),
      child: Column(
        children: [
          Icon(
            tab == null ? Icons.inventory_2_outlined : Icons.menu_book_outlined,
            size: 40,
            color: colors.muted,
          ),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(color: colors.muted)),
        ],
      ),
    );
  }
}

class V3KnowledgeSquarePage extends StatelessWidget {
  const V3KnowledgeSquarePage({
    required this.controller,
    required this.active,
    required this.query,
    required this.category,
    required this.showAllUpdates,
    required this.onAction,
    required this.onQueryChanged,
    required this.onCategoryChanged,
    required this.onShowAllUpdatesChanged,
    super.key,
  });

  final KnowledgeLibraryController controller;
  final bool active;
  final String query;
  final V3SquareExploreCategory category;
  final bool showAllUpdates;
  final Future<void> Function(V3FeedItem, V3KnowledgeNoteAction) onAction;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<V3SquareExploreCategory> onCategoryChanged;
  final VoidCallback onShowAllUpdatesChanged;

  @override
  Widget build(BuildContext context) {
    final queryNotes = controller.filteredNotesFor(
      V3KnowledgeLibraryTab.square,
      queryOverride: query,
    );
    final categoryMatches = queryNotes
        .where((note) => _matchesSquareCategory(note, category))
        .toList(growable: false);
    final notes = categoryMatches.isNotEmpty || query.trim().isNotEmpty
        ? categoryMatches
        : _squareCategoryFallback(queryNotes, category);
    final visibleNotes = showAllUpdates ? notes : notes.take(3).toList();
    final recommendations = controller
        .filteredNotesFor(V3KnowledgeLibraryTab.square, queryOverride: '')
        .take(3)
        .toList(growable: false);

    return ListView(
      key: const PageStorageKey<String>('knowledge-square'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
      children: [
        TextField(
          key: const ValueKey<String>('knowledge-square-search'),
          contextMenuBuilder: V3TextEditing.buildContextMenu,
          onChanged: onQueryChanged,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            hintText: '搜索知识世界',
          ),
        ),
        const SizedBox(height: 14),
        _SquareDiscoveryBanner(
          notes: recommendations,
          active: active,
          onOpen: (note) =>
              context.push('/v3/feed/items/${Uri.encodeComponent(note.id)}'),
        ),
        const SizedBox(height: 18),
        _SquareTopicGrid(selected: category, onSelected: onCategoryChanged),
        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(
              child: Text(
                '其他',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            if (notes.length > 3)
              TextButton(
                key: const ValueKey('knowledge-square-more'),
                onPressed: onShowAllUpdatesChanged,
                child: Text(showAllUpdates ? '收起' : '更多'),
              ),
          ],
        ),
        const SizedBox(height: 2),
        if (notes.isEmpty)
          const V3KnowledgeEmptyState(tab: V3KnowledgeLibraryTab.square)
        else
          for (final note in visibleNotes)
            _SquareRecentUpdateRow(
              note: note,
              isDeposited: controller.isDeposited(note.id),
              onOpen: () => context.push(
                '/v3/feed/items/${Uri.encodeComponent(note.id)}',
              ),
              onAction: (action) => onAction(note, action),
            ),
      ],
    );
  }
}

enum V3SquareExploreCategory {
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

extension V3SquareExploreCategoryX on V3SquareExploreCategory {
  String get label => switch (this) {
    V3SquareExploreCategory.treasure => '镇馆之宝',
    V3SquareExploreCategory.history => '历史',
    V3SquareExploreCategory.socialScience => '社科',
    V3SquareExploreCategory.art => '艺术',
    V3SquareExploreCategory.literature => '文学',
    V3SquareExploreCategory.audio => '必听',
    V3SquareExploreCategory.culture => '文创',
    V3SquareExploreCategory.city => '城市漫游',
    V3SquareExploreCategory.bookstore => '书店',
    V3SquareExploreCategory.all => '全部',
  };

  IconData get icon => switch (this) {
    V3SquareExploreCategory.treasure => Icons.workspace_premium_outlined,
    V3SquareExploreCategory.history => Icons.history_edu_outlined,
    V3SquareExploreCategory.socialScience => Icons.auto_stories_outlined,
    V3SquareExploreCategory.art => Icons.palette_outlined,
    V3SquareExploreCategory.literature => Icons.menu_book_outlined,
    V3SquareExploreCategory.audio => Icons.headphones_outlined,
    V3SquareExploreCategory.culture => Icons.lightbulb_outline_rounded,
    V3SquareExploreCategory.city => Icons.location_city_outlined,
    V3SquareExploreCategory.bookstore => Icons.local_library_outlined,
    V3SquareExploreCategory.all => Icons.grid_view_rounded,
  };

  KnowledgeChannel? get channel => switch (this) {
    V3SquareExploreCategory.treasure => KnowledgeChannel.treasure,
    V3SquareExploreCategory.history => KnowledgeChannel.history,
    V3SquareExploreCategory.socialScience => KnowledgeChannel.socialScience,
    V3SquareExploreCategory.art => KnowledgeChannel.art,
    V3SquareExploreCategory.literature => KnowledgeChannel.literature,
    V3SquareExploreCategory.audio => KnowledgeChannel.audio,
    V3SquareExploreCategory.culture => KnowledgeChannel.culture,
    V3SquareExploreCategory.city => KnowledgeChannel.city,
    V3SquareExploreCategory.bookstore => KnowledgeChannel.bookstore,
    V3SquareExploreCategory.all => null,
  };
}

IconData _knowledgeChannelIcon(KnowledgeChannel channel) => switch (channel) {
  KnowledgeChannel.treasure => Icons.workspace_premium_outlined,
  KnowledgeChannel.history => Icons.history_edu_outlined,
  KnowledgeChannel.socialScience => Icons.auto_stories_outlined,
  KnowledgeChannel.art => Icons.palette_outlined,
  KnowledgeChannel.literature => Icons.menu_book_outlined,
  KnowledgeChannel.audio => Icons.headphones_outlined,
  KnowledgeChannel.culture => Icons.lightbulb_outline_rounded,
  KnowledgeChannel.city => Icons.location_city_outlined,
  KnowledgeChannel.bookstore => Icons.local_library_outlined,
};

class V3SubscribedChannelBar extends StatelessWidget {
  const V3SubscribedChannelBar({
    required this.channels,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final List<KnowledgeChannel> channels;
  final KnowledgeChannel? selected;
  final ValueChanged<KnowledgeChannel?> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final values = <KnowledgeChannel?>[null, ...channels];
    return SizedBox(
      key: const ValueKey('knowledge-subscribed-channel-bar'),
      height: 78,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final channel = values[index];
          final active = selected == channel;
          return InkWell(
            key: ValueKey(
              'knowledge-subscribed-channel-${channel?.id ?? 'all'}',
            ),
            onTap: () => onSelected(channel),
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 62,
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: V3MotionTokens.quick,
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active
                          ? colors.coolGlass.selectedFallback
                          : colors.surfaceMuted,
                      border: Border.all(
                        color: active ? colors.primary : colors.line,
                        width: active ? 1.5 : 1,
                      ),
                    ),
                    child: Icon(
                      channel == null
                          ? Icons.dynamic_feed_outlined
                          : _knowledgeChannelIcon(channel),
                      size: 22,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    channel?.label ?? '全部订阅',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class V3SubscribedArticleRow extends StatelessWidget {
  const V3SubscribedArticleRow({
    required this.note,
    required this.channel,
    required this.isDeposited,
    required this.onOpen,
    required this.onDeposit,
    super.key,
  });

  final V3FeedItem note;
  final KnowledgeChannel channel;
  final bool isDeposited;
  final VoidCallback onOpen;
  final VoidCallback onDeposit;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 13),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: HuahuoV3Theme.tokensOf(context).surfaceMuted,
          child: Icon(_knowledgeChannelIcon(channel), size: 20),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  note.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${channel.label} · ${v3KnowledgeFormatDate(note.createdAt)}',
                  style: TextStyle(
                    color: HuahuoV3Theme.tokensOf(context).muted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
        ),
        TextButton(
          onPressed: isDeposited ? null : onDeposit,
          child: Text(isDeposited ? '已沉淀' : '沉淀'),
        ),
      ],
    ),
  );
}

class V3KnowledgeChannelDetailPage extends ConsumerWidget {
  const V3KnowledgeChannelDetailPage({required this.channelId, super.key});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = KnowledgeChannel.fromId(channelId);
    if (channel == null) {
      return const V3KnowledgeRouteRecoveryPage(
        recoveryKey: ValueKey('knowledge-channel-missing'),
        title: '知识世界',
        message: '该频道不存在或已下线，请返回知识世界查看其他内容',
      );
    }
    final controller = ref.watch(knowledgeLibraryControllerProvider);
    final subscribed = controller.isChannelSubscribed(channel);
    final notes = controller.channelArticlesFor(channel);
    return V3PageScaffold(
      title: channel.label,
      fallbackRoute: AppRoutePaths.knowledgeSquare,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 30,
              child: Icon(_knowledgeChannelIcon(channel), size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    channel.description,
                    style: const TextStyle(height: 1.5),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '${12000 + channel.index * 1731} 人订阅 · ${notes.length} 篇文章',
                    style: TextStyle(
                      color: HuahuoV3Theme.tokensOf(context).muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        V3PrimaryButton(
          label: subscribed ? '取消订阅' : '订阅频道',
          icon: subscribed
              ? Icons.notifications_off_outlined
              : Icons.add_alert_outlined,
          onPressed: () {
            final changed = subscribed
                ? ref
                      .read(knowledgeLibraryControllerProvider)
                      .unsubscribeChannel(channel)
                : ref
                      .read(knowledgeLibraryControllerProvider)
                      .subscribeChannel(channel);
            showV3Snack(
              context,
              changed
                  ? subscribed
                        ? '已取消订阅'
                        : '已订阅 ${channel.label}'
                  : '订阅状态保存失败，请重试',
            );
          },
        ),
        const SizedBox(height: 20),
        const V3SectionTitle('频道文章'),
        for (var index = 0; index < notes.length; index++) ...[
          V3SubscribedArticleRow(
            note: notes[index],
            channel: channel,
            isDeposited: controller.isDeposited(notes[index].id),
            onOpen: () => context.push(AppRoutePaths.feedItem(notes[index].id)),
            onDeposit: () => _handleNoteAction(
              context,
              ref,
              notes[index],
              V3KnowledgeNoteAction.move,
            ),
          ),
          if (index != notes.length - 1) const Divider(height: 1),
        ],
      ],
    );
  }
}

class V3KnowledgeRouteRecoveryPage extends StatelessWidget {
  const V3KnowledgeRouteRecoveryPage({
    required this.recoveryKey,
    required this.title,
    required this.message,
    super.key,
  });

  final Key recoveryKey;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return V3PageScaffold(
      title: title,
      fallbackRoute: AppRoutePaths.knowledgeSquare,
      children: <Widget>[
        Center(
          key: recoveryKey,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.travel_explore_outlined, size: 38),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => returnToPreviousRoute(
                    context,
                    fallbackRoute: AppRoutePaths.knowledgeSquare,
                  ),
                  child: Text(
                    canReturnToPreviousRoute(context) ? '返回上一级' : '返回知识世界',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SquareDiscoveryBanner extends ConsumerStatefulWidget {
  const _SquareDiscoveryBanner({
    required this.notes,
    required this.active,
    required this.onOpen,
  });

  final List<V3FeedItem> notes;
  final bool active;
  final ValueChanged<V3FeedItem> onOpen;

  @override
  ConsumerState<_SquareDiscoveryBanner> createState() =>
      _SquareDiscoveryBannerState();
}

class _SquareDiscoveryBannerState
    extends ConsumerState<_SquareDiscoveryBanner> {
  static const _interval = V3InteractionTimingTokens.carouselAdvance;
  static const _assets = <String>['assets/images/knowledge_square_banner.png'];

  late final PageController _controller;
  Timer? _timer;
  int _index = 0;
  bool _assetsPrecached = false;
  bool _appActive = true;
  bool _allowImagePrefetch = true;

  @override
  void initState() {
    super.initState();
    _appActive = ref.read(appActivityCoordinatorProvider).state.isForeground;
    _allowImagePrefetch = ref
        .read(performancePolicyProvider)
        .allowImagePrefetch;
    ref.listenManual<bool>(
      appActivityCoordinatorProvider.select(
        (coordinator) => coordinator.state.isForeground,
      ),
      (_, next) {
        _appActive = next;
        _syncTimer();
      },
    );
    ref.listenManual<bool>(
      performancePolicyProvider.select((policy) => policy.allowImagePrefetch),
      (_, next) {
        _allowImagePrefetch = next;
        if (next) _precacheAssets();
      },
    );
    _controller = PageController();
    _syncTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheAssets();
  }

  void _precacheAssets() {
    if (_assetsPrecached || !_allowImagePrefetch || !mounted) return;
    _assetsPrecached = true;
    for (final asset in _assets) {
      unawaited(precacheImage(AssetImage(asset), context, onError: (_, __) {}));
    }
  }

  @override
  void didUpdateWidget(covariant _SquareDiscoveryBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (!widget.active || !_appActive || _assets.length < 2) return;
    _timer = Timer.periodic(_interval, (_) => _advance());
  }

  void _advance() {
    if (!mounted || !_controller.hasClients) return;
    final next = (_index + 1) % _assets.length;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpToPage(next);
    } else {
      _controller.animateToPage(
        next,
        duration: V3MotionTokens.slow,
        curve: Curves.easeOutCubic,
      );
    }
  }

  V3FeedItem? _noteFor(int index) =>
      widget.notes.isEmpty ? null : widget.notes[index % widget.notes.length];

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return ClipRRect(
      key: const ValueKey('knowledge-square-banner'),
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 647 / 305,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              key: const ValueKey('knowledge-square-banner-pages'),
              controller: _controller,
              itemCount: _assets.length,
              onPageChanged: (index) {
                setState(() => _index = index);
                _syncTimer();
              },
              itemBuilder: (context, index) {
                final note = _noteFor(index);
                final title = note?.title ?? '发现值得订阅的知识';
                return Semantics(
                  button: note != null,
                  label: note == null ? title : '查看推荐：$title',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: note == null ? null : () => widget.onOpen(note),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ExcludeSemantics(
                            child: Image.asset(
                              _assets[index],
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => ColoredBox(
                                color: colors.surfaceMuted,
                                child: Center(
                                  child: Icon(
                                    Icons.menu_book_outlined,
                                    color: colors.muted,
                                    size: 34,
                                  ),
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
                                stops: [.45, 1],
                              ),
                            ),
                          ),
                          Positioned(
                            left: 14,
                            right: 14,
                            bottom: 26,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                shadows: [
                                  Shadow(color: Colors.black54, blurRadius: 5),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var index = 0; index < _assets.length; index++)
                    AnimatedContainer(
                      key: ValueKey('knowledge-square-banner-dot-$index'),
                      duration: V3MotionTokens.standard,
                      width: index == _index ? 16 : 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(
                          alpha: index == _index ? .92 : .55,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
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

class _SquareTopicGrid extends StatelessWidget {
  const _SquareTopicGrid({required this.selected, required this.onSelected});

  final V3SquareExploreCategory selected;
  final ValueChanged<V3SquareExploreCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(
          context,
        ).scale(1).clamp(1.0, 1.3).toDouble();
        final columnCount = constraints.maxWidth < 320 ? 4 : 5;
        final childAspectRatio = .82 - (textScale - 1) * .2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: V3SquareExploreCategory.values.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columnCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 6,
            childAspectRatio: childAspectRatio,
          ),
          itemBuilder: (context, index) {
            final item = V3SquareExploreCategory.values[index];
            final isSelected = selected == item;
            return Semantics(
              label: '${item.label}主题',
              selected: isSelected,
              button: true,
              child: InkWell(
                key: ValueKey('knowledge-square-category-${item.name}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => onSelected(item),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedContainer(
                      duration: V3MotionTokens.quick,
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected
                            ? colors.coolGlass.selectedFallback
                            : colors.surfaceMuted,
                        border: Border.all(
                          color: isSelected
                              ? colors.coolGlass.rim
                              : colors.line,
                        ),
                      ),
                      child: Icon(
                        item.icon,
                        size: 22,
                        color: isSelected ? colors.ink : colors.text,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: isSelected ? colors.ink : colors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SquareRecentUpdateRow extends StatelessWidget {
  const _SquareRecentUpdateRow({
    required this.note,
    required this.isDeposited,
    required this.onOpen,
    required this.onAction,
  });

  final V3FeedItem note;
  final bool isDeposited;
  final VoidCallback onOpen;
  final Future<void> Function(V3KnowledgeNoteAction) onAction;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SquareUpdateThumbnail(note: note),
            const SizedBox(width: 11),
            Expanded(
              child: InkWell(
                onTap: onOpen,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_knowledgeSourceLabel(note.source)} · ${v3KnowledgeFormatDate(note.updatedAt)} 更新',
                        key: ValueKey('knowledge-square-source-${note.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.muted, fontSize: 11.5),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        note.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _squarePreview(note),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.muted, fontSize: 12.5),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${_squareAuthor(note)} · ${_squareSubscriberCount(note)} 人在用',
                        key: ValueKey('knowledge-square-author-${note.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Column(
              children: [
                TextButton(
                  key: ValueKey('knowledge-square-deposit-${note.id}'),
                  onPressed: isDeposited
                      ? null
                      : () => onAction(V3KnowledgeNoteAction.move),
                  child: Text(isDeposited ? '已沉淀' : '沉淀'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SquareUpdateThumbnail extends StatelessWidget {
  const _SquareUpdateThumbnail({required this.note});

  final V3FeedItem note;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 70,
        height: 70,
        child: ColoredBox(
          color: _squareThumbnailColor(note, colors),
          child: Center(
            child: Icon(
              _squareThumbnailIcon(note),
              color: colors.text,
              size: 25,
            ),
          ),
        ),
      ),
    );
  }
}

bool _matchesSquareCategory(V3FeedItem note, V3SquareExploreCategory category) {
  if (category == V3SquareExploreCategory.all) return true;
  final searchable = <String>[
    note.title,
    note.rawBody,
    note.summaryBody ?? '',
    ...note.topics,
  ].join(' ').toLowerCase();
  final keywords = switch (category) {
    V3SquareExploreCategory.treasure => const ['藏', '博物', '文物', '展览'],
    V3SquareExploreCategory.history => const ['历史', '史学', '古', '朝代'],
    V3SquareExploreCategory.socialScience => const ['社科', '社会', '人文', '经济'],
    V3SquareExploreCategory.art => const ['艺术', '设计', '绘画', '音乐'],
    V3SquareExploreCategory.literature => const ['文学', '写作', '小说', '诗'],
    V3SquareExploreCategory.audio => const ['播客', '音频', '听', '声音'],
    V3SquareExploreCategory.culture => const ['文创', '文化', '创意', '品牌'],
    V3SquareExploreCategory.city => const ['城市', '旅行', '漫游', '空间'],
    V3SquareExploreCategory.bookstore => const ['书店', '阅读', '图书', '书籍'],
    V3SquareExploreCategory.all => const <String>[],
  };
  return keywords.any(searchable.contains);
}

List<V3FeedItem> _squareCategoryFallback(
  List<V3FeedItem> notes,
  V3SquareExploreCategory category,
) {
  if (notes.isEmpty || category == V3SquareExploreCategory.all) return notes;
  final offset =
      V3SquareExploreCategory.values.indexOf(category) % notes.length;
  return <V3FeedItem>[
    ...notes.skip(offset),
    ...notes.take(offset),
  ].take(3).toList(growable: false);
}

String _squarePreview(V3FeedItem note) {
  final preferred = note.summaryBody?.trim();
  return preferred == null || preferred.isEmpty ? note.rawBody : preferred;
}

IconData _squareThumbnailIcon(V3FeedItem note) {
  final category = V3SquareExploreCategory.values.firstWhere(
    (candidate) => _matchesSquareCategory(note, candidate),
    orElse: () => V3SquareExploreCategory.all,
  );
  return category == V3SquareExploreCategory.all
      ? Icons.auto_stories_outlined
      : category.icon;
}

Color _squareThumbnailColor(V3FeedItem note, HuahuoV3ThemeTokens colors) {
  final category = V3SquareExploreCategory.values.firstWhere(
    (candidate) => _matchesSquareCategory(note, candidate),
    orElse: () => V3SquareExploreCategory.all,
  );
  return switch (category) {
    V3SquareExploreCategory.art ||
    V3SquareExploreCategory.culture => colors.warmGlass.fallback,
    V3SquareExploreCategory.history ||
    V3SquareExploreCategory.treasure => colors.neutralGlass.selectedFallback,
    V3SquareExploreCategory.audio ||
    V3SquareExploreCategory.literature => colors.coolGlass.fallback,
    _ => colors.surfaceMuted,
  };
}

String _squareAuthor(V3FeedItem note) {
  final collection = note.contentLineName?.trim();
  return collection == null || collection.isEmpty
      ? '花火知识共创者'
      : '$collection共创组';
}

int _squareSubscriberCount(V3FeedItem note) {
  var checksum = 0;
  for (final unit in note.id.codeUnits) {
    checksum = (checksum + unit) % 8000;
  }
  return 680 + checksum;
}

enum V3KnowledgeNoteAction {
  share,
  export,
  tags,
  move,
  duplicate,
  sync,
  resolveConflict,
  rename,
  edit,
  delete,
}

Future<V3KnowledgeNoteAction?> showV3KnowledgeNoteActions({
  required BuildContext context,
  required V3FeedItem note,
  required bool inDeposits,
  required bool isDeposited,
}) async {
  final action = await _showKnowledgeNoteActions(
    context: context,
    note: note,
    inDeposits: inDeposits,
    isDeposited: isDeposited,
  );
  return action == null
      ? null
      : V3KnowledgeNoteAction.values.byName(action.name);
}

Future<V3KnowledgeNoteAction?> _showKnowledgeNoteActions({
  required BuildContext context,
  required V3FeedItem note,
  required bool inDeposits,
  required bool isDeposited,
}) {
  final items = inDeposits
      ? <V3ActionSheetItem<V3KnowledgeNoteAction>>[
          const V3ActionSheetItem(
            value: V3KnowledgeNoteAction.share,
            icon: Icons.share_outlined,
            label: '分享',
          ),
          V3ActionSheetItem(
            value: V3KnowledgeNoteAction.edit,
            icon: note.isReadOnly
                ? Icons.copy_rounded
                : Icons.edit_note_rounded,
            label: note.isReadOnly ? '复制并编辑' : '编辑内容',
          ),
          if (!note.isReadOnly)
            const V3ActionSheetItem(
              value: V3KnowledgeNoteAction.rename,
              icon: Icons.drive_file_rename_outline_rounded,
              label: '重命名',
            ),
          const V3ActionSheetItem(
            value: V3KnowledgeNoteAction.move,
            icon: Icons.drive_file_move_outline,
            label: '移动到文件夹',
          ),
          const V3ActionSheetItem(
            value: V3KnowledgeNoteAction.duplicate,
            icon: Icons.copy_all_outlined,
            label: '创建副本',
          ),
          if (!note.isReadOnly &&
              (note.syncState == NoteSyncState.pending ||
                  note.syncState == NoteSyncState.localOnly))
            const V3ActionSheetItem(
              value: V3KnowledgeNoteAction.sync,
              icon: Icons.sync_rounded,
              label: '立即同步',
            ),
          if (!note.isReadOnly && note.syncState == NoteSyncState.conflict)
            const V3ActionSheetItem(
              value: V3KnowledgeNoteAction.resolveConflict,
              icon: Icons.merge_type_rounded,
              label: '处理冲突',
            ),
          if (!note.isReadOnly)
            const V3ActionSheetItem(
              value: V3KnowledgeNoteAction.delete,
              icon: Icons.delete_outline_rounded,
              label: '删除',
              destructive: true,
            ),
        ]
      : <V3ActionSheetItem<V3KnowledgeNoteAction>>[
          const V3ActionSheetItem(
            value: V3KnowledgeNoteAction.share,
            icon: Icons.ios_share_rounded,
            label: '分享',
          ),
          V3ActionSheetItem(
            value: V3KnowledgeNoteAction.edit,
            icon: note.isReadOnly ? Icons.copy_rounded : Icons.edit_outlined,
            label: note.isReadOnly ? '复制并编辑' : '编辑',
          ),
          const V3ActionSheetItem(
            value: V3KnowledgeNoteAction.export,
            icon: Icons.file_download_outlined,
            label: '导出',
          ),
          const V3ActionSheetItem(
            value: V3KnowledgeNoteAction.tags,
            icon: Icons.sell_outlined,
            label: '管理标签',
          ),
          V3ActionSheetItem(
            value: V3KnowledgeNoteAction.move,
            icon: isDeposited
                ? Icons.drive_file_move_outline
                : Icons.bookmark_add_outlined,
            label: isDeposited ? '移动沉淀位置' : '沉淀',
          ),
          if (!note.isReadOnly &&
              (note.syncState == NoteSyncState.pending ||
                  note.syncState == NoteSyncState.localOnly))
            const V3ActionSheetItem(
              value: V3KnowledgeNoteAction.sync,
              icon: Icons.sync_rounded,
              label: '立即同步',
            ),
          if (!note.isReadOnly && note.syncState == NoteSyncState.conflict)
            const V3ActionSheetItem(
              value: V3KnowledgeNoteAction.resolveConflict,
              icon: Icons.merge_type_rounded,
              label: '处理冲突',
            ),
          if (!note.isReadOnly) ...[
            const V3ActionSheetItem(
              value: V3KnowledgeNoteAction.rename,
              icon: Icons.drive_file_rename_outline_rounded,
              label: '重命名',
            ),
            const V3ActionSheetItem(
              value: V3KnowledgeNoteAction.delete,
              icon: Icons.delete_outline_rounded,
              label: '删除',
              destructive: true,
            ),
          ],
        ];
  return showV3ActionSheet<V3KnowledgeNoteAction>(
    context: context,
    title: note.title,
    items: items,
  );
}

class _KnowledgeTagEditorSheet extends StatefulWidget {
  const _KnowledgeTagEditorSheet({
    required this.noteTitle,
    required this.initialTags,
    required this.authorTags,
  });

  final String noteTitle;
  final List<String> initialTags;
  final List<String> authorTags;

  @override
  State<_KnowledgeTagEditorSheet> createState() =>
      _KnowledgeTagEditorSheetState();
}

class _KnowledgeTagEditorSheetState extends State<_KnowledgeTagEditorSheet> {
  late final TextEditingController _input;
  late final List<String> _tags;
  late final Set<String> _authorTagKeys;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController();
    _tags = List<String>.of(widget.initialTags);
    _authorTagKeys = widget.authorTags
        .map((tag) => tag.trim().toLowerCase())
        .where((tag) => tag.isNotEmpty)
        .toSet();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _addTags() {
    final candidates = _input.text
        .split(RegExp(r'[,，]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (candidates.isEmpty) {
      setState(() => _errorText = '请输入标签');
      return;
    }
    if (candidates.any((value) => value.runes.length > 24)) {
      setState(() => _errorText = '每个标签最多 24 个字');
      return;
    }
    final existing = _tags.map((value) => value.toLowerCase()).toSet();
    final additions = <String>[];
    for (final candidate in candidates) {
      if (existing.add(candidate.toLowerCase())) additions.add(candidate);
    }
    if (_tags.length + additions.length > 20) {
      setState(() => _errorText = '每条内容最多添加 20 个标签');
      return;
    }
    setState(() {
      _tags.addAll(additions);
      _input.clear();
      _errorText = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final keyboardVisible = bottomInset > 0;
    const glassSheetHandleExtent = 20.0;
    final keyboardMaxHeight =
        (mediaQuery.size.height - bottomInset - glassSheetHandleExtent)
            .clamp(0.0, mediaQuery.size.height)
            .toDouble();
    final compactKeyboard = keyboardVisible && keyboardMaxHeight < 280;
    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: bottomInset),
      duration: V3MotionTokens.resolve(context, V3MotionTokens.standard),
      curve: Curves.easeOutCubic,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: keyboardVisible ? keyboardMaxHeight : double.infinity,
        ),
        child: V3SheetScaffold(
          title: compactKeyboard ? null : '管理标签',
          message: compactKeyboard ? null : widget.noteTitle,
          showClose: !compactKeyboard,
          maxHeightFactor: keyboardVisible ? 1 : .78,
          child: Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (compactKeyboard)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      height: 44,
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '管理标签',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HuahuoV3Theme.sectionTitle,
                            ),
                          ),
                          V3CloseButton(
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                  ),
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('knowledge-tag-editor-scroll'),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.manual,
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (compactKeyboard) ...[
                          Text(
                            widget.noteTitle,
                            style: HuahuoV3Theme.body.copyWith(
                              color: colors.muted,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (_tags.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final tag in _tags)
                                if (_authorTagKeys.contains(tag.toLowerCase()))
                                  Tooltip(
                                    message: '作者标签',
                                    child: Chip(
                                      key: ValueKey(
                                        'knowledge-author-tag-$tag',
                                      ),
                                      avatar: const Icon(
                                        Icons.lock_outline_rounded,
                                      ),
                                      label: Text(tag),
                                    ),
                                  )
                                else
                                  InputChip(
                                    key: ValueKey('knowledge-tag-$tag'),
                                    label: Text(tag),
                                    onDeleted: () => setState(() {
                                      _tags.remove(tag);
                                      _errorText = null;
                                    }),
                                  ),
                            ],
                          )
                        else
                          Text('尚未添加标签', style: TextStyle(color: colors.muted)),
                        const SizedBox(height: 14),
                        TextField(
                          key: const ValueKey('knowledge-tag-input'),
                          controller: _input,
                          contextMenuBuilder: V3TextEditing.buildContextMenu,
                          autofocus: true,
                          maxLength: 50,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _addTags(),
                          decoration: InputDecoration(
                            labelText: '自定义标签',
                            hintText: '多个标签用逗号分隔',
                            errorText: _errorText,
                            suffixIcon: IconButton(
                              tooltip: '添加标签',
                              onPressed: _addTags,
                              icon: const Icon(Icons.add_rounded),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: compactKeyboard ? 4 : 12),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    8,
                    0,
                    8,
                    compactKeyboard ? 0 : 8,
                  ),
                  child: FilledButton(
                    key: const ValueKey('knowledge-tags-save'),
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(List<String>.unmodifiable(_tags)),
                    child: const Text('保存'),
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

Future<bool> showV3KnowledgeNoteDeleteConfirmation(
  BuildContext context,
  V3FeedItem note,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '删除笔记',
        message: '确定删除“${note.title}”？',
        primaryLabel: '删除',
        onPrimary: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    ) ??
    false;

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
) async {
  final confirmed = await showV3KnowledgeNoteDeleteConfirmation(context, note);
  if (!confirmed || !context.mounted) return;
  final controller = ref.read(knowledgeLibraryControllerProvider);
  final result = await controller.deleteNoteDurably(note.id);
  if (!context.mounted) return;
  if (result.outcome == KnowledgeNoteDeleteOutcome.notEditable) {
    showV3Snack(context, '该笔记不可删除');
    return;
  }
  if (result.outcome == KnowledgeNoteDeleteOutcome.persistenceFailed) {
    showV3Snack(context, '删除未完成，笔记仍保留，请重试');
    return;
  }
  final removed = result.note!;
  ref.read(profileHubControllerProvider).removeActivitiesForNote(removed.id);
  showV3Snack(context, '笔记已删除');
}

Future<void> _handleNoteAction(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
  V3KnowledgeNoteAction action,
) async {
  switch (action) {
    case V3KnowledgeNoteAction.share:
      await _shareKnowledgeNote(context, ref, note);
      return;
    case V3KnowledgeNoteAction.export:
      await _exportKnowledgeNote(context, ref, note);
      return;
    case V3KnowledgeNoteAction.tags:
      await _manageKnowledgeTags(context, ref, note);
      return;
    case V3KnowledgeNoteAction.move:
      await showV3DepositPicker(context, contentId: note.id);
      return;
    case V3KnowledgeNoteAction.duplicate:
      final controller = ref.read(knowledgeLibraryControllerProvider);
      final copy = controller.createEditableCopy(note.id);
      if (copy == null) {
        showV3Snack(context, '创建副本失败，请重试');
        return;
      }
      final persisted = await controller.flushPersistenceResult();
      if (!context.mounted) return;
      if (!persisted) {
        showV3Snack(context, '副本保存失败，请重试');
        return;
      }
      await context.push('/v3/feed/note/${Uri.encodeComponent(copy.id)}');
      return;
    case V3KnowledgeNoteAction.sync:
      await _syncNote(context, ref, note);
      return;
    case V3KnowledgeNoteAction.resolveConflict:
      await _resolveNoteConflict(context, ref, note);
      return;
    case V3KnowledgeNoteAction.rename:
      await _renameNote(context, ref, note);
      return;
    case V3KnowledgeNoteAction.edit:
      if (note.isReadOnly) {
        final controller = ref.read(knowledgeLibraryControllerProvider);
        final copy = controller.createEditableCopy(note.id);
        if (copy == null) {
          showV3Snack(context, '创建副本失败，请重试');
          return;
        }
        final persisted = await controller.flushPersistenceResult();
        if (!context.mounted) return;
        if (!persisted) {
          showV3Snack(context, '副本保存失败，请重试');
          return;
        }
        await context.push('/v3/feed/note/${Uri.encodeComponent(copy.id)}');
        return;
      }
      await context.push('/v3/feed/note/${Uri.encodeComponent(note.id)}');
      return;
    case V3KnowledgeNoteAction.delete:
      await _confirmDelete(context, ref, note);
      return;
  }
}

Future<void> handleV3KnowledgeNoteAction(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
  V3KnowledgeNoteAction action,
) {
  return _handleNoteAction(context, ref, note, action);
}

Future<void> shareV3KnowledgeNoteAsMarkdown(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
) {
  return _openKnowledgeNoteDocument(
    context,
    ref,
    note,
    KnowledgeExportFormat.markdown,
    isShare: true,
  );
}

Future<void> _manageKnowledgeTags(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
) async {
  final controller = ref.read(knowledgeLibraryControllerProvider);
  final tags = await showV3GlassBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _KnowledgeTagEditorSheet(
      noteTitle: note.title,
      initialTags: controller.effectiveTags(note),
      authorTags: note.isReadOnly ? note.topics : const <String>[],
    ),
  );
  if (tags == null || !context.mounted) return;
  final updated = controller.updateEffectiveTags(note.id, tags);
  if (!updated) {
    showV3Snack(context, '标签保存失败，请检查数量和长度');
    return;
  }
  final persisted = await controller.flushPersistenceResult();
  if (!context.mounted) return;
  showV3Snack(context, persisted ? '标签已更新' : '标签保存失败，请重试');
}

Future<void> _shareKnowledgeNote(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
) async {
  final controller = ref.read(knowledgeLibraryControllerProvider);
  final payload = KnowledgeSharePayload.fromNote(
    note,
    sourceLabel: _knowledgeSourceLabel(note.source),
    effectiveTags: controller.effectiveTags(note),
    publicUrl: note.publicUrl,
  );
  final result = await ref
      .read(knowledgeSharePortProvider)
      .shareKnowledge(payload);
  if (!context.mounted) return;
  if (!result.ok) {
    showV3Snack(context, '分享失败，请重试');
    return;
  }
  showV3Snack(context, result.value == true ? '已打开系统分享' : '已取消分享');
}

Future<void> _exportKnowledgeNote(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
) async {
  final format = await showV3ActionSheet<KnowledgeExportFormat>(
    context: context,
    title: '选择导出格式',
    items: const [
      V3ActionSheetItem(
        value: KnowledgeExportFormat.markdown,
        icon: Icons.code_rounded,
        label: 'Markdown',
        subtitle: '保留可继续编辑的文本结构',
      ),
      V3ActionSheetItem(
        value: KnowledgeExportFormat.pdf,
        icon: Icons.picture_as_pdf_outlined,
        label: 'PDF',
        subtitle: '适合阅读、打印和转发',
      ),
    ],
  );
  if (format == null || !context.mounted) return;

  await _openKnowledgeNoteDocument(context, ref, note, format);
}

Future<void> _openKnowledgeNoteDocument(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
  KnowledgeExportFormat format, {
  bool isShare = false,
}) async {
  final controller = ref.read(knowledgeLibraryControllerProvider);
  if (!note.isReadOnly) {
    await controller.refreshRemoteDerivedParts(note.id);
  }
  if (!context.mounted) return;
  final exportNote = controller.noteForId(note.id) ?? note;
  final document = KnowledgeExportDocument.fromNote(
    exportNote,
    sourceLabel: _knowledgeSourceLabel(exportNote.source),
    effectiveTags: controller.effectiveTags(exportNote),
  );
  showV3Snack(context, '正在准备${format.label}文件');
  final service = ref.read(knowledgeDocumentExportServiceProvider);
  final preparedResult = await service.prepare(document, format);
  final prepared = preparedResult.value;
  if (!context.mounted) {
    if (prepared != null) await service.discard(prepared);
    return;
  }
  if (!preparedResult.ok || prepared == null) {
    showV3Snack(context, '${isShare ? '分享' : '导出'}文件生成失败，请重试');
    return;
  }

  final openResult = await ref
      .read(nativePreparedDocumentExportPortProvider)
      .openPreparedKnowledgeExport(
        opaqueExportRef: prepared.opaqueExportRef,
        displayName: prepared.displayName,
        mimeType: prepared.mimeType,
      );
  if (!openResult.ok || openResult.value != true) {
    await service.discard(prepared);
  }
  if (!context.mounted) return;
  if (!openResult.ok) {
    showV3Snack(context, '无法打开系统应用，请重试');
    return;
  }
  if (openResult.value != true) {
    showV3Snack(context, '已取消${isShare ? '分享' : '导出'}');
    return;
  }
  showV3Snack(context, isShare ? '已打开系统分享' : '已打开系统方式选择');
}

Future<void> _syncNote(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
) async {
  final controller = ref.read(knowledgeLibraryControllerProvider);
  final result = await controller.syncNote(note.id);
  if (!context.mounted) return;
  if (result.outcome == KnowledgeNoteSyncOutcome.conflict) {
    await _resolveNoteConflict(context, ref, result.note ?? note);
    return;
  }
  _showSyncResult(context, result);
}

Future<void> _resolveNoteConflict(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
) async {
  final controller = ref.read(knowledgeLibraryControllerProvider);
  var conflict = controller.conflictFor(note.id);
  if (conflict == null) {
    final refreshed = await controller.syncNote(note.id);
    if (!context.mounted) return;
    conflict = refreshed.conflict;
    if (conflict == null) {
      _showSyncResult(context, refreshed);
      return;
    }
  }

  final resolution = await showDialog<KnowledgeNoteConflictResolution>(
    context: context,
    builder: (dialogContext) => _KnowledgeConflictDialog(conflict: conflict!),
  );
  if (resolution == null || !context.mounted) return;
  final result = await controller.resolveConflict(note.id, resolution);
  if (!context.mounted) return;
  if (resolution == KnowledgeNoteConflictResolution.keepLocal &&
      result.outcome == KnowledgeNoteSyncOutcome.unavailable) {
    showV3Snack(context, '已保留本地版本；同步服务暂不可用，笔记仍待同步');
    return;
  }
  _showSyncResult(context, result);
}

void _showSyncResult(BuildContext context, KnowledgeNoteSyncResult result) {
  final message = switch (result.outcome) {
    KnowledgeNoteSyncOutcome.synced => '笔记已同步',
    KnowledgeNoteSyncOutcome.conflict => '检测到远端冲突，请选择保留版本',
    KnowledgeNoteSyncOutcome.unavailable => '同步服务暂不可用，本地版本已保留',
    KnowledgeNoteSyncOutcome.failed =>
      '同步失败，本地版本已保留（${result.errorCode ?? 'UNKNOWN'}）',
    KnowledgeNoteSyncOutcome.notEditable => '该笔记不可同步或已不存在',
    KnowledgeNoteSyncOutcome.superseded => '同步期间笔记已更新，旧响应未覆盖本地内容',
  };
  showV3Snack(context, message);
}

Future<void> _renameNote(
  BuildContext context,
  WidgetRef ref,
  V3FeedItem note,
) async {
  final title = await showV3TextInputSheet(
    context: context,
    title: '重命名笔记',
    initialValue: note.title,
    label: '笔记标题',
    maxLength: 20,
    prefixIcon: Icons.edit_outlined,
    inputKey: const ValueKey('knowledge-rename-input'),
    validator: (value) => value.isEmpty ? '请输入笔记名称' : null,
  );
  if (title == null || !context.mounted) return;
  final controller = ref.read(knowledgeLibraryControllerProvider);
  final renamed = controller.renameNote(id: note.id, title: title);
  if (renamed == null) {
    showV3Snack(context, '标题不能为空，或该笔记不可编辑');
    return;
  }
  final persisted = await controller.flushPersistenceResult();
  if (!context.mounted) return;
  showV3Snack(context, persisted ? '已重命名，等待同步' : '本地保存失败，请重试');
}

class _KnowledgeConflictDialog extends StatelessWidget {
  const _KnowledgeConflictDialog({required this.conflict});

  final KnowledgeNoteConflictSnapshot conflict;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3GlassDialogFrame(
      title: '选择笔记版本',
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '远端内容已在你编辑期间发生变化。请选择一个版本，系统不会自动覆盖本地草稿。',
              style: TextStyle(color: colors.muted, height: 1.45),
            ),
            const SizedBox(height: 14),
            _ConflictVersionPreview(
              key: const ValueKey('knowledge-conflict-local'),
              label: '本地版本',
              note: conflict.localNote,
            ),
            const SizedBox(height: 10),
            _ConflictVersionPreview(
              key: const ValueKey('knowledge-conflict-remote'),
              label: '远端版本',
              note: conflict.remoteNote,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('knowledge-conflict-use-remote'),
          onPressed: () => Navigator.of(
            context,
          ).pop(KnowledgeNoteConflictResolution.useRemote),
          child: const Text('使用远端版本'),
        ),
        FilledButton(
          key: const ValueKey('knowledge-conflict-keep-local'),
          onPressed: () => Navigator.of(
            context,
          ).pop(KnowledgeNoteConflictResolution.keepLocal),
          child: const Text('保留本地版本'),
        ),
      ],
    );
  }
}

class _ConflictVersionPreview extends StatelessWidget {
  const _ConflictVersionPreview({
    required this.label,
    required this.note,
    super.key,
  });

  final String label;
  final V3FeedItem note;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              _conflictBodyPreview(note.rawBody),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.muted,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _conflictBodyPreview(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  return normalized.isEmpty ? '无正文' : normalized;
}

String v3KnowledgeFormatDate(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

String _knowledgeSourceLabel(V3MaterialSource source) => source.label;
