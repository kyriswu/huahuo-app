import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/di/media_cache_providers.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:huahuoai_app/app/di/native_port_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/app/navigation/app_routes.dart';
import 'package:huahuoai_app/app/navigation/route_parameter_parser.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/knowledge_export_port.dart';
import 'package:huahuoai_app/features/chat/data/authenticated_resource_image_cache.dart';
import 'package:huahuoai_app/features/chat/data/chat_api.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_document_export_service.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/photo_album_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/subscription_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/workbench_generation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/workspace_folder_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/knowledge_library_cache.dart';
import 'package:huahuoai_app/features/ui_v3/data/photo_album_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/workbench_generation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/workspace_content_sync.dart';
import 'package:huahuoai_app/features/ui_v3/data/workspace_content_sync_store.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_export_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_library_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/profile_activity_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/photo_album_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_item_detail_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_library_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_remote_detail.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_my_assets_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_workbench_material_picker_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

void main() {
  testWidgets(
    'My Assets loads folders on entry and retains them through retry',
    (tester) async {
      final remote = _AssetsWorkspaceRemote();
      final controller = KnowledgeLibraryController(
        initialNotes: [
          V3FeedItem(
            id: 'cached-folder-note',
            title: '文件夹内的本地笔记',
            source: V3MaterialSource.note,
            createdAt: DateTime.utc(2026, 8, 15),
            rawBody: '内容',
            folderId: 'folder-assets',
            folderName: '项目资料',
            syncState: NoteSyncState.localOnly,
          ),
        ],
        includeDemoFixtures: false,
        workspaceFolderPort: _AssetsWorkspaceFolderPort(),
      );
      final database = AppDatabase();
      final store = WorkspaceContentSyncStore(
        preferences: AppPreferencesDao(database),
        userScope: 'assets-entry-user',
        workspaceId: 'workspace-assets',
      );
      controller.attachWorkspaceContentSync(
        WorkspaceContentSync(
          remote: remote,
          store: store,
          workspaceId: 'workspace-assets',
          readProjection: () => controller.notes,
          readProjectionCursor: () => controller.workspaceContentCursor,
          applyProjection: controller.applyWorkspaceContentProjection,
          applyFolderProjection: controller.applyWorkspaceFolderProjection,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
          ],
          child: const MaterialApp(home: V3MyAssetsPage()),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(remote.snapshotCalls, 1);
      expect(
        find.byKey(const ValueKey('my-assets-sync-loading')),
        findsOneWidget,
      );
      expect(find.text('文件夹内的本地笔记'), findsNothing);

      remote.snapshot.complete(
        WorkspaceContentSnapshotResponse.success(
          SharedWorkspaceContentSnapshot(
            snapshotId: 'assets-snapshot',
            atCursor: '10',
            folders: [
              for (final folderId in ['folder-assets', 'folder-empty'])
                SharedWorkspaceFolder(
                  folderId: folderId,
                  workspaceId: 'workspace-assets',
                  parentFolderId: null,
                  displayName: folderId == 'folder-assets' ? '项目资料' : '空文件夹',
                  normalizedName: folderId,
                  state: 'live',
                  currentRevisionId: 'revision-$folderId',
                  etag: '"$folderId"',
                  contentCursor: '10',
                ),
            ],
            objects: const [],
            hasMore: false,
            nextPageToken: null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('asset-deposit-folder-folder-assets')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('asset-deposit-folder-folder-empty')),
        findsOneWidget,
      );
      expect(find.text('文件夹内的本地笔记'), findsOneWidget);
      expect(controller.depositedNotes(folderId: null), isEmpty);

      await tester.tap(find.byKey(const ValueKey('my-assets-refresh')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('my-assets-sync-error')),
        findsOneWidget,
      );
      expect(find.text('文件夹内的本地笔记'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-assets-sync-retry')));
      await tester.pumpAndSettle();
      expect(remote.changeCalls, 2);
      expect(remote.snapshotCalls, 1);
      expect(find.byKey(const ValueKey('my-assets-sync-error')), findsNothing);
      expect(controller.depositFoldersIn(null), hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('My Assets exposes one inline search and no category pager', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(),
          ),
        ],
        child: const MaterialApp(home: V3MyAssetsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的资产'), findsOneWidget);
    expect(find.text('我的笔记'), findsNothing);
    expect(find.text('我的沉淀'), findsNothing);
    expect(find.byKey(const ValueKey('asset-primary-deposits')), findsNothing);
    expect(find.byKey(const ValueKey('asset-deposit-overview')), findsNothing);
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-assets-top-search')), findsNothing);
    expect(find.byKey(const ValueKey('my-assets-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-assets-sort')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('asset-create-deposit-folder')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('asset-create-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-assets-page-view')), findsNothing);
    expect(find.byKey(const ValueKey('asset-tab-experience')), findsNothing);
    expect(find.text('经历'), findsNothing);
    expect(find.text('知识'), findsNothing);
    expect(find.text('观点'), findsNothing);
    expect(find.text('资讯'), findsNothing);
  });

  testWidgets('Mobile V5 M07 exposes canonical external-world chrome', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(),
          ),
        ],
        child: const MaterialApp(home: V3KnowledgeLibraryPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('外部世界'), findsOneWidget);
    expect(find.text('我的订阅'), findsOneWidget);
    expect(find.text('知识广场'), findsOneWidget);
    final selected = tester.widget<Text>(find.text('我的订阅'));
    expect(selected.style?.fontSize, 15);
    expect(selected.style?.fontWeight, FontWeight.w500);
    final indicator = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(const ValueKey('knowledge-tab-subscribed')),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(indicator.constraints?.maxWidth, 44);
    final decoration = indicator.decoration! as BoxDecoration;
    expect(decoration.color, HuahuoV3Theme.lightTokens.accent);
  });

  test('knowledge route defaults to the square tab', () {
    expect(
      v3KnowledgeLibraryTabFromRouteParameter(null),
      V3KnowledgeLibraryTab.square,
    );
    expect(
      v3KnowledgeLibraryTabFromRouteParameter('square'),
      V3KnowledgeLibraryTab.square,
    );
    expect(
      v3KnowledgeLibraryTabFromRouteParameter('subscribed'),
      V3KnowledgeLibraryTab.subscribed,
    );
  });

  test('knowledge secondary routes accept only typed route input', () {
    expect(routeKnowledgeChannel('history'), KnowledgeChannel.history);
    expect(routeKnowledgeChannel('unknown'), isNull);
    expect(routeKnowledgeChannel(' history'), isNull);
    expect(routeKnowledgePublicationId('publication-1'), 'publication-1');
    expect(routeKnowledgePublicationId('../publication'), isNull);
    expect(routeKnowledgeWorldQuery('  城市观察  '), '城市观察');
    expect(routeKnowledgeWorldQuery('line\nbreak'), isNull);
    expect(routeKnowledgeWorldQuery('x' * 81), isNull);
    expect(
      AppRoutePaths.knowledgeWorldDetail(
        publicationId: 'publication-1',
        query: '城市观察',
      ),
      '/v3/profile/knowledge/world?publicationId=publication-1&q=%E5%9F%8E%E5%B8%82%E8%A7%82%E5%AF%9F',
    );
  });

  testWidgets('unknown channel route returns to the visible square fallback', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/v3/profile/knowledge/channel/unknown',
      routes: _knowledgeAppRoutes(),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const PageStorageKey<String>('knowledge-square')),
      findsOneWidget,
    );
    expect(find.text('知识广场'), findsOneWidget);
  });

  testWidgets('missing remote publication renders a visible recovery state', (
    tester,
  ) async {
    final port = _PageSubscriptionPort(
      const MobileSubscriptionCatalogResult.success(
        <MobileSubscriptionPublication>[],
      ),
    );
    final controller = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      subscriptionPort: port,
    );
    await controller.reloadSubscriptions();
    final router = GoRouter(
      initialLocation: AppRoutePaths.knowledgeWorldDetail(
        publicationId: 'missing-publication',
      ),
      routes: _knowledgeAppRoutes(),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-knowledge-world-publication-missing')),
      findsOneWidget,
    );
    expect(find.textContaining('该出版物不存在或已下线'), findsOneWidget);
  });

  testWidgets('My note deletion confirms and clears matching activities', (
    tester,
  ) async {
    final library = KnowledgeLibraryController();
    library.showAllDeposits();
    final profile = ProfileHubController(referenceDay: DateTime(2026, 7, 13));
    final note = library.mineNotes.first;
    profile.recordActivity(
      V3ProfileActivity(
        id: 'delete-page-activity',
        occurredAt: DateTime(2026, 7, 13, 9),
        type: V3ProfileActivityType.raw,
        title: note.title,
        feedItemId: note.id,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith((ref) => profile),
        ],
        child: const MaterialApp(home: V3MyAssetsPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('笔记操作 ${note.title}'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除笔记'), findsOneWidget);
    expect(find.byType(V3GlassDialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('确定删除“${note.title}”？'), findsOneWidget);
    expect(find.text('将删除以下笔记'), findsNothing);
    expect(find.textContaining('不提供恢复入口'), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(library.noteForId(note.id), isNotNull);
    expect(
      profile.activities.where((activity) => activity.feedItemId == note.id),
      isNotEmpty,
    );

    await tester.tap(find.byTooltip('笔记操作 ${note.title}'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(library.noteForId(note.id), isNull);
    expect(
      profile.activities.where((activity) => activity.feedItemId == note.id),
      isEmpty,
    );

    expect(find.byTooltip('笔记操作 ${note.title}'), findsNothing);
  });

  testWidgets('photo preview route returns a delete receipt to My Assets', (
    tester,
  ) async {
    final photo = _pagePhotoAlbumEntry();
    final repository = _PagePhotoAlbumRepository(
      entries: [photo],
      deleteStatus: 'delete_pending',
    );
    final router = GoRouter(
      initialLocation: AppRoutePaths.assetsMedia,
      routes: _knowledgeAppRoutes(),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(),
          ),
          photoAlbumRepositoryProvider.overrideWithValue(repository),
          _pageDownloadableResourceImageCacheOverride(),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final photoTile = find.byKey(
      const ValueKey('photo-album-item-page-photo-resource'),
    );
    final gridImage = tester.widget<Image>(
      find.descendant(of: photoTile, matching: find.byType(Image)).first,
    );
    final gridResize = gridImage.image as ResizeImage;
    expect(gridResize.width, inInclusiveRange(1, 4096));
    tester.widget<InkWell>(photoTile).onTap!();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-album-preview')), findsOneWidget);
    final previewImages = tester.widgetList<Image>(
      find.descendant(
        of: find.byKey(const ValueKey('photo-album-preview')),
        matching: find.byType(Image),
      ),
    );
    expect(
      previewImages.any(
        (image) =>
            image.image is ResizeImage &&
            (image.image as ResizeImage).width != null &&
            (image.image as ResizeImage).width! > gridResize.width! &&
            (image.image as ResizeImage).width! <= 4096,
      ),
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('photo-album-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('photo-album-preview')), findsNothing);
    expect(
      find.byKey(const ValueKey('photo-album-item-page-photo-resource')),
      findsNothing,
    );
    expect(find.text('已停止使用影像，正在完成清理'), findsOneWidget);
    expect(repository.deletedResourceIds, ['page-photo-resource']);
  });

  testWidgets('photo preview saves authorized bytes to the local gallery', (
    tester,
  ) async {
    final photo = _pagePhotoAlbumEntry(displayName: '客户现场影像');
    final repository = _PagePhotoAlbumRepository(entries: [photo]);
    final saver = _PageImageGallerySaver();
    final router = GoRouter(
      initialLocation: AppRoutePaths.photoAlbumPreview(photo.resourceId),
      routes: _knowledgeAppRoutes(),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(),
          ),
          photoAlbumRepositoryProvider.overrideWithValue(repository),
          photoAlbumNativeFilePortProvider.overrideWithValue(saver),
          _pageDownloadableResourceImageCacheOverride(),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('photo-album-save')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('photo-album-save')));
    await tester.pumpAndSettle();

    expect(saver.savedBytes, Uint8List.fromList(_pagePngBytes));
    expect(saver.savedMimeType, 'image/png');
    expect(saver.savedDisplayName, '客户现场影像.png');
    expect(find.text('图片已保存到本地相册'), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-album-preview')), findsOneWidget);
  });

  testWidgets('unavailable photo preview route returns to the media tab', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: AppRoutePaths.photoAlbumPreview('missing-resource'),
      routes: _knowledgeAppRoutes(),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(),
          ),
          photoAlbumRepositoryProvider.overrideWithValue(
            _PagePhotoAlbumRepository(entries: [_pagePhotoAlbumEntry()]),
          ),
          _pageResourceImageCacheOverride(),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('photo-album-preview')), findsNothing);
    expect(
      find.byKey(const ValueKey('asset-tab-mediaResources')),
      findsOneWidget,
    );
    expect(
      router.routeInformationProvider.value.uri.toString(),
      AppRoutePaths.assetsMedia,
    );
  });

  testWidgets(
    'photo preview waits for remote reconciliation when cache lacks the Resource',
    (tester) async {
      final cache = PhotoAlbumMetadataCache(
        preferences: AppPreferencesDao(AppDatabase()),
        ownerScope: 'photo-route-cache-user\u0000workspace',
      );
      final cachedPhoto = _pagePhotoAlbumEntry(
        resourceId: 'cached-photo-resource',
        displayName: '缓存影像',
      );
      final cacheWriter = PhotoAlbumController(
        nativeFilePort: const UnavailableNativeFilePort(),
        repository: _PagePhotoAlbumRepository(entries: [cachedPhoto]),
        cache: cache,
      );
      await cacheWriter.load();
      cacheWriter.dispose();

      final remoteEntries = Completer<List<V3PhotoAlbumEntry>>();
      final remotePhoto = _pagePhotoAlbumEntry(
        resourceId: 'remote-photo-resource',
        displayName: '远端影像',
      );
      final repository = _PagePhotoAlbumRepository(
        entries: const <V3PhotoAlbumEntry>[],
        loadFuture: remoteEntries.future,
      );
      final router = GoRouter(
        initialLocation: AppRoutePaths.photoAlbumPreview(
          remotePhoto.resourceId,
        ),
        routes: _knowledgeAppRoutes(),
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => KnowledgeLibraryController(),
            ),
            photoAlbumRepositoryProvider.overrideWithValue(repository),
            photoAlbumMetadataCacheProvider.overrideWithValue(cache),
            _pageResourceImageCacheOverride(),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('photo-album-preview-unavailable')),
        findsOneWidget,
      );
      expect(
        router.routeInformationProvider.value.uri.toString(),
        AppRoutePaths.photoAlbumPreview(remotePhoto.resourceId),
      );

      remoteEntries.complete([cachedPhoto, remotePhoto]);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('photo-album-preview')), findsOneWidget);
      expect(
        router.routeInformationProvider.value.uri.toString(),
        AppRoutePaths.photoAlbumPreview(remotePhoto.resourceId),
      );
    },
  );

  testWidgets(
    'invalid generated deep link uses the production material route',
    (tester) async {
      final library = KnowledgeLibraryController();
      final generation = WorkbenchGenerationController(
        library: library,
        repository: const WorkbenchGenerationMockRepository(
          delay: Duration.zero,
        ),
      );
      final router = GoRouter(
        initialLocation: AppRoutePaths.workbenchGenerated('persona'),
        routes: _knowledgeAppRoutes(),
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            workbenchGenerationControllerProvider.overrideWith(
              (ref) => generation,
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(V3WorkbenchMaterialPickerPage), findsOneWidget);
      expect(
        router.routeInformationProvider.value.uri.toString(),
        AppRoutePaths.workbenchMaterials('persona'),
      );
      expect(router.canPop(), isFalse);
    },
  );

  testWidgets(
    'deposit picker moves assets without retired classification controls',
    (tester) async {
      final note = V3FeedItem(
        id: 'confirm-deposit-note',
        title: '等待确认沉淀',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 7, 19),
        rawBody: '正文',
      );
      final library = KnowledgeLibraryController(initialNotes: [note]);
      final router = GoRouter(
        initialLocation: AppRoutePaths.knowledgeSquare,
        routes: _knowledgeAppRoutes(),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: const MaterialApp(home: V3MyAssetsPage()),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> openPicker() async {
        await tester.tap(find.byTooltip('笔记操作 ${note.title}'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移动到文件夹'));
        await tester.pumpAndSettle();
      }

      await openPicker();
      expect(library.isDeposited(note.id), isTrue);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(library.isDeposited(note.id), isTrue);

      await openPicker();
      expect(find.text('资产分类'), findsNothing);
      expect(find.text('保存位置'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('deposit-picker-create-folder')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('deposit-picker-confirm')));
      await tester.pumpAndSettle();
      expect(library.isDeposited(note.id), isTrue);
    },
  );

  testWidgets(
    'knowledge tabs keep collections separate and square is an interactive discovery page',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = KnowledgeLibraryController(
        now: () => DateTime(2026, 7, 15, 12),
        initialNotes: [
          V3FeedItem(
            id: 'meeting-note',
            title: '会议结论',
            source: V3MaterialSource.meeting,
            createdAt: DateTime(2026, 7, 15),
            rawBody: '会议正文',
          ),
          V3FeedItem(
            id: 'knowledge-channel-history-01',
            title: '订阅洞察',
            source: V3MaterialSource.knowledgeSquare,
            ownership: V3NoteOwnership.knowledgeSquare,
            createdAt: DateTime(2026, 7, 14),
            rawBody: '笔记正文',
          ),
          V3FeedItem(
            id: 'square-history-note',
            title: '历史中的城市观察',
            source: V3MaterialSource.knowledgeSquare,
            createdAt: DateTime(2026, 7, 13),
            rawBody: '从历史中理解城市的变化。',
          ),
          V3FeedItem(
            id: 'square-art-note',
            title: '艺术与设计的观察方法',
            source: V3MaterialSource.knowledgeSquare,
            createdAt: DateTime(2026, 7, 12),
            rawBody: '艺术创作中的结构化思考。',
          ),
          V3FeedItem(
            id: 'square-bookstore-note',
            title: '独立书店阅读清单',
            source: V3MaterialSource.knowledgeSquare,
            createdAt: DateTime(2026, 7, 11),
            rawBody: '书店与阅读的日常。',
          ),
        ],
      );
      expect(controller.subscribeChannel(KnowledgeChannel.history), isTrue);
      final router = GoRouter(
        initialLocation: '${AppRoutePaths.knowledge}?tab=subscribed',
        routes: _knowledgeSecondaryTestRoutes(),
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('外部世界'), findsOneWidget);
      expect(find.text('我创建的'), findsNothing);
      expect(find.text('我的订阅'), findsWidgets);
      expect(find.text('知识广场'), findsOneWidget);
      expect(find.text('会议结论'), findsNothing);
      expect(find.text('订阅洞察'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('knowledge-stage-knowledge-channel-history-01-raw'),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('knowledge-tab-subscribed')));
      await tester.pumpAndSettle();
      expect(controller.tab, V3KnowledgeLibraryTab.subscribed);
      expect(find.text('订阅洞察'), findsOneWidget);

      await tester.drag(
        find.byKey(const ValueKey('knowledge-page-view')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      expect(controller.tab, V3KnowledgeLibraryTab.square);
      expect(
        find.byKey(const ValueKey<String>('knowledge-square-search')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('knowledge-square-banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('knowledge-square-banner-pages')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('knowledge-square-banner-dot-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('knowledge-square-banner-dot-1')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('knowledge-square-banner-dot-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('knowledge-square-category-history')),
        findsOneWidget,
      );
      expect(find.textContaining('人在用'), findsWidgets);
      expect(
        find.byKey(const ValueKey('knowledge-search-toggle')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('knowledge-create-note')), findsNothing);
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      final historyDeposit = find.byKey(
        const ValueKey('knowledge-square-deposit-square-history-note'),
      );
      final squareScrollable = find
          .descendant(
            of: find.byKey(const PageStorageKey<String>('knowledge-square')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        historyDeposit,
        320,
        scrollable: squareScrollable,
      );
      await tester.tap(historyDeposit);
      await tester.pumpAndSettle();
      expect(find.text('保存到我的资产'), findsOneWidget);
      expect(controller.isSubscribed('square-history-note'), isFalse);
      await tester.tap(find.byKey(const ValueKey('deposit-picker-confirm')));
      await tester.pumpAndSettle();
      expect(
        controller.mineNotes.any(
          (note) => note.copiedFromContentId == 'square-history-note',
        ),
        isTrue,
      );
      expect(controller.isSubscribed('square-history-note'), isFalse);

      final squareSearch = find.byKey(
        const ValueKey<String>('knowledge-square-search'),
      );
      await tester.scrollUntilVisible(
        squareSearch,
        -360,
        scrollable: squareScrollable,
      );
      await tester.enterText(squareSearch, '艺术');
      await tester.pumpAndSettle();
      expect(find.text('艺术与设计的观察方法'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('knowledge-square-deposit-square-history-note'),
        ),
        findsNothing,
      );

      await tester.enterText(squareSearch, '');
      await tester.pumpAndSettle();
      final historyCategory = find.byKey(
        const ValueKey('knowledge-square-category-history'),
      );
      await tester.scrollUntilVisible(
        historyCategory,
        -220,
        scrollable: squareScrollable,
      );
      await tester.tap(historyCategory);
      await tester.pumpAndSettle();
      expect(find.text('频道文章'), findsOneWidget);
      expect(find.text('取消订阅'), findsOneWidget);
    },
  );

  testWidgets('single square banner remains stable while a route covers it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = KnowledgeLibraryController(
      initialNotes: [
        for (var index = 0; index < 3; index++)
          V3FeedItem(
            id: 'route-square-$index',
            title: '稳定推荐 $index',
            source: V3MaterialSource.knowledgeSquare,
            createdAt: DateTime(2026, 7, 20 - index),
            rawBody: '正文 $index',
          ),
      ],
    );
    final router = GoRouter(
      initialLocation: '/knowledge',
      observers: <NavigatorObserver>[appRouteObserver],
      routes: [
        GoRoute(
          path: '/knowledge',
          builder: (context, state) => const V3KnowledgeLibraryPage(
            initialTab: V3KnowledgeLibraryTab.square,
          ),
        ),
        GoRoute(
          path: '/covered',
          builder: (context, state) => const Scaffold(body: Text('覆盖页面')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('knowledge-square-banner-dot-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('knowledge-square-banner-dot-1')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('knowledge-square-banner-dot-0')),
      findsOneWidget,
    );

    unawaited(router.push<void>('/covered'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 12));
    router.pop();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('knowledge-square-banner-dot-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('knowledge-square-banner-dot-1')),
      findsNothing,
    );
  });

  testWidgets('owned notes edit in place from my assets', (tester) async {
    final owned = V3FeedItem(
      id: 'owned-note',
      title: '可编辑笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 15),
      rawBody: '正文',
    );
    final controller = KnowledgeLibraryController(initialNotes: [owned]);
    controller.showAllDeposits();
    final router = GoRouter(
      initialLocation: '/assets',
      routes: [
        GoRoute(
          path: '/library',
          builder: (context, state) => const V3KnowledgeLibraryPage(),
        ),
        GoRoute(
          path: '/assets',
          builder: (context, state) => const V3MyAssetsPage(),
        ),
        GoRoute(
          path: '/v3/feed/note/:itemId',
          builder: (context, state) =>
              Text('editing:${state.pathParameters['itemId']}'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('笔记操作 可编辑笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑内容'));
    await tester.pumpAndSettle();
    expect(find.text('editing:owned-note'), findsOneWidget);
  });

  testWidgets('assets keep every source visible in Mobile V5 summary cards', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final recording = V3FeedItem(
      id: 'source-recording',
      title: '录音来源内容',
      source: V3MaterialSource.monologue,
      createdAt: DateTime(2026, 7, 19),
      rawBody: '录音正文',
    );
    final link = V3FeedItem(
      id: 'source-link',
      title: '链接来源内容',
      source: V3MaterialSource.link,
      createdAt: DateTime(2026, 7, 19),
      rawBody: '链接正文',
      topics: const ['公开资料'],
    );
    final controller = KnowledgeLibraryController(
      initialNotes: [recording, link],
    );
    controller.setSourceCategory(
      V3KnowledgeLibraryTab.mine,
      KnowledgeSourceCategory.link,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: const MaterialApp(home: V3MyAssetsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('录音来源内容'), findsOneWidget);
    expect(find.text('链接来源内容'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('knowledge-mine-source-filter')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('knowledge-card-display-switch')),
      findsNothing,
    );
    expect(controller.cardDisplayMode, KnowledgeCardDisplayMode.expanded);
    expect(find.text('录音来源内容'), findsOneWidget);
    expect(find.text('链接来源内容'), findsOneWidget);
    for (final stage in ['raw', 'summary', 'sprout']) {
      expect(
        find.byKey(ValueKey('knowledge-stage-source-link-$stage')),
        findsNothing,
      );
    }
    expect(find.text('#公开资料'), findsNothing);
    expect(
      find.byKey(const ValueKey('knowledge-card-tags-source-link')),
      findsNothing,
    );
    expect(find.byTooltip('归类 链接来源内容'), findsNothing);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('knowledge-note-card-source-link')),
          )
          .height,
      inInclusiveRange(120, 160),
    );
    expect(find.text('来源 · 链接导入'), findsOneWidget);
    expect(find.byKey(const ValueKey('asset-new-growth-line')), findsNothing);
    expect(find.byKey(const ValueKey('asset-statistics-bar')), findsNothing);

    expect(
      find.byKey(const ValueKey('knowledge-mine-source-filter')),
      findsNothing,
    );
    expect(find.text('我的沉淀'), findsNothing);
  });

  testWidgets('deposited root groups folder previews and opens direct files', (
    tester,
  ) async {
    final first = V3FeedItem(
      id: 'folder-total-first',
      title: '第一条沉淀',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 19),
      rawBody: '正文',
    );
    final second = V3FeedItem(
      id: 'folder-total-second',
      title: '第二条沉淀',
      source: V3MaterialSource.meeting,
      createdAt: DateTime(2026, 7, 18),
      rawBody: '正文',
    );
    final controller = KnowledgeLibraryController(
      initialNotes: [first, second],
    );
    final folder = controller.createDepositFolder('客户项目')!;
    expect(
      controller.assignToDepositFolder(
        contentId: first.id,
        folderId: folder.id,
      ),
      isTrue,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: const MaterialApp(home: V3MyAssetsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('全部'), findsNothing);
    expect(
      find.byKey(ValueKey('asset-deposit-folder-${folder.id}')),
      findsOneWidget,
    );
    expect(find.text('第一条沉淀'), findsOneWidget);
    expect(find.text('第二条沉淀'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('asset-deposit-folder-${folder.id}')));
    await tester.pumpAndSettle();
    expect(find.text('第一条沉淀'), findsOneWidget);
    expect(find.text('第二条沉淀'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('asset-deposit-folder-back')));
    await tester.pumpAndSettle();
    expect(find.text('第一条沉淀'), findsOneWidget);
    expect(find.text('第二条沉淀'), findsOneWidget);
  });

  testWidgets(
    'My Assets browses nested folders and moves notes without copies',
    (tester) async {
      final first = V3FeedItem(
        id: 'asset-folder-first',
        title: '客户复盘',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 7, 20),
        rawBody: '第一条正文',
      );
      final second = V3FeedItem(
        id: 'asset-folder-second',
        title: '产品观察',
        source: V3MaterialSource.meeting,
        createdAt: DateTime(2026, 7, 19),
        rawBody: '第二条正文',
      );
      final controller = KnowledgeLibraryController(
        initialNotes: [first, second],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: const MaterialApp(home: V3MyAssetsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('asset-create-deposit-folder')),
        findsOneWidget,
      );
      expect(
        tester.getSize(
          find.byKey(const ValueKey('asset-create-deposit-folder')),
        ),
        const Size(40, 40),
      );
      await tester.tap(
        find.byKey(const ValueKey('asset-create-deposit-folder')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(find.text('请输入文件夹名称'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('asset-deposit-folder-name')),
        '客户项目',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      final rootFolder = controller.depositFolders.single;
      expect(
        find.byKey(ValueKey('asset-deposit-folder-${rootFolder.id}')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('asset-create-deposit-folder')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('asset-deposit-folder-name')),
        '会议资料',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      final childFolder = controller.depositFolders.singleWhere(
        (folder) => folder.parentFolderId == rootFolder.id,
      );
      expect(controller.depositFolderPath(childFolder.id), '客户项目 / 会议资料');

      await tester.tap(find.byKey(const ValueKey('asset-deposit-root')));
      await tester.pumpAndSettle();
      final rootStrip = find.byKey(
        const ValueKey('asset-deposit-folder-horizontal-list'),
      );
      expect(rootStrip, findsNothing);
      expect(
        find.byKey(const ValueKey('asset-deposit-folder-strip')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('asset-deposit-folder-directory-label')),
        findsNothing,
      );
      expect(
        tester
            .getCenter(
              find.byKey(ValueKey('asset-deposit-folder-${rootFolder.id}')),
            )
            .dy,
        greaterThan(
          tester
              .getCenter(
                find.byKey(const ValueKey('asset-create-deposit-folder')),
              )
              .dy,
        ),
      );
      expect(
        tester
            .getTopLeft(
              find.byKey(ValueKey('asset-deposit-folder-${rootFolder.id}')),
            )
            .dy,
        lessThan(tester.getTopLeft(find.text(first.title)).dy),
      );
      await tester.tap(find.byTooltip('笔记操作 ${first.title}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(childFolder.name).last);
      await tester.tap(find.byKey(const ValueKey('deposit-picker-confirm')));
      await tester.pumpAndSettle();

      expect(controller.depositRecordFor(first.id)?.folderId, childFolder.id);
      await tester.tap(
        find.byKey(ValueKey('asset-deposit-folder-${rootFolder.id}')),
      );
      await tester.pumpAndSettle();
      final childStrip = find.byKey(
        const ValueKey('asset-deposit-folder-horizontal-list'),
      );
      expect(childStrip, findsOneWidget);
      expect(
        tester.widget<ListView>(childStrip).scrollDirection,
        Axis.horizontal,
      );
      await tester.tap(
        find.byKey(ValueKey('asset-deposit-folder-${childFolder.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text(first.title), findsOneWidget);
      expect(find.text(second.title), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('asset-deposit-folder-actions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('asset-deposit-folder-rename')),
        '重点客户',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(controller.depositFolderFor(childFolder.id)?.name, '重点客户');

      await tester.tap(
        find.byKey(const ValueKey('asset-deposit-folder-actions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(controller.depositFolderFor(childFolder.id), isNull);
      expect(controller.depositRecordFor(first.id)?.folderId, rootFolder.id);
      expect(find.text(first.title), findsOneWidget);
      expect(find.text(second.title), findsNothing);
    },
  );

  testWidgets('custom tags save from the unified note action sheet', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'taggable-note',
      title: '可加标签内容',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 19),
      rawBody: '正文',
    );
    final controller = KnowledgeLibraryController(initialNotes: [note]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp(
          home: _PageKnowledgeActionInvoker(
            note: note,
            child: const V3MyAssetsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('page-invoke-tags')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('knowledge-tag-input')),
      '客户洞察',
    );
    await tester.tap(find.byTooltip('添加标签'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('knowledge-tags-save')));
    await tester.pumpAndSettle();

    expect(controller.effectiveTags(controller.noteForId(note.id)!), ['客户洞察']);
    expect(find.text('#客户洞察'), findsNothing);
    expect(find.byTooltip('归类 可加标签内容'), findsNothing);
  });

  testWidgets('compact tag editor keeps save above the keyboard', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final note = V3FeedItem(
      id: 'compact-taggable-note',
      title: '需要在小屏幕上管理标签的内容',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 9, 3),
      rawBody: '正文',
    );
    final controller = KnowledgeLibraryController(initialNotes: [note]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: _PageKnowledgeActionInvoker(
              note: note,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('page-invoke-tags')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('knowledge-tag-input')),
      '客户洞察',
    );
    await tester.tap(find.byTooltip('添加标签'));
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    const keyboardTop = 320 - 160.0;
    final save = find.byKey(const ValueKey('knowledge-tags-save'));
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(keyboardTop));
    expect(tester.takeException(), isNull);

    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(controller.effectiveTags(controller.noteForId(note.id)!), ['客户洞察']);
  });

  testWidgets('asset rows show source and omit classification shortcuts', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'asset-label-note',
      title: '多标签内容',
      source: V3MaterialSource.note,
      createdAt: DateTime.now(),
      rawBody: '正文',
    );
    final controller = KnowledgeLibraryController(initialNotes: [note]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: const MaterialApp(home: V3MyAssetsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('asset-statistics-bar')), findsNothing);
    expect(find.byKey(const ValueKey('asset-new-growth-line')), findsNothing);
    expect(find.text('资产总数'), findsNothing);
    expect(find.byTooltip('归类 多标签内容'), findsNothing);
    expect(find.byKey(const ValueKey('asset-labels-save')), findsNothing);
    expect(find.textContaining('#'), findsNothing);
    expect(find.byTooltip('笔记操作 多标签内容'), findsOneWidget);
    expect(find.text('来源 · 手动创建'), findsOneWidget);
  });

  testWidgets('asset share emits Markdown and export keeps both formats', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'exportable-note',
      title: '可导出知识',
      source: V3MaterialSource.link,
      createdAt: DateTime(2026, 7, 19),
      rawBody: '# 原始正文',
      summaryBody: '纲要内容',
      publicUrl: 'https://example.com/public-note',
      topics: const ['客户研究'],
    );
    final controller = KnowledgeLibraryController(initialNotes: [note]);
    final exportService = _PageKnowledgeExportService();
    final openPort = _PageKnowledgeOpenPort();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
          knowledgeDocumentExportServiceProvider.overrideWithValue(
            exportService,
          ),
          nativePreparedDocumentExportPortProvider.overrideWithValue(openPort),
        ],
        child: MaterialApp(
          home: _PageKnowledgeActionInvoker(
            note: note,
            child: const V3MyAssetsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('笔记操作 可导出知识'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();
    expect(exportService.formats, [KnowledgeExportFormat.markdown]);
    expect(openPort.exports, hasLength(1));

    Future<void> exportAs(KnowledgeExportFormat format) async {
      await tester.tap(find.byKey(const ValueKey('page-invoke-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(format.label));
      await tester.pumpAndSettle();
    }

    await exportAs(KnowledgeExportFormat.markdown);
    await exportAs(KnowledgeExportFormat.pdf);
    expect(exportService.formats, [
      KnowledgeExportFormat.markdown,
      KnowledgeExportFormat.markdown,
      KnowledgeExportFormat.pdf,
    ]);
    expect(openPort.exports, hasLength(3));
    expect(
      openPort.exports.every(
        (item) => item.startsWith('app-private-export://knowledge/'),
      ),
      isTrue,
    );
  });

  testWidgets('unmounted export flow discards every unhanded prepared file', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'deferred-export-note',
      title: '延迟导出知识',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 19),
      rawBody: '正文',
    );

    final preparingService = _ControlledPageKnowledgeExportService();
    await _pumpExportPage(
      tester,
      note: note,
      exportService: preparingService,
      openPort: _PageKnowledgeOpenPort(),
    );
    await _startMarkdownExport(tester);
    await preparingService.prepareStarted.future;
    await tester.pumpWidget(const SizedBox.shrink());
    preparingService.completePreparation();
    await tester.pump();
    expect(preparingService.discarded, hasLength(1));

    final handingOffService = _ControlledPageKnowledgeExportService();
    final handingOffPort = _ControlledPageKnowledgeOpenPort();
    await _pumpExportPage(
      tester,
      note: note,
      exportService: handingOffService,
      openPort: handingOffPort,
    );
    await _startMarkdownExport(tester);
    await handingOffService.prepareStarted.future;
    handingOffService.completePreparation();
    await tester.pump();
    await handingOffPort.openStarted.future;
    await tester.pumpWidget(const SizedBox.shrink());
    handingOffPort.complete(completed: false);
    await tester.pump();
    expect(handingOffService.discarded, hasLength(1));
  });

  testWidgets('conflict action previews versions and applies explicit choice', (
    tester,
  ) async {
    final local = _pageNote(
      id: 'page-conflict',
      title: '本地方案',
      body: '保留的本地正文',
      remoteRevision: 3,
    );
    final remote = _pageNote(
      id: local.id,
      title: '远端方案',
      body: '服务端已经更新的正文',
      remoteRevision: 4,
      syncState: NoteSyncState.synced,
    );
    final controller = KnowledgeLibraryController(
      initialNotes: [local],
      notePort: _PageKnowledgeNotePort([
        KnowledgeNotePortResult.conflict(remote),
      ]),
    );
    controller.showAllDeposits();
    await controller.syncNote(local.id);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: const MaterialApp(home: V3MyAssetsPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('笔记操作 本地方案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('处理冲突'));
    await tester.pumpAndSettle();

    expect(find.text('选择笔记版本'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('knowledge-conflict-local')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('knowledge-conflict-remote')),
      findsOneWidget,
    );
    expect(find.text('本地方案'), findsWidgets);
    expect(find.text('远端方案'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('knowledge-conflict-use-remote')),
    );
    await tester.pumpAndSettle();

    expect(controller.noteForId(local.id)?.title, '远端方案');
    expect(controller.noteForId(local.id)?.syncState, NoteSyncState.synced);
    expect(find.text('笔记已同步'), findsOneWidget);
  });

  testWidgets('unavailable sync stays pending and never claims success', (
    tester,
  ) async {
    final note = _pageNote(
      id: 'page-unavailable',
      title: '待同步笔记',
      body: '本地内容',
    );
    final controller = KnowledgeLibraryController(initialNotes: [note]);
    controller.showAllDeposits();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: const MaterialApp(home: V3MyAssetsPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('笔记操作 待同步笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();

    expect(controller.noteForId(note.id)?.syncState, NoteSyncState.pending);
    expect(find.text('同步服务暂不可用，本地版本已保留'), findsOneWidget);
    expect(find.text('笔记已同步'), findsNothing);
  });

  testWidgets('failed durable delete restores row and keeps activity', (
    tester,
  ) async {
    final note = _pageNote(
      id: 'page-delete-failure',
      title: '不能丢失的笔记',
      body: '本地正文',
    );
    final cache = _ControlledFailingKnowledgeCache();
    final controller = KnowledgeLibraryController(
      initialNotes: [note],
      cache: cache,
    );
    controller.showAllDeposits();
    final profile = ProfileHubController();
    profile.recordActivity(
      V3ProfileActivity(
        id: 'page-delete-failure-activity',
        occurredAt: DateTime(2026, 7, 15),
        type: V3ProfileActivityType.raw,
        title: note.title,
        feedItemId: note.id,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith((ref) => profile),
        ],
        child: const MaterialApp(home: V3MyAssetsPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('笔记操作 ${note.title}'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await cache.saveStarted.future;
    await tester.pump();

    expect(
      profile.activities.where((item) => item.feedItemId == note.id),
      isNotEmpty,
    );
    expect(find.text('已删除笔记'), findsNothing);

    cache.failSave();
    await tester.pumpAndSettle();

    expect(controller.noteForId(note.id), isNotNull);
    expect(find.text(note.title), findsOneWidget);
    expect(
      profile.activities.where((item) => item.feedItemId == note.id),
      isNotEmpty,
    );
    expect(find.text('删除未完成，笔记仍保留，请重试'), findsOneWidget);
  });

  testWidgets(
    'asset cards expand heading trees and heading-free raw content inline',
    (tester) async {
      final first = V3FeedItem(
        id: 'expansion-first',
        title: '第一文档',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 7, 18, 10),
        rawBody: '文档总览引导\n\n# 第一标题\n引导正文\n## 子标题\n### 叶标题\n叶子正文',
      );
      final second = V3FeedItem(
        id: 'expansion-second',
        title: '第二文档',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 7, 18, 9),
        rawBody: '无标题完整正文\n第二行',
      );
      final library = KnowledgeLibraryController(initialNotes: [first, second]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: const MaterialApp(home: V3MyAssetsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('第一标题'), findsNothing);
      expect(find.text('无标题完整正文'), findsNothing);
      expect(
        find.byKey(const ValueKey('knowledge-stage-expansion-first-summary')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('knowledge-stage-expansion-first-sprout')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey('asset-note-expand-expansion-first')),
      );
      await tester.pumpAndSettle();
      expect(find.text('第一标题'), findsOneWidget);
      expect(find.text('文档总览引导'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('asset-note-leading-expansion-first')),
        findsOneWidget,
      );
      expect(find.text('引导正文'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('asset-heading-expansion-first-raw-第一标题')),
      );
      await tester.pumpAndSettle();
      expect(find.text('引导正文'), findsOneWidget);
      expect(find.text('子标题'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('asset-heading-expansion-first-raw-子标题')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('asset-heading-expansion-first-raw-叶标题')),
      );
      await tester.pumpAndSettle();
      expect(find.text('叶子正文'), findsOneWidget);

      final secondExpand = find.byKey(
        const ValueKey('asset-note-expand-expansion-second'),
      );
      await tester.drag(find.byType(ListView).last, const Offset(0, -120));
      await tester.pumpAndSettle();
      await tester.tap(secondExpand);
      await tester.pumpAndSettle();
      expect(find.text('无标题完整正文'), findsOneWidget);
      expect(find.text('第二行'), findsOneWidget);

      expect(find.text('叶子正文'), findsOneWidget);
      expect(find.text('无标题完整正文'), findsOneWidget);
    },
  );

  testWidgets('legacy sections fall back and the card body opens Raw detail', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'route-update-note',
      title: '路由同步笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 18),
      rawBody: '正文',
    );
    final library = KnowledgeLibraryController(initialNotes: [note]);
    expect(library.depositContent(note.id), isNotNull);
    expect(
      v3MyAssetsSectionFromRouteParameter(' DEPOSITED '),
      V3MyAssetsSection.deposited,
    );
    expect(
      v3MyAssetsSectionFromRouteParameter('unknown'),
      V3MyAssetsSection.deposited,
    );
    expect(
      v3MyAssetsSectionFromRouteParameter('insight'),
      V3MyAssetsSection.deposited,
    );
    expect(
      v3MyAssetsSectionFromRouteParameter('media'),
      V3MyAssetsSection.mediaResources,
    );

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const V3MyAssetsPage()),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) => Text(
            '已打开 ${state.pathParameters['itemId']} '
            '${state.uri.queryParameters['stage']}',
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    final expand = find.byKey(
      const ValueKey('asset-note-expand-route-update-note'),
    );
    final actions = find.byKey(
      const ValueKey('asset-note-actions-route-update-note'),
    );
    expect(tester.getCenter(expand).dx, lessThan(tester.getCenter(actions).dx));

    await tester.tap(
      find.byKey(const ValueKey('asset-note-open-route-update-note')),
    );
    await tester.pumpAndSettle();
    expect(find.text('已打开 route-update-note raw'), findsOneWidget);
  });

  testWidgets(
    'legacy knowledge route renders the single deposited collection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 667));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final shared = V3FeedItem(
        id: 'knowledge-shared-note',
        title: '跨分类知识',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 7, 22, 9, 15),
        rawBody: '这条笔记同时属于两个知识分类。',
        topics: const <String>['落地', '创作'],
      );
      final organization = V3FeedItem(
        id: 'knowledge-organization-note',
        title: '组织协同知识',
        source: V3MaterialSource.meeting,
        createdAt: DateTime(2026, 7, 21, 17, 30),
        rawBody: '组织协同方法。',
      );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[shared, organization],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
          ],
          child: MaterialApp(
            home: V3MyAssetsPage(
              initialSection: v3MyAssetsSectionFromRouteParameter('knowledge'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('knowledge-secondary-directory')),
        findsNothing,
      );
      expect(find.text('跨分类知识'), findsOneWidget);
      expect(find.text('组织协同知识'), findsOneWidget);
      expect(find.text('来源 · 手动创建'), findsOneWidget);
      expect(find.text('来源 · 会议'), findsOneWidget);
    },
  );

  testWidgets(
    'legacy experience route renders the same cards and opens Raw detail',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 667));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final older = V3FeedItem(
        id: 'experience-older',
        title: '第一次交付复盘',
        source: V3MaterialSource.meeting,
        createdAt: DateTime(2026, 7, 18, 8, 5),
        rawBody: '# 复盘\n记录第一次交付中得到的经验。',
        topics: const <String>['交付'],
        linkedMaterials: const <V3LinkedMaterialRef>[
          V3LinkedMaterialRef(
            id: 'shared-interview',
            source: V3MaterialSource.meeting,
            title: '客户访谈录音',
          ),
        ],
      );
      final newer = V3FeedItem(
        id: 'experience-newer',
        title: '客户访谈取得突破',
        source: V3MaterialSource.monologue,
        createdAt: DateTime(2026, 7, 23, 14, 26),
        rawBody: '原始正文',
        summaryBody: '较新的真实经历摘要。',
        topics: const <String>['客户', '复盘'],
        linkedMaterials: const <V3LinkedMaterialRef>[
          V3LinkedMaterialRef(
            id: 'shared-interview',
            source: V3MaterialSource.meeting,
            title: '客户访谈录音（重复引用）',
          ),
        ],
      );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[older, newer],
      );
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => V3MyAssetsPage(
              initialSection: v3MyAssetsSectionFromRouteParameter('experience'),
            ),
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (context, state) => Text(
              '已打开 ${state.pathParameters['itemId']} ${state.uri.queryParameters['stage']}',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('experience-asset-timeline')),
        findsNothing,
      );
      expect(find.text('第一次交付复盘'), findsOneWidget);
      expect(find.text('客户访谈取得突破'), findsOneWidget);
      expect(find.text('较新的真实经历摘要。'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('asset-note-open-experience-newer')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已打开 experience-newer raw'), findsOneWidget);
    },
  );

  testWidgets('independent album hides deposited legacy media notes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const privatePath = '/private/path/that-must-not-render.png';
    final note = V3FeedItem(
      id: 'media-note',
      title: '图片资产',
      source: V3MaterialSource.mediaImport,
      createdAt: DateTime(2026, 7, 18),
      rawBody: '图片说明',
      mediaAttachments: const [
        V3MediaAttachment(
          privateUri: 'app-private-media://private-preview.png',
          displayName: '预览图片.png',
          mimeType: 'image/png',
          sizeBytes: 1,
          kind: V3MediaAttachmentKind.image,
          privatePath: privatePath,
        ),
      ],
    );
    final library = KnowledgeLibraryController(initialNotes: [note]);
    expect(library.depositContent(note.id), isNotNull);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: const MaterialApp(
          home: V3MyAssetsPage(
            initialSection: V3MyAssetsSection.mediaResources,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    final mediaTab = find.byKey(const ValueKey('asset-tab-mediaResources'));
    expect(mediaTab, findsOneWidget);
    expect(tester.getRect(mediaTab).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(mediaTab).right, lessThanOrEqualTo(375));

    expect(find.byType(Image), findsNothing);
    expect(find.text('预览图片.png'), findsNothing);
    expect(find.text('图片资产'), findsNothing);
    expect(find.text(privatePath), findsNothing);
  });

  testWidgets('remote subscription error retries into an honest empty state', (
    tester,
  ) async {
    final port = _PageSubscriptionPort(
      const MobileSubscriptionCatalogResult.failure('UNAUTHORIZED'),
    );
    final controller = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      subscriptionPort: port,
    );
    await controller.reloadSubscriptions();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: V3KnowledgeLibraryPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('subscription-runtime-error')),
      findsOneWidget,
    );
    expect(find.text('登录状态已失效，请重新登录'), findsOneWidget);
    expect(find.text('无限花火日报'), findsNothing);

    port.catalogResult = const MobileSubscriptionCatalogResult.success(
      <MobileSubscriptionPublication>[],
    );
    await tester.tap(find.byKey(const ValueKey('subscription-runtime-retry')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('subscription-runtime-empty')),
      findsOneWidget,
    );
  });

  testWidgets(
    'entering Knowledge Square starts the catalog and keeps its shell visible',
    (tester) async {
      final pendingCatalog = Completer<MobileSubscriptionCatalogResult>();
      final article = _pageSubscriptionArticle();
      final publication = MobileSubscriptionPublication(
        publicationId: 'publication-loading-1',
        title: '加载完成的知识世界',
        sectionCount: 1,
        articleCount: 1,
        updatedAt: DateTime.utc(2026, 8, 18, 10),
        articles: <V3FeedItem>[article],
        followed: false,
        available: true,
      );
      final port = _PageSubscriptionPort(
        MobileSubscriptionCatalogResult.success(<MobileSubscriptionPublication>[
          publication,
        ]),
        catalogCompleter: pendingCatalog,
      );
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        subscriptionPort: port,
      );
      final router = GoRouter(
        initialLocation: AppRoutePaths.knowledgeSquare,
        routes: _knowledgeSecondaryTestRoutes(),
        observers: <NavigatorObserver>[appRouteObserver],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      expect(port.catalogCalls, 1);
      expect(
        find.byKey(
          const PageStorageKey<String>('remote-knowledge-world-loading-shell'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('remote-knowledge-world-loading-hero'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('remote-knowledge-world-loading-grid'),
        ),
        findsOneWidget,
      );

      pendingCatalog.complete(
        MobileSubscriptionCatalogResult.success(<MobileSubscriptionPublication>[
          publication,
        ]),
      );
      await tester.pumpAndSettle();

      expect(controller.subscriptionMode, MobileSubscriptionRuntimeMode.remote);
      expect(
        find.byKey(const PageStorageKey<String>('remote-knowledge-world-home')),
        findsOneWidget,
      );

      port.catalogResult = const MobileSubscriptionCatalogResult.failure(
        'SUBSCRIPTION_CATALOG_UNAVAILABLE',
      );
      await controller.reloadSubscriptions();
      await tester.pumpAndSettle();
      expect(port.catalogCalls, 2);

      await tester.tap(find.text('我的订阅'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('知识广场'));
      await tester.pumpAndSettle();
      expect(port.catalogCalls, 2);

      unawaited(router.push<void>('/v3/feed/items/catalog-refresh-guard'));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      expect(port.catalogCalls, 2);
    },
  );

  for (final square in [false, true]) {
    testWidgets('external world refresh retains loaded home square=$square', (
      tester,
    ) async {
      final article = _pageSubscriptionArticle();
      final catalog = MobileSubscriptionCatalogResult.success([
        MobileSubscriptionPublication(
          publicationId: article.publicationId!,
          title: '已订阅栏目',
          sectionCount: 1,
          articleCount: 1,
          updatedAt: article.updatedAt,
          articles: [article],
          followed: true,
          available: true,
        ),
      ]);
      final port = _PageSubscriptionPort(catalog);
      final controller = KnowledgeLibraryController(
        initialNotes: const [],
        subscriptionPort: port,
      );
      await controller.reloadSubscriptions();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
          ],
          child: MaterialApp(
            home: V3KnowledgeLibraryPage(
              initialTab: square
                  ? V3KnowledgeLibraryTab.square
                  : V3KnowledgeLibraryTab.subscribed,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scope = square ? 'remote-knowledge-world' : 'remote-subscriptions';
      final home = find.byKey(
        PageStorageKey<String>(
          square ? 'remote-knowledge-world-home' : 'remote-subscriptions',
        ),
      );
      final rail = find.byKey(
        ValueKey(
          square
              ? 'remote-knowledge-world-today-carousel'
              : 'remote-subscription-channel-carousel',
        ),
      );
      final homeElement = tester.element(home);
      final railState = tester.state(rail);
      final pending = Completer<MobileSubscriptionCatalogResult>();
      port.nextCatalogCompleter = pending;
      final refresh = controller.reloadSubscriptions();
      await tester.pump();
      expect(tester.element(home), same(homeElement));
      expect(tester.state(rail), same(railState));
      expect(find.byKey(ValueKey('$scope-refreshing')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subscription-runtime-loading')),
        findsNothing,
      );

      pending.complete(
        const MobileSubscriptionCatalogResult.failure('UNAUTHORIZED'),
      );
      await refresh;
      await tester.pumpAndSettle();
      expect(tester.element(home), same(homeElement));
      expect(tester.state(rail), same(railState));
      expect(find.text('登录状态已失效，请重新登录'), findsOneWidget);
      final calls = port.catalogCalls;
      await tester.tap(find.byKey(ValueKey('$scope-retry')));
      await tester.pumpAndSettle();
      expect(port.catalogCalls, calls + 1);
      expect(tester.element(home), same(homeElement));
      expect(tester.state(rail), same(railState));
      expect(find.byKey(ValueKey('$scope-retry')), findsNothing);
      expect(
        controller.isRemotePublicationFollowed(article.publicationId!),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('remote subscription follow and save buttons call formal port', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final article = _pageSubscriptionArticle();
    final savedNote = _pageSavedSubscriptionNote(article);
    final port = _PageSubscriptionPort(
      MobileSubscriptionCatalogResult.success(<MobileSubscriptionPublication>[
        MobileSubscriptionPublication(
          publicationId: 'publication-1',
          title: '无限花火日报',
          sectionCount: 2,
          articleCount: 1,
          updatedAt: DateTime.utc(2026, 8, 7, 10),
          articles: <V3FeedItem>[article],
          followed: false,
          available: true,
        ),
      ]),
      savedItem: savedNote,
    );
    final controller = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      subscriptionPort: port,
    );
    final folderResult = await controller.createWorkspaceDepositFolder('行业资料');
    final folder = folderResult.data!;
    await controller.reloadSubscriptions();
    final router = GoRouter(
      initialLocation: AppRoutePaths.knowledgeSquare,
      routes: _knowledgeSecondaryTestRoutes(),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.subscriptionMode, MobileSubscriptionRuntimeMode.remote);
    expect(controller.tab, V3KnowledgeLibraryTab.square);
    expect(
      find.byKey(
        const PageStorageKey<String>('remote-knowledge-world-home'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const PageStorageKey<String>('remote-knowledge-world-home')),
      findsOneWidget,
    );
    final todayHero = find.byKey(
      ValueKey('remote-knowledge-world-hero-${article.id}'),
    );
    expect(todayHero, findsOneWidget);
    expect(
      find.descendant(
        of: todayHero,
        matching: find.byIcon(Icons.north_east_rounded),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('remote-knowledge-world-publication-grid')),
      findsOneWidget,
    );
    expect(find.text('安全摘要'), findsOneWidget);
    expect(find.text('无限花火日报'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey('remote-knowledge-world-editor-publication-1')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('2 个栏目'), findsOneWidget);
    expect(find.textContaining('1 篇文章'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('subscription-follow-publication-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('订阅该栏目？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('subscription-sheet-confirm')));
    await tester.pumpAndSettle();
    expect(port.followCalls, 1);
    expect(controller.isRemotePublicationFollowed('publication-1'), isTrue);
    expect(find.text('订阅成功'), findsOneWidget);
    await tester.tap(find.text('继续浏览'));
    await tester.pumpAndSettle();

    final save = find.byKey(ValueKey('subscription-save-${article.id}'));
    await tester.drag(find.byType(ListView).first, const Offset(0, -520));
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('保存到我的资产'), findsOneWidget);
    expect(find.text('保存位置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('deposit-picker-asset-label-knowledge')),
      findsNothing,
    );
    final destination = find.byKey(
      ValueKey('deposit-picker-folder-${folder.id}'),
    );
    expect(destination, findsOneWidget);
    await tester.tap(destination);
    await tester.tap(find.byKey(const ValueKey('deposit-picker-confirm')));
    await tester.pumpAndSettle();
    expect(port.saveCalls, 1);
    expect(controller.depositRecordFor(savedNote.id)?.folderId, folder.id);
    expect(find.text('已沉淀到笔记'), findsOneWidget);
    await tester.tap(find.text('去笔记查看'));
    await tester.pumpAndSettle();
    expect(find.text('文章详情 ${savedNote.id}'), findsOneWidget);
    expect(port.saveCalls, 1);
    expect(controller.noteForId(savedNote.id)?.isReadOnly, isFalse);
    expect(controller.noteForId(article.id)?.isReadOnly, isTrue);
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('subscription-open-${article.id}')));
    await tester.pumpAndSettle();
    expect(port.articleLoadCalls, 1);
    expect(controller.noteForId(article.id)?.rawBody, '# 文章正文');
    expect(find.text('文章详情 ${article.id}'), findsOneWidget);
  });

  testWidgets(
    'remote Knowledge World filters the loaded catalog and subscribed avatars enter a channel directly',
    (tester) async {
      final first = V3FeedItem(
        id: 'remote-search-article-a',
        title: '城市观察',
        source: V3MaterialSource.knowledgeSquare,
        createdAt: DateTime.utc(2026, 8, 8),
        rawBody: '',
        summaryBody: '真实城市文章摘要',
        ownership: V3NoteOwnership.knowledgeSquare,
        publicationId: 'remote-publication-a',
        articleId: 'remote-article-a',
        articleRevisionId: 'remote-revision-a',
      );
      final second = V3FeedItem(
        id: 'remote-search-article-b',
        title: '创作方法',
        source: V3MaterialSource.knowledgeSquare,
        createdAt: DateTime.utc(2026, 8, 9),
        rawBody: '',
        summaryBody: '真实创作文章摘要',
        ownership: V3NoteOwnership.knowledgeSquare,
        publicationId: 'remote-publication-b',
        articleId: 'remote-article-b',
        articleRevisionId: 'remote-revision-b',
      );
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        subscriptionPort: _PageSubscriptionPort(
          MobileSubscriptionCatalogResult.success(
            <MobileSubscriptionPublication>[
              MobileSubscriptionPublication(
                publicationId: 'remote-publication-a',
                title: '城市频道',
                sectionCount: 1,
                articleCount: 1,
                updatedAt: DateTime.utc(2026, 8, 8),
                articles: <V3FeedItem>[first],
                followed: true,
                available: true,
              ),
              MobileSubscriptionPublication(
                publicationId: 'remote-publication-b',
                title: '创作频道',
                sectionCount: 1,
                articleCount: 1,
                updatedAt: DateTime.utc(2026, 8, 9),
                articles: <V3FeedItem>[second],
                followed: true,
                available: true,
              ),
            ],
          ),
        ),
      );
      await controller.reloadSubscriptions();
      final router = GoRouter(
        initialLocation: AppRoutePaths.knowledgeSquare,
        routes: _knowledgeSecondaryTestRoutes(),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('remote-knowledge-world-search')),
        '城市',
      );
      await tester.pumpAndSettle();
      expect(find.text('搜索结果'), findsOneWidget);
      expect(find.text('城市观察'), findsOneWidget);
      expect(find.text('创作方法'), findsNothing);

      await tester.drag(
        find.byKey(const ValueKey<String>('knowledge-page-view')),
        const Offset(500, 0),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>('remote-subscription-channel-carousel'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'remote-subscribed-publication-remote-publication-b',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<V3RemoteKnowledgeWorldDetailPage>(
              find.byType(V3RemoteKnowledgeWorldDetailPage),
            )
            .publicationId,
        'remote-publication-b',
      );
      expect(find.byType(V3RemoteKnowledgeWorldDetailPage), findsOneWidget);
      expect(find.text('进入栏目'), findsNothing);
      expect(find.text('城市观察'), findsNothing);
    },
  );

  testWidgets(
    'remote discovery rails resize focus and random article keeps its cover',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(402, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final publications = List<MobileSubscriptionPublication>.generate(6, (
        index,
      ) {
        const titles = <String>[
          '人工智能/深度文章',
          '人工智能/行业动态',
          '星座哲学/深度文章',
          '星座哲学/行业动态',
          '美业时尚/深度文章',
          '美业时尚/行业动态',
        ];
        return MobileSubscriptionPublication(
          publicationId: 'publication-grid-$index',
          title: titles[index],
          sectionCount: 1,
          articleCount: index == 0 ? 2 : 1,
          updatedAt: DateTime.utc(2026, 8, 8, 12 - index),
          articles: <V3FeedItem>[
            V3FeedItem(
              id: 'subscription-grid-article-$index',
              title: '云端订阅文章 $index',
              source: V3MaterialSource.knowledgeSquare,
              createdAt: DateTime.utc(2026, 8, 8, 12 - index),
              rawBody: '',
              summaryBody: '云端订阅摘要',
              ownership: V3NoteOwnership.knowledgeSquare,
              publicationId: 'publication-grid-$index',
              articleId: 'article-grid-$index',
              articleRevisionId: 'article-revision-grid-$index',
            ),
            if (index == 0)
              V3FeedItem(
                id: 'subscription-grid-article-older',
                title: '更早的云端订阅文章',
                source: V3MaterialSource.knowledgeSquare,
                createdAt: DateTime.utc(2026, 7, 1),
                rawBody: '',
                summaryBody: '更早的云端订阅摘要',
                ownership: V3NoteOwnership.knowledgeSquare,
                publicationId: 'publication-grid-0',
                articleId: 'article-grid-older',
                articleRevisionId: 'article-revision-grid-older',
              ),
          ],
          followed: false,
          available: true,
        );
      });
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        subscriptionPort: _PageSubscriptionPort(
          MobileSubscriptionCatalogResult.success(publications),
        ),
      );
      await controller.reloadSubscriptions();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: const V3KnowledgeLibraryPage(
              initialTab: V3KnowledgeLibraryTab.square,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('remote-knowledge-world-publication-grid')),
        findsOneWidget,
      );

      final todayCarousel = find.byKey(
        const ValueKey('remote-knowledge-world-today-carousel'),
      );
      final firstToday = find.byKey(
        const ValueKey(
          'remote-knowledge-world-hero-subscription-grid-article-0',
        ),
      );
      final secondToday = find.byKey(
        const ValueKey(
          'remote-knowledge-world-hero-subscription-grid-article-1',
        ),
      );
      expect(
        tester.getSize(firstToday).width,
        greaterThan(tester.getSize(secondToday).width),
      );
      expect(
        tester.getSize(firstToday).height,
        greaterThan(tester.getSize(secondToday).height),
      );
      final secondTodayCollapsedSize = tester.getSize(secondToday);
      await tester.drag(todayCarousel, const Offset(-280, 0));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(secondToday).width,
        greaterThan(secondTodayCollapsedSize.width),
      );
      expect(
        tester.getSize(secondToday).height,
        greaterThan(secondTodayCollapsedSize.height),
      );

      final editorCarousel = find.byKey(
        const ValueKey('remote-knowledge-world-publication-grid'),
      );
      await tester.ensureVisible(editorCarousel);
      await tester.pumpAndSettle();
      final firstEditor = find.byKey(
        const ValueKey('remote-knowledge-world-editor-publication-grid-0'),
      );
      final secondEditor = find.byKey(
        const ValueKey('remote-knowledge-world-editor-publication-grid-1'),
      );
      expect(
        tester.getSize(firstEditor).width,
        greaterThan(tester.getSize(secondEditor).width),
      );
      expect(
        find.descendant(
          of: firstEditor,
          matching: find.byKey(
            const ValueKey('knowledge-publication-avatar-publication-grid-0'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: firstEditor,
          matching: find.byType(V3RemoteKnowledgeArticleCover),
        ),
        findsNothing,
      );
      final secondEditorCollapsedWidth = tester.getSize(secondEditor).width;
      await tester.drag(editorCarousel, const Offset(-210, 0));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(secondEditor).width,
        greaterThan(secondEditorCollapsedWidth),
      );

      expect(
        find.byKey(
          const ValueKey(
            'remote-knowledge-world-article-subscription-grid-article-3',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey(
            'remote-knowledge-world-article-subscription-grid-article-0',
          ),
        ),
        findsNothing,
      );
      expect(find.text('编辑推荐'), findsOneWidget);
      expect(find.text('随手读一篇'), findsOneWidget);
      expect(find.text('按行业发现栏目'), findsNothing);

      final randomCards = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('remote-knowledge-world-random-');
      });
      final world = find
          .descendant(
            of: find.byKey(
              const PageStorageKey<String>('remote-knowledge-world-home'),
            ),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('随手读一篇'),
        -280,
        scrollable: world,
      );
      await tester.pumpAndSettle();
      expect(randomCards, findsOneWidget);
      final beforeKey = tester.widget(randomCards).key! as ValueKey<String>;
      final beforeArticleId = beforeKey.value.substring(
        'remote-knowledge-world-random-'.length,
      );
      expect(
        find.descendant(
          of: randomCards,
          matching: find.byKey(
            ValueKey<String>('knowledge-random-cover-$beforeArticleId'),
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('换一篇  ↻'));
      await tester.pumpAndSettle();
      expect(randomCards, findsOneWidget);
      final afterKey = tester.widget(randomCards).key! as ValueKey<String>;
      final afterArticleId = afterKey.value.substring(
        'remote-knowledge-world-random-'.length,
      );
      expect(afterArticleId, isNot(beforeArticleId));
      expect(
        find.descendant(
          of: randomCards,
          matching: find.byKey(
            ValueKey<String>('knowledge-random-cover-$afterArticleId'),
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remote discovery bottom catalog opens every channel and its article reader',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final overflowArticle = V3FeedItem(
        id: 'overflow-publication-9-article',
        title: '溢出频道的完整文章',
        source: V3MaterialSource.knowledgeSquare,
        createdAt: DateTime.utc(2026, 8, 8, 3),
        rawBody: '',
        summaryBody: '频道最新文章摘要',
        ownership: V3NoteOwnership.knowledgeSquare,
        publicationId: 'overflow-publication-9',
        articleId: 'overflow-article-9',
        articleRevisionId: 'overflow-revision-9',
      );
      final publications = <MobileSubscriptionPublication>[
        for (var index = 0; index < 11; index++)
          MobileSubscriptionPublication(
            publicationId: 'overflow-publication-$index',
            title: '云端栏目 $index',
            sectionCount: 1,
            articleCount: index == 9 ? 1 : 0,
            updatedAt: DateTime.utc(2026, 8, 8, 12 - index),
            articles: index == 9
                ? <V3FeedItem>[overflowArticle]
                : const <V3FeedItem>[],
            followed: false,
            available: true,
          ),
        MobileSubscriptionPublication(
          publicationId: 'overflow-publication-0',
          title: '重复的云端栏目',
          sectionCount: 1,
          articleCount: 0,
          updatedAt: DateTime.utc(2026, 8, 8),
          articles: const <V3FeedItem>[],
          followed: false,
          available: true,
        ),
      ];
      final port = _PageSubscriptionPort(
        MobileSubscriptionCatalogResult.success(publications),
      );
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        subscriptionPort: port,
      );
      await controller.reloadSubscriptions();
      final router = GoRouter(
        initialLocation: AppRoutePaths.knowledgeSquare,
        routes: [
          ..._knowledgeSecondaryTestRoutes().where(
            (route) =>
                route is! GoRoute || route.path != '/v3/feed/items/:itemId',
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (context, state) =>
                V3FeedItemDetailPage(itemId: state.pathParameters['itemId']!),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('bottom-catalog-test'),
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => controller,
            ),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('编辑推荐'), findsOneWidget);
      final home = find.byKey(
        const PageStorageKey<String>('remote-knowledge-world-home'),
      );
      final catalog = find.byKey(
        const ValueKey('remote-knowledge-world-catalog-list'),
      );
      await tester.scrollUntilVisible(
        find.text('全部栏目'),
        300,
        scrollable: find
            .descendant(of: home, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('全部栏目'), findsOneWidget);
      expect(catalog, findsOneWidget);
      expect(find.text('共 11 个栏目'), findsOneWidget);
      expect(find.text('重复的云端栏目'), findsNothing);
      for (var index = 0; index < 11; index++) {
        expect(
          find.byKey(
            ValueKey(
              'remote-knowledge-world-catalog-overflow-publication-$index',
            ),
          ),
          findsOneWidget,
        );
      }
      final channel = find.byKey(
        const ValueKey('remote-knowledge-world-catalog-overflow-publication-9'),
      );
      await tester.ensureVisible(channel);
      await tester.pumpAndSettle();
      await tester.tap(channel);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('subscription-follow-overflow-publication-9'),
        ),
        findsOneWidget,
      );
      expect(find.text('溢出频道的完整文章'), findsWidgets);
      final openArticle = find.byKey(
        ValueKey('subscription-open-${overflowArticle.id}'),
      );
      await tester.ensureVisible(openArticle);
      await tester.pumpAndSettle();
      await tester.tap(openArticle);
      await tester.pumpAndSettle();
      expect(port.articleLoadCalls, 1);
      expect(port.followCalls, 0);
      expect(find.byType(V3FeedItemDetailPage), findsOneWidget);
      expect(controller.noteForId(overflowArticle.id)?.rawBody, '# 文章正文');
      expect(find.textContaining('文章正文'), findsWidgets);

      router.pop();
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      expect(channel.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in ['reader', 'publication', 'square', 'reader-failure']) {
    testWidgets(
      'unfollowed article deposit from $entry keeps subscription unchanged',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final article = _pageSubscriptionArticle().copyWith(rawBody: '作者完整正文');
        final savedNote = _pageSavedSubscriptionNote(article);
        final succeeds = entry != 'reader-failure';
        final port = _PageSubscriptionPort(
          MobileSubscriptionCatalogResult.success([
            MobileSubscriptionPublication(
              publicationId: 'publication-1',
              title: '无限花火日报',
              sectionCount: 2,
              articleCount: 1,
              updatedAt: article.updatedAt,
              articles: [article],
              followed: false,
              available: true,
            ),
          ]),
          savedItem: savedNote,
          saveResult: succeeds
              ? null
              : const MobileSubscriptionActionResult.failure(
                  'SUBSCRIPTION_SAVE_FAILED',
                ),
        );
        final controller = KnowledgeLibraryController(
          initialNotes: [],
          subscriptionPort: port,
        );
        await controller.reloadSubscriptions();
        final isReader = entry.startsWith('reader');
        final router = GoRouter(
          initialLocation: isReader
              ? AppRoutePaths.feedItem(article.id)
              : entry == 'publication'
              ? AppRoutePaths.knowledgeWorldDetail(
                  publicationId: 'publication-1',
                )
              : AppRoutePaths.knowledgeSquare,
          routes: [
            ..._knowledgeSecondaryTestRoutes().where(
              (route) =>
                  route is! GoRoute || route.path != '/v3/feed/items/:itemId',
            ),
            GoRoute(
              path: '/v3/feed/items/:itemId',
              builder: (context, state) =>
                  V3FeedItemDetailPage(itemId: state.pathParameters['itemId']!),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              resolvedDeviceIdProvider.overrideWithValue(
                'unfollowed-deposit-test',
              ),
              knowledgeLibraryControllerProvider.overrideWith(
                (ref) => controller,
              ),
              profileHubControllerProvider.overrideWith(
                (ref) => ProfileHubController(),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        if (entry == 'square') {
          await tester.enterText(
            find.byKey(const ValueKey('remote-knowledge-world-search')),
            article.title,
          );
          await tester.pumpAndSettle();
        }
        final save = find.byKey(
          ValueKey(
            isReader
                ? 'external-article-deposit'
                : 'subscription-save-${article.id}',
          ),
        );
        if (!isReader) {
          await tester.scrollUntilVisible(
            save,
            320,
            scrollable: find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .last,
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.text('保存到我的资产'), findsOneWidget);
        expect(port.followCalls, 0);
        expect(port.saveCalls, 0);
        await tester.tap(find.byKey(const ValueKey('deposit-picker-confirm')));
        await tester.pumpAndSettle();
        expect(port.saveCalls, 1);
        expect(port.savedArticleRevisionIds, [article.articleRevisionId]);
        expect(port.followCalls, 0);
        expect(
          controller.isRemotePublicationFollowed('publication-1'),
          isFalse,
        );
        expect(controller.remoteSubscribedArticles, isEmpty);
        expect(controller.noteForId(article.id)?.isReadOnly, isTrue);
        if (succeeds) {
          expect(find.text('已沉淀到笔记'), findsOneWidget);
          expect(controller.isDeposited(savedNote.id), isTrue);
          await tester.tap(find.text('去笔记查看'));
          await tester.pumpAndSettle();
          expect(find.text('保存正文'), findsOneWidget);
          expect(find.text('原始'), findsOneWidget);
          expect(find.text('纲要'), findsOneWidget);
          expect(find.text('深度洞察'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('external-article-deposit')),
            findsNothing,
          );
        } else {
          expect(find.text('云端沉淀失败，请稍后重试'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('deposit-picker-confirm')),
            findsOneWidget,
          );
          expect(controller.allDepositedNotes, isEmpty);
          expect(controller.noteForId(savedNote.id), isNull);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('production knowledge article detail is a body-only reader', (
    tester,
  ) async {
    final article = _pageSubscriptionArticle().copyWith(rawBody: '服务器文章正文');
    final savedNote = _pageSavedSubscriptionNote(article);
    final port = _PageSubscriptionPort(
      MobileSubscriptionCatalogResult.success(<MobileSubscriptionPublication>[
        MobileSubscriptionPublication(
          publicationId: 'publication-1',
          title: '无限花火日报',
          sectionCount: 2,
          articleCount: 1,
          updatedAt: DateTime.utc(2026, 8, 7, 10),
          articles: <V3FeedItem>[article],
          followed: true,
          available: true,
        ),
      ]),
      savedItem: savedNote,
    );
    final controller = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      subscriptionPort: port,
    );
    await controller.reloadSubscriptions();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('knowledge-detail-test'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp(home: V3FeedItemDetailPage(itemId: article.id)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(article.title), findsOneWidget);
    expect(find.text('服务器文章正文'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-external-read-content')),
      findsOneWidget,
    );
    expect(find.text('沉淀到我的资产'), findsNothing);
    expect(find.text('订阅'), findsNothing);
    expect(find.text('原始'), findsNothing);
    expect(find.text('纲要'), findsNothing);
    expect(find.text('深度洞察'), findsNothing);
    expect(port.saveCalls, 0);
    expect(controller.noteForId(savedNote.id), isNull);
  });
}

List<RouteBase> _knowledgeAppRoutes() {
  return buildAppRoutes(
    splashBuilder: (context, state) => const SizedBox.shrink(),
    restoreFailedBuilder: (context, state) => const SizedBox.shrink(),
    workspaceRetryBuilder: (context, state) => const SizedBox.shrink(),
  );
}

List<RouteBase> _knowledgeSecondaryTestRoutes() {
  return <RouteBase>[
    GoRoute(
      path: AppRoutePaths.knowledge,
      builder: (context, state) => V3KnowledgeLibraryPage(
        initialTab: v3KnowledgeLibraryTabFromRouteParameter(
          state.uri.queryParameters['tab'],
        ),
      ),
    ),
    GoRoute(
      path: AppRoutePaths.knowledgeChannelRoute,
      redirect: (context, state) =>
          routeKnowledgeChannel(state.pathParameters['channelId']) == null
          ? AppRoutePaths.knowledgeSquare
          : null,
      builder: (context, state) => V3KnowledgeChannelDetailPage(
        channelId: routeKnowledgeChannel(state.pathParameters['channelId'])!.id,
      ),
    ),
    GoRoute(
      path: AppRoutePaths.knowledgeWorld,
      builder: (context, state) => V3RemoteKnowledgeWorldDetailPage(
        publicationId: routeKnowledgePublicationId(
          state.uri.queryParameters['publicationId'],
        ),
        query: routeKnowledgeWorldQuery(state.uri.queryParameters['q']) ?? '',
      ),
    ),
    GoRoute(
      path: '/v3/feed/items/:itemId',
      builder: (context, state) =>
          Scaffold(body: Text('文章详情 ${state.pathParameters['itemId']}')),
    ),
  ];
}

V3FeedItem _pageSubscriptionArticle() {
  return V3FeedItem(
    id: 'subscription-article-page-1',
    title: 'API25 文章',
    source: V3MaterialSource.knowledgeSquare,
    createdAt: DateTime.utc(2026, 8, 7, 9),
    rawBody: '',
    summaryBody: '安全摘要',
    ownership: V3NoteOwnership.knowledgeSquare,
    publicationId: 'publication-1',
    articleId: 'article-1',
    articleRevisionId: 'article-revision-1',
    author: '花火编辑部',
  );
}

V3FeedItem _pageSavedSubscriptionNote(V3FeedItem article) {
  return V3FeedItem(
    id: 'saved-subscription-note-page-1',
    title: article.title,
    source: V3MaterialSource.subscription,
    createdAt: DateTime.utc(2026, 8, 7, 11),
    rawBody: '# 保存正文',
    ownership: V3NoteOwnership.mine,
    copiedFromContentId: article.id,
    remoteNoteId: 'saved-subscription-note-page-1',
    noteRevisionId: 'note-revision-1',
    rawPartRevisionId: 'raw-revision-1',
    etag: '"note-1"',
    contentCursor: '220',
    publicationId: article.publicationId,
    articleId: article.articleId,
    articleRevisionId: article.articleRevisionId,
    syncState: NoteSyncState.synced,
  );
}

final class _AssetsWorkspaceRemote implements WorkspaceContentSyncRemotePort {
  final snapshot = Completer<WorkspaceContentSnapshotResponse>();
  var snapshotCalls = 0;
  var changeCalls = 0;

  @override
  Future<WorkspaceContentSnapshotResponse> contentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  }) {
    snapshotCalls += 1;
    return snapshot.future;
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>>
  changes(String workspaceId, {required String after}) async {
    changeCalls += 1;
    if (changeCalls == 1) {
      return const WorkspaceContentRemoteResponse.failure(
        errorCode: 'SERVICE_UNAVAILABLE',
      );
    }
    return const WorkspaceContentRemoteResponse.success(
      SharedWorkspaceContentEventPage(
        events: [],
        nextAfter: '10',
        hasMore: false,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'unexpected assets remote call: ${invocation.memberName}',
  );
}

final class _AssetsWorkspaceFolderPort implements WorkspaceFolderPort {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected folder mutation: ${invocation.memberName}');
}

final class _PageSubscriptionPort implements MobileSubscriptionPort {
  _PageSubscriptionPort(
    this.catalogResult, {
    this.savedItem,
    this.catalogCompleter,
    this.saveResult,
  });

  MobileSubscriptionCatalogResult catalogResult;
  final V3FeedItem? savedItem;
  final MobileSubscriptionActionResult? saveResult;
  final List<String?> savedArticleRevisionIds = [];
  final Completer<MobileSubscriptionCatalogResult>? catalogCompleter;
  Completer<MobileSubscriptionCatalogResult>? nextCatalogCompleter;
  bool _usedCatalogCompleter = false;
  int catalogCalls = 0;
  int followCalls = 0;
  int articleLoadCalls = 0;
  int saveCalls = 0;

  @override
  bool get isDemo => false;

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() {
    catalogCalls += 1;
    final next = nextCatalogCompleter;
    if (next != null) {
      nextCatalogCompleter = null;
      return next.future;
    }
    final pending = catalogCompleter;
    if (pending != null && !_usedCatalogCompleter) {
      _usedCatalogCompleter = true;
      return pending.future;
    }
    return Future<MobileSubscriptionCatalogResult>.value(catalogResult);
  }

  @override
  Future<MobileSubscriptionActionResult> loadArticle(V3FeedItem article) async {
    articleLoadCalls += 1;
    return MobileSubscriptionActionResult.success(
      article.copyWith(rawBody: '# 文章正文'),
    );
  }

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
  }) async {
    saveCalls += 1;
    savedArticleRevisionIds.add(article.articleRevisionId);
    return saveResult ?? MobileSubscriptionActionResult.success(savedItem);
  }

  @override
  Future<MobileSubscriptionActionResult> setPublicationFollowed({
    required String publicationId,
    required bool followed,
    required String actionId,
  }) async {
    followCalls += 1;
    return const MobileSubscriptionActionResult.success();
  }
}

V3FeedItem _pageNote({
  required String id,
  required String title,
  required String body,
  int? remoteRevision,
  NoteSyncState syncState = NoteSyncState.pending,
}) {
  return V3FeedItem(
    id: id,
    title: title,
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 7, 15),
    rawBody: body,
    localRevision: 2,
    remoteRevision: remoteRevision,
    syncState: syncState,
  );
}

final class _PageKnowledgeNotePort implements KnowledgeNotePort {
  _PageKnowledgeNotePort(List<KnowledgeNotePortResult> responses)
    : _responses = List<KnowledgeNotePortResult>.of(responses);

  final List<KnowledgeNotePortResult> _responses;

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    return _responses.removeAt(0);
  }
}

final class _ControlledFailingKnowledgeCache implements KnowledgeLibraryCache {
  final Completer<void> saveStarted = Completer<void>();
  final Completer<void> _saveGate = Completer<void>();

  void failSave() =>
      _saveGate.completeError(const FileSystemException('test cache failure'));

  @override
  Future<List<V3FeedItem>?> load() async => null;

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    await _saveGate.future;
  }
}

final class _PageKnowledgeExportService
    implements KnowledgeDocumentExportService {
  final List<KnowledgeExportFormat> formats = <KnowledgeExportFormat>[];

  @override
  Future<KnowledgeExportResult<PreparedKnowledgeExport>> prepare(
    KnowledgeExportDocument document,
    KnowledgeExportFormat format,
  ) async {
    formats.add(format);
    return KnowledgeExportResult<PreparedKnowledgeExport>.success(
      PreparedKnowledgeExport(
        opaqueExportRef:
            'app-private-export://knowledge/cache/export-test/note.${format.extension}',
        displayName: 'note.${format.extension}',
        mimeType: format.mimeType,
        sizeBytes: 12,
        format: format,
      ),
    );
  }

  @override
  Future<KnowledgeExportResult<PreparedKnowledgeExport>> prepareArchive({
    required String title,
    required Uint8List bytes,
  }) => throw UnsupportedError('not used');

  @override
  Future<void> discard(PreparedKnowledgeExport export) async {}
}

final class _PageKnowledgeOpenPort implements NativePreparedDocumentExportPort {
  final List<String> exports = <String>[];

  @override
  Future<NativeFileResult<bool>> openPreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    exports.add(opaqueExportRef);
    return NativeFileResult<bool>.success(true);
  }
}

final class _ControlledPageKnowledgeExportService
    implements KnowledgeDocumentExportService {
  final Completer<void> prepareStarted = Completer<void>();
  final Completer<KnowledgeExportResult<PreparedKnowledgeExport>> _preparation =
      Completer<KnowledgeExportResult<PreparedKnowledgeExport>>();
  final List<PreparedKnowledgeExport> discarded = <PreparedKnowledgeExport>[];

  @override
  Future<KnowledgeExportResult<PreparedKnowledgeExport>> prepare(
    KnowledgeExportDocument document,
    KnowledgeExportFormat format,
  ) {
    if (!prepareStarted.isCompleted) prepareStarted.complete();
    return _preparation.future;
  }

  @override
  Future<KnowledgeExportResult<PreparedKnowledgeExport>> prepareArchive({
    required String title,
    required Uint8List bytes,
  }) => throw UnsupportedError('not used');

  void completePreparation() {
    _preparation.complete(
      KnowledgeExportResult<PreparedKnowledgeExport>.success(
        const PreparedKnowledgeExport(
          opaqueExportRef:
              'app-private-export://knowledge/cache/export-deferred/note.md',
          displayName: '延迟导出知识.md',
          mimeType: 'text/markdown',
          sizeBytes: 12,
          format: KnowledgeExportFormat.markdown,
        ),
      ),
    );
  }

  @override
  Future<void> discard(PreparedKnowledgeExport export) async {
    discarded.add(export);
  }
}

class _PageKnowledgeActionInvoker extends ConsumerWidget {
  const _PageKnowledgeActionInvoker({required this.note, required this.child});

  final V3FeedItem note;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          right: 0,
          bottom: 0,
          child: Opacity(
            opacity: 0,
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('page-invoke-tags'),
                  onPressed: () => handleV3KnowledgeNoteAction(
                    context,
                    ref,
                    note,
                    V3KnowledgeNoteAction.tags,
                  ),
                  icon: const Icon(Icons.sell_outlined),
                ),
                IconButton(
                  key: const ValueKey('page-invoke-export'),
                  onPressed: () => handleV3KnowledgeNoteAction(
                    context,
                    ref,
                    note,
                    V3KnowledgeNoteAction.export,
                  ),
                  icon: const Icon(Icons.file_download_outlined),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _ControlledPageKnowledgeOpenPort
    implements NativePreparedDocumentExportPort {
  final Completer<void> openStarted = Completer<void>();
  final Completer<NativeFileResult<bool>> _result =
      Completer<NativeFileResult<bool>>();

  @override
  Future<NativeFileResult<bool>> openPreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) {
    if (!openStarted.isCompleted) openStarted.complete();
    return _result.future;
  }

  void complete({required bool completed}) {
    _result.complete(NativeFileResult<bool>.success(completed));
  }
}

Future<void> _pumpExportPage(
  WidgetTester tester, {
  required V3FeedItem note,
  required KnowledgeDocumentExportService exportService,
  required NativePreparedDocumentExportPort openPort,
}) async {
  final controller = KnowledgeLibraryController(initialNotes: [note]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
        profileHubControllerProvider.overrideWith(
          (ref) => ProfileHubController(),
        ),
        knowledgeDocumentExportServiceProvider.overrideWithValue(exportService),
        nativePreparedDocumentExportPortProvider.overrideWithValue(openPort),
      ],
      child: MaterialApp(
        home: _PageKnowledgeActionInvoker(
          note: note,
          child: const V3MyAssetsPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _startMarkdownExport(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('page-invoke-export')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Markdown'));
  await tester.pump();
}

V3PhotoAlbumEntry _pagePhotoAlbumEntry({
  String resourceId = 'page-photo-resource',
  String displayName = '路由影像',
}) => V3PhotoAlbumEntry(
  id: resourceId,
  resourceId: resourceId,
  displayName: displayName,
  role: 'gallery_photo',
  ordinal: 0,
  version: 1,
  etag:
      '"wcc-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"',
);

Override _pageResourceImageCacheOverride() =>
    resourceImageCacheProvider.overrideWith((ref) {
      final cache = _pageResourceImageCache();
      ref.onDispose(cache.dispose);
      return cache;
    });

Override _pageDownloadableResourceImageCacheOverride() =>
    resourceImageCacheProvider.overrideWith((ref) {
      final cache = AuthenticatedResourceImageCache(
        playbackClient: ChatImagePlaybackClient(
          ApiClient(
            config: ApiClientConfig(
              baseUrl: Uri.parse('https://api.example.test'),
              clientVersion: 'test',
              deviceId: 'test-device-photo-save',
              platform: 'ios',
              locale: 'zh-CN',
              getAccessToken: () async => 'access-token',
            ),
            transport: const _PagePlaybackTransport(),
          ),
        ),
        userScope: 'test-user',
        workspaceScope: 'test-workspace',
        cacheDirectoryProvider: () async => throw StateError('DISK_DISABLED'),
        download: (_) async => ChatImageBytes(
          bytes: Uint8List.fromList(_pagePngBytes),
          mimeType: 'image/png',
        ),
      );
      ref.onDispose(cache.dispose);
      return cache;
    });

AuthenticatedResourceImageCache _pageResourceImageCache() =>
    AuthenticatedResourceImageCache(
      playbackClient: ChatImagePlaybackClient(
        ApiClient(
          config: ApiClientConfig(
            baseUrl: Uri.parse('https://api.example.test'),
            clientVersion: 'test',
            deviceId: 'test-device-photo-route',
            platform: 'ios',
            locale: 'zh-CN',
            getAccessToken: () async => 'access-token',
          ),
          transport: const UnconfiguredApiTransport(),
        ),
      ),
      userScope: 'test-user',
      workspaceScope: 'test-workspace',
      cacheDirectoryProvider: () async => throw StateError('DISK_DISABLED'),
    );

final _pagePngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+'
  'A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

final class _PagePlaybackTransport implements ApiTransport {
  const _PagePlaybackTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async =>
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'resourceId': request.url.pathSegments[4],
            'url': 'https://media.example.test/photo.png',
            'mimeType': 'image/png',
            'fileName': 'photo.png',
          },
        },
      );
}

final class _PageImageGallerySaver
    implements NativeFilePort, NativeImageGallerySaverPort {
  Uint8List? savedBytes;
  String? savedDisplayName;
  String? savedMimeType;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async =>
      NativeFileResult<List<PickedAudioFile>>.success(
        const <PickedAudioFile>[],
      );

  @override
  Future<NativeFileResult<bool>> saveImageToGallery({
    required Uint8List bytes,
    required String displayName,
    required String mimeType,
  }) async {
    savedBytes = Uint8List.fromList(bytes);
    savedDisplayName = displayName;
    savedMimeType = mimeType;
    return NativeFileResult<bool>.success(true);
  }
}

final class _PagePhotoAlbumRepository implements PhotoAlbumRepository {
  _PagePhotoAlbumRepository({
    required this.entries,
    this.deleteStatus = 'deleted',
    this.loadFuture,
  });

  final List<V3PhotoAlbumEntry> entries;
  final String deleteStatus;
  final Future<List<V3PhotoAlbumEntry>>? loadFuture;
  final List<String> deletedResourceIds = <String>[];

  @override
  Future<List<V3PhotoAlbumEntry>> load() =>
      loadFuture ?? Future<List<V3PhotoAlbumEntry>>.value(entries);

  @override
  Future<Uri?> resolvePlayback(String resourceId) async => null;

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files) =>
      throw UnimplementedError();

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) async {
    deletedResourceIds.add(resourceId);
    return MediaResourceDeleteReceipt(
      workspaceId: 'workspace-photo-route',
      resourceId: resourceId,
      status: deleteStatus,
    );
  }
}
