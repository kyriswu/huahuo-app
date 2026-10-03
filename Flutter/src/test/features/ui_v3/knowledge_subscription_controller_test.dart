import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_subscription_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/subscription_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  test(
    'catalog reloads join completion without delaying first-screen publication',
    () async {
      final port = _ProgressiveSubscriptionPort();
      var publications = 0;
      final controller = KnowledgeSubscriptionController(
        port: port,
        onCatalogApplied: () => publications += 1,
        onSavedArticle: (_) async => null,
      );
      addTearDown(controller.dispose);

      final first = controller.reload();
      await pumpEventQueue();
      expect(controller.mode, MobileSubscriptionRuntimeMode.remote);
      expect(controller.publications, hasLength(1));
      expect(publications, 1);
      expect(port.initialLoads, 1);
      expect(port.completionLoads, 1);

      final joined = controller.reload();
      expect(identical(first, joined), isTrue);
      expect(port.initialLoads, 1);
      port.completion.complete(
        MobileSubscriptionCatalogResult.success(controller.publications),
      );
      await Future.wait([first, joined]);
      expect(publications, 2);

      await controller.reload();
      expect(port.initialLoads, 2);
      expect(port.completionLoads, 2);
    },
  );

  test(
    'catalog completion failure releases the reload owner for retry',
    () async {
      final port = _ProgressiveSubscriptionPort();
      final controller = KnowledgeSubscriptionController(
        port: port,
        onCatalogApplied: () {},
        onSavedArticle: (_) async => null,
      );
      addTearDown(controller.dispose);

      final first = controller.reload();
      await pumpEventQueue();
      port.completion.complete(
        const MobileSubscriptionCatalogResult.failure(
          'SUBSCRIPTION_LOAD_FAILED',
        ),
      );
      await first;
      port.completion = Completer<MobileSubscriptionCatalogResult>();
      final retry = controller.reload();
      await pumpEventQueue();
      expect(port.initialLoads, 2);
      expect(port.completionLoads, 2);
      port.completion.complete(
        MobileSubscriptionCatalogResult.success(controller.publications),
      );
      await retry;
    },
  );

  test(
    'saved Note images load without catalog and isolate cache by Note',
    () async {
      final port = _SubscriptionPort();
      final controller = KnowledgeSubscriptionController(
        port: port,
        onCatalogApplied: () {},
        onSavedArticle: (_) async => null,
      );
      addTearDown(controller.dispose);
      final note = V3FeedItem(
        id: 'saved-note',
        title: 'Saved',
        source: V3MaterialSource.subscription,
        createdAt: DateTime(2026, 8, 31),
        rawBody: '![Image](assets/cover.png)',
        remoteNoteId: 'remote-saved-note',
        rawPartRevisionId: 'raw-revision-1',
      );
      final first = controller.loadSavedNoteAsset(note, 'assets/cover.png');
      final duplicate = controller.loadSavedNoteAsset(note, 'assets/cover.png');
      expect(identical(first, duplicate), isTrue);
      port.assetResult.complete(
        MobileSubscriptionArticleAssetResult.success(
          MobileSubscriptionArticleAsset(
            bytes: Uint8List.fromList([1, 2, 3]),
            mimeType: 'image/png',
          ),
        ),
      );
      expect((await first).status, MobileSubscriptionResultStatus.success);
      await controller.loadSavedNoteAsset(note, 'assets/cover.png');
      expect(port.assetLoads, 1);
      await controller.loadSavedNoteAsset(
        note.copyWith(remoteNoteId: 'another-remote-note'),
        'assets/cover.png',
      );
      expect(port.assetLoads, 2);
      expect(port.articleLoads, 0);
      expect(controller.publications, isEmpty);
      expect(port.requestedAssetPaths, [
        'assets/cover.png',
        'assets/cover.png',
      ]);
    },
  );

  test('loads catalog and rolls back a failed optimistic follow', () async {
    final port = _SubscriptionPort();
    final applied = <int>[];
    final controller = KnowledgeSubscriptionController(
      port: port,
      onCatalogApplied: () => applied.add(1),
      onSavedArticle: (_) async => null,
      now: () => DateTime(2026, 8, 31),
    );
    addTearDown(controller.dispose);

    await controller.ensureCatalogLoaded();
    expect(controller.mode, MobileSubscriptionRuntimeMode.remote);
    expect(controller.publications.single.followed, isFalse);
    expect(applied, <int>[1]);

    final pending = controller.togglePublication('publication-1');
    expect(controller.publications.single.followed, isTrue);
    expect(controller.isPublicationActionInFlight('publication-1'), isTrue);
    port.followResult.complete(
      const MobileSubscriptionActionResult.failure('FOLLOW_FAILED'),
    );

    final result = await pending;
    expect(result.errorCode, 'FOLLOW_FAILED');
    expect(controller.publications.single.followed, isFalse);
    expect(controller.isPublicationActionInFlight('publication-1'), isFalse);
  });

  test('joins article asset requests and caches successful bytes', () async {
    final port = _SubscriptionPort();
    final controller = KnowledgeSubscriptionController(
      port: port,
      onCatalogApplied: () {},
      onSavedArticle: (_) async => null,
    );
    addTearDown(controller.dispose);
    await controller.ensureCatalogLoaded();

    final first = controller.loadArticleAsset('article-1', 'hero.png');
    final joined = controller.loadArticleAsset('article-1', 'hero.png');
    expect(joined, same(first));
    port.assetResult.complete(
      MobileSubscriptionArticleAssetResult.success(
        MobileSubscriptionArticleAsset(
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          mimeType: 'image/png',
        ),
      ),
    );
    expect((await first).asset?.bytes, <int>[1, 2, 3]);

    final cached = await controller.loadArticleAsset('article-1', 'hero.png');
    expect(cached.asset?.bytes, <int>[1, 2, 3]);
    expect(port.assetLoads, 1);
  });

  test(
    'hydrates and joins lead asset requests without marking article busy',
    () async {
      final port = _SubscriptionPort()
        ..articleResult = Completer<MobileSubscriptionActionResult>();
      final controller = KnowledgeSubscriptionController(
        port: port,
        onCatalogApplied: () {},
        onSavedArticle: (_) async => null,
      );
      addTearDown(controller.dispose);
      await controller.ensureCatalogLoaded();

      final first = controller.loadArticleLeadAsset('article-1');
      final joined = controller.loadArticleLeadAsset('article-1');

      expect(port.articleLoads, 1);
      expect(controller.isArticleActionInFlight('article-1'), isFalse);

      port.articleResult!.complete(
        MobileSubscriptionActionResult.success(
          controller
              .articleForId('article-1')!
              .copyWith(
                subscriptionArticleAssets: <V3SubscriptionArticleAssetRef>[
                  V3SubscriptionArticleAssetRef(
                    fileKey: 'cover-file',
                    logicalPath: 'cover-first.png',
                  ),
                  V3SubscriptionArticleAssetRef(
                    fileKey: 'later-file',
                    logicalPath: 'later.png',
                  ),
                ],
              ),
        ),
      );
      await port.assetRequested.future;

      expect(port.assetLoads, 1);
      expect(port.requestedAssetPaths, <String>['cover-first.png']);
      expect(controller.isArticleActionInFlight('article-1'), isFalse);

      port.assetResult.complete(
        MobileSubscriptionArticleAssetResult.success(
          MobileSubscriptionArticleAsset(
            bytes: Uint8List.fromList(<int>[9, 8, 7]),
            mimeType: 'image/png',
          ),
        ),
      );
      final results = await Future.wait(
        <Future<MobileSubscriptionArticleAssetResult>>[first, joined],
      );

      expect(results, hasLength(2));
      for (final result in results) {
        expect(result.status, MobileSubscriptionResultStatus.success);
        expect(result.asset?.bytes, <int>[9, 8, 7]);
      }
      expect(port.articleLoads, 1);
      expect(port.assetLoads, 1);
      expect(controller.isArticleActionInFlight('article-1'), isFalse);

      await controller.reload();
      MobileSubscriptionArticleAssetResult? immediate;
      unawaited(
        controller.loadArticleLeadAsset('article-1').then((result) {
          immediate = result;
        }),
      );
      expect(immediate?.asset, same(results.first.asset));
      expect(port.articleLoads, 1);
      expect(port.assetLoads, 1);
    },
  );

  test('article image failure retries only after explicit reload', () async {
    final port = _SubscriptionPort();
    final controller = KnowledgeSubscriptionController(
      port: port,
      onCatalogApplied: () {},
      onSavedArticle: (_) async => null,
    );
    addTearDown(controller.dispose);
    await controller.ensureCatalogLoaded();
    port.assetResult.complete(
      const MobileSubscriptionArticleAssetResult.failure('IMAGE_FAILED'),
    );
    final failed = await controller.loadArticleLeadAsset('article-1');
    MobileSubscriptionArticleAssetResult? immediate;
    unawaited(
      controller.loadArticleLeadAsset('article-1').then((result) {
        immediate = result;
      }),
    );
    expect(immediate, same(failed));
    expect(port.assetLoads, 1);

    port.assetResult = Completer<MobileSubscriptionArticleAssetResult>()
      ..complete(
        MobileSubscriptionArticleAssetResult.success(
          MobileSubscriptionArticleAsset(
            bytes: Uint8List.fromList([1, 2, 3]),
            mimeType: 'image/png',
          ),
        ),
      );
    await controller.reload();
    final recovered = await controller.loadArticleLeadAsset('article-1');
    expect(recovered.status, MobileSubscriptionResultStatus.success);
    expect(port.assetLoads, 2);
    expect(port.articleLoads, 1);

    port.catalogArticle = _article().copyWith(articleRevisionId: 'revision-2');
    await controller.reload();
    await controller.loadArticleLeadAsset('article-1');
    expect(port.assetLoads, 3);
    expect(port.articleLoads, 2);
  });

  test('hands a saved article to the authoritative facade callback', () async {
    final port = _SubscriptionPort();
    final adopted = <V3FeedItem>[];
    final controller = KnowledgeSubscriptionController(
      port: port,
      onCatalogApplied: () {},
      onSavedArticle: (note) async {
        adopted.add(note);
        return null;
      },
    );
    addTearDown(controller.dispose);
    await controller.ensureCatalogLoaded();

    final result = await controller.saveArticle('article-1');
    expect(result.status, MobileSubscriptionResultStatus.success);
    expect(adopted.single.id, 'saved-note-1');
  });
}

