import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/feed_item_models.dart';
import 'subscription_port.dart';

typedef KnowledgeSubscriptionSavedArticleHandler =
    Future<String?> Function(V3FeedItem savedArticle);

/// Owns the subscription catalog and its remote action lifecycle.
///
/// The broader Knowledge facade supplies only two command callbacks: removing
/// legacy catalog snapshots after a successful catalog load and adopting a
/// saved remote article into the authoritative note/deposit stores.
final class KnowledgeSubscriptionController extends ChangeNotifier {
  static const int _maxAssetCacheEntries = 32;

  KnowledgeSubscriptionController({
    required MobileSubscriptionPort port,
    required VoidCallback onCatalogApplied,
    required KnowledgeSubscriptionSavedArticleHandler onSavedArticle,
    DateTime Function()? now,
  }) : _port = port,
       _onCatalogApplied = onCatalogApplied,
       _onSavedArticle = onSavedArticle,
       _now = now ?? DateTime.now,
       _mode = port.isDemo
           ? MobileSubscriptionRuntimeMode.demo
           : MobileSubscriptionRuntimeMode.loading;

  final MobileSubscriptionPort _port;
  final VoidCallback _onCatalogApplied;
  final KnowledgeSubscriptionSavedArticleHandler _onSavedArticle;
  final DateTime Function() _now;

  MobileSubscriptionRuntimeMode _mode;
  List<MobileSubscriptionPublication> _publications =
      const <MobileSubscriptionPublication>[];
  Map<String, V3FeedItem> _articlesById = const <String, V3FeedItem>{};
  String? _errorCode;
  final Set<String> _publicationActionsInFlight = <String>{};
  final Set<String> _articleActionsInFlight = <String>{};
  final Set<String> _hydratedArticleRevisions = <String>{};
  final Map<String, Future<MobileSubscriptionActionResult>>
  _articleDetailRequests = <String, Future<MobileSubscriptionActionResult>>{};
  final Map<String, MobileSubscriptionArticleAssetResult> _assetCache =
      <String, MobileSubscriptionArticleAssetResult>{};
  final Map<String, Future<MobileSubscriptionArticleAssetResult>>
  _assetRequests = <String, Future<MobileSubscriptionArticleAssetResult>>{};
  final Map<String, String> _pendingActionIds = <String, String>{};
  int _actionSequence = 0;
  int _loadGeneration = 0;
  Future<void>? _loadInFlight;
  bool _disposed = false;

  MobileSubscriptionRuntimeMode get mode => _mode;
  List<MobileSubscriptionPublication> get publications =>
      List<MobileSubscriptionPublication>.unmodifiable(_publications);
  String? get errorCode => _errorCode;
  V3FeedItem? articleForId(String noteId) => _articlesById[noteId.trim()];

  List<V3FeedItem> articlesFor(String publicationId) {
    for (final publication in _publications) {
      if (publication.publicationId == publicationId) {
        return List<V3FeedItem>.unmodifiable(publication.articles);
      }
    }
    return const <V3FeedItem>[];
  }

  List<V3FeedItem> get followedArticles =>
      List<V3FeedItem>.unmodifiable(<V3FeedItem>[
        for (final publication in _publications)
          if (publication.followed) ...publication.articles,
      ]);

  bool isPublicationFollowed(String publicationId) => _publications.any(
    (publication) =>
        publication.publicationId == publicationId && publication.followed,
  );

  bool isPublicationActionInFlight(String publicationId) =>
      _publicationActionsInFlight.contains(publicationId);

  bool isArticleActionInFlight(String noteId) =>
      _articleActionsInFlight.contains(noteId);

  Future<void> ensureCatalogLoaded() {
    if (_port.isDemo ||
        (_mode == MobileSubscriptionRuntimeMode.remote &&
            _publications.isNotEmpty)) {
      return Future<void>.value();
    }
    return _loadCatalog();
  }

  Future<void> reload() => _loadCatalog();

