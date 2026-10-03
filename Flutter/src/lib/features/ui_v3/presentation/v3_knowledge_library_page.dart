import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/app_route_paths.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../application/knowledge_library_controller.dart';
import '../application/subscription_port.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';
import 'v3_deposit_picker.dart';
import 'v3_knowledge_local_surfaces.dart';
import 'v3_knowledge_remote_detail.dart';
import 'v3_knowledge_remote_home.dart';

export 'v3_knowledge_local_surfaces.dart'
    show
        V3KnowledgeChannelDetailPage,
        V3KnowledgeNoteAction,
        handleV3KnowledgeNoteAction,
        showV3KnowledgeNoteActions;
export 'v3_knowledge_remote_detail.dart'
    show
        V3RemoteKnowledgeWorldDetailPage,
        v3KnowledgeLibraryTabFromRouteParameter;

const _visibleKnowledgeTabs = <V3KnowledgeLibraryTab>[
  V3KnowledgeLibraryTab.subscribed,
  V3KnowledgeLibraryTab.square,
];

V3KnowledgeLibraryTab _visibleKnowledgeTab(V3KnowledgeLibraryTab tab) =>
    tab == V3KnowledgeLibraryTab.mine ? V3KnowledgeLibraryTab.subscribed : tab;

int _knowledgePageIndex(V3KnowledgeLibraryTab tab) =>
    _visibleKnowledgeTabs.indexOf(_visibleKnowledgeTab(tab));

class V3KnowledgeLibraryPage extends ConsumerStatefulWidget {
  const V3KnowledgeLibraryPage({
    this.initialTab = V3KnowledgeLibraryTab.subscribed,
    super.key,
  });

  final V3KnowledgeLibraryTab initialTab;

  @override
  ConsumerState<V3KnowledgeLibraryPage> createState() =>
      _V3KnowledgeLibraryPageState();
}