final class _ProgressiveSubscriptionPort extends _SubscriptionPort
    implements MobileSubscriptionCatalogRefreshPort {
  int initialLoads = 0;
  int completionLoads = 0;
  Completer<MobileSubscriptionCatalogResult> completion = Completer();

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() {
    initialLoads += 1;
    return super.loadCatalog();
  }

  @override
  Future<MobileSubscriptionCatalogResult> loadCompleteCatalog() {
    completionLoads += 1;
    return completion.future;
  }
}

final class _SubscriptionPort
    implements MobileSubscriptionPort, MobileSubscriptionNoteAssetPort {
  final Completer<MobileSubscriptionActionResult> followResult =
      Completer<MobileSubscriptionActionResult>();
  Completer<MobileSubscriptionArticleAssetResult> assetResult =
      Completer<MobileSubscriptionArticleAssetResult>();
  final Completer<void> assetRequested = Completer<void>();
  Completer<MobileSubscriptionActionResult>? articleResult;
  final List<String> requestedAssetPaths = <String>[];
  int articleLoads = 0;
  int assetLoads = 0;
  V3FeedItem? catalogArticle;

  @override
  bool get isDemo => false;

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() async =>
      MobileSubscriptionCatalogResult.success(<MobileSubscriptionPublication>[
        MobileSubscriptionPublication(
          publicationId: 'publication-1',
          title: 'Publication',
          sectionCount: 1,
          articleCount: 1,
          updatedAt: DateTime(2026, 8, 31),
          articles: <V3FeedItem>[catalogArticle ?? _article()],
          followed: false,
          available: true,
        ),
      ]);

  @override
  Future<MobileSubscriptionActionResult> setPublicationFollowed({
    required String publicationId,
    required bool followed,
    required String actionId,
  }) => followResult.future;

  @override
  Future<MobileSubscriptionActionResult> loadArticle(V3FeedItem article) {
    articleLoads += 1;
    return articleResult?.future ??
        Future<MobileSubscriptionActionResult>.value(
          MobileSubscriptionActionResult.success(article),
        );
  }

  @override
  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset({
    required V3FeedItem article,
    required V3SubscriptionArticleAssetRef asset,
  }) {
    assetLoads += 1;
    requestedAssetPaths.add(asset.logicalPath);
    if (!assetRequested.isCompleted) assetRequested.complete();
    return assetResult.future;
  }

  @override
  Future<MobileSubscriptionArticleAssetResult> loadSavedNoteAsset({
    required V3FeedItem note,
    required String logicalPath,
  }) {
    assetLoads += 1;
    requestedAssetPaths.add(logicalPath);
    if (!assetRequested.isCompleted) assetRequested.complete();
    return assetResult.future;
  }

  @override
  Future<MobileSubscriptionActionResult> saveArticleAsNote({
    required V3FeedItem article,
    required String actionId,
  }) async => MobileSubscriptionActionResult.success(
    V3FeedItem(
      id: 'saved-note-1',
      title: article.title,
      source: V3MaterialSource.note,
      createdAt: article.createdAt,
      rawBody: article.rawBody,
      remoteNoteId: 'remote-saved-note-1',
    ),
  );
}

V3FeedItem _article() => V3FeedItem(
  id: 'article-1',
  title: 'Article',
  source: V3MaterialSource.subscription,
  createdAt: DateTime(2026, 8, 31),
  rawBody: 'Body',
  ownership: V3NoteOwnership.subscribed,
  publicationId: 'publication-1',
  articleId: 'remote-article-1',
  articleRevisionId: 'revision-1',
  subscriptionArticleAssets: <V3SubscriptionArticleAssetRef>[
    V3SubscriptionArticleAssetRef(fileKey: 'file-1', logicalPath: 'hero.png'),
  ],
);
