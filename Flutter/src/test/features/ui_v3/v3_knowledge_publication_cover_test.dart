import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/subscription_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_publication_assets.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_remote_detail.dart';

const _aiDepthId = 'publication_3d625bf5f8a4fcba2b64f59a864a0a49';
const _aiNewsId = 'publication_2736ef58e718a3446dd8841501639755';
const _fallbackAsset = 'assets/images/knowledge_channel_ai_depth.png';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all 59 backend column avatars are bundled valid JPEGs', () async {
    expect(v3KnowledgePublicationAvatarAssets, hasLength(59));
    expect(v3KnowledgePublicationAvatarAssets.values.toSet(), hasLength(59));
    for (final entry in v3KnowledgePublicationAvatarAssets.entries) {
      expect(entry.value, endsWith('/${entry.key}.jpg'));
      final asset = await rootBundle.load(entry.value);
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      expect(bytes.take(3), orderedEquals([0xff, 0xd8, 0xff]));
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 800, reason: entry.key);
      expect(frame.image.height, 450, reason: entry.key);
      frame.image.dispose();
      codec.dispose();
    }
  });

  testWidgets('column avatar stays bound to ID rather than articles or title', (
    tester,
  ) async {
    final first = _article('first');
    final newer = _article('newer', revision: 'revision-newer');
    final publications = [
      _publication(_aiDepthId),
      _publication(_aiDepthId, articles: [first, newer]),
      _publication(_aiDepthId, articles: [newer, first]),
      _publication(_aiDepthId, title: '栏目已重命名', articles: [newer]),
      _publication(_aiNewsId, title: '栏目已重命名', articles: [newer]),
    ];
    for (final publication in publications) {
      await tester.pumpWidget(
        _surface(
          V3RemoteKnowledgePublicationCover(
            publication: publication,
            fallbackAsset: _fallbackAsset,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final image = tester.widget<Image>(
        find.byKey(
          ValueKey<String>(
            'knowledge-publication-avatar-${publication.publicationId}',
          ),
        ),
      );
      expect(
        (image.image as AssetImage).assetName,
        v3KnowledgePublicationAvatarAssets[publication.publicationId],
      );
      expect(find.byType(V3RemoteKnowledgeArticleCover), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'unknown column retains a static fallback without article reads',
    (tester) async {
      await tester.pumpWidget(
        _surface(
          V3RemoteKnowledgePublicationCover(
            publication: _publication(
              'future-column',
              articles: [_article('one')],
            ),
            fallbackAsset: _fallbackAsset,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, _fallbackAsset);
      expect(find.byType(V3RemoteKnowledgeArticleCover), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'article covers still reload their own exact-revision lead image',
    (tester) async {
      final bytes = File(
        v3KnowledgePublicationAvatarAssets[_aiDepthId]!,
      ).readAsBytesSync();
      final requests = <String>[];
      Future<MobileSubscriptionArticleAssetResult> loadLeadAsset(
        String noteId,
      ) {
        requests.add(noteId);
        return SynchronousFuture(
          MobileSubscriptionArticleAssetResult.success(
            MobileSubscriptionArticleAsset(
              bytes: bytes,
              mimeType: 'image/jpeg',
            ),
          ),
        );
      }

      for (final article in [
        _article('first'),
        _article('first', revision: 'revision-two'),
        _article('second'),
      ]) {
        await tester.pumpWidget(
          _surface(
            V3RemoteKnowledgeArticleCover(
              article: article,
              loadLeadAsset: loadLeadAsset,
              fallbackAsset: _fallbackAsset,
            ),
          ),
        );
        expect(tester.widget<Image>(_articleImage()).image, isA<ResizeImage>());
        await tester.pumpAndSettle();
        final image = tester.widget<Image>(_articleImage());
        final provider = image.image;
        final source = provider is ResizeImage
            ? provider.imageProvider
            : provider;
        expect(source, isA<MemoryImage>());
        expect((source as MemoryImage).bytes, same(bytes));
        expect(tester.takeException(), isNull);
      }
      expect(requests, ['first', 'first', 'second']);
    },
  );

  testWidgets('article cover stays ready through metadata and size changes', (
    tester,
  ) async {
    final pending = Completer<MobileSubscriptionArticleAssetResult>();
    final bytes = File(
      v3KnowledgePublicationAvatarAssets[_aiDepthId]!,
    ).readAsBytesSync();
    var requests = 0;
    Future<MobileSubscriptionArticleAssetResult> loadLeadAsset(String noteId) {
      requests += 1;
      return pending.future;
    }

    Widget cover(V3FeedItem article) => V3RemoteKnowledgeArticleCover(
      article: article,
      loadLeadAsset: loadLeadAsset,
      fallbackAsset: _fallbackAsset,
    );
    final article = _article('stable');
    await tester.pumpWidget(_surface(cover(article)));
    await tester.pumpWidget(_surface(cover(article.copyWith(rawBody: '正文'))));
    expect(requests, 1);
    pending.complete(
      MobileSubscriptionArticleAssetResult.success(
        MobileSubscriptionArticleAsset(bytes: bytes, mimeType: 'image/jpeg'),
      ),
    );
    await tester.pumpAndSettle();
    final provider = tester.widget<Image>(_articleImage()).image;
    await tester.runAsync(
      () => precacheImage(provider, tester.element(_articleImage())),
    );
    await tester.pump();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    final element = tester.element(_articleImage());
    for (final width in [190.0, 248.0, 318.0]) {
      await tester.pumpWidget(
        _surface(
          cover(
            article.copyWith(
              title: '更新标题',
              ownership: V3NoteOwnership.subscribed,
            ),
          ),
          width: width,
        ),
      );
      expect(tester.element(_articleImage()), same(element));
      expect(tester.widget<Image>(_articleImage()).image, provider);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(requests, 1);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('new cover revision ignores a late previous image result', (
    tester,
  ) async {
    final previous = Completer<MobileSubscriptionArticleAssetResult>();
    final current = Completer<MobileSubscriptionArticleAssetResult>();
    final bytes = File(
      v3KnowledgePublicationAvatarAssets[_aiNewsId]!,
    ).readAsBytesSync();
    var requests = 0;
    Future<MobileSubscriptionArticleAssetResult> loadLeadAsset(String noteId) {
      requests += 1;
      return requests == 1 ? previous.future : current.future;
    }

    for (final revision in ['old', 'new']) {
      await tester.pumpWidget(
        _surface(
          V3RemoteKnowledgeArticleCover(
            article: _article('same', revision: revision),
            loadLeadAsset: loadLeadAsset,
            fallbackAsset: _fallbackAsset,
          ),
        ),
      );
    }
    current.complete(
      MobileSubscriptionArticleAssetResult.success(
        MobileSubscriptionArticleAsset(bytes: bytes, mimeType: 'image/jpeg'),
      ),
    );
    await tester.pumpAndSettle();
    final provider = tester.widget<Image>(_articleImage()).image;
    previous.complete(
      const MobileSubscriptionArticleAssetResult.failure('OLD_FAILURE'),
    );
    await tester.pump();
    expect(tester.widget<Image>(_articleImage()).image, provider);
    expect(requests, 2);
    expect(tester.takeException(), isNull);
  });
}

Finder _articleImage() => find.byWidgetPredicate(
  (widget) => widget is Image && widget.image is ResizeImage,
);

Widget _surface(Widget child, {double width = 200}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, height: 120, child: child),
    ),
  ),
);

MobileSubscriptionPublication _publication(
  String publicationId, {
  String title = '人工智能 / 深度文章',
  List<V3FeedItem> articles = const [],
}) => MobileSubscriptionPublication(
  publicationId: publicationId,
  title: title,
  sectionCount: 1,
  articleCount: articles.length,
  updatedAt: DateTime.utc(2026, 9, 6),
  articles: articles,
  followed: false,
  available: true,
);

V3FeedItem _article(String identity, {String revision = 'revision-one'}) =>
    V3FeedItem(
      id: identity,
      title: '文章 $identity',
      source: V3MaterialSource.knowledgeSquare,
      createdAt: DateTime.utc(2026, 9, 6),
      rawBody: '',
      publicationId: _aiDepthId,
      articleId: identity,
      articleRevisionId: revision,
    );