class _V3KnowledgeLibraryPageState extends ConsumerState<V3KnowledgeLibraryPage>
    with RouteAware {
  late final PageController _pageController;
  KnowledgeChannel? _selectedSubscribedChannel;
  String? _selectedRemoteSubscribedPublicationId;
  String _squareQuery = '';
  String _remoteSquareQuery = '';
  V3SquareExploreCategory _squareCategory = V3SquareExploreCategory.all;
  bool _showAllSquareUpdates = false;
  PageRoute<dynamic>? _observedRoute;
  bool _routeVisible = true;
  bool _didRefreshCatalogOnEntry = false;
  KnowledgeLibraryController? _catalogLoadScheduledFor;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: _knowledgePageIndex(widget.initialTab),
    );
    ref.listenManual<
      ({
        KnowledgeLibraryController controller,
        MobileSubscriptionRuntimeMode mode,
        bool publicationsEmpty,
      })
    >(
      knowledgeLibraryControllerProvider.select(
        (controller) => (
          controller: controller,
          mode: controller.subscriptionMode,
          publicationsEmpty: controller.subscriptionPublications.isEmpty,
        ),
      ),
      (previous, next) {
        if (previous == null ||
            !identical(previous.controller, next.controller)) {
          _ensureRemoteCatalogFor(next.controller);
        }
      },
      fireImmediately: false,
    );
    _applyInitialTabAfterBuild(animate: false, refreshCatalog: true);
  }

  @override
  void didUpdateWidget(covariant V3KnowledgeLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _applyInitialTabAfterBuild(animate: true, refreshCatalog: false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is! PageRoute<dynamic> || identical(route, _observedRoute)) {
      return;
    }
    final previous = _observedRoute;
    if (previous != null) {
      appRouteObserver.unsubscribe(this);
    }
    _observedRoute = route;
    _routeVisible = route.isCurrent;
    appRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() => _setRouteVisible(false);

  @override
  void didPopNext() => _setRouteVisible(true);

  @override
  void didPop() => _routeVisible = false;

  @override
  void dispose() {
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _pageController.dispose();
    super.dispose();
  }

  void _setRouteVisible(bool visible) {
    if (!mounted || _routeVisible == visible) return;
    setState(() => _routeVisible = visible);
    if (visible) {
      unawaited(
        ref
            .read(knowledgeLibraryControllerProvider)
            .synchronizeWorkspaceContent(),
      );
    }
  }

  void _applyInitialTabAfterBuild({
    required bool animate,
    required bool refreshCatalog,
  }) {
    scheduleMicrotask(() {
      if (!mounted) return;
      final initialTab = _visibleKnowledgeTab(widget.initialTab);
      final library = ref.read(knowledgeLibraryControllerProvider);
      library.setTab(initialTab);
      if (refreshCatalog && !_didRefreshCatalogOnEntry) {
        _didRefreshCatalogOnEntry = true;
        unawaited(library.reloadSubscriptions());
      }
      unawaited(library.synchronizeWorkspaceContent());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final initialTab = _visibleKnowledgeTab(widget.initialTab);
      if (!_pageController.hasClients) return;
      final targetPage = _knowledgePageIndex(initialTab);
      if (_pageController.page?.round() != targetPage) {
        if (animate && !MediaQuery.disableAnimationsOf(context)) {
          unawaited(
            _pageController.animateToPage(
              targetPage,
              duration: V3MotionTokens.deliberate,
              curve: Curves.easeOutCubic,
            ),
          );
        } else {
          _pageController.jumpToPage(targetPage);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(knowledgeLibraryControllerProvider);
    final squareActive =
        controller.tab == V3KnowledgeLibraryTab.square && _routeVisible;
    final colors = HuahuoV3Theme.tokensOf(context);
    final pageCanvas = colors.canvas;
    return ColoredBox(
      color: pageCanvas,
      child: Scaffold(
        backgroundColor: pageCanvas,
        body: SafeArea(
          child: Column(
            children: [
              const V3PageTopBar(
                title: '外部世界',
                fallbackRoute: '/v3/feed',
                actions: <Widget>[],
                height: 54,
              ),
              V3KnowledgeTabStrip(
                selected: controller.tab,
                onSelected: _selectTab,
              ),
              Divider(height: 1, color: colors.line),
              Expanded(
                child: PageView(
                  key: const ValueKey('knowledge-page-view'),
                  controller: _pageController,
                  onPageChanged: _onPageChanged,
                  children: [
                    _buildSubscribedPage(controller),
                    _buildSquarePage(controller, squareActive),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _ensureRemoteCatalogFor(KnowledgeLibraryController controller) {
    final pageIndex = _pageController.hasClients
        ? (_pageController.page?.round() ??
              _knowledgePageIndex(widget.initialTab))
        : _knowledgePageIndex(widget.initialTab);
    final targetTab =
        _visibleKnowledgeTabs[pageIndex
            .clamp(0, _visibleKnowledgeTabs.length - 1)
            .toInt()];
    final needsCatalog =
        controller.subscriptionMode == MobileSubscriptionRuntimeMode.loading &&
        controller.subscriptionPublications.isEmpty;
    final needsTab = controller.tab != targetTab;
    if ((!needsCatalog && !needsTab) ||
        identical(_catalogLoadScheduledFor, controller)) {
      return;
    }
    _catalogLoadScheduledFor = controller;
    scheduleMicrotask(() {
      if (!mounted ||
          !identical(
            ref.read(knowledgeLibraryControllerProvider),
            controller,
          )) {
        return;
      }
      controller.setTab(targetTab);
      if (needsCatalog) {
        unawaited(controller.ensureSubscriptionCatalogLoaded());
      }
    });
  }

  Widget _buildSubscribedPage(KnowledgeLibraryController controller) {
    if (controller.subscriptionMode != MobileSubscriptionRuntimeMode.demo) {
      return _buildRemoteSubscriptionPage(controller, followedOnly: true);
    }
    final channels = controller.subscribedChannels;
    if (_selectedSubscribedChannel != null &&
        !channels.contains(_selectedSubscribedChannel)) {
      _selectedSubscribedChannel = null;
    }
    final notes = _selectedSubscribedChannel == null
        ? controller.subscribedChannelArticles
        : controller.channelArticlesFor(_selectedSubscribedChannel!);
    return ListView(
      key: const PageStorageKey<String>('knowledge-subscribed-channels'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        V3SubscribedChannelBar(
          channels: channels,
          selected: _selectedSubscribedChannel,
          onSelected: (channel) =>
              setState(() => _selectedSubscribedChannel = channel),
        ),
        const SizedBox(height: 18),
        if (channels.isEmpty)
          const V3KnowledgeEmptyState(tab: V3KnowledgeLibraryTab.subscribed)
        else
          for (var index = 0; index < notes.length; index++) ...[
            V3SubscribedArticleRow(
              note: notes[index],
              channel: controller.channelForArticle(notes[index].id)!,
              isDeposited: controller.isDeposited(notes[index].id),
              onOpen: () => context.push(
                '/v3/feed/items/${Uri.encodeComponent(notes[index].id)}',
              ),
              onDeposit: () => handleV3KnowledgeNoteAction(
                context,
                ref,
                notes[index],
                V3KnowledgeNoteAction.move,
              ),
            ),
            if (index != notes.length - 1)
              Divider(height: 1, color: HuahuoV3Theme.tokensOf(context).line),
          ],
      ],
    );
  }

  Widget _buildSquarePage(
    KnowledgeLibraryController controller,
    bool squareActive,
  ) {
    if (controller.subscriptionMode != MobileSubscriptionRuntimeMode.demo) {
      return _buildRemoteSubscriptionPage(controller, followedOnly: false);
    }
    return V3KnowledgeSquarePage(
      controller: controller,
      active: squareActive,
      query: _squareQuery,
      category: _squareCategory,
      showAllUpdates: _showAllSquareUpdates,
      onAction: (note, action) =>
          handleV3KnowledgeNoteAction(context, ref, note, action),
      onQueryChanged: (value) => setState(() {
        _squareQuery = value;
        _showAllSquareUpdates = false;
      }),
      onCategoryChanged: (value) {
        if (value == V3SquareExploreCategory.all) {
          setState(() {
            _squareCategory = value;
            _showAllSquareUpdates = false;
          });
          return;
        }
        final channel = value.channel;
        if (channel != null) {
          context.push(AppRoutePaths.knowledgeChannel(channel.id));
        }
      },
      onShowAllUpdatesChanged: () =>
          setState(() => _showAllSquareUpdates = !_showAllSquareUpdates),
    );
  }

  Widget _buildRemoteSubscriptionPage(
    KnowledgeLibraryController controller, {
    required bool followedOnly,
  }) {
    final mode = controller.subscriptionMode;
    final allPublications = controller.subscriptionPublications;
    Widget buildKnowledgeWorld({
      bool refreshing = false,
      String? errorCode,
      VoidCallback? onRetry,
    }) => V3RemoteKnowledgeWorldHome(
      publications: allPublications,
      query: _remoteSquareQuery,
      actionInFlight: controller.isSubscriptionActionInFlight,
      isArticleInFlight: controller.isSubscriptionArticleActionInFlight,
      loadLeadAsset: controller.loadRemoteSubscriptionArticleLeadAsset,
      onQueryChanged: (value) => setState(() => _remoteSquareQuery = value),
      onToggleFollow: (publicationId) =>
          _toggleRemotePublication(controller, publicationId),
      onOpenArticle: (article) =>
          _openRemoteSubscriptionArticle(controller, article),
      onSaveArticle: (article) =>
          _saveRemoteSubscriptionArticle(controller, article),
      refreshing: refreshing,
      errorCode: errorCode,
      onRetry: onRetry,
    );
    if (!followedOnly && mode == MobileSubscriptionRuntimeMode.loading) {
      return allPublications.isEmpty
          ? const V3RemoteKnowledgeWorldLoadingShell()
          : buildKnowledgeWorld(refreshing: true);
    }
    if (!followedOnly &&
        (mode == MobileSubscriptionRuntimeMode.failure ||
            mode == MobileSubscriptionRuntimeMode.unavailable)) {
      void retry() => unawaited(controller.reloadSubscriptions());
      return allPublications.isEmpty
          ? V3RemoteKnowledgeWorldLoadingShell(
              errorCode: controller.subscriptionErrorCode,
              onRetry: retry,
            )
          : buildKnowledgeWorld(
              errorCode: controller.subscriptionErrorCode,
              onRetry: retry,
            );
    }
    if (allPublications.isEmpty &&
        mode == MobileSubscriptionRuntimeMode.loading) {
      return const Center(
        key: ValueKey('subscription-runtime-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (allPublications.isEmpty &&
        (mode == MobileSubscriptionRuntimeMode.failure ||
            mode == MobileSubscriptionRuntimeMode.unavailable)) {
      return V3SubscriptionRuntimeError(
        errorCode: controller.subscriptionErrorCode,
        unavailable: mode == MobileSubscriptionRuntimeMode.unavailable,
        onRetry: controller.reloadSubscriptions,
      );
    }
    final publications = followedOnly
        ? allPublications
              .where((publication) => publication.followed)
              .toList(growable: false)
        : allPublications;
    if (publications.isEmpty) {
      return V3SubscriptionRuntimeEmpty(followedOnly: followedOnly);
    }
    if (!followedOnly) {
      return buildKnowledgeWorld();
    }
    if (_selectedRemoteSubscribedPublicationId != null &&
        !publications.any(
          (publication) =>
              publication.publicationId ==
              _selectedRemoteSubscribedPublicationId,
        )) {
      _selectedRemoteSubscribedPublicationId = null;
    }
    final selected = _selectedRemoteSubscribedPublicationId == null
        ? publications.first
        : publications
                  .where(
                    (publication) =>
                        publication.publicationId ==
                        _selectedRemoteSubscribedPublicationId,
                  )
                  .firstOrNull ??
              publications.first;
    final articles =
        <V3RemoteKnowledgeArticleEntry>[
          for (final article in selected.articles)
            V3RemoteKnowledgeArticleEntry(
              publication: selected,
              article: article,
            ),
        ]..sort((left, right) {
          final timestamp = right.article.updatedAt.compareTo(
            left.article.updatedAt,
          );
          return timestamp != 0
              ? timestamp
              : left.article.id.compareTo(right.article.id);
        });
    return V3RemoteSubscriptionsHome(
      refreshing: mode == MobileSubscriptionRuntimeMode.loading,
      errorCode: controller.subscriptionErrorCode,
      onRetry: () => unawaited(controller.reloadSubscriptions()),
      publications: publications,
      selectedPublicationId: selected.publicationId,
      articles: articles,
      isArticleInFlight: controller.isSubscriptionArticleActionInFlight,
      loadLeadAsset: controller.loadRemoteSubscriptionArticleLeadAsset,
      onSelected: (publicationId) => setState(
        () => _selectedRemoteSubscribedPublicationId = publicationId,
      ),
      onManage: () => showV3SubscriptionManagementSheet(
        context,
        controller: controller,
        publication: selected,
      ),
      onOpenPublication: (publication) => pushV3RemoteKnowledgeWorldDetail(
        context,
        publicationId: publication.publicationId,
      ),
      onOpenArticle: (entry) =>
          _openRemoteSubscriptionArticle(controller, entry.article),
      onSaveArticle: (entry) =>
          _saveRemoteSubscriptionArticle(controller, entry.article),
    );
  }

  Future<void> _toggleRemotePublication(
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
    if (!mounted || !confirmed) return;
    final result = await controller.toggleRemotePublication(publicationId);
    if (!mounted) return;
    if (result.status == MobileSubscriptionResultStatus.success) {
      await showV3SubscriptionSuccessSheet(context, publication: publication);
    } else {
      showV3Snack(context, v3SubscriptionFailureMessage(result.errorCode));
    }
  }

  Future<void> _openRemoteSubscriptionArticle(
    KnowledgeLibraryController controller,
    V3FeedItem article,
  ) async {
    final result = await controller.loadRemoteSubscriptionArticle(article.id);
    if (!mounted) return;
    if (result.status != MobileSubscriptionResultStatus.success) {
      showV3Snack(context, v3SubscriptionFailureMessage(result.errorCode));
      return;
    }
    context.push('/v3/feed/items/${Uri.encodeComponent(article.id)}');
  }

  Future<void> _saveRemoteSubscriptionArticle(
    KnowledgeLibraryController controller,
    V3FeedItem article,
  ) async {
    final record = await showV3DepositPicker(
      context,
      contentId: article.id,
      enableDistillation: true,
    );
    if (!mounted || record == null) return;
    await showV3KnowledgeDepositSuccessSheet(
      context,
      article: article,
      depositedNoteId: record.contentId,
    );
  }

  void _selectTab(V3KnowledgeLibraryTab tab) {
    final visibleTab = _visibleKnowledgeTab(tab);
    final library = ref.read(knowledgeLibraryControllerProvider);
    library.setTab(visibleTab);
    _pageController.animateToPage(
      _knowledgePageIndex(visibleTab),
      duration: V3MotionTokens.deliberate,
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int index) {
    final tab = _visibleKnowledgeTabs[index];
    final library = ref.read(knowledgeLibraryControllerProvider);
    library.setTab(tab);
  }
}
