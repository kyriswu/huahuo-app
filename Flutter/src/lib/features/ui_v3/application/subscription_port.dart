import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../domain/feed_item_models.dart';
import 'knowledge_note_port.dart';

const _subscriptionCatalogPageLimit = 100;
const _subscriptionCatalogMaximumPages = 100;

enum MobileSubscriptionResultStatus { success, unavailable, failure }

enum MobileSubscriptionRuntimeMode {
  demo,
  loading,
  remote,
  unavailable,
  failure,
}

@immutable
final class MobileSubscriptionPublication {
  const MobileSubscriptionPublication({
    required this.publicationId,
    required this.title,
    required this.sectionCount,
    required this.articleCount,
    required this.updatedAt,
    required this.articles,
    required this.followed,
    required this.available,
    this.summary,
    this.unavailableReason,
  });

  final String publicationId;
  final String title;
  final String? summary;
  final int sectionCount;
  final int articleCount;
  final DateTime updatedAt;
  final List<V3FeedItem> articles;
  final bool followed;
  final bool available;
  final String? unavailableReason;

  MobileSubscriptionPublication copyWith({bool? followed}) {
    return MobileSubscriptionPublication(
      publicationId: publicationId,
      title: title,
      summary: summary,
      sectionCount: sectionCount,
      articleCount: articleCount,
      updatedAt: updatedAt,
      articles: articles,
      followed: followed ?? this.followed,
      available: available,
      unavailableReason: unavailableReason,
    );
  }
}

@immutable
final class MobileSubscriptionCatalogResult {
  const MobileSubscriptionCatalogResult._({
    required this.status,
    this.publications = const <MobileSubscriptionPublication>[],
    this.errorCode,
  });

  const MobileSubscriptionCatalogResult.success(
    List<MobileSubscriptionPublication> publications,
  ) : this._(
        status: MobileSubscriptionResultStatus.success,
        publications: publications,
      );

  const MobileSubscriptionCatalogResult.unavailable(String errorCode)
    : this._(
        status: MobileSubscriptionResultStatus.unavailable,
        errorCode: errorCode,
      );

  const MobileSubscriptionCatalogResult.failure(String errorCode)
    : this._(
        status: MobileSubscriptionResultStatus.failure,
        errorCode: errorCode,
      );

  final MobileSubscriptionResultStatus status;
  final List<MobileSubscriptionPublication> publications;
  final String? errorCode;
}

@immutable
final class MobileSubscriptionActionResult {
  const MobileSubscriptionActionResult._({
    required this.status,
    this.item,
    this.errorCode,
  });

  const MobileSubscriptionActionResult.success([V3FeedItem? item])
    : this._(status: MobileSubscriptionResultStatus.success, item: item);

  const MobileSubscriptionActionResult.unavailable(String errorCode)
    : this._(
        status: MobileSubscriptionResultStatus.unavailable,
        errorCode: errorCode,
      );

  const MobileSubscriptionActionResult.failure(String errorCode)
    : this._(
        status: MobileSubscriptionResultStatus.failure,
        errorCode: errorCode,
      );

  final MobileSubscriptionResultStatus status;
  final V3FeedItem? item;
  final String? errorCode;
}