  Future<MobileSubscriptionActionResult> togglePublication(
    String publicationId,
  ) async {
    final index = _publications.indexWhere(
      (publication) => publication.publicationId == publicationId,
    );
    if (_mode != MobileSubscriptionRuntimeMode.remote || index < 0) {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_PUBLICATION_NOT_AVAILABLE',
      );
    }
    if (!_publicationActionsInFlight.add(publicationId)) {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_ACTION_IN_PROGRESS',
      );
    }
    final previous = _publications[index];
    final followed = !previous.followed;
    _replacePublication(index, previous.copyWith(followed: followed));
    _notify();
    final operation = followed ? 'follow' : 'unfollow';
    final actionKey = '$operation:$publicationId';
    final actionId = _actionId(actionKey);
    MobileSubscriptionActionResult result;
    try {
      result = await _port.setPublicationFollowed(
        publicationId: publicationId,
        followed: followed,
        actionId: actionId,
      );
    } on Object {
      result = const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_MUTATION_FAILED',
      );
    }
    if (_disposed) return result;
    _publicationActionsInFlight.remove(publicationId);
    if (result.status != MobileSubscriptionResultStatus.success) {
      final currentIndex = _publications.indexWhere(
        (publication) => publication.publicationId == publicationId,
      );
      if (currentIndex >= 0) _replacePublication(currentIndex, previous);
    } else {
      _pendingActionIds.remove(actionKey);
    }
    _notify();
    return result;
  }

  Future<MobileSubscriptionActionResult> loadArticle(String noteId) {
    final article = articleForId(noteId);
    if (_port.isDemo || article == null || article.articleId == null) {
      return Future<MobileSubscriptionActionResult>.value(
        const MobileSubscriptionActionResult.failure(
          'SUBSCRIPTION_ARTICLE_NOT_AVAILABLE',
        ),
      );
    }
    return _ensureArticleDetail(article, markActionInFlight: true);
  }

  Future<MobileSubscriptionArticleAssetResult> loadArticleLeadAsset(
    String noteId,
  ) {
    final article = articleForId(noteId);
    if (_port.isDemo || article == null || article.articleId == null) {
      return SynchronousFuture(
        const MobileSubscriptionArticleAssetResult.failure(
          'SUBSCRIPTION_ARTICLE_NOT_AVAILABLE',
        ),
      );
    }
    if (_hydratedArticleRevisions.contains(_articleRevisionKey(article))) {
      return _loadHydratedLeadAsset(article);
    }
    return _ensureArticleDetail(article, markActionInFlight: false).then((
      detailResult,
    ) {
      if (detailResult.status != MobileSubscriptionResultStatus.success) {
        return detailResult.status == MobileSubscriptionResultStatus.unavailable
            ? MobileSubscriptionArticleAssetResult.unavailable(
                detailResult.errorCode ?? 'SUBSCRIPTION_ARTICLE_LOAD_FAILED',
              )
            : MobileSubscriptionArticleAssetResult.failure(
                detailResult.errorCode ?? 'SUBSCRIPTION_ARTICLE_LOAD_FAILED',
              );
      }
      final hydrated = detailResult.item;
      final current = articleForId(noteId);
      if (hydrated == null ||
          current == null ||
          _articleRevisionKey(hydrated) != _articleRevisionKey(current)) {
        return const MobileSubscriptionArticleAssetResult.failure(
          'SUBSCRIPTION_ARTICLE_REVISION_MISMATCH',
        );
      }
      return _loadHydratedLeadAsset(hydrated);
    });
  }

  Future<MobileSubscriptionArticleAssetResult> _loadHydratedLeadAsset(
    V3FeedItem article,
  ) {
    if (article.subscriptionArticleAssets.isEmpty) {
      return SynchronousFuture(
        const MobileSubscriptionArticleAssetResult.failure(
          'SUBSCRIPTION_ASSET_NOT_AVAILABLE',
        ),
      );
    }
    return loadArticleAsset(
      article.id,
      article.subscriptionArticleAssets.first.logicalPath,
    );
  }

  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset(
    String noteId,
    String logicalPath,
  ) {
    final article = articleForId(noteId);
    final path = logicalPath.trim();
    if (_port.isDemo || article == null || path.isEmpty) {
      return Future<MobileSubscriptionArticleAssetResult>.value(
        const MobileSubscriptionArticleAssetResult.failure(
          'SUBSCRIPTION_ASSET_NOT_AVAILABLE',
        ),
      );
    }
    V3SubscriptionArticleAssetRef? asset;
    for (final candidate in article.subscriptionArticleAssets) {
      if (candidate.logicalPath == path) {
        asset = candidate;
        break;
      }
    }
    if (asset == null) {
      return Future<MobileSubscriptionArticleAssetResult>.value(
        const MobileSubscriptionArticleAssetResult.failure(
          'SUBSCRIPTION_ASSET_NOT_AVAILABLE',
        ),
      );
    }
    final cacheKey = <String>[
      'article',
      article.articleId ?? '',
      article.articleRevisionId ?? '',
      asset.fileKey,
    ].join('|');
    return _loadCachedAsset(
      cacheKey,
      () => _port.loadArticleAsset(article: article, asset: asset!),
      cacheFailure: true,
    );
  }

  Future<MobileSubscriptionArticleAssetResult> loadSavedNoteAsset(
    V3FeedItem note,
    String logicalPath,
  ) {
    final port = _port;
    if (_port.isDemo ||
        port is! MobileSubscriptionNoteAssetPort ||
        !note.isSavedSubscriptionNote ||
        !isV3SubscriptionNoteAssetPath(logicalPath)) {
      return Future<MobileSubscriptionArticleAssetResult>.value(
        const MobileSubscriptionArticleAssetResult.failure(
          'SUBSCRIPTION_ASSET_NOT_AVAILABLE',
        ),
      );
    }
    final cacheKey = <String>[
      'note',
      note.remoteNoteId!,
      note.rawPartRevisionId ?? '',
      logicalPath,
    ].join('|');
    return _loadCachedAsset(
      cacheKey,
      () => (port as MobileSubscriptionNoteAssetPort).loadSavedNoteAsset(
        note: note,
        logicalPath: logicalPath,
      ),
    );
  }

  Future<MobileSubscriptionArticleAssetResult> _loadCachedAsset(
    String cacheKey,
    Future<MobileSubscriptionArticleAssetResult> Function() load, {
    bool cacheFailure = false,
  }) {
    final cached = _assetCache[cacheKey];
    if (cached != null) {
      _assetCache
        ..remove(cacheKey)
        ..[cacheKey] = cached;
      return SynchronousFuture(cached);
    }
    final pending = _assetRequests[cacheKey];
    if (pending != null) return pending;
    final request = _loadAsset(
      load: load,
      cacheKey: cacheKey,
      cacheFailure: cacheFailure,
    );
    _assetRequests[cacheKey] = request;
    return request;
  }

  Future<MobileSubscriptionActionResult> saveArticle(String noteId) async {
    final article = articleForId(noteId);
    if (_mode != MobileSubscriptionRuntimeMode.remote ||
        article == null ||
        article.articleId == null) {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_ARTICLE_NOT_AVAILABLE',
      );
    }
    if (!_articleActionsInFlight.add(noteId)) {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_ACTION_IN_PROGRESS',
      );
    }
    _notify();
    final actionKey =
        'save:${article.articleId}:${article.articleRevisionId ?? 'current'}';
    final actionId = _actionId(actionKey);
    MobileSubscriptionActionResult result;
    try {
      result = await _port.saveArticleAsNote(
        article: article,
        actionId: actionId,
      );
    } on Object {
      result = const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_SAVE_FAILED',
      );
    }
    if (_disposed) return result;
    _articleActionsInFlight.remove(noteId);
    final saved = result.item;
    if (result.status == MobileSubscriptionResultStatus.success &&
        saved != null &&
        !saved.isReadOnly &&
        saved.remoteNoteId != null) {
      final errorCode = await _onSavedArticle(saved);
      if (errorCode == null) {
        _pendingActionIds.remove(actionKey);
      } else {
        result = MobileSubscriptionActionResult.failure(errorCode);
      }
    }
    _notify();
    return result;
  }

  Future<void> _loadCatalog() {
    if (_port.isDemo) return Future<void>.value();
    final active = _loadInFlight;
    if (active != null) return active;
    late final Future<void> request;
    request = _loadCatalogOnce().whenComplete(() {
      if (identical(_loadInFlight, request)) _loadInFlight = null;
    });
    _loadInFlight = request;
    return request;
  }

  Future<void> _loadCatalogOnce() async {
    final generation = ++_loadGeneration;
    _assetCache.removeWhere(
      (_, result) => result.status != MobileSubscriptionResultStatus.success,
    );
    _mode = MobileSubscriptionRuntimeMode.loading;
    _errorCode = null;
    _notify();
    MobileSubscriptionCatalogResult result;
    try {
      result = await _port.loadCatalog();
    } on Object {
      result = const MobileSubscriptionCatalogResult.failure(
        'SUBSCRIPTION_LOAD_FAILED',
      );
    }
    if (_disposed) return;
    if (result.status != MobileSubscriptionResultStatus.success) {
      _mode = result.status == MobileSubscriptionResultStatus.unavailable
          ? MobileSubscriptionRuntimeMode.unavailable
          : MobileSubscriptionRuntimeMode.failure;
      _errorCode = result.errorCode ?? 'SUBSCRIPTION_LOAD_FAILED';
      _notify();
      return;
    }
    _applyCatalog(result);
    final refreshPort = _port;
    if (refreshPort is MobileSubscriptionCatalogRefreshPort) {
      await _completeCatalog(
        refreshPort as MobileSubscriptionCatalogRefreshPort,
        generation,
      );
    }
  }

  Future<void> _completeCatalog(
    MobileSubscriptionCatalogRefreshPort refreshPort,
    int generation,
  ) async {
    MobileSubscriptionCatalogResult result;
    try {
      result = await refreshPort.loadCompleteCatalog();
    } on Object {
      return;
    }
    if (_disposed ||
        generation != _loadGeneration ||
        result.status != MobileSubscriptionResultStatus.success) {
      return;
    }
    _applyCatalog(result);
  }

  void _applyCatalog(MobileSubscriptionCatalogResult result) {
    final publications = <MobileSubscriptionPublication>[];
    final articlesById = <String, V3FeedItem>{};
    for (final publication in result.publications) {
      final articles = <V3FeedItem>[];
      for (final catalogArticle in publication.articles) {
        final article = _retainHydratedArticle(catalogArticle);
        articles.add(article);
        articlesById[article.id] = article;
      }
      publications.add(
        MobileSubscriptionPublication(
          publicationId: publication.publicationId,
          title: publication.title,
          summary: publication.summary,
          sectionCount: publication.sectionCount,
          articleCount: publication.articleCount,
          updatedAt: publication.updatedAt,
          articles: List<V3FeedItem>.unmodifiable(articles),
          followed: publication.followed,
          available: publication.available,
          unavailableReason: publication.unavailableReason,
        ),
      );
    }
    _publications = List<MobileSubscriptionPublication>.unmodifiable(
      publications,
    );
    _articlesById = Map<String, V3FeedItem>.unmodifiable(articlesById);
    _hydratedArticleRevisions.retainWhere(
      (key) => articlesById.values.any(
        (article) => _articleRevisionKey(article) == key,
      ),
    );
    _mode = MobileSubscriptionRuntimeMode.remote;
    _errorCode = null;
    _onCatalogApplied();
    _notify();
  }

  V3FeedItem _retainHydratedArticle(V3FeedItem catalogArticle) {
    final existing = _articlesById[catalogArticle.id];
    final revisionId = catalogArticle.articleRevisionId?.trim();
    if (existing == null ||
        revisionId == null ||
        revisionId.isEmpty ||
        existing.articleId != catalogArticle.articleId ||
        existing.articleRevisionId != revisionId ||
        !_hydratedArticleRevisions.contains(_articleRevisionKey(existing))) {
      return catalogArticle;
    }
    return catalogArticle.copyWith(
      rawBody: existing.rawBody,
      subscriptionArticleAssets: existing.subscriptionArticleAssets,
      author: existing.author,
      publicUrl: existing.publicUrl,
    );
  }

  Future<MobileSubscriptionArticleAssetResult> _loadAsset({
    required Future<MobileSubscriptionArticleAssetResult> Function() load,
    required String cacheKey,
    required bool cacheFailure,
  }) async {
    MobileSubscriptionArticleAssetResult result;
    try {
      result = await load();
    } on Object {
      result = const MobileSubscriptionArticleAssetResult.failure(
        'SUBSCRIPTION_ASSET_LOAD_FAILED',
      );
    }
    _assetRequests.remove(cacheKey);
    if (_disposed) return result;
    final loaded = result.asset;
    if ((result.status == MobileSubscriptionResultStatus.success &&
            loaded != null) ||
        cacheFailure) {
      if (!_assetCache.containsKey(cacheKey) &&
          _assetCache.length >= _maxAssetCacheEntries) {
        _assetCache.remove(_assetCache.keys.first);
      }
      _assetCache[cacheKey] = result;
    }
    return result;
  }

  Future<MobileSubscriptionActionResult> _ensureArticleDetail(
    V3FeedItem article, {
    required bool markActionInFlight,
  }) {
    final requestKey = _articleRevisionKey(article);
    if (_hydratedArticleRevisions.contains(requestKey)) {
      return Future<MobileSubscriptionActionResult>.value(
        MobileSubscriptionActionResult.success(articleForId(article.id)),
      );
    }
    final pending = _articleDetailRequests[requestKey];
    if (pending != null) {
      if (!markActionInFlight) return pending;
      if (!_articleActionsInFlight.add(article.id)) {
        return Future<MobileSubscriptionActionResult>.value(
          const MobileSubscriptionActionResult.failure(
            'SUBSCRIPTION_ACTION_IN_PROGRESS',
          ),
        );
      }
      _notify();
      return _joinPendingArticleDetail(pending, article.id);
    }
    if (markActionInFlight && !_articleActionsInFlight.add(article.id)) {
      return Future<MobileSubscriptionActionResult>.value(
        const MobileSubscriptionActionResult.failure(
          'SUBSCRIPTION_ACTION_IN_PROGRESS',
        ),
      );
    }
    if (markActionInFlight) _notify();
    final request = _loadArticleDetail(
      article: article,
      requestKey: requestKey,
      markedActionInFlight: markActionInFlight,
    );
    _articleDetailRequests[requestKey] = request;
    return request;
  }

  Future<MobileSubscriptionActionResult> _joinPendingArticleDetail(
    Future<MobileSubscriptionActionResult> pending,
    String noteId,
  ) async {
    try {
      return await pending;
    } finally {
      if (!_disposed) {
        _articleActionsInFlight.remove(noteId);
        _notify();
      }
    }
  }

  Future<MobileSubscriptionActionResult> _loadArticleDetail({
    required V3FeedItem article,
    required String requestKey,
    required bool markedActionInFlight,
  }) async {
    MobileSubscriptionActionResult result;
    try {
      result = await _port.loadArticle(article);
    } on Object {
      result = const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_ARTICLE_LOAD_FAILED',
      );
    }
    _articleDetailRequests.remove(requestKey);
    if (_disposed) return result;
    final detail = result.item;
    final current = articleForId(article.id);
    final requestedRevision = article.articleRevisionId?.trim();
    final detailRevision = detail?.articleRevisionId?.trim();
    var articleReplaced = false;
    if (result.status == MobileSubscriptionResultStatus.success &&
        detail != null &&
        detail.id == article.id &&
        detail.articleId == article.articleId &&
        (requestedRevision == null ||
            requestedRevision.isEmpty ||
            detailRevision == requestedRevision) &&
        current != null &&
        _articleRevisionKey(current) == requestKey) {
      _replaceArticle(detail);
      _hydratedArticleRevisions.add(_articleRevisionKey(detail));
      articleReplaced = true;
    } else if (result.status == MobileSubscriptionResultStatus.success) {
      result = const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_ARTICLE_REVISION_MISMATCH',
      );
    }
    if (markedActionInFlight) {
      _articleActionsInFlight.remove(article.id);
    }
    if (articleReplaced || markedActionInFlight) {
      _notify();
    }
    return result;
  }

  String _articleRevisionKey(V3FeedItem article) => <String>[
    article.id,
    article.articleId ?? '',
    article.articleRevisionId ?? 'current',
  ].join('|');

  void _replacePublication(
    int index,
    MobileSubscriptionPublication publication,
  ) {
    final values = List<MobileSubscriptionPublication>.of(_publications);
    values[index] = publication;
    _publications = List<MobileSubscriptionPublication>.unmodifiable(values);
  }

  void _replaceArticle(V3FeedItem article) {
    if (_articlesById.containsKey(article.id)) {
      _articlesById = Map<String, V3FeedItem>.unmodifiable(<String, V3FeedItem>{
        ..._articlesById,
        article.id: article,
      });
    }
    final values = <MobileSubscriptionPublication>[];
    for (final publication in _publications) {
      final index = publication.articles.indexWhere(
        (candidate) => candidate.id == article.id,
      );
      if (index < 0) {
        values.add(publication);
        continue;
      }
      final articles = List<V3FeedItem>.of(publication.articles);
      articles[index] = article;
      values.add(
        MobileSubscriptionPublication(
          publicationId: publication.publicationId,
          title: publication.title,
          summary: publication.summary,
          sectionCount: publication.sectionCount,
          articleCount: publication.articleCount,
          updatedAt: publication.updatedAt,
          articles: List<V3FeedItem>.unmodifiable(articles),
          followed: publication.followed,
          available: publication.available,
          unavailableReason: publication.unavailableReason,
        ),
      );
    }
    _publications = List<MobileSubscriptionPublication>.unmodifiable(values);
  }

  String _actionId(String actionKey) {
    return _pendingActionIds.putIfAbsent(actionKey, () {
      _actionSequence += 1;
      return '$actionKey:${_now().microsecondsSinceEpoch}:$_actionSequence';
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration += 1;
    _articleDetailRequests.clear();
    _hydratedArticleRevisions.clear();
    _assetRequests.clear();
    _assetCache.clear();
    super.dispose();
  }
}
