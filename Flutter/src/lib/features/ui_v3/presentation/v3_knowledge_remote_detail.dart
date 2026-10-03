import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../application/knowledge_library_controller.dart';
import '../application/subscription_port.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';
import 'v3_deposit_picker.dart';

import 'v3_knowledge_local_surfaces.dart';
import 'v3_knowledge_publication_assets.dart';

String v3SubscriptionFailureMessage(String? errorCode) {
  return switch (errorCode) {
    'WORKSPACE_CONTEXT_UNAVAILABLE' => '当前工作区不可用，请重新登录后重试',
    'UNAUTHORIZED' || 'AUTH_SESSION_EXPIRED' => '登录状态已失效，请重新登录',
    'SUBSCRIPTION_CATALOG_NOT_FOUND' => '暂时没有可展示的知识广场内容',
    'SUBSCRIPTION_CATALOG_UNAVAILABLE' => '知识广场数据源暂不可用，请稍后重试',
    'SUBSCRIPTION_SOURCE_NOT_ACTIVE' => '知识广场数据源尚未激活，请稍后重试',
    'SUBSCRIPTION_ACTION_IN_PROGRESS' => '操作正在处理中',
    'SUBSCRIPTION_ARTICLE_REVISION_MISMATCH' => '文章已更新，请刷新后重试',
    'SUBSCRIPTION_SAVED_ASSET_DEPOSIT_FAILED' ||
    'SUBSCRIPTION_SAVED_ASSET_LOCAL_PERSIST_FAILED' => '云端笔记已创建，但我的资产尚未完成，请重试',
    _ => '订阅服务暂时不可用，请稍后重试',
  };
}

class _ScrollableSubscriptionSheet extends StatelessWidget {
  const _ScrollableSubscriptionSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final availableHeight =
        mediaQuery.size.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.padding.vertical;
    final maxHeight = (availableHeight * .88).clamp(
      0.0,
      mediaQuery.size.height,
    );
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          key: const ValueKey('subscription-sheet-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: child,
        ),
      ),
    );
  }
}

String _knowledgeArticleAsset(int index) => switch (index % 3) {
  0 => 'assets/images/knowledge_article_claude.png',
  1 => 'assets/images/knowledge_channel_business.png',
  _ => 'assets/images/knowledge_article_copyright.png',
};

typedef V3KnowledgeArticleLeadAssetLoader =
    Future<MobileSubscriptionArticleAssetResult> Function(String noteId);

class V3RemoteKnowledgeArticleCover extends StatefulWidget {
  const V3RemoteKnowledgeArticleCover({
    required this.article,
    required this.loadLeadAsset,
    required this.fallbackAsset,
    this.fit = BoxFit.cover,
    super.key,
  });

  final V3FeedItem article;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final String fallbackAsset;
  final BoxFit fit;

  @override
  State<V3RemoteKnowledgeArticleCover> createState() =>
      _V3RemoteKnowledgeArticleCoverState();
}

class _V3RemoteKnowledgeArticleCoverState
    extends State<V3RemoteKnowledgeArticleCover> {
  late Future<MobileSubscriptionArticleAssetResult> _asset;
  bool _hasRenderedImage = false;

  @override
  void initState() {
    super.initState();
    _asset = widget.loadLeadAsset(widget.article.id);
  }

  @override
  void didUpdateWidget(covariant V3RemoteKnowledgeArticleCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_articleIdentity(oldWidget.article) !=
            _articleIdentity(widget.article) ||
        oldWidget.loadLeadAsset != widget.loadLeadAsset) {
      _hasRenderedImage = false;
      _asset = widget.loadLeadAsset(widget.article.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback() => Image.asset(
      widget.fallbackAsset,
      fit: widget.fit,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: HuahuoV3Theme.tokensOf(context).surfaceMuted,
        child: Icon(
          Icons.image_not_supported_outlined,
          color: HuahuoV3Theme.tokensOf(context).muted,
        ),
      ),
    );
    final cacheWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, 2048);
    return FutureBuilder<MobileSubscriptionArticleAssetResult>(
      future: _asset,
      builder: (context, snapshot) {
        final result = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        final loaded = result?.status == MobileSubscriptionResultStatus.success
            ? result?.asset
            : null;
        if (loaded == null || loaded.bytes.isEmpty) return fallback();
        return Image.memory(
          loaded.bytes,
          key: ValueKey(_articleIdentity(widget.article)),
          fit: widget.fit,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, synchronous) {
            if (frame != null || synchronous) _hasRenderedImage = true;
            return _hasRenderedImage ? child : fallback();
          },
          errorBuilder: (_, __, ___) => fallback(),
        );
      },
    );
  }

  String _articleIdentity(V3FeedItem article) => <String>[
    article.id,
    article.articleId ?? '',
    article.articleRevisionId ?? '',
  ].join('|');
}