@immutable
final class MobileSubscriptionArticleAsset {
  const MobileSubscriptionArticleAsset({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String mimeType;
}

@immutable
final class MobileSubscriptionArticleAssetResult {
  const MobileSubscriptionArticleAssetResult._({
    required this.status,
    this.asset,
    this.errorCode,
  });

  const MobileSubscriptionArticleAssetResult.success(
    MobileSubscriptionArticleAsset asset,
  ) : this._(status: MobileSubscriptionResultStatus.success, asset: asset);

  const MobileSubscriptionArticleAssetResult.unavailable(String errorCode)
    : this._(
        status: MobileSubscriptionResultStatus.unavailable,
        errorCode: errorCode,
      );

  const MobileSubscriptionArticleAssetResult.failure(String errorCode)
    : this._(
        status: MobileSubscriptionResultStatus.failure,
        errorCode: errorCode,
      );

  final MobileSubscriptionResultStatus status;
  final MobileSubscriptionArticleAsset? asset;
  final String? errorCode;
}

abstract interface class MobileSubscriptionPort {
  bool get isDemo;

  Future<MobileSubscriptionCatalogResult> loadCatalog();

  Future<MobileSubscriptionActionResult> setPublicationFollowed({
    required String publicationId,
    required bool followed,
    required String actionId,
  });

  Future<MobileSubscriptionActionResult> loadArticle(V3FeedItem article);

  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset({
    required V3FeedItem article,
    required V3SubscriptionArticleAssetRef asset,
  });

  Future<MobileSubscriptionActionResult> saveArticleAsNote({
    required V3FeedItem article,
    required String actionId,
  });
}

/// A remote catalog may publish a first-screen projection, then complete its
/// opaque cursor chain without delaying the Knowledge Square shell.
abstract interface class MobileSubscriptionCatalogRefreshPort {
  Future<MobileSubscriptionCatalogResult> loadCompleteCatalog();
}

abstract interface class MobileSubscriptionNoteAssetPort {
  Future<MobileSubscriptionArticleAssetResult> loadSavedNoteAsset({
    required V3FeedItem note,
    required String logicalPath,
  });
}

final class DemoMobileSubscriptionPort implements MobileSubscriptionPort {
  const DemoMobileSubscriptionPort();

  @override
  bool get isDemo => true;

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() async =>
      const MobileSubscriptionCatalogResult.unavailable(
        'SUBSCRIPTION_DEMO_ONLY',
      );

  @override
  Future<MobileSubscriptionActionResult> loadArticle(
    V3FeedItem article,
  ) async => const MobileSubscriptionActionResult.unavailable(
    'SUBSCRIPTION_DEMO_ONLY',
  );

  @override
  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset({
    required V3FeedItem article,
    required V3SubscriptionArticleAssetRef asset,
  }) async => const MobileSubscriptionArticleAssetResult.unavailable(
    'SUBSCRIPTION_DEMO_ONLY',
  );

  @override
  Future<MobileSubscriptionActionResult> saveArticleAsNote({
    required V3FeedItem article,
    required String actionId,
  }) async => const MobileSubscriptionActionResult.unavailable(
    'SUBSCRIPTION_DEMO_ONLY',
  );

  @override
  Future<MobileSubscriptionActionResult> setPublicationFollowed({
    required String publicationId,
    required bool followed,
    required String actionId,
  }) async => const MobileSubscriptionActionResult.unavailable(
    'SUBSCRIPTION_DEMO_ONLY',
  );
}

final class RemoteMobileSubscriptionPort
    implements
        MobileSubscriptionPort,
        MobileSubscriptionCatalogRefreshPort,
        MobileSubscriptionNoteAssetPort {
  factory RemoteMobileSubscriptionPort({
    required ApiClient apiClient,
    required String? Function() workspaceId,
  }) {
    return RemoteMobileSubscriptionPort._(
      subscription: SubscriptionClient(apiClient),
      workspaceContent: WorkspaceContentClient(apiClient),
      noteReader: RemoteKnowledgeNotePort(
        apiClient: apiClient,
        workspaceId: workspaceId,
      ),
      workspaceId: workspaceId,
    );
  }

  RemoteMobileSubscriptionPort._({
    required this._subscription,
    required this._workspaceContent,
    required this._noteReader,
    required this._workspaceId,
  });

  final SubscriptionClient _subscription;
  final WorkspaceContentClient _workspaceContent;
  final KnowledgeNoteRemoteDetailPort _noteReader;
  final String? Function() _workspaceId;
  _SubscriptionCatalogFirstScreen? _latestFirstScreen;
  Future<_SubscriptionCatalogFirstScreen>? _firstScreenRequest;

  @override
  bool get isDemo => false;

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() async {
    final workspaceId = _activeWorkspaceId();
    _debugSubscriptionCatalog(
      'fast-load-start workspace=${workspaceId == null ? 'absent' : 'present'}',
    );
    try {
      final firstScreen = await _loadFirstScreen(
        workspaceId: workspaceId,
        force: true,
      );
      return _catalogFromPages(
        publications: firstScreen.publications.items,
        library:
            firstScreen.library?.items ??
            const <SharedSubscriptionLibraryPublication>[],
        articles: firstScreen.articles.items,
        logStage: 'fast-load',
      );
    } on _SubscriptionCatalogLoadFailure catch (failure) {
      _debugSubscriptionCatalog('fast-load-failed code=${failure.code}');
      return _catalogFailure(failure.code);
    } on FormatException {
      _debugSubscriptionCatalog(
        'fast-load-failed code=SUBSCRIPTION_RESPONSE_INVALID',
      );
      return const MobileSubscriptionCatalogResult.failure(
        'SUBSCRIPTION_RESPONSE_INVALID',
      );
    } on Object {
      _debugSubscriptionCatalog(
        'fast-load-failed code=SUBSCRIPTION_LOAD_FAILED',
      );
      return const MobileSubscriptionCatalogResult.failure(
        'SUBSCRIPTION_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileSubscriptionCatalogResult> loadCompleteCatalog() async {
    final workspaceId = _activeWorkspaceId();
    try {
      final cachedFirstScreen = _latestFirstScreen;
      final firstScreen =
          cachedFirstScreen != null &&
              cachedFirstScreen.workspaceId == workspaceId
          ? cachedFirstScreen
          : await _loadFirstScreen(workspaceId: workspaceId, force: true);
      final publicationsFuture = _loadPagesFromFirst(
        firstScreen.publications,
        (cursor) => _subscription.publicationPage(
          cursor: cursor,
          limit: _subscriptionCatalogPageLimit,
        ),
      );
      final libraryFuture = firstScreen.library == null
          ? Future<_PortPageResult<SharedSubscriptionLibraryPublication>>.value(
              const _PortPageSuccess<SharedSubscriptionLibraryPublication>(
                <SharedSubscriptionLibraryPublication>[],
              ),
            )
          : _loadPagesFromFirst(
              firstScreen.library!,
              (cursor) => _subscription.libraryPage(
                workspaceId!,
                cursor: cursor,
                limit: _subscriptionCatalogPageLimit,
              ),
            );
      final articlesFuture = _loadPagesFromFirst(
        firstScreen.articles,
        (cursor) => _subscription.globalArticlePage(
          cursor: cursor,
          limit: _subscriptionCatalogPageLimit,
        ),
      );
      final publications = await publicationsFuture;
      final library = await libraryFuture;
      final articles = await articlesFuture;
      if (publications case _PortPageFailure<SharedSubscriptionPublication>()) {
        return _catalogFailure(publications.code);
      }
      if (library
          case _PortPageFailure<SharedSubscriptionLibraryPublication>()) {
        return _catalogFailure(library.code);
      }
      if (articles case _PortPageFailure<SharedSubscriptionArticle>()) {
        return _catalogFailure(articles.code);
      }
      return _catalogFromPages(
        publications:
            (publications as _PortPageSuccess<SharedSubscriptionPublication>)
                .items,
        library:
            (library as _PortPageSuccess<SharedSubscriptionLibraryPublication>)
                .items,
        articles:
            (articles as _PortPageSuccess<SharedSubscriptionArticle>).items,
        logStage: 'complete-load',
      );
    } on _SubscriptionCatalogLoadFailure catch (failure) {
      _debugSubscriptionCatalog('complete-load-failed code=${failure.code}');
      return _catalogFailure(failure.code);
    } on FormatException {
      return const MobileSubscriptionCatalogResult.failure(
        'SUBSCRIPTION_RESPONSE_INVALID',
      );
    } on Object {
      return const MobileSubscriptionCatalogResult.failure(
        'SUBSCRIPTION_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileSubscriptionActionResult> setPublicationFollowed({
    required String publicationId,
    required bool followed,
    required String actionId,
  }) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) return _actionUnavailable();
    try {
      final result = followed
          ? await _subscription.followPublication(
              workspaceId,
              publicationId,
              idempotencyKey: _actionKey(
                workspaceId,
                publicationId,
                'follow',
                actionId,
              ),
            )
          : await _subscription.unfollowPublication(
              workspaceId,
              publicationId,
              idempotencyKey: _actionKey(
                workspaceId,
                publicationId,
                'unfollow',
                actionId,
              ),
            );
      final data = result.data;
      if (!result.ok || data == null) return _actionFailure(result);
      if (data.workspaceId != workspaceId ||
          data.publicationId != publicationId ||
          data.lifecycle != (followed ? 'following' : 'unfollowed')) {
        return const MobileSubscriptionActionResult.failure(
          'SUBSCRIPTION_RESPONSE_INVALID',
        );
      }
      return const MobileSubscriptionActionResult.success();
    } on ArgumentError {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_REQUEST_INVALID',
      );
    } on Object {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_MUTATION_FAILED',
      );
    }
  }

  @override
  Future<MobileSubscriptionActionResult> loadArticle(V3FeedItem article) async {
    final articleId = _nonEmpty(article.articleId);
    final revisionId = _nonEmpty(article.articleRevisionId);
    if (articleId == null) {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_ARTICLE_ID_MISSING',
      );
    }
    try {
      final result = revisionId == null
          ? await _subscription.article(articleId)
          : await _subscription.articleRevision(articleId, revisionId);
      final revision = result.data;
      if (!result.ok || revision == null) return _actionFailure(result);
      if (revision.articleId != articleId ||
          (revisionId != null && revision.articleRevisionId != revisionId)) {
        return const MobileSubscriptionActionResult.failure(
          'SUBSCRIPTION_ARTICLE_REVISION_MISMATCH',
        );
      }
      return MobileSubscriptionActionResult.success(
        _mapArticleRevision(article, revision),
      );
    } on Object {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_ARTICLE_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileSubscriptionArticleAssetResult> loadSavedNoteAsset({
    required V3FeedItem note,
    required String logicalPath,
  }) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) {
      return const MobileSubscriptionArticleAssetResult.unavailable(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    if (!note.isSavedSubscriptionNote ||
        !isV3SubscriptionNoteAssetPath(logicalPath)) {
      return const MobileSubscriptionArticleAssetResult.failure(
        'SUBSCRIPTION_ASSET_NOT_AVAILABLE',
      );
    }
    try {
      return _decodeSubscriptionImage(
        await _subscription.savedNoteAsset(
          workspaceId,
          note.remoteNoteId!,
          logicalPath: logicalPath,
        ),
      );
    } on Object {
      return const MobileSubscriptionArticleAssetResult.failure(
        'SUBSCRIPTION_ASSET_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset({
    required V3FeedItem article,
    required V3SubscriptionArticleAssetRef asset,
  }) async {
    final articleId = _nonEmpty(article.articleId);
    final revisionId = _nonEmpty(article.articleRevisionId);
    if (articleId == null || revisionId == null) {
      return const MobileSubscriptionArticleAssetResult.failure(
        'SUBSCRIPTION_ARTICLE_REVISION_MISSING',
      );
    }
    final expected = article.subscriptionArticleAssets.any(
      (candidate) =>
          candidate.fileKey == asset.fileKey &&
          candidate.logicalPath == asset.logicalPath,
    );
    if (!expected) {
      return const MobileSubscriptionArticleAssetResult.failure(
        'SUBSCRIPTION_ASSET_NOT_AVAILABLE',
      );
    }
    try {
      final result = await _subscription.articleRevisionAsset(
        articleId,
        revisionId,
        asset.fileKey,
      );
      return _decodeSubscriptionImage(result);
    } on Object {
      return const MobileSubscriptionArticleAssetResult.failure(
        'SUBSCRIPTION_ASSET_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileSubscriptionActionResult> saveArticleAsNote({
    required V3FeedItem article,
    required String actionId,
  }) async {
    final workspaceId = _activeWorkspaceId();
    final articleId = _nonEmpty(article.articleId);
    final articleRevisionId = _nonEmpty(article.articleRevisionId);
    if (workspaceId == null) return _actionUnavailable();
    if (articleId == null) {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_ARTICLE_ID_MISSING',
      );
    }
    if (articleRevisionId == null) {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_ARTICLE_REVISION_MISSING',
      );
    }
    try {
      final saved = await _subscription.saveArticleAsNote(
        workspaceId,
        articleId,
        articleRevisionId: articleRevisionId,
        idempotencyKey: _actionKey(workspaceId, articleId, 'save', actionId),
      );
      final receipt = saved.data;
      if (!saved.ok || receipt == null) return _actionFailure(saved);
      if (receipt.articleId != articleId ||
          receipt.articleRevisionId != articleRevisionId) {
        return const MobileSubscriptionActionResult.failure(
          'SUBSCRIPTION_SAVE_RECEIPT_INVALID',
        );
      }
      if (!receipt.created) {
        final current = await _noteReader.loadNote(
          receipt.noteId,
          localId: receipt.noteId,
        );
        final note = current.remoteNote;
        if (current.status != KnowledgeNotePortStatus.success ||
            note == null ||
            note.isReadOnly ||
            note.remoteNoteId != receipt.noteId) {
          return const MobileSubscriptionActionResult.failure(
            'SUBSCRIPTION_SAVED_NOTE_INVALID',
          );
        }
        return MobileSubscriptionActionResult.success(
          note.copyWith(
            source: V3MaterialSource.subscription,
            remoteSourceKind: 'subscription_article',
            copiedFromContentId: article.id,
            publicationId: article.publicationId,
            articleId: article.articleId,
            articleRevisionId: receipt.articleRevisionId,
            subscriptionArticleAssets: article.subscriptionArticleAssets,
            author: article.author,
          ),
        );
      }
      final note = await _workspaceContent.legacyNote(
        workspaceId,
        receipt.noteId,
        revisionId: receipt.noteRevisionId,
      );
      final head = note.data?.fields;
      final title = head == null ? null : _remoteText(head, 'title');
      final createdAt = head == null
          ? null
          : DateTime.tryParse(_remoteText(head, 'createdAt') ?? '');
      final updatedAt = head == null
          ? null
          : DateTime.tryParse(_remoteText(head, 'updatedAt') ?? '');
      if (!note.ok ||
          head == null ||
          title == null ||
          createdAt == null ||
          updatedAt == null ||
          _remoteText(head, 'noteId') != receipt.noteId ||
          _remoteText(head, 'noteRevisionId') != receipt.noteRevisionId ||
          _remoteText(head, 'rawPartRevisionId') != receipt.rawPartRevisionId ||
          _remoteText(head, 'state') != 'live') {
        return const MobileSubscriptionActionResult.failure(
          'SUBSCRIPTION_SAVED_NOTE_INVALID',
        );
      }
      final raw = await _workspaceContent.legacyRawNotePart(
        workspaceId,
        receipt.noteId,
        partRevisionId: receipt.rawPartRevisionId,
      );
      final rawFields = raw.data?.fields;
      final rawBody = rawFields == null
          ? null
          : _remoteText(rawFields, 'contentMarkdown', allowEmpty: true) ??
                _remoteText(rawFields, 'markdown', allowEmpty: true);
      if (!raw.ok ||
          rawFields == null ||
          rawBody == null ||
          _remoteText(rawFields, 'partRevisionId') !=
              receipt.rawPartRevisionId) {
        return const MobileSubscriptionActionResult.failure(
          'SUBSCRIPTION_SAVED_NOTE_INVALID',
        );
      }
      return MobileSubscriptionActionResult.success(
        _mapSavedNote(
          article,
          receipt,
          title: title,
          rawBody: rawBody,
          createdAt: createdAt,
          updatedAt: updatedAt,
        ),
      );
    } on Object {
      return const MobileSubscriptionActionResult.failure(
        'SUBSCRIPTION_SAVE_FAILED',
      );
    }
  }

  Future<_SubscriptionCatalogFirstScreen> _loadFirstScreen({
    required String? workspaceId,
    required bool force,
  }) async {
    if (!force && _latestFirstScreen != null) return _latestFirstScreen!;
    final activeRequest = _firstScreenRequest;
    if (activeRequest != null) return activeRequest;
    final request = _requestFirstScreen(workspaceId: workspaceId);
    _firstScreenRequest = request;
    try {
      final value = await request;
      _latestFirstScreen = value;
      return value;
    } finally {
      if (identical(_firstScreenRequest, request)) {
        _firstScreenRequest = null;
      }
    }
  }

  Future<_SubscriptionCatalogFirstScreen> _requestFirstScreen({
    required String? workspaceId,
  }) async {
    // All independent requests are started before the first await, matching
    // the authenticated Knowledge Square fast-load contract.
    final publicationsFuture = _subscription.publicationPage(
      limit: _subscriptionCatalogPageLimit,
    );
    final libraryFuture = workspaceId == null
        ? null
        : _subscription.libraryPage(
            workspaceId,
            limit: _subscriptionCatalogPageLimit,
          );
    final articlesFuture = _subscription.globalArticlePage(
      limit: _subscriptionCatalogPageLimit,
    );
    final publications = await _requireSubscriptionPage(publicationsFuture);
    final library = libraryFuture == null
        ? null
        : await _requireSubscriptionPage(libraryFuture);
    final articles = await _requireSubscriptionPage(articlesFuture);
    _requireFirstScreenPublicationCounts(publications);
    _requireFirstScreenArticles(articles);
    return _SubscriptionCatalogFirstScreen(
      workspaceId: workspaceId,
      publications: publications,
      library: library,
      articles: articles,
    );
  }

  void _requireFirstScreenPublicationCounts(
    SharedSubscriptionPage<SharedSubscriptionPublication> publications,
  ) {
    if (publications.items.isEmpty) {
      throw const _SubscriptionCatalogLoadFailure(
        'SUBSCRIPTION_CATALOG_NOT_FOUND',
      );
    }
    if (publications.items.any(
      (publication) =>
          publication.sectionCount == null || publication.articleCount == null,
    )) {
      throw const _SubscriptionCatalogLoadFailure(
        'SUBSCRIPTION_RESPONSE_INVALID',
      );
    }
  }

  void _requireFirstScreenArticles(
    SharedSubscriptionPage<SharedSubscriptionArticle> articles,
  ) {
    if (articles.items.isEmpty) {
      throw const _SubscriptionCatalogLoadFailure(
        'SUBSCRIPTION_CATALOG_NOT_FOUND',
      );
    }
  }

  Future<SharedSubscriptionPage<T>> _requireSubscriptionPage<T>(
    Future<ApiResult<SharedSubscriptionPage<T>>> request,
  ) async {
    final result = await request;
    final page = result.data;
    if (!result.ok || page == null) {
      throw _SubscriptionCatalogLoadFailure(
        result.error?.code ?? 'SUBSCRIPTION_LOAD_FAILED',
      );
    }
    return page;
  }

  Future<_PortPageResult<T>> _loadPagesFromFirst<T>(
    SharedSubscriptionPage<T> first,
    Future<ApiResult<SharedSubscriptionPage<T>>> Function(String? cursor)
    request,
  ) async {
    final values = <T>[...first.items];
    final observed = <String>{};
    String? cursor = _nonEmpty(first.nextCursor);
    if (cursor != null) observed.add(cursor);
    var pageCount = 1;
    do {
      if (cursor == null) break;
      pageCount += 1;
      if (pageCount > _subscriptionCatalogMaximumPages) {
        return _PortPageFailure<T>('SUBSCRIPTION_PAGE_LIMIT_EXCEEDED');
      }
      final result = await request(cursor);
      final page = result.data;
      if (!result.ok || page == null) {
        _debugSubscriptionCatalog(
          'page-failed code=${result.error?.code ?? 'SUBSCRIPTION_LOAD_FAILED'} '
          'dto=${_subscriptionDtoDiagnostic(result.error?.cause)}',
        );
        return _PortPageFailure<T>(
          result.error?.code ?? 'SUBSCRIPTION_LOAD_FAILED',
        );
      }
      values.addAll(page.items);
      final next = _nonEmpty(page.nextCursor);
      if (next == null) break;
      if (!observed.add(next)) {
        return _PortPageFailure<T>('SUBSCRIPTION_CURSOR_INVALID');
      }
      cursor = next;
    } while (true);
    return _PortPageSuccess<T>(List<T>.unmodifiable(values));
  }

  MobileSubscriptionCatalogResult _catalogFromPages({
    required List<SharedSubscriptionPublication> publications,
    required List<SharedSubscriptionLibraryPublication> library,
    required List<SharedSubscriptionArticle> articles,
    required String logStage,
  }) {
    final publicationValues = <String, SharedSubscriptionPublication>{
      for (final publication in publications)
        publication.publicationId: publication,
    };
    final libraryValues = <String, SharedSubscriptionLibraryPublication>{
      for (final item in library) item.publication.publicationId: item,
    };
    for (final item in libraryValues.values) {
      publicationValues.putIfAbsent(
        item.publication.publicationId,
        () => item.publication,
      );
    }
    final articlesByPublication = <String, List<SharedSubscriptionArticle>>{};
    for (final article in articles) {
      if (!publicationValues.containsKey(article.publicationId)) continue;
      articlesByPublication
          .putIfAbsent(
            article.publicationId,
            () => <SharedSubscriptionArticle>[],
          )
          .add(article);
    }
    final mapped = <MobileSubscriptionPublication>[];
    for (final publication in publicationValues.values) {
      final libraryItem = libraryValues[publication.publicationId];
      final available = libraryItem?.availability != 'unavailable';
      final articleItems = available
          ? articlesByPublication[publication.publicationId] ??
                const <SharedSubscriptionArticle>[]
          : const <SharedSubscriptionArticle>[];
      mapped.add(
        MobileSubscriptionPublication(
          publicationId: publication.publicationId,
          title: publication.title,
          summary: publication.summary,
          sectionCount: publication.sectionCount ?? 0,
          articleCount: publication.articleCount ?? articleItems.length,
          updatedAt: publication.updatedAt,
          articles: List<V3FeedItem>.unmodifiable(
            articleItems.map(
              (article) => _mapArticleListItem(
                article,
                fallbackDate: publication.updatedAt,
              ),
            ),
          ),
          followed: libraryItem != null,
          available: available,
          unavailableReason: libraryItem?.unavailableReason,
        ),
      );
    }
    _debugSubscriptionCatalog(
      '$logStage-success publications=${mapped.length} '
      'articles=${mapped.fold<int>(0, (total, item) => total + item.articles.length)}',
    );
    return MobileSubscriptionCatalogResult.success(
      List<MobileSubscriptionPublication>.unmodifiable(mapped),
    );
  }

  String? _activeWorkspaceId() {
    return _nonEmpty(_workspaceId());
  }
}

final class _SubscriptionCatalogFirstScreen {
  const _SubscriptionCatalogFirstScreen({
    required this.workspaceId,
    required this.publications,
    required this.library,
    required this.articles,
  });

  final String? workspaceId;
  final SharedSubscriptionPage<SharedSubscriptionPublication> publications;
  final SharedSubscriptionPage<SharedSubscriptionLibraryPublication>? library;
  final SharedSubscriptionPage<SharedSubscriptionArticle> articles;
}

final class _SubscriptionCatalogLoadFailure implements Exception {
  const _SubscriptionCatalogLoadFailure(this.code);

  final String code;
}

sealed class _PortPageResult<T> {
  const _PortPageResult();
}

final class _PortPageSuccess<T> extends _PortPageResult<T> {
  const _PortPageSuccess(this.items);

  final List<T> items;
}

final class _PortPageFailure<T> extends _PortPageResult<T> {
  const _PortPageFailure(this.code);

  final String code;
}

MobileSubscriptionCatalogResult _catalogFailure(String code) =>
    _isUnavailable(code)
    ? MobileSubscriptionCatalogResult.unavailable(code)
    : MobileSubscriptionCatalogResult.failure(code);

MobileSubscriptionActionResult _actionFailure(ApiResult<Object?> result) {
  final code = result.error?.code ?? 'SUBSCRIPTION_OPERATION_FAILED';
  return _isUnavailable(code)
      ? MobileSubscriptionActionResult.unavailable(code)
      : MobileSubscriptionActionResult.failure(code);
}

MobileSubscriptionActionResult _actionUnavailable() =>
    const MobileSubscriptionActionResult.unavailable(
      'WORKSPACE_CONTEXT_UNAVAILABLE',
    );

MobileSubscriptionArticleAssetResult _assetFailure(ApiResult<Object?> result) {
  final code = result.error?.code ?? 'SUBSCRIPTION_ASSET_LOAD_FAILED';
  return _isUnavailable(code)
      ? MobileSubscriptionArticleAssetResult.unavailable(code)
      : MobileSubscriptionArticleAssetResult.failure(code);
}

void _debugSubscriptionCatalog(String message) {
  if (kDebugMode) debugPrint('[SubscriptionCatalog] $message');
}

String _subscriptionDtoDiagnostic(Object? cause) {
  if (cause is! FormatException) return 'none';
  final message = cause.message.toString();
  return RegExp(r'^[A-Za-z][A-Za-z0-9 ._()/-]{0,95}$').hasMatch(message)
      ? message
      : 'invalid';
}

bool _isUnavailable(String code) =>
    code == 'WORKSPACE_CONTEXT_UNAVAILABLE' ||
    code == 'API_BASE_URL_UNCONFIGURED' ||
    code == 'SUBSCRIPTION_CATALOG_UNAVAILABLE' ||
    code.endsWith('_UNAVAILABLE');

String? _subscriptionImageMimeType(Map<String, String> headers) {
  String? value;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'content-type') {
      value = entry.value;
      break;
    }
  }
  final mimeType = value?.split(';').first.trim().toLowerCase();
  return switch (mimeType) {
    'image/png' ||
    'image/jpeg' ||
    'image/webp' ||
    'image/gif' ||
    'image/avif' => mimeType,
    _ => null,
  };
}

