import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/features/chat/data/authenticated_resource_image_cache.dart';
import 'package:huahuoai_app/features/chat/data/chat_api.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/subscription_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_item_detail_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_quick_dock.dart';

void main() {
  testWidgets('link-import raw content begins with its tappable source URL', (
    tester,
  ) async {
    const sourceUrl = 'https://www.douyin.com/video/753123456789';
    const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
    final launcherCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      launcherChannel,
      (call) async {
        launcherCalls.add(call);
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        launcherChannel,
        null,
      ),
    );
    final note = V3FeedItem(
      id: 'douyin-link-note',
      title: '抖音链接笔记',
      source: V3MaterialSource.link,
      createdAt: DateTime(2026, 9, 12),
      rawBody: '''Source: $sourceUrl
Platform: douyin
Author: 示例作者

---

# 抖音笔记

视频分析正文''',
      remoteNoteId: 'remote-douyin-link-note',
      remoteSourceKind: 'url_import',
      rawPartRevisionId: 'raw-douyin-1',
      syncState: NoteSyncState.synced,
    );
    final library = KnowledgeLibraryController(initialNotes: [note]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('douyin-link-test'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp(home: V3FeedItemDetailPage(itemId: note.id)),
      ),
    );
    await tester.pumpAndSettle();

    final rawContent = find.byKey(const ValueKey('detail-raw-content'));
    final sourceLink = find.byKey(const ValueKey('detail-source-link'));
    expect(find.textContaining('视频分析正文'), findsOneWidget);
    expect(find.textContaining('Source:'), findsNothing);
    expect(find.textContaining('Platform:'), findsNothing);
    expect(find.text(sourceUrl), findsOneWidget);
    expect(sourceLink, findsOneWidget);
    expect(
      tester.getBottomLeft(sourceLink).dy,
      lessThan(tester.getTopLeft(rawContent).dy),
    );

    await tester.ensureVisible(sourceLink);
    await tester.tap(sourceLink);
    await tester.pumpAndSettle();
    expect(launcherCalls, hasLength(1));
    expect(launcherCalls.single.method, 'launch');
    expect(
      (launcherCalls.single.arguments as Map<Object?, Object?>)['url'],
      sourceUrl,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'imported gallery admits visible images and loads more on scroll',
    (tester) async {
      const cardEvents = MethodChannel('huahuoai/recording_card/events');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        cardEvents,
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          cardEvents,
          null,
        ),
      );
      final requested = <String>[];
      final cache = _galleryCache('gallery', (playback) async {
        requested.add(playback.resourceId);
        return _galleryImage();
      });
      final note = _galleryNote(
        30,
      ).copyWith(publicUrl: 'https://www.xiaohongshu.com/explore/gallery-note');
      final library = KnowledgeLibraryController(initialNotes: [note]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('gallery-test'),
            resourceImageCacheProvider.overrideWithValue(cache),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: MaterialApp(home: V3FeedItemDetailPage(itemId: note.id)),
        ),
      );
      await _settleGallery(tester);
      final initialCount = requested.length;
      expect(initialCount, greaterThan(0));
      expect(initialCount, lessThan(30));
      expect(requested, contains('gallery_resource_0'));
      final sourceLink = find.byKey(const ValueKey('detail-source-link'));
      expect(sourceLink.hitTestable(), findsOneWidget);
      expect(
        tester.getBottomLeft(sourceLink).dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('remote-image-gallery_resource_0')),
              )
              .dy,
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('remote-image-gallery_resource_$initialCount')),
        500,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(requested.length, greaterThan(initialCount));
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(CustomScrollView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      for (var attempt = 0; attempt < 4; attempt += 1) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        if (position.extentAfter < 1) break;
      }
      expect(
        tester
            .getRect(find.byType(CustomScrollView).first)
            .contains(tester.getCenter(find.text('导入图片之后的完整正文'))),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'gallery heading deep link reaches body without eager downloads',
    (tester) async {
      final requested = <String>[];
      final cache = _galleryCache('heading', (playback) async {
        requested.add(playback.resourceId);
        return _galleryImage();
      });
      final note = _galleryNote(30).copyWith(rawBody: '# 目标章节\n\n导入图片之后的完整正文');
      final library = KnowledgeLibraryController(initialNotes: [note]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('gallery-heading-test'),
            resourceImageCacheProvider.overrideWithValue(cache),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: MaterialApp(
            home: V3FeedItemDetailPage(
              itemId: note.id,
              initialSectionId: 'raw-目标章节',
            ),
          ),
        ),
      );
      await _settleGallery(tester);
      expect(
        tester
            .getRect(find.byType(CustomScrollView).first)
            .contains(tester.getCenter(find.text('目标章节'))),
        isTrue,
      );
      expect(requested.length, lessThan(30));
      expect(requested, isNot(contains('gallery_resource_0')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same Resource switches reader without retaining old image bytes',
    (tester) async {
      final first = _galleryCache('first', (_) async => _galleryImage());
      final secondDownload = Completer<ChatImageBytes>();
      var secondReads = 0;
      final second = _galleryCache('second', (_) {
        secondReads += 1;
        return secondDownload.future;
      });
      final note = _galleryNote(1);
      final library = KnowledgeLibraryController(initialNotes: [note]);
      Future<void> render(AuthenticatedResourceImageCache cache) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              resolvedDeviceIdProvider.overrideWithValue('gallery-scope-test'),
              resourceImageCacheProvider.overrideWithValue(cache),
              knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            ],
            child: MaterialApp(home: V3FeedItemDetailPage(itemId: note.id)),
          ),
        );
      }

      await render(first);
      await _settleGallery(tester);
      final imageFinder = find.descendant(
        of: find.byKey(const ValueKey('remote-image-gallery_resource_0')),
        matching: find.byType(Image),
      );
      expect(imageFinder, findsOneWidget);
      await render(second);
      await tester.pump();
      expect(secondReads, 1);
      expect(imageFinder, findsNothing);
      secondDownload.complete(_galleryImage());
      await tester.pumpAndSettle();
      expect(imageFinder, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved subscription Note renders images without catalog metadata',
    (tester) async {
      final note = V3FeedItem(
        id: 'saved-image-note',
        title: '包含配图的笔记',
        source: V3MaterialSource.subscription,
        createdAt: DateTime(2026, 8, 8),
        rawBody: '原始正文\n\n![保存配图](assets/cover.png)',
        remoteNoteId: 'remote-image-note',
        rawPartRevisionId: 'raw-image-1',
        syncState: NoteSyncState.synced,
      );
      final port = _SavedNoteImagePort();
      final library = KnowledgeLibraryController(
        initialNotes: [note],
        subscriptionPort: port,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('saved-image-note-test'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: MaterialApp(home: V3FeedItemDetailPage(itemId: note.id)),
        ),
      );
      await tester.pumpAndSettle();
      expect(port.requests, [(note.id, 'assets/cover.png')]);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.semanticLabel == '保存配图',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('external-article-deposit')),
        findsNothing,
      );
      expect(library.subscriptionPublications, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saved subscription HNote uses editable canonical stages', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'saved-subscription-note',
      title: '已沉淀的订阅笔记',
      source: V3MaterialSource.subscription,
      createdAt: DateTime(2026, 7, 13),
      rawBody: '保存到笔记的完整原始内容',
      remoteNoteId: 'saved-subscription-note',
      remoteSourceKind: 'subscription_article',
      noteRevisionId: 'note-revision-1',
      rawPartRevisionId: 'raw-revision-1',
      syncState: NoteSyncState.synced,
    );
    final library = KnowledgeLibraryController(initialNotes: [note]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('saved-note-detail-test'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp(home: V3FeedItemDetailPage(itemId: note.id)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('保存到笔记的完整原始内容'), findsOneWidget);
    expect(find.text('原始'), findsOneWidget);
    expect(find.text('纲要'), findsOneWidget);
    expect(find.text('深度洞察'), findsOneWidget);
    expect(find.byType(V3ChatEntry), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('external-article-deposit')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('detail-external-read-content')),
      findsNothing,
    );

    await tester.tap(find.text('纲要'));
    await tester.pumpAndSettle();
    expect(find.text('尚未生成纲要'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-generate-outline')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.text('深度洞察'));
    await tester.pumpAndSettle();
    expect(find.text('尚未生成深度洞察'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-generate-sprout')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.text('原始'));
    await tester.pumpAndSettle();
    expect(find.text('保存到笔记的完整原始内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final source in [
    V3MaterialSource.subscription,
    V3MaterialSource.knowledgeSquare,
  ]) {
    testWidgets('${source.name} deposit opens all existing note stages', (
      tester,
    ) async {
      final reportHeading = source == V3MaterialSource.subscription
          ? '点火报告'
          : '深度洞察报告';
      final original = V3FeedItem(
        id: '${source.name}-original',
        title: '来源文章',
        source: source,
        ownership: source == V3MaterialSource.subscription
            ? V3NoteOwnership.subscribed
            : V3NoteOwnership.knowledgeSquare,
        createdAt: DateTime(2026, 7, 13),
        rawBody: '沉淀的原始正文',
        summaryBody: '已生成的笔记纲要',
        sproutStatus: V3SproutTaskStatus.succeeded,
        sproutReport: V3SproutReport(
          id: '${source.name}-sprout',
          noteId: '${source.name}-original',
          title: reportHeading,
          markdown: '# $reportHeading\n\n已生成的笔记点火内容',
          generatedAt: DateTime(2026, 7, 14),
        ),
      );
      final library = KnowledgeLibraryController(initialNotes: [original]);
      if (source == V3MaterialSource.knowledgeSquare) {
        expect(library.subscribeToSquare(original.id), isTrue);
      }
      final note = library.depositSubscribedSnapshot(original.id)!;
      expect(note.isReadOnly, isFalse);
      expect(note.source, source);
      expect(library.isDeposited(note.id), isTrue);
      expect(library.noteForId(original.id)?.isReadOnly, isTrue);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('deposit-detail-test'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: MaterialApp(home: V3FeedItemDetailPage(itemId: note.id)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('沉淀的原始正文'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('external-article-deposit')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('detail-external-read-content')),
        findsNothing,
      );
      await tester.tap(find.text('纲要'));
      await tester.pumpAndSettle();
      expect(find.text('已生成的笔记纲要'), findsOneWidget);
      await tester.tap(find.text('深度洞察'));
      await tester.pumpAndSettle();
      expect(find.text('已生成的笔记点火内容'), findsOneWidget);
      expect(find.text(reportHeading), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('hotspot keeps shared stages and the specified raw empty state', (
    tester,
  ) async {
    final hotspot = V3FeedItem(
      id: 'hotspot',
      title: '热点笔记',
      source: V3MaterialSource.hotspot,
      ownership: V3NoteOwnership.hotspot,
      createdAt: DateTime(2026, 7, 13),
      rawBody: '',
      summaryBody: '热点纲要',
    );
    final library = KnowledgeLibraryController(initialNotes: [hotspot]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('hotspot-detail-test'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: const MaterialApp(home: V3FeedItemDetailPage(itemId: 'hotspot')),
      ),
    );
    await tester.pump();

    expect(find.text('原始', skipOffstage: false), findsOneWidget);
    expect(find.text('暂无原始材料', skipOffstage: false), findsOneWidget);
    expect(
      find.text('该热点笔记根据当前热点整理生成，默认从纲要开始。', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('纲要', skipOffstage: false), findsOneWidget);
    expect(find.text('深度洞察', skipOffstage: false), findsOneWidget);
    expect(find.text('生成深度洞察', skipOffstage: false), findsNothing);
  });

  testWidgets('subscribed detail renders title and original content only', (
    tester,
  ) async {
    final subscription = V3FeedItem(
      id: 'subscription',
      title: '订阅原文',
      source: V3MaterialSource.subscription,
      ownership: V3NoteOwnership.subscribed,
      createdAt: DateTime(2026, 7, 13),
      rawBody: '作者的完整原始内容',
      summaryBody: '不应展示的纲要',
      sproutTopic: '不应展示的点火',
    );
    final library = KnowledgeLibraryController(initialNotes: [subscription]);
    expect(library.isSubscribed(subscription.id), isTrue);
    expect(library.isDeposited(subscription.id), isFalse);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue(
            'subscription-detail-test',
          ),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: const MaterialApp(
          home: V3FeedItemDetailPage(itemId: 'subscription'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('订阅原文'), findsOneWidget);
    expect(find.text('作者的完整原始内容'), findsOneWidget);
    expect(find.text('不应展示的纲要'), findsNothing);
    expect(find.text('不应展示的点火'), findsNothing);
    expect(
      find.byKey(const ValueKey('detail-external-read-content')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('detail-external-read-body')),
      findsOneWidget,
    );
    expect(find.text('原始'), findsNothing);
    expect(find.text('纲要'), findsNothing);
    expect(find.text('深度洞察'), findsNothing);
    expect(find.text('继续追加'), findsNothing);
    expect(find.text('生成深度洞察'), findsNothing);
    expect(find.text('沉淀到我的资产'), findsNothing);
    expect(find.byType(V3ChatEntry), findsNothing);
    expect(find.byKey(const ValueKey('detail-chat-entry')), findsNothing);
    expect(find.text('聊一聊'), findsNothing);
    expect(find.text('进入创作空间'), findsNothing);
  });

  testWidgets(
    'Knowledge Square detail renders title and original content only',
    (tester) async {
      final square = V3FeedItem(
        id: 'square-reader',
        title: '广场文章',
        source: V3MaterialSource.knowledgeSquare,
        ownership: V3NoteOwnership.knowledgeSquare,
        createdAt: DateTime(2026, 7, 13),
        rawBody: '广场文章的完整原始内容',
        summaryBody: '不应显示的广场纲要',
        sproutTopic: '不应显示的广场点火',
      );
      final library = KnowledgeLibraryController(initialNotes: [square]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('square-detail-test'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: const MaterialApp(
            home: V3FeedItemDetailPage(itemId: 'square-reader'),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('广场文章'), findsOneWidget);
      expect(find.text('广场文章的完整原始内容'), findsOneWidget);
      expect(find.text('不应显示的广场纲要'), findsNothing);
      expect(find.text('不应显示的广场点火'), findsNothing);
      expect(
        find.byKey(const ValueKey('detail-external-read-content')),
        findsOneWidget,
      );
      expect(find.text('原始'), findsNothing);
      expect(find.text('纲要'), findsNothing);
      expect(find.text('深度洞察'), findsNothing);
      expect(find.text('订阅'), findsNothing);
      expect(find.byType(V3ChatEntry), findsNothing);
    },
  );
}

V3FeedItem _galleryNote(int imageCount) => V3FeedItem(
  id: 'imported-gallery',
  title: '多图小红书笔记',
  source: V3MaterialSource.link,
  createdAt: DateTime(2026, 9, 11),
  rawBody: '导入图片之后的完整正文',
  remoteMediaAttachments: List.generate(
    imageCount,
    (index) => V3RemoteMediaAttachment(
      resourceId: 'gallery_resource_$index',
      displayName: '图片 $index',
      mimeType: 'image/png',
      usage: 'inline_image',
    ),
  ),
);

final _galleryImageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAHgAAAC0AQAAAAB3NdWwAAAAGklEQVR4nO3BgQAAAADDoPlTX+EAVQEAAK8BC0AAARKx8PsAAAAASUVORK5CYII=',
);

ChatImageBytes _galleryImage() =>
    ChatImageBytes(bytes: _galleryImageBytes, mimeType: 'image/png');

Future<void> _settleGallery(WidgetTester tester) async {
  await tester.pump();
  final scrollView = find.byType(CustomScrollView).first;
  final context = tester.element(scrollView);
  final images = tester
      .widgetList<Image>(
        find.descendant(of: scrollView, matching: find.byType(Image)),
      )
      .toList();
  await tester.runAsync(() async {
    await Future.wait(
      images.map((image) => precacheImage(image.image, context)),
    );
  });
  await tester.pumpAndSettle();
}

AuthenticatedResourceImageCache _galleryCache(
  String scope,
  ResourceImageByteDownloader download,
) {
  final cache = AuthenticatedResourceImageCache(
    playbackClient: ChatImagePlaybackClient(
      ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'gallery-test',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () async => 'gallery-test-token',
        ),
        transport: _GalleryPlaybackTransport(),
      ),
    ),
    userScope: scope,
    workspaceScope: 'gallery-workspace',
    cacheDirectoryProvider: () async =>
        throw const FileSystemException('Test disk unavailable'),
    download: download,
  );
  addTearDown(cache.dispose);
  return cache;
}

final class _GalleryPlaybackTransport implements ApiTransport {
  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async =>
      ApiTransportResponse(
        status: 200,
        body: {
          'success': true,
          'data': {
            'resourceId': request.url.pathSegments[4],
            'url': 'https://images.example.test/image.png',
            'mimeType': 'image/png',
          },
        },
      );
}

final class _SavedNoteImagePort
    implements MobileSubscriptionPort, MobileSubscriptionNoteAssetPort {
  final List<(String, String)> requests = [];

  @override
  bool get isDemo => false;

  @override
  Future<MobileSubscriptionArticleAssetResult> loadSavedNoteAsset({
    required V3FeedItem note,
    required String logicalPath,
  }) async {
    requests.add((note.id, logicalPath));
    return MobileSubscriptionArticleAssetResult.success(
      MobileSubscriptionArticleAsset(
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+'
          'A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        mimeType: 'image/png',
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