class V3RemoteKnowledgePublicationCover extends StatelessWidget {
  const V3RemoteKnowledgePublicationCover({
    required this.publication,
    required this.fallbackAsset,
    this.fit = BoxFit.cover,
    super.key,
  });

  final MobileSubscriptionPublication publication;
  final String fallbackAsset;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final asset = v3KnowledgePublicationAvatarAssets[publication.publicationId];
    Widget fallback() => Image.asset(
      fallbackAsset,
      fit: fit,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: HuahuoV3Theme.tokensOf(context).surfaceMuted,
        child: Icon(
          Icons.image_not_supported_outlined,
          color: HuahuoV3Theme.tokensOf(context).muted,
        ),
      ),
    );
    return Image.asset(
      asset ?? fallbackAsset,
      key: ValueKey<String>(
        'knowledge-publication-avatar-${publication.publicationId}',
      ),
      fit: fit,
      width: double.infinity,
      height: double.infinity,
      semanticLabel: '${publication.title}栏目头像',
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => fallback(),
    );
  }
}

class V3SubscriptionRuntimeError extends StatelessWidget {
  const V3SubscriptionRuntimeError({
    required this.errorCode,
    required this.unavailable,
    required this.onRetry,
    super.key,
  });

  final String? errorCode;
  final bool unavailable;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Center(
      key: const ValueKey('subscription-runtime-error'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 40, color: colors.muted),
            const SizedBox(height: 12),
            Text(
              unavailable ? '订阅服务尚未就绪' : '订阅内容加载失败',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              v3SubscriptionFailureMessage(errorCode),
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('subscription-runtime-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class V3RemoteSubscriptionArticleTile extends StatelessWidget {
  const V3RemoteSubscriptionArticleTile({
    required this.entry,
    required this.index,
    required this.busy,
    required this.loadLeadAsset,
    required this.onOpen,
    required this.onSave,
    super.key,
  });

  final V3RemoteKnowledgeArticleEntry entry;
  final int index;
  final bool busy;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final VoidCallback onOpen;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final article = entry.article;
    final preview = article.summaryBody?.trim().isNotEmpty == true
        ? article.summaryBody!.trim()
        : article.rawBody.trim();
    return InkWell(
      key: ValueKey('subscription-open-${article.id}'),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: index == 0 ? 126 : 94,
                height: index == 0 ? 104 : 84,
                child: V3RemoteKnowledgeArticleCover(
                  key: ValueKey<String>('subscription-cover-${article.id}'),
                  article: article,
                  loadLeadAsset: loadLeadAsset,
                  fallbackAsset: _knowledgeArticleAsset(index),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${entry.publication.title} · 深度文章 · ${v3KnowledgeFormatDate(article.updatedAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.muted, fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 15,
                      height: 1.45,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.muted, fontSize: 11),
                        ),
                      ),
                      IconButton(
                        key: ValueKey('subscription-save-${article.id}'),
                        tooltip: '沉淀到笔记',
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(
                          backgroundColor: colors.surfaceMuted,
                          minimumSize: const Size.square(32),
                          maximumSize: const Size.square(32),
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: busy ? null : onSave,
                        icon: busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                Icons.add_rounded,
                                color: colors.accent,
                                size: 20,
                              ),
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

class _RemoteKnowledgeChannelDetailSurface extends StatefulWidget {
  const _RemoteKnowledgeChannelDetailSurface({
    required this.publication,
    required this.entries,
    required this.actionInFlight,
    required this.isArticleInFlight,
    required this.loadLeadAsset,
    required this.onToggleFollow,
    required this.onOpenArticle,
    required this.onSaveArticle,
  });

  final MobileSubscriptionPublication publication;
  final List<V3RemoteKnowledgeArticleEntry> entries;
  final bool actionInFlight;
  final bool Function(String) isArticleInFlight;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final Future<void> Function() onToggleFollow;
  final Future<void> Function(V3FeedItem) onOpenArticle;
  final Future<void> Function(V3FeedItem) onSaveArticle;

  @override
  State<_RemoteKnowledgeChannelDetailSurface> createState() =>
      _RemoteKnowledgeChannelDetailSurfaceState();
}

class _RemoteKnowledgeChannelDetailSurfaceState
    extends State<_RemoteKnowledgeChannelDetailSurface> {
  final _scrollController = ScrollController();
  bool _depth = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final canvas = colors.canvas;
    final entries = widget.entries
        .where((entry) => !_depth || _isDepthArticle(entry.article))
        .toList(growable: false);
    entries.sort(_compareRemoteKnowledgeEntriesNewestFirst);
    final heroAsset = widget.publication.title.contains('文化')
        ? 'assets/images/knowledge_today_city.png'
        : 'assets/images/knowledge_today_ai.png';
    final featuredAsset = widget.publication.title.contains('文化')
        ? 'assets/images/knowledge_channel_law.png'
        : 'assets/images/knowledge_article_claude.png';
    final featured = entries.firstOrNull;
    final content = <Widget>[
      SizedBox(
        height: 218,
        child: Stack(
          fit: StackFit.expand,
          children: [
            V3RemoteKnowledgePublicationCover(
              key: ValueKey<String>(
                'knowledge-channel-hero-cover-${widget.publication.publicationId}',
              ),
              publication: widget.publication,
              fallbackAsset: heroAsset,
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x18000000), Color(0xB8000000)],
                ),
              ),
            ),
            Positioned(
              left: 20,
              top: 18,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .92),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Text('人工智能', style: TextStyle(fontSize: 11)),
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 18,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.publication.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.publication.summary ?? '追踪趋势、产品方法与真实案例',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFECE8E2),
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${widget.publication.sectionCount} 个栏目 · '
                          '${widget.publication.articleCount} 篇文章 · '
                          '${_compactSubscriberCount(widget.publication.articleCount)} 人订阅',
                          style: const TextStyle(
                            color: Color(0xFFECE8E2),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    key: ValueKey(
                      'subscription-follow-${widget.publication.publicationId}',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: colors.accent,
                      minimumSize: const Size(84, 38),
                    ),
                    onPressed: widget.actionInFlight
                        ? null
                        : widget.onToggleFollow,
                    icon: widget.actionInFlight
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            widget.publication.followed
                                ? Icons.check_rounded
                                : Icons.add_rounded,
                            size: 16,
                          ),
                    label: Text(widget.publication.followed ? '已订阅' : '订阅'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      SizedBox(
        height: 58,
        child: Row(
          children: [
            Expanded(
              child: _KnowledgeChannelTab(
                label: '资讯',
                selected: !_depth,
                onTap: () => setState(() => _depth = false),
              ),
            ),
            Expanded(
              child: _KnowledgeChannelTab(
                label: '深度文章',
                selected: _depth,
                onTap: () => setState(() => _depth = true),
              ),
            ),
          ],
        ),
      ),
      Divider(height: 1, color: colors.line),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
        child: Text(
          'FEATURED',
          style: TextStyle(
            color: colors.accent,
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      if (featured != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
          child: Material(
            color: const Color(0xFF171513),
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('knowledge-channel-featured'),
              onTap: () => widget.onOpenArticle(featured.article),
              child: SizedBox(
                height: 190,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    V3RemoteKnowledgeArticleCover(
                      key: ValueKey<String>(
                        'knowledge-channel-featured-cover-${featured.article.id}',
                      ),
                      article: featured.article,
                      loadLeadAsset: widget.loadLeadAsset,
                      fallbackAsset: featuredAsset,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xCC000000)],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: Text(
                        featured.article.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          height: 1.45,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '最新文章',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
              ),
            ),
            Text('每周更新', style: TextStyle(color: colors.muted, fontSize: 11)),
          ],
        ),
      ),
      if (entries.isEmpty)
        const V3KnowledgeEmptyState(tab: V3KnowledgeLibraryTab.square)
      else
        for (var index = 0; index < entries.length; index++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: V3RemoteSubscriptionArticleTile(
              entry: entries[index],
              index: index + 1,
              busy: widget.isArticleInFlight(entries[index].article.id),
              loadLeadAsset: widget.loadLeadAsset,
              onOpen: () => widget.onOpenArticle(entries[index].article),
              onSave: () => widget.onSaveArticle(entries[index].article),
            ),
          ),
      const SizedBox(height: 30),
    ];
    return ColoredBox(
      color: canvas,
      child: Scaffold(
        backgroundColor: canvas,
        body: SafeArea(
          child: Column(
            children: [
              const V3PageTopBar(
                title: '栏目详情',
                fallbackRoute: AppRoutePaths.knowledgeSquare,
                actions: <Widget>[],
                height: 52,
              ),
              Expanded(
                child: V3InteractiveScrollbar(
                  controller: _scrollController,
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.zero,
                    itemCount: content.length,
                    itemBuilder: (_, index) => content[index],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KnowledgeChannelTab extends StatelessWidget {
  const _KnowledgeChannelTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(
              color: selected ? colors.ink : colors.muted,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          const SizedBox(height: 7),
          Container(
            width: 54,
            height: 2,
            color: selected ? colors.accent : Colors.transparent,
          ),
        ],
      ),
    );
  }
}

bool _isDepthArticle(V3FeedItem article) {
  final value = '${article.title} ${article.summaryBody ?? ''}'.toLowerCase();
  return value.contains('深度') || value.contains('分析') || value.contains('判断');
}

String _compactSubscriberCount(int articleCount) =>
    '${(2.4 + articleCount / 100).toStringAsFixed(1)}万';

class V3RemoteKnowledgeWorldDetailPage extends ConsumerWidget {
  const V3RemoteKnowledgeWorldDetailPage({
    this.publicationId,
    this.query = '',
    super.key,
  });

  final String? publicationId;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(knowledgeLibraryControllerProvider);
    final mode = controller.subscriptionMode;
    if (mode == MobileSubscriptionRuntimeMode.loading) {
      return const V3PageScaffold(
        title: '知识世界',
        fallbackRoute: AppRoutePaths.knowledgeSquare,
        children: <Widget>[
          Center(
            key: ValueKey('remote-knowledge-world-loading'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 56),
              child: CircularProgressIndicator(),
            ),
          ),
        ],
      );
    }
    if (mode == MobileSubscriptionRuntimeMode.failure ||
        mode == MobileSubscriptionRuntimeMode.unavailable) {
      return V3PageScaffold(
        title: '知识世界',
        fallbackRoute: AppRoutePaths.knowledgeSquare,
        children: <Widget>[
          V3SubscriptionRuntimeError(
            errorCode: controller.subscriptionErrorCode,
            unavailable: mode == MobileSubscriptionRuntimeMode.unavailable,
            onRetry: controller.reloadSubscriptions,
          ),
        ],
      );
    }
    if (mode != MobileSubscriptionRuntimeMode.remote) {
      return const V3KnowledgeRouteRecoveryPage(
        recoveryKey: ValueKey('remote-knowledge-world-unavailable'),
        title: '知识世界',
        message: '知识世界当前不可用，请返回后重试',
      );
    }
    MobileSubscriptionPublication? publication;
    if (publicationId != null) {
      for (final item in controller.subscriptionPublications) {
        if (item.publicationId == publicationId) {
          publication = item;
          break;
        }
      }
    }
    if (publicationId != null && publication == null) {
      return const V3KnowledgeRouteRecoveryPage(
        recoveryKey: ValueKey('remote-knowledge-world-publication-missing'),
        title: '知识世界',
        message: '该出版物不存在或已下线，请返回知识世界查看其他内容',
      );
    }
    final publications = publication == null
        ? controller.subscriptionPublications
        : <MobileSubscriptionPublication>[publication];
    final entries = v3RemoteKnowledgeArticles(publications, query: query);
    if (publication != null) {
      return _RemoteKnowledgeChannelDetailSurface(
        publication: publication,
        entries: entries,
        actionInFlight: controller.isSubscriptionActionInFlight(
          publication.publicationId,
        ),
        isArticleInFlight: controller.isSubscriptionArticleActionInFlight,
        loadLeadAsset: controller.loadRemoteSubscriptionArticleLeadAsset,
        onToggleFollow: () => _toggleRemotePublication(
          context,
          controller,
          publication!.publicationId,
        ),
        onOpenArticle: (article) =>
            _openRemoteSubscriptionArticle(context, controller, article),
        onSaveArticle: (article) =>
            _saveRemoteSubscriptionArticle(context, controller, article),
      );
    }
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3PageScaffold(
      title: _remoteKnowledgeWorldDetailTitle(
        publication: publication,
        query: query,
        entries: entries,
      ),
      fallbackRoute: AppRoutePaths.knowledgeSquare,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              '${entries.length} 篇文章',
              style: TextStyle(color: colors.muted, fontSize: 12.5),
            ),
          ),
        ),
        if (entries.isEmpty)
          const SliverToBoxAdapter(
            child: V3KnowledgeEmptyState(tab: V3KnowledgeLibraryTab.square),
          )
        else
          SliverList.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return V3RemoteKnowledgeArticleRow(
                entry: entry,
                busy: controller.isSubscriptionArticleActionInFlight(
                  entry.article.id,
                ),
                loadLeadAsset:
                    controller.loadRemoteSubscriptionArticleLeadAsset,
                onOpen: () => _openRemoteSubscriptionArticle(
                  context,
                  controller,
                  entry.article,
                ),
                onSave: () => _saveRemoteSubscriptionArticle(
                  context,
                  controller,
                  entry.article,
                ),
              );
            },
          ),
      ],
    );
  }

  Future<void> _toggleRemotePublication(
    BuildContext context,
    KnowledgeLibraryController controller,
    String publicationId,
  ) async {
    final publication = controller.subscriptionPublications
        .where((item) => item.publicationId == publicationId)
        .firstOrNull;
    if (publication == null) return;
    if (publication.followed) {
      await showV3SubscriptionManagementSheet(
        context,
        controller: controller,
        publication: publication,
      );
      return;
    }
    final confirmed = await showV3SubscriptionPromptSheet(
      context,
      publication: publication,
    );
    if (!context.mounted || !confirmed) return;
    final result = await controller.toggleRemotePublication(publicationId);
    if (!context.mounted) return;
    if (result.status == MobileSubscriptionResultStatus.success) {
      await showV3SubscriptionSuccessSheet(context, publication: publication);
    } else {
      showV3Snack(context, v3SubscriptionFailureMessage(result.errorCode));
    }
  }

  Future<void> _openRemoteSubscriptionArticle(
    BuildContext context,
    KnowledgeLibraryController controller,
    V3FeedItem article,
  ) async {
    final result = await controller.loadRemoteSubscriptionArticle(article.id);
    if (!context.mounted) return;
    if (result.status != MobileSubscriptionResultStatus.success) {
      showV3Snack(context, v3SubscriptionFailureMessage(result.errorCode));
      return;
    }
    context.push(AppRoutePaths.feedItem(article.id));
  }

  Future<void> _saveRemoteSubscriptionArticle(
    BuildContext context,
    KnowledgeLibraryController controller,
    V3FeedItem article,
  ) async {
    final record = await showV3DepositPicker(
      context,
      contentId: article.id,
      enableDistillation: true,
    );
    if (!context.mounted || record == null) return;
    await showV3KnowledgeDepositSuccessSheet(
      context,
      article: article,
      depositedNoteId: record.contentId,
    );
  }
}

String _remoteKnowledgeWorldDetailTitle({
  required MobileSubscriptionPublication? publication,
  required String query,
  required List<V3RemoteKnowledgeArticleEntry> entries,
}) {
  if (publication != null) return publication.title;
  if (query.isNotEmpty) return '搜索结果';
  return entries.isEmpty ? '知识世界' : '全部更新';
}

class V3RemoteKnowledgeArticleEntry {
  const V3RemoteKnowledgeArticleEntry({
    required this.publication,
    required this.article,
  });

  final MobileSubscriptionPublication publication;
  final V3FeedItem article;
}

List<V3RemoteKnowledgeArticleEntry> v3RemoteKnowledgeArticles(
  Iterable<MobileSubscriptionPublication> publications, {
  String query = '',
}) {
  final normalizedQuery = query.trim().toLowerCase();
  final entries = <V3RemoteKnowledgeArticleEntry>[];
  for (final publication in publications) {
    final publicationMatches =
        normalizedQuery.isEmpty ||
        _remoteKnowledgeText(publication.title, normalizedQuery) ||
        _remoteKnowledgeText(publication.summary, normalizedQuery);
    for (final article in publication.articles) {
      final articleMatches =
          publicationMatches ||
          _remoteKnowledgeText(article.title, normalizedQuery) ||
          _remoteKnowledgeText(article.summaryBody, normalizedQuery) ||
          _remoteKnowledgeText(article.author, normalizedQuery);
      if (articleMatches) {
        entries.add(
          V3RemoteKnowledgeArticleEntry(
            publication: publication,
            article: article,
          ),
        );
      }
    }
  }
  entries.sort(_compareRemoteKnowledgeEntriesNewestFirst);
  return entries;
}

int _compareRemoteKnowledgeEntriesNewestFirst(
  V3RemoteKnowledgeArticleEntry left,
  V3RemoteKnowledgeArticleEntry right,
) {
  final timestamp = right.article.updatedAt.compareTo(left.article.updatedAt);
  return timestamp != 0
      ? timestamp
      : left.article.id.compareTo(right.article.id);
}

List<MobileSubscriptionPublication> uniqueV3RemoteKnowledgePublications(
  Iterable<MobileSubscriptionPublication> publications,
) {
  final publicationIds = <String>{};
  return [
    for (final publication in publications)
      if (publicationIds.add(publication.publicationId)) publication,
  ];
}

bool _remoteKnowledgeText(String? value, String query) =>
    value?.toLowerCase().contains(query) ?? false;

IconData _remotePublicationIcon(int index) {
  const icons = <IconData>[
    Icons.workspace_premium_outlined,
    Icons.history_edu_outlined,
    Icons.auto_stories_outlined,
    Icons.palette_outlined,
    Icons.menu_book_outlined,
    Icons.headphones_outlined,
    Icons.lightbulb_outline_rounded,
    Icons.location_city_outlined,
    Icons.local_library_outlined,
  ];
  return icons[index % icons.length];
}

IconData v3RemoteSubscriptionIcon({required String title, String? summary}) {
  final text = '$title ${summary ?? ''}'.toLowerCase();
  final industry = _containsAny(text, const <String>[
    '行业',
    '动态',
    '趋势',
    '市场',
    '商业',
    '增长',
    '运营',
  ]);
  final artificialIntelligence = _containsAny(text, const <String>[
    '人工智能',
    '大模型',
    'ai',
    '智能',
    '算法',
  ]);
  final philosophy = _containsAny(text, const <String>['星座', '哲学', '心理', '灵性']);
  final beauty = _containsAny(text, const <String>[
    '美业',
    '时尚',
    '美妆',
    '美容',
    '穿搭',
  ]);
  if (artificialIntelligence && industry) {
    return Icons.trending_up_rounded;
  }
  if (artificialIntelligence) {
    return Icons.psychology_alt_outlined;
  }
  if (philosophy && industry) {
    return Icons.insights_outlined;
  }
  if (philosophy) {
    return Icons.auto_awesome_outlined;
  }
  if (beauty && industry) {
    return Icons.storefront_outlined;
  }
  if (beauty) {
    return Icons.face_retouching_natural_outlined;
  }
  if (_containsAny(text, const <String>['科技', '技术', '数字', '数据'])) {
    return Icons.memory_outlined;
  }
  if (_containsAny(text, const <String>['财经', '金融', '投资', '经济'])) {
    return Icons.account_balance_wallet_outlined;
  }
  if (_containsAny(text, const <String>['历史', '文化', '人文'])) {
    return Icons.museum_outlined;
  }
  if (_containsAny(text, const <String>['旅行', '城市', '地理'])) {
    return Icons.explore_outlined;
  }
  if (_containsAny(text, const <String>['艺术', '设计', '创作'])) {
    return Icons.palette_outlined;
  }
  return Icons.menu_book_outlined;
}

IconData uniqueV3RemoteKnowledgeGridIcon(
  IconData preferred,
  Set<IconData> usedIcons,
) {
  if (!usedIcons.contains(preferred)) return preferred;
  for (var index = 0; index < 9; index++) {
    final fallback = _remotePublicationIcon(index);
    if (!usedIcons.contains(fallback)) return fallback;
  }
  return preferred;
}

bool _containsAny(String value, Iterable<String> candidates) =>
    candidates.any(value.contains);

String v3RemotePublicationGridLabel(String title) {
  final parts = title
      .split('/')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  return parts.length < 2 ? title : parts.take(2).join('\n');
}

void pushV3RemoteKnowledgeWorldDetail(
  BuildContext context, {
  String? publicationId,
  String query = '',
}) {
  context.push(
    AppRoutePaths.knowledgeWorldDetail(
      publicationId: publicationId,
      query: query,
    ),
  );
}

Future<bool> showV3SubscriptionPromptSheet(
  BuildContext context, {
  required MobileSubscriptionPublication publication,
}) async {
  final confirmed = await showV3GlassBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final colors = HuahuoV3Theme.tokensOf(sheetContext);
      return _ScrollableSubscriptionSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                '订阅该栏目？',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '订阅后，从明天起进入你的订阅更新。',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              _SubscriptionSheetPublicationCard(publication: publication),
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.check_rounded, size: 17),
                      SizedBox(width: 8),
                      Expanded(child: Text('接收资讯与深度文章更新')),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                key: const ValueKey('subscription-sheet-confirm'),
                onPressed: () => Navigator.pop(sheetContext, true),
                child: const Text('确认订阅'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.pop(sheetContext, false),
                child: const Text('暂不订阅'),
              ),
            ],
          ),
        ),
      );
    },
  );
  return confirmed ?? false;
}

