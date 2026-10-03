import '../../../shared/markdown/v3_markdown.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../application/subscription_port.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';

import 'v3_knowledge_local_surfaces.dart';
import 'v3_knowledge_remote_detail.dart';

typedef _ScaledPageRailItemBuilder<T> =
    Widget Function(
      BuildContext context,
      T item,
      int index,
      double emphasis,
      VoidCallback onTap,
    );

class _ScaledPageRail<T> extends StatelessWidget {
  const _ScaledPageRail({
    required this.items,
    required this.itemId,
    required this.activeItemId,
    required this.onActiveItemChanged,
    required this.onOpen,
    required this.expandedSize,
    required this.collapsedSize,
    required this.collapsedTopInset,
    required this.height,
    required this.pageViewKey,
    required this.itemBuilder,
    this.spacing = 12,
  });

  final List<T> items;
  final String Function(T item) itemId;
  final String? activeItemId;
  final ValueChanged<T> onActiveItemChanged;
  final ValueChanged<T> onOpen;
  final Size expandedSize;
  final Size collapsedSize;
  final double collapsedTopInset;
  final double height;
  final double spacing;
  final Key pageViewKey;
  final _ScaledPageRailItemBuilder<T> itemBuilder;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return SizedBox(height: height);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final reservedPeek = items.length > 1 ? 40.0 : 0.0;
        final expandedWidth = math.min(
          expandedSize.width,
          math.max(1.0, maxWidth - spacing - reservedPeek),
        );
        final collapsedWidth = math.min(collapsedSize.width, expandedWidth);
        final resolvedExpanded = Size(expandedWidth, expandedSize.height);
        final resolvedCollapsed = Size(collapsedWidth, collapsedSize.height);
        final fraction = ((expandedWidth + spacing) / maxWidth)
            .clamp(.01, 1.0)
            .toDouble();
        return SizedBox(
          height: height,
          child: _ScaledPageRailViewport<T>(
            items: items,
            itemId: itemId,
            activeItemId: activeItemId,
            onActiveItemChanged: onActiveItemChanged,
            onOpen: onOpen,
            expandedSize: resolvedExpanded,
            collapsedSize: resolvedCollapsed,
            collapsedTopInset: collapsedTopInset,
            viewportFraction: fraction,
            pageViewKey: pageViewKey,
            itemBuilder: itemBuilder,
          ),
        );
      },
    );
  }
}

class _ScaledPageRailViewport<T> extends StatefulWidget {
  const _ScaledPageRailViewport({
    required this.items,
    required this.itemId,
    required this.activeItemId,
    required this.onActiveItemChanged,
    required this.onOpen,
    required this.expandedSize,
    required this.collapsedSize,
    required this.collapsedTopInset,
    required this.viewportFraction,
    required this.pageViewKey,
    required this.itemBuilder,
  });

  final List<T> items;
  final String Function(T item) itemId;
  final String? activeItemId;
  final ValueChanged<T> onActiveItemChanged;
  final ValueChanged<T> onOpen;
  final Size expandedSize;
  final Size collapsedSize;
  final double collapsedTopInset;
  final double viewportFraction;
  final Key pageViewKey;
  final _ScaledPageRailItemBuilder<T> itemBuilder;

  @override
  State<_ScaledPageRailViewport<T>> createState() =>
      _ScaledPageRailViewportState<T>();
}