V3FeedItem _mapArticleListItem(
  SharedSubscriptionArticle article, {
  required DateTime fallbackDate,
}) {
  final timestamp = article.publishedAt ?? fallbackDate;
  return V3FeedItem(
    id: 'subscription-article-${_shortHash(article.articleId)}',
    title: article.title,
    source: V3MaterialSource.knowledgeSquare,
    createdAt: timestamp,
    updatedAt: timestamp,
    rawBody: '',
    summaryBody: article.summary,
    ownership: V3NoteOwnership.knowledgeSquare,
    publicationId: article.publicationId,
    articleId: article.articleId,
    articleRevisionId: article.currentArticleRevisionId,
    author: article.author,
  );
}

V3FeedItem _mapArticleRevision(
  V3FeedItem local,
  SharedSubscriptionArticleRevision revision,
) {
  return V3FeedItem(
    id: local.id,
    title: revision.title,
    source: V3MaterialSource.knowledgeSquare,
    createdAt: revision.publishedAt ?? local.createdAt,
    updatedAt: revision.publishedAt ?? local.updatedAt,
    rawBody: revision.contentMarkdown,
    summaryBody: local.summaryBody,
    ownership: V3NoteOwnership.knowledgeSquare,
    publicationId: local.publicationId,
    articleId: revision.articleId,
    articleRevisionId: revision.articleRevisionId,
    subscriptionArticleAssets: List<V3SubscriptionArticleAssetRef>.unmodifiable(
      revision.assetRefs
          .map(
            (asset) => V3SubscriptionArticleAssetRef(
              fileKey: asset.fileKey,
              logicalPath: asset.logicalPath,
            ),
          )
          .toList(growable: false),
    ),
    author: local.author,
  );
}