Future<void> showV3SubscriptionSuccessSheet(
  BuildContext context, {
  required MobileSubscriptionPublication publication,
}) {
  return showV3GlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final colors = HuahuoV3Theme.tokensOf(sheetContext);
      final successSurface = HuahuoV3Theme.semanticSurface(
        colors.success,
        colors.surface,
      );
      final successForeground = HuahuoV3Theme.contrastingForeground(
        colors.success,
        background: successSurface,
      );
      return _ScrollableSubscriptionSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(sheetContext),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
              CircleAvatar(
                radius: 30,
                backgroundColor: successSurface,
                child: Icon(
                  Icons.check_rounded,
                  color: successForeground,
                  size: 30,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '订阅成功',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '已订阅 ${publication.title}，更新将出现在“我的订阅”。',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('查看我的订阅'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('继续浏览'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> showV3SubscriptionManagementSheet(
  BuildContext context, {
  required KnowledgeLibraryController controller,
  required MobileSubscriptionPublication publication,
}) async {
  final cancel = await showV3GlassBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SubscriptionManagementSheet(publication: publication),
  );
  if (cancel != true || !context.mounted) return;
  final confirmed = await showV3GlassBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final colors = HuahuoV3Theme.tokensOf(sheetContext);
      return _ScrollableSubscriptionSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '取消订阅 ${publication.title}？',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '取消后不会删除已经沉淀到笔记的内容。',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.danger.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '你将不再收到该栏目的更新提醒。',
                    style: TextStyle(color: colors.danger, fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () => Navigator.pop(sheetContext, false),
                child: const Text('继续订阅'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('subscription-cancel-confirm'),
                style: FilledButton.styleFrom(backgroundColor: colors.danger),
                onPressed: () => Navigator.pop(sheetContext, true),
                child: const Text('确认取消'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (confirmed != true || !context.mounted) return;
  final result = await controller.toggleRemotePublication(
    publication.publicationId,
  );
  if (!context.mounted) return;
  showV3Snack(
    context,
    result.status == MobileSubscriptionResultStatus.success
        ? '已取消订阅'
        : v3SubscriptionFailureMessage(result.errorCode),
  );
}

class _SubscriptionSheetPublicationCard extends StatelessWidget {
  const _SubscriptionSheetPublicationCard({required this.publication});

  final MobileSubscriptionPublication publication;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/images/knowledge_today_ai.png',
                width: 54,
                height: 54,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    publication.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${publication.sectionCount} 个栏目 · ${publication.articleCount} 篇',
                    style: TextStyle(color: colors.muted, fontSize: 11),
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

class _SubscriptionManagementSheet extends StatefulWidget {
  const _SubscriptionManagementSheet({required this.publication});

  final MobileSubscriptionPublication publication;

  @override
  State<_SubscriptionManagementSheet> createState() =>
      _SubscriptionManagementSheetState();
}

class _SubscriptionManagementSheetState
    extends State<_SubscriptionManagementSheet> {
  bool _alerts = true;
  bool _pinned = false;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return _ScrollableSubscriptionSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '管理 ${widget.publication.title}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              '调整这个栏目的订阅方式',
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('更新提醒'),
              subtitle: const Text('有新内容时在订阅页显示'),
              value: _alerts,
              onChanged: (value) => setState(() => _alerts = value),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('置顶栏目'),
              subtitle: const Text('固定在栏目的首位'),
              value: _pinned,
              onChanged: (value) => setState(() => _pinned = value),
            ),
            Divider(color: colors.line),
            TextButton(
              key: const ValueKey('subscription-manage-cancel'),
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: colors.danger),
              child: const Text('取消订阅'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showV3KnowledgeDepositSuccessSheet(
  BuildContext context, {
  required V3FeedItem article,
  required String depositedNoteId,
}) {
  return showV3GlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final colors = HuahuoV3Theme.tokensOf(sheetContext);
      final successSurface = HuahuoV3Theme.semanticSurface(
        colors.success,
        colors.surface,
      );
      final successForeground = HuahuoV3Theme.contrastingForeground(
        colors.success,
        background: successSurface,
      );
      return _ScrollableSubscriptionSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: successSurface,
                    child: Icon(Icons.check_rounded, color: successForeground),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '已沉淀到笔记',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _SubscriptionSheetPublicationCard(
                publication: MobileSubscriptionPublication(
                  publicationId: article.publicationId ?? article.id,
                  title: article.title,
                  sectionCount: 1,
                  articleCount: 1,
                  updatedAt: article.updatedAt,
                  articles: <V3FeedItem>[article],
                  followed: true,
                  available: true,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('继续阅读'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        context.push(AppRoutePaths.feedItem(depositedNoteId));
                      },
                      child: const Text('去笔记查看'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class V3RemoteKnowledgeArticleRow extends StatelessWidget {
  const V3RemoteKnowledgeArticleRow({
    required this.entry,
    required this.busy,
    required this.loadLeadAsset,
    required this.onOpen,
    required this.onSave,
    super.key,
  });

  final V3RemoteKnowledgeArticleEntry entry;
  final bool busy;
  final V3KnowledgeArticleLeadAssetLoader loadLeadAsset;
  final Future<void> Function() onOpen;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final article = entry.article;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Padding(
        key: ValueKey('subscription-article-${article.id}'),
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 62,
                height: 62,
                child: V3RemoteKnowledgeArticleCover(
                  key: ValueKey<String>('knowledge-row-cover-${article.id}'),
                  article: article,
                  loadLeadAsset: loadLeadAsset,
                  fallbackAsset: _knowledgeArticleAsset(
                    entry.publication.publicationId.hashCode.abs(),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: InkWell(
                key: ValueKey('subscription-open-${article.id}'),
                onTap: busy ? null : onOpen,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entry.publication.title} · '
                        '${v3KnowledgeFormatDate(article.updatedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.muted, fontSize: 11.5),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        article.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (article.summaryBody case final summary?
                          when summary.trim().isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.muted, fontSize: 12.5),
                        ),
                      ],
                      if (article.author case final author?
                          when author.trim().isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.muted, fontSize: 11.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
            IconButton(
              key: ValueKey('subscription-save-${article.id}'),
              tooltip: '保存为笔记',
              onPressed: busy ? null : onSave,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bookmark_add_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

V3KnowledgeLibraryTab v3KnowledgeLibraryTabFromRouteParameter(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'subscribed' || 'subscription' => V3KnowledgeLibraryTab.subscribed,
    'square' => V3KnowledgeLibraryTab.square,
    _ => V3KnowledgeLibraryTab.square,
  };
}