class _ScaledPageRailViewportState<T>
    extends State<_ScaledPageRailViewport<T>> {
  late PageController _controller;
  late int _settledIndex;

  @override
  void initState() {
    super.initState();
    _settledIndex = _activeIndex(
      widget,
    ).clamp(0, widget.items.length - 1).toInt();
    _controller = _newController(_settledIndex);
  }

  @override
  void didUpdateWidget(covariant _ScaledPageRailViewport<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targetIndex = _activeIndex(
      widget,
    ).clamp(0, widget.items.length - 1).toInt();
    if ((oldWidget.viewportFraction - widget.viewportFraction).abs() > .0001) {
      _controller.dispose();
      _settledIndex = targetIndex;
      _controller = _newController(targetIndex);
      return;
    }
    if (targetIndex != _settledIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _moveTo(targetIndex);
      });
    }
  }

  PageController _newController(int initialPage) => PageController(
    initialPage: initialPage,
    viewportFraction: widget.viewportFraction,
  );

  int _activeIndex(_ScaledPageRailViewport<T> value) {
    final activeId = value.activeItemId;
    if (activeId == null) return 0;
    final index = value.items.indexWhere(
      (item) => value.itemId(item) == activeId,
    );
    return index < 0 ? 0 : index;
  }

  void _moveTo(int index) {
    if (!_controller.hasClients || index < 0 || index >= widget.items.length) {
      return;
    }
    final duration = V3MotionTokens.resolve(context, V3MotionTokens.reveal);
    if (duration == Duration.zero) {
      _controller.jumpToPage(index);
    } else {
      unawaited(
        _controller.animateToPage(
          index,
          duration: duration,
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  void _handleTap(int index, T item) {
    if (index != _settledIndex) {
      widget.onActiveItemChanged(item);
    }
    widget.onOpen(item);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return PageView.builder(
      key: widget.pageViewKey,
      controller: _controller,
      padEnds: false,
      allowImplicitScrolling: true,
      itemCount: widget.items.length,
      onPageChanged: (index) {
        _settledIndex = index;
        final item = widget.items[index];
        if (widget.itemId(item) != widget.activeItemId) {
          widget.onActiveItemChanged(item);
        }
      },
      itemBuilder: (context, index) {
        final item = widget.items[index];
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final page = _controller.hasClients
                ? (_controller.page ?? _settledIndex.toDouble())
                : _settledIndex.toDouble();
            final emphasis = reduceMotion
                ? (index == _settledIndex ? 1.0 : 0.0)
                : (1 - (page - index).abs()).clamp(0.0, 1.0).toDouble();
            final width = _lerp(
              widget.collapsedSize.width,
              widget.expandedSize.width,
              emphasis,
            );
            final height = _lerp(
              widget.collapsedSize.height,
              widget.expandedSize.height,
              emphasis,
            );
            final top = _lerp(widget.collapsedTopInset, 0, emphasis);
            return Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.only(top: top),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: widget.itemBuilder(
                    context,
                    item,
                    index,
                    emphasis,
                    () => _handleTap(index, item),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  double _lerp(double start, double end, double t) => start + (end - start) * t;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class V3RemoteSubscriptionsHome extends StatefulWidget {
  const V3RemoteSubscriptionsHome({
    required this.publications,
    required this.selectedPublicationId,
    required this.articles,
    required this.isArticleInFlight,
    required this.loadLeadAsset,
    required this.onSelected,
    required this.onManage,
    required this.onOpenPublication,
    required this.onOpenArticle,
    required this.onSaveArticle,
    this.refreshing = false,
    this.errorCode,
    this.onRetry,
    super.key,
  });

  final List<MobileSubscriptionPublication> publications;
  final String? selectedPublicationId;
  final List<V3RemoteKnowledgeArticleEntry> articles;
  final bool Function(String articleId) isArticleInFlight;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final ValueChanged<String> onSelected;
  final VoidCallback onManage;
  final bool refreshing;
  final String? errorCode;
  final VoidCallback? onRetry;
  final ValueChanged<MobileSubscriptionPublication> onOpenPublication;
  final ValueChanged<V3RemoteKnowledgeArticleEntry> onOpenArticle;
  final ValueChanged<V3RemoteKnowledgeArticleEntry> onSaveArticle;

  @override
  State<V3RemoteSubscriptionsHome> createState() =>
      _V3RemoteSubscriptionsHomeState();
}

class _V3RemoteSubscriptionsHomeState extends State<V3RemoteSubscriptionsHome> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<MobileSubscriptionPublication> get publications => widget.publications;
  String? get selectedPublicationId => widget.selectedPublicationId;
  List<V3RemoteKnowledgeArticleEntry> get articles => widget.articles;
  bool Function(String articleId) get isArticleInFlight =>
      widget.isArticleInFlight;
  V3KnowledgeArticleLeadAssetLoader get loadLeadAsset => widget.loadLeadAsset;
  ValueChanged<String> get onSelected => widget.onSelected;
  VoidCallback get onManage => widget.onManage;
  ValueChanged<MobileSubscriptionPublication> get onOpenPublication =>
      widget.onOpenPublication;
  ValueChanged<V3RemoteKnowledgeArticleEntry> get onOpenArticle =>
      widget.onOpenArticle;
  ValueChanged<V3RemoteKnowledgeArticleEntry> get onSaveArticle =>
      widget.onSaveArticle;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final selected = publications.firstWhere(
      (item) => item.publicationId == selectedPublicationId,
      orElse: () => publications.first,
    );
    final content = <Widget>[
      _KnowledgeCatalogStatus(
        refreshing: widget.refreshing,
        errorCode: widget.errorCode,
        onRetry: widget.onRetry,
        scope: 'remote-subscriptions',
      ),
      Text(
        'YOUR CHANNELS',
        style: TextStyle(
          color: colors.accent,
          fontSize: 10,
          height: 1.6,
          fontWeight: FontWeight.w500,
        ),
      ),
      Row(
        children: [
          Expanded(
            child: Text(
              '已订阅 ${publications.length} 个栏目',
              style: TextStyle(
                color: colors.ink,
                fontSize: 21,
                height: 1.48,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onManage,
            style: TextButton.styleFrom(
              backgroundColor: HuahuoV3Theme.semanticSurface(
                colors.accent,
                colors.surface,
              ),
              foregroundColor: colors.accent,
              minimumSize: const Size(58, 32),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: const Text('管理', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      const SizedBox(height: 10),
      _ScaledPageRail<MobileSubscriptionPublication>(
        items: publications,
        itemId: (publication) => publication.publicationId,
        activeItemId: selected.publicationId,
        onActiveItemChanged: (publication) =>
            onSelected(publication.publicationId),
        onOpen: onOpenPublication,
        expandedSize: const Size(248, 170),
        collapsedSize: const Size(164, 148),
        collapsedTopInset: 14,
        height: 178,
        pageViewKey: const ValueKey('remote-subscription-channel-carousel'),
        itemBuilder: (context, publication, index, emphasis, onTap) =>
            _RemoteSubscriptionChannelCard(
              key: ValueKey(
                'remote-subscribed-publication-${publication.publicationId}',
              ),
              publication: publication,
              assetIndex: _stableKnowledgeAssetIndex(publication.publicationId),
              loadLeadAsset: loadLeadAsset,
              prominence: emphasis,
              onTap: onTap,
            ),
      ),
      const SizedBox(height: 18),
      InkWell(
        key: const ValueKey('remote-subscribed-selected-publication'),
        onTap: () => onOpenPublication(selected),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Row(
            children: [
              ClipOval(
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: V3RemoteKnowledgePublicationCover(
                    key: ValueKey<String>(
                      'knowledge-selected-publication-cover-${selected.publicationId}',
                    ),
                    publication: selected,
                    fallbackAsset: _knowledgeChannelAsset(
                      _stableKnowledgeAssetIndex(selected.publicationId),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '今日更新 ${selected.articles.length} · ${selected.articleCount} 篇已收录',
                      style: TextStyle(color: colors.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Text(
                '查看栏目  ›',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
      Divider(height: 1, color: colors.line),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: Text(
              '最近更新',
              style: TextStyle(
                color: colors.ink,
                fontSize: 18,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            '${articles.length} 篇未读',
            style: TextStyle(color: colors.accent, fontSize: 12),
          ),
        ],
      ),
      const SizedBox(height: 4),
      if (articles.isEmpty)
        const V3SubscriptionRuntimeEmpty(followedOnly: true)
      else
        for (var index = 0; index < articles.length; index++)
          V3RemoteSubscriptionArticleTile(
            entry: articles[index],
            index: index,
            busy: isArticleInFlight(articles[index].article.id),
            loadLeadAsset: loadLeadAsset,
            onOpen: () => onOpenArticle(articles[index]),
            onSave: () => onSaveArticle(articles[index]),
          ),
    ];
    return V3InteractiveScrollbar(
      controller: _scrollController,
      child: ListView.builder(
        key: const PageStorageKey<String>('remote-subscriptions'),
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        itemCount: content.length,
        itemBuilder: (_, index) => content[index],
      ),
    );
  }
}

class _RemoteSubscriptionChannelCard extends StatelessWidget {
  const _RemoteSubscriptionChannelCard({
    required this.publication,
    required this.assetIndex,
    required this.loadLeadAsset,
    required this.prominence,
    required this.onTap,
    super.key,
  });

  final MobileSubscriptionPublication publication;
  final int assetIndex;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final double prominence;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final prominent = prominence >= .5;
    return Semantics(
      button: true,
      selected: prominent,
      label: '查看栏目：${publication.title}',
      child: Material(
        color: const Color(0xFF171513),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: [
                V3RemoteKnowledgePublicationCover(
                  key: ValueKey<String>(
                    'knowledge-subscription-publication-cover-${publication.publicationId}',
                  ),
                  publication: publication,
                  fallbackAsset: _knowledgeChannelAsset(assetIndex),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xC0000000)],
                      stops: [.35, 1],
                    ),
                  ),
                ),
                if (prominent)
                  Positioned(
                    left: 14,
                    top: 14,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .9),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        child: Text(
                          '今日更新 ${publication.articles.length}',
                          style: const TextStyle(
                            color: Color(0xFF171513),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: prominent ? 14 : 12,
                  right: prominent ? 14 : 12,
                  bottom: prominent ? 13 : 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        publication.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: prominent ? 19 : 16,
                          height: 1.45,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        prominent
                            ? (publication.summary?.trim().isNotEmpty == true
                                  ? publication.summary!.trim()
                                  : '产品、模型与真实案例')
                            : '今日更新',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xFFF2EEE8),
                          fontSize: prominent ? 12 : 11,
                        ),
                      ),
                    ],
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

String _knowledgeChannelAsset(int index) => switch (index % 4) {
  0 => 'assets/images/knowledge_channel_ai_depth.png',
  1 => 'assets/images/knowledge_channel_chinese_culture.png',
  2 => 'assets/images/knowledge_channel_health.png',
  _ => 'assets/images/knowledge_channel_business.png',
};

class V3SubscriptionRuntimeEmpty extends StatelessWidget {
  const V3SubscriptionRuntimeEmpty({required this.followedOnly, super.key});

  final bool followedOnly;

  @override
  Widget build(BuildContext context) => Center(
    key: const ValueKey('subscription-runtime-empty'),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(followedOnly ? '还没有订阅内容，可以去知识世界看看' : '知识世界暂无内容'),
    ),
  );
}

class V3RemoteKnowledgeWorldLoadingShell extends StatelessWidget {
  const V3RemoteKnowledgeWorldLoadingShell({
    this.errorCode,
    this.onRetry,
    super.key,
  });

  final String? errorCode;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return ListView(
      key: const PageStorageKey<String>('remote-knowledge-world-loading-shell'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
      children: [
        const TextField(
          key: ValueKey<String>('remote-knowledge-world-search'),
          contextMenuBuilder: V3TextEditing.buildContextMenu,
          enabled: false,
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            hintText: '搜索知识世界',
          ),
        ),
        const SizedBox(height: 10),
        const LinearProgressIndicator(
          key: ValueKey<String>('remote-knowledge-world-loading-progress'),
          minHeight: 2,
        ),
        const SizedBox(height: 14),
        const _KnowledgeSquarePlaceholder(
          key: ValueKey<String>('remote-knowledge-world-loading-hero'),
          height: 176,
        ),
        const SizedBox(height: 18),
        GridView.builder(
          key: const ValueKey<String>('remote-knowledge-world-loading-grid'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 10,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            mainAxisSpacing: 10,
            crossAxisSpacing: 6,
            childAspectRatio: .82,
          ),
          itemBuilder: (_, __) => const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _KnowledgeSquarePlaceholder(height: 42, circular: true),
              SizedBox(height: 7),
              _KnowledgeSquarePlaceholder(height: 10, width: 42),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          '其他',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        for (var index = 0; index < 3; index += 1) ...[
          const _KnowledgeSquarePlaceholder(height: 72),
          if (index != 2) const SizedBox(height: 10),
        ],
        if (errorCode != null) ...[
          const SizedBox(height: 16),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_outlined, color: colors.muted, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      v3SubscriptionFailureMessage(errorCode),
                      style: TextStyle(color: colors.muted, fontSize: 13),
                    ),
                  ),
                  if (onRetry != null)
                    IconButton(
                      key: const ValueKey<String>(
                        'remote-knowledge-world-retry',
                      ),
                      tooltip: '重试',
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _KnowledgeSquarePlaceholder extends StatelessWidget {
  const _KnowledgeSquarePlaceholder({
    required this.height,
    this.width,
    this.circular = false,
    super.key,
  });

  final double height;
  final double? width;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          shape: circular ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circular ? null : BorderRadius.circular(6),
        ),
      ),
    );
  }
}

class _KnowledgeWorldSearchField extends StatelessWidget {
  const _KnowledgeWorldSearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      height: 42,
      child: TextField(
        key: const ValueKey<String>('remote-knowledge-world-search'),
        contextMenuBuilder: V3TextEditing.buildContextMenu,
        onChanged: onChanged,
        textAlignVertical: TextAlignVertical.center,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          prefixIconConstraints: const BoxConstraints.tightFor(
            width: 42,
            height: 42,
          ),
          hintText: '搜索栏目、行业或文章',
          hintStyle: TextStyle(color: colors.muted, fontSize: 14),
          filled: true,
          fillColor: colors.surfaceMuted,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          contentPadding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(height: 42),
        ),
      ),
    );
  }
}

class V3RemoteKnowledgeWorldHome extends StatefulWidget {
  const V3RemoteKnowledgeWorldHome({
    required this.publications,
    required this.query,
    required this.actionInFlight,
    required this.isArticleInFlight,
    required this.loadLeadAsset,
    required this.onQueryChanged,
    required this.onToggleFollow,
    required this.onOpenArticle,
    required this.onSaveArticle,
    this.refreshing = false,
    this.errorCode,
    this.onRetry,
    super.key,
  });

  final List<MobileSubscriptionPublication> publications;
  final String query;
  final bool Function(String) actionInFlight;
  final bool Function(String) isArticleInFlight;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final ValueChanged<String> onQueryChanged;
  final Future<void> Function(String publicationId) onToggleFollow;
  final Future<void> Function(V3FeedItem article) onOpenArticle;
  final Future<void> Function(V3FeedItem article) onSaveArticle;
  final bool refreshing;
  final String? errorCode;
  final VoidCallback? onRetry;

  @override
  State<V3RemoteKnowledgeWorldHome> createState() =>
      _V3RemoteKnowledgeWorldHomeState();
}

class _V3RemoteKnowledgeWorldHomeState
    extends State<V3RemoteKnowledgeWorldHome> {
  final math.Random _random = math.Random();
  final _scrollController = ScrollController();
  String? _todayActiveArticleId;
  String? _editorActivePublicationId;
  String? _randomArticleId;

  @override
  void initState() {
    super.initState();
    _reconcileSelections();
  }

  @override
  void didUpdateWidget(covariant V3RemoteKnowledgeWorldHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcileSelections();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<MobileSubscriptionPublication> get _publications =>
      uniqueV3RemoteKnowledgePublications(widget.publications);

  List<V3RemoteKnowledgeArticleEntry> get _latestPool =>
      v3RemoteKnowledgeArticles(_publications).take(30).toList(growable: false);

  void _reconcileSelections() {
    final publications = _publications;
    final latest = _latestPool;
    if (!publications.any(
      (item) => item.publicationId == _editorActivePublicationId,
    )) {
      _editorActivePublicationId = publications.firstOrNull?.publicationId;
    }
    if (!latest.any((entry) => entry.article.id == _todayActiveArticleId)) {
      _todayActiveArticleId = latest.firstOrNull?.article.id;
    }
    if (!latest.any((entry) => entry.article.id == _randomArticleId)) {
      final catalogIdentity = latest.map((entry) => entry.article.id).join('|');
      _randomArticleId = latest.isEmpty
          ? null
          : latest[_stableKnowledgeAssetIndex(catalogIdentity) % latest.length]
                .article
                .id;
    }
  }

  void _advanceEditor(List<MobileSubscriptionPublication> publications) {
    if (publications.length < 2) return;
    final current = publications.indexWhere(
      (item) => item.publicationId == _editorActivePublicationId,
    );
    final next = current < 0 ? 0 : (current + 1) % publications.length;
    setState(
      () => _editorActivePublicationId = publications[next].publicationId,
    );
  }

  void _replaceRandomArticle(List<V3RemoteKnowledgeArticleEntry> latest) {
    if (latest.isEmpty) return;
    final candidates = latest
        .where((entry) => entry.article.id != _randomArticleId)
        .toList(growable: false);
    final pool = candidates.isEmpty ? latest : candidates;
    setState(
      () => _randomArticleId = pool[_random.nextInt(pool.length)].article.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final uniquePublications = _publications;
    if (uniquePublications.isEmpty) {
      return V3InteractiveScrollbar(
        controller: _scrollController,
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 36),
          children: [
            _KnowledgeWorldSearchField(onChanged: widget.onQueryChanged),
            const SizedBox(height: 22),
            const V3KnowledgeEmptyState(tab: V3KnowledgeLibraryTab.square),
          ],
        ),
      );
    }
    final latest = _latestPool;
    final todayEntries = latest.take(5).toList(growable: false);
    final recent = v3RemoteKnowledgeArticles(
      uniquePublications,
      query: widget.query,
    );
    final randomEntry = latest
        .where((entry) => entry.article.id == _randomArticleId)
        .firstOrNull;
    final searching = widget.query.trim().isNotEmpty;
    final effectiveTextScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 1.3).toDouble();
    final editorCardHeight = 208 + (effectiveTextScale - 1) * 88;
    final editorRailHeight = editorCardHeight + 12;
    final content = <Widget>[
      _KnowledgeWorldSearchField(onChanged: widget.onQueryChanged),
      _KnowledgeCatalogStatus(
        refreshing: widget.refreshing,
        errorCode: widget.errorCode,
        onRetry: widget.onRetry,
        scope: 'remote-knowledge-world',
      ),
      const SizedBox(height: 16),
      if (!searching) ...[
        if (todayEntries.isEmpty)
          const V3KnowledgeEmptyState(tab: V3KnowledgeLibraryTab.square)
        else
          _ScaledPageRail<V3RemoteKnowledgeArticleEntry>(
            items: todayEntries,
            itemId: (entry) => entry.article.id,
            activeItemId: _todayActiveArticleId,
            onActiveItemChanged: (entry) =>
                setState(() => _todayActiveArticleId = entry.article.id),
            onOpen: (entry) => _showKnowledgeHeroPreview(
              context,
              entry: entry,
              loadLeadAsset: widget.loadLeadAsset,
              onOpen: () => widget.onOpenArticle(entry.article),
            ),
            expandedSize: const Size(318, 214),
            collapsedSize: const Size(190, 186),
            collapsedTopInset: 14,
            height: 224,
            pageViewKey: const ValueKey(
              'remote-knowledge-world-today-carousel',
            ),
            itemBuilder: (context, entry, index, emphasis, onTap) =>
                _KnowledgeTodayRecommendation(
                  key: ValueKey<String>(
                    'remote-knowledge-world-hero-${entry.article.id}',
                  ),
                  entry: entry,
                  loadLeadAsset: widget.loadLeadAsset,
                  prominence: emphasis,
                  onOpen: onTap,
                ),
          ),
        const SizedBox(height: 20),
        _KnowledgeSectionHeader(
          title: '编辑推荐',
          actionLabel: '换一换  ↻',
          onAction: () => _advanceEditor(uniquePublications),
        ),
        const SizedBox(height: 10),
        _ScaledPageRail<MobileSubscriptionPublication>(
          items: uniquePublications,
          itemId: (publication) => publication.publicationId,
          activeItemId: _editorActivePublicationId,
          onActiveItemChanged: (publication) => setState(
            () => _editorActivePublicationId = publication.publicationId,
          ),
          onOpen: (publication) => pushV3RemoteKnowledgeWorldDetail(
            context,
            publicationId: publication.publicationId,
          ),
          expandedSize: Size(222, editorCardHeight),
          collapsedSize: Size(190, editorCardHeight),
          collapsedTopInset: 0,
          height: editorRailHeight,
          pageViewKey: const ValueKey(
            'remote-knowledge-world-publication-grid',
          ),
          itemBuilder: (context, publication, index, emphasis, onTap) =>
              _KnowledgeEditorPublicationCard(
                key: ValueKey(
                  'remote-knowledge-world-editor-${publication.publicationId}',
                ),
                publication: publication,
                assetIndex: _stableKnowledgeAssetIndex(
                  publication.publicationId,
                ),
                loadLeadAsset: widget.loadLeadAsset,
                prominence: emphasis,
                busy: widget.actionInFlight(publication.publicationId),
                onOpen: onTap,
                onToggle: () =>
                    widget.onToggleFollow(publication.publicationId),
              ),
        ),
        const SizedBox(height: 22),
        _KnowledgeSectionHeader(
          title: '随手读一篇',
          actionLabel: '换一篇  ↻',
          onAction: () => _replaceRandomArticle(latest),
        ),
        const SizedBox(height: 10),
        if (randomEntry != null)
          _KnowledgeRandomArticleCard(
            key: ValueKey<String>(
              'remote-knowledge-world-random-${randomEntry.article.id}',
            ),
            entry: randomEntry,
            loadLeadAsset: widget.loadLeadAsset,
            onOpen: () => widget.onOpenArticle(randomEntry.article),
          ),
        const SizedBox(height: 22),
        V3SectionTitle('全部栏目', subtitle: '共 ${uniquePublications.length} 个栏目'),
        _RemoteKnowledgePublicationList(
          listKey: const ValueKey('remote-knowledge-world-catalog-list'),
          itemKeyPrefix: 'remote-knowledge-world-catalog-',
          publications: uniquePublications,
          loadLeadAsset: widget.loadLeadAsset,
          onOpenPublication: (publication) => pushV3RemoteKnowledgeWorldDetail(
            context,
            publicationId: publication.publicationId,
          ),
        ),
      ] else ...[
        _KnowledgeSectionHeader(
          title: '搜索结果',
          actionLabel: '查看全部',
          onAction: () =>
              pushV3RemoteKnowledgeWorldDetail(context, query: widget.query),
        ),
        const SizedBox(height: 6),
        _RemoteKnowledgePublicationList(
          listKey: const ValueKey(
            'remote-knowledge-world-overflow-publication-list',
          ),
          itemKeyPrefix: 'remote-knowledge-world-overflow-publication-',
          publications: uniquePublications,
          loadLeadAsset: widget.loadLeadAsset,
          onOpenPublication: (publication) => pushV3RemoteKnowledgeWorldDetail(
            context,
            publicationId: publication.publicationId,
          ),
        ),
        for (final entry in recent.take(30))
          V3RemoteKnowledgeArticleRow(
            entry: entry,
            busy: widget.isArticleInFlight(entry.article.id),
            loadLeadAsset: widget.loadLeadAsset,
            onOpen: () => widget.onOpenArticle(entry.article),
            onSave: () => widget.onSaveArticle(entry.article),
          ),
      ],
    ];
    return V3InteractiveScrollbar(
      controller: _scrollController,
      child: ListView.builder(
        key: const PageStorageKey<String>('remote-knowledge-world-home'),
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 36),
        itemCount: content.length,
        itemBuilder: (_, index) => content[index],
      ),
    );
  }
}

class _KnowledgeSectionHeader extends StatelessWidget {
  const _KnowledgeSectionHeader({
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 34),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: colors.ink,
                fontSize: 18,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: colors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(60, 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(actionLabel, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _KnowledgeTodayRecommendation extends StatelessWidget {
  const _KnowledgeTodayRecommendation({
    required this.entry,
    required this.loadLeadAsset,
    required this.prominence,
    required this.onOpen,
    super.key,
  });

  final V3RemoteKnowledgeArticleEntry entry;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final double prominence;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final article = entry.article;
    final publication = entry.publication;
    final prominent = prominence >= .5;
    return Semantics(
      button: true,
      selected: prominent,
      label: '今日推荐：${article.title}',
      child: Material(
        color: const Color(0xFF171513),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: [
                V3RemoteKnowledgeArticleCover(
                  key: ValueKey<String>('knowledge-today-cover-${article.id}'),
                  article: article,
                  loadLeadAsset: loadLeadAsset,
                  fallbackAsset: _knowledgeEditorAsset(
                    _stableKnowledgeAssetIndex(article.id),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xD0171513)],
                      stops: [.35, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: prominent ? 16 : 12,
                  top: prominent ? 16 : 12,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .9),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(
                        '今日推荐',
                        style: TextStyle(
                          color: Color(0xFF171513),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: prominent ? 16 : 12,
                  right: prominent ? 16 : 12,
                  bottom: prominent ? 12 : 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${publication.title} · 深度文章',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFF1ECE6),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        article.title,
                        maxLines: prominent ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: prominent ? 20 : 16,
                          height: 1.4,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (prominent)
                        const Text(
                          '8 分钟阅读  ·  编辑精选',
                          style: TextStyle(
                            color: Color(0xFFF1ECE6),
                            fontSize: 11,
                          ),
                        ),
                    ],
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

Future<void> _showKnowledgeHeroPreview(
  BuildContext context, {
  required V3RemoteKnowledgeArticleEntry entry,
  required V3KnowledgeArticleLeadAssetLoader loadLeadAsset,
  required VoidCallback onOpen,
}) {
  final publication = entry.publication;
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (previewContext) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            V3RemoteKnowledgeArticleCover(
              key: ValueKey<String>(
                'knowledge-hero-preview-cover-${entry.article.id}',
              ),
              article: entry.article,
              loadLeadAsset: loadLeadAsset,
              fallbackAsset: _knowledgeEditorAsset(
                _stableKnowledgeAssetIndex(entry.article.id),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x22000000), Color(0xDD000000)],
                  stops: [.3, 1],
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .92),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            child: Text('今日推荐', style: TextStyle(fontSize: 11)),
                          ),
                        ),
                        const Spacer(),
                        IconButton.filled(
                          key: const ValueKey('knowledge-hero-preview-close'),
                          tooltip: '关闭',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: () => Navigator.pop(previewContext),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) => SingleChildScrollView(
                          key: const ValueKey('knowledge-hero-preview-scroll'),
                          reverse: true,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: constraints.maxHeight,
                            ),
                            child: IntrinsicHeight(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    publication.title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    publication.summary ?? '产品、模型与真实案例',
                                    style: const TextStyle(
                                      color: Color(0xFFEDE8E2),
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 72,
                                    ),
                                    child: SingleChildScrollView(
                                      primary: false,
                                      physics:
                                          const NeverScrollableScrollPhysics(),
                                      child: Theme(
                                        data: HuahuoV3Theme.dark(),
                                        child: IgnorePointer(
                                          child: V3AssistantReplyMarkdown(
                                            source:
                                                entry.article.summaryBody ??
                                                '精选栏目内容，帮助你建立清晰的判断。',
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  SizedBox(
                                    width: double.infinity,
                                    height: 48,
                                    child: FilledButton(
                                      key: const ValueKey(
                                        'knowledge-hero-preview-open',
                                      ),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        foregroundColor: const Color(
                                          0xFF9B6222,
                                        ),
                                      ),
                                      onPressed: () {
                                        Navigator.pop(previewContext);
                                        onOpen();
                                      },
                                      child: const Text('阅读文章'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
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

class _KnowledgeEditorPublicationCard extends StatelessWidget {
  const _KnowledgeEditorPublicationCard({
    required this.publication,
    required this.assetIndex,
    required this.loadLeadAsset,
    required this.prominence,
    required this.busy,
    required this.onOpen,
    required this.onToggle,
    super.key,
  });

  final MobileSubscriptionPublication publication;
  final int assetIndex;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final double prominence;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final prominent = prominence >= .5;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(8),
      elevation: 2,
      shadowColor: const Color(0x142E241A),
      clipBehavior: Clip.antiAlias,
      child: SizedBox.expand(
        child: InkWell(
          onTap: onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                height: 99,
                child: V3RemoteKnowledgePublicationCover(
                  key: ValueKey<String>(
                    'knowledge-editor-publication-cover-${publication.publicationId}',
                  ),
                  publication: publication,
                  fallbackAsset: _knowledgeEditorAsset(assetIndex),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Text(
                  prominent ? '编辑精选' : '精选栏目',
                  style: TextStyle(
                    color: colors.accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  publication.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 16,
                    height: 1.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  publication.summary ?? '真实内容与深度案例',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.muted, fontSize: 11),
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 8, 7),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${v3KnowledgeFormatDate(publication.updatedAt)} · ${publication.articleCount} 篇',
                        style: TextStyle(color: colors.muted, fontSize: 10),
                      ),
                    ),
                    IconButton(
                      tooltip: publication.followed ? '取消订阅' : '订阅',
                      visualDensity: VisualDensity.compact,
                      onPressed: busy ? null : onToggle,
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              publication.followed
                                  ? Icons.check_rounded
                                  : Icons.add_rounded,
                              color: colors.accent,
                              size: 18,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KnowledgeRandomArticleCard extends StatelessWidget {
  const _KnowledgeRandomArticleCard({
    required this.entry,
    required this.loadLeadAsset,
    required this.onOpen,
    super.key,
  });

  final V3RemoteKnowledgeArticleEntry entry;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final article = entry.article;
    final summary = article.summaryBody?.trim().isNotEmpty == true
        ? article.summaryBody!.trim()
        : article.rawBody.trim();
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 1.3).toDouble();
    final resolvedHeight = 208 + (textScale - 1) * 280;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 148,
              child: V3RemoteKnowledgeArticleCover(
                key: ValueKey<String>('knowledge-random-cover-${article.id}'),
                article: article,
                loadLeadAsset: loadLeadAsset,
                fallbackAsset: 'assets/images/knowledge_random_business.png',
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 148),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: resolvedHeight),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 14, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${entry.publication.title} · 深度文章',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.accent,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            article.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: 17,
                              height: 1.52,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            summary,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 12,
                              height: 1.65,
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '6 分钟阅读  ·  今日',
                          style: TextStyle(color: colors.muted, fontSize: 10),
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
    );
  }
}

String _knowledgeEditorAsset(int index) => switch (index % 3) {
  0 => 'assets/images/knowledge_today_ai.png',
  1 => 'assets/images/knowledge_channel_law.png',
  _ => 'assets/images/knowledge_channel_wellness.png',
};

int _stableKnowledgeAssetIndex(String value) {
  var result = 0;
  for (final unit in value.codeUnits) {
    result = (result * 31 + unit) & 0x7fffffff;
  }
  return result;
}

class _KnowledgeCatalogStatus extends StatelessWidget {
  const _KnowledgeCatalogStatus({
    required this.refreshing,
    required this.errorCode,
    required this.onRetry,
    required this.scope,
  });

  final bool refreshing;
  final String? errorCode;
  final VoidCallback? onRetry;
  final String scope;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (refreshing) ...[
        const SizedBox(height: 10),
        LinearProgressIndicator(
          key: ValueKey('$scope-refreshing'),
          minHeight: 2,
        ),
      ],
      if (errorCode != null) ...[
        const SizedBox(height: 10),
        _RemoteKnowledgeWorldErrorStrip(
          errorCode: errorCode,
          onRetry: onRetry,
          retryKey: ValueKey('$scope-retry'),
        ),
      ],
    ],
  );
}

class _RemoteKnowledgeWorldErrorStrip extends StatelessWidget {
  const _RemoteKnowledgeWorldErrorStrip({
    required this.errorCode,
    this.onRetry,
    required this.retryKey,
  });

  final String? errorCode;
  final VoidCallback? onRetry;
  final Key retryKey;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                v3SubscriptionFailureMessage(errorCode),
                style: TextStyle(color: colors.muted, fontSize: 13),
              ),
            ),
            if (onRetry != null)
              IconButton(
                key: retryKey,
                tooltip: '重试',
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _RemoteKnowledgePublicationList extends StatelessWidget {
  const _RemoteKnowledgePublicationList({
    required this.listKey,
    required this.itemKeyPrefix,
    required this.publications,
    required this.loadLeadAsset,
    required this.onOpenPublication,
  });

  final Key listKey;
  final String itemKeyPrefix;
  final List<MobileSubscriptionPublication> publications;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final ValueChanged<MobileSubscriptionPublication> onOpenPublication;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return ListView.separated(
      key: listKey,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: publications.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: colors.line),
      itemBuilder: (context, index) {
        final publication = publications[index];
        final latestArticle = _latestRemoteKnowledgeArticle(publication);
        final supportingText = _remotePublicationListSupportingText(
          publication,
          latestArticle,
        );
        final available = publication.available;
        return Semantics(
          button: available,
          label: '查看频道：${publication.title}',
          child: InkWell(
            key: ValueKey('$itemKeyPrefix${publication.publicationId}'),
            onTap: available ? () => onOpenPublication(publication) : null,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: V3RemoteKnowledgePublicationCover(
                        key: ValueKey<String>(
                          'knowledge-search-publication-cover-${publication.publicationId}',
                        ),
                        publication: publication,
                        fallbackAsset: _knowledgeEditorAsset(
                          _stableKnowledgeAssetIndex(publication.publicationId),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${publication.title} · '
                          '${v3KnowledgeFormatDate(publication.updatedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.muted, fontSize: 11.5),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          publication.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.25,
                            fontWeight: FontWeight.w700,
                            color: available ? colors.text : colors.muted,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          supportingText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.muted, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: available ? colors.muted : colors.line,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

V3FeedItem? _latestRemoteKnowledgeArticle(
  MobileSubscriptionPublication publication,
) {
  V3FeedItem? latest;
  for (final article in publication.articles) {
    if (latest == null || article.updatedAt.isAfter(latest.updatedAt)) {
      latest = article;
    }
  }
  return latest;
}

String _remotePublicationListSupportingText(
  MobileSubscriptionPublication publication,
  V3FeedItem? latestArticle,
) {
  final articleSummary = latestArticle?.summaryBody?.trim();
  if (articleSummary?.isNotEmpty == true) return articleSummary!;
  final publicationSummary = publication.summary?.trim();
  if (publicationSummary?.isNotEmpty == true) return publicationSummary!;
  return '${publication.articleCount} 篇文章';
}