V3FeedItem _mapSavedNote(
  V3FeedItem article,
  SharedSubscriptionSaveReceipt receipt, {
  required String title,
  required String rawBody,
  required DateTime createdAt,
  required DateTime updatedAt,
}) {
  return V3FeedItem(
    id: receipt.noteId,
    title: title,
    source: V3MaterialSource.subscription,
    createdAt: createdAt,
    updatedAt: updatedAt,
    rawBody: rawBody,
    ownership: V3NoteOwnership.mine,
    copiedFromContentId: article.id,
    remoteRevision: 0,
    remoteNoteId: receipt.noteId,
    remoteSourceKind: 'subscription_article',
    noteRevisionId: receipt.noteRevisionId,
    rawPartRevisionId: receipt.rawPartRevisionId,
    outlinePartRevisionId: receipt.outlinePartRevisionId,
    germinationPartRevisionId: receipt.germinationPartRevisionId,
    etag: receipt.etag,
    contentCursor: receipt.contentCursor,
    syncState: NoteSyncState.synced,
    publicationId: article.publicationId,
    articleId: article.articleId,
    articleRevisionId: receipt.articleRevisionId,
    subscriptionArticleAssets: article.subscriptionArticleAssets,
    author: article.author,
  );
}

String? _remoteText(
  Map<String, Object?> fields,
  String key, {
  bool allowEmpty = false,
}) {
  final value = fields[key];
  if (value is! String) return null;
  return allowEmpty || value.trim().isNotEmpty ? value : null;
}

MobileSubscriptionArticleAssetResult _decodeSubscriptionImage(
  ApiResult<Uint8List> result,
) {
  final bytes = result.data;
  if (!result.ok || bytes == null || bytes.isEmpty) {
    return _assetFailure(result);
  }
  final mimeType = _subscriptionImageMimeType(result.responseHeaders);
  if (mimeType == null) {
    return const MobileSubscriptionArticleAssetResult.failure(
      'SUBSCRIPTION_ASSET_MEDIA_UNSUPPORTED',
    );
  }
  return MobileSubscriptionArticleAssetResult.success(
    MobileSubscriptionArticleAsset(bytes: bytes, mimeType: mimeType),
  );
}

String _actionKey(
  String workspaceId,
  String objectId,
  String operation,
  String actionId,
) {
  final value = '$workspaceId:$objectId:$operation:$actionId';
  return 'mobile-subscription-${sha256.convert(utf8.encode(value))}';
}

String _shortHash(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 20);

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
