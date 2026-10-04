import 'package:huahuoai_app/app/di/native_port_providers.dart';
import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/core/native/knowledge_export_port.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/features/chat/application/chat_controller.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/data/chat_thread_alias_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_document_export_service.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/subscription_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/knowledge_library_cache.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_export_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/profile_activity_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_item_detail_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_quick_dock.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_note_page.dart';
import 'package:huahuoai_app/shared/navigation/foreground_ingress_coordinator.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  for (final sourceKind in V3MaterialSource.values) {
    final ownership = switch (sourceKind) {
      V3MaterialSource.subscription => V3NoteOwnership.subscribed,
      V3MaterialSource.knowledgeSquare => V3NoteOwnership.knowledgeSquare,
      V3MaterialSource.hotspot => V3NoteOwnership.hotspot,
      _ => V3NoteOwnership.mine,
    };
    final external =
        ownership == V3NoteOwnership.subscribed ||
        ownership == V3NoteOwnership.knowledgeSquare;
    for (final stage
        in external ? [V3ContentStage.raw] : V3ContentStage.values) {
      testWidgets('visible Canvas ingress ${sourceKind.name}/${stage.name}', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(402, 874));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final note = V3FeedItem(
          id: 'ingress-${sourceKind.name}',
          title: '入口契约-${sourceKind.name}',
          source: sourceKind,
          ownership: ownership,
          createdAt: DateTime.utc(2026, 9, 16),
          rawBody: '不可覆盖的原始正文。',
          summaryBody: '不可覆盖的纲要正文。',
          sproutReport: V3SproutReport(
            id: 'ingress-sprout',
            noteId: 'ingress-${sourceKind.name}',
            title: '深度洞察',
            markdown: '不可覆盖的深度洞察正文。',
            generatedAt: DateTime.utc(2026, 9, 16),
          ),
          remoteNoteId: external ? null : 'remote-${sourceKind.name}',
          rawPartRevisionId: external ? null : 'raw-ingress-1',
          outlinePartRevisionId: external ? null : 'outline-ingress-1',
          germinationPartRevisionId: external ? null : 'sprout-ingress-1',
          articleId: external ? 'article-${sourceKind.name}' : null,
          articleRevisionId: external ? 'article-revision-1' : null,
        );
        final library = KnowledgeLibraryController(
          initialNotes: [note],
          includeDemoFixtures: false,
        );
        AssetCanvasSeed? openedSeed;
        final router = GoRouter(
          initialLocation: '/detail',
          routes: [
            GoRoute(
              path: '/detail',
              builder: (_, __) => V3FeedItemDetailPage(itemId: note.id),
            ),
            GoRoute(
              path: '/v3/workbench/canvas',
              builder: (_, state) {
                openedSeed = state.extra! as AssetCanvasSeed;
                return const Scaffold(body: Text('已进入自由创作'));
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              resolvedDeviceIdProvider.overrideWithValue('canvas-ingress-test'),
              knowledgeLibraryControllerProvider.overrideWith((ref) => library),
              profileHubControllerProvider.overrideWith(
                (ref) => ProfileHubController(),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        if (stage != V3ContentStage.raw) {
          await tester.tap(
            find.text(stage == V3ContentStage.summary ? '纲要' : '深度洞察').first,
          );
          await tester.pumpAndSettle();
        }
        final action = find.byKey(
          ValueKey(
            external
                ? 'external-article-free-creation'
                : 'detail-floating-action-Agent 自由创作',
          ),
        );
        expect(action, findsOneWidget);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.text('已进入自由创作'), findsOneWidget);
        _expectAssetCanvasSeed(
          openedSeed!,
          item: note,
          stage: AssetCanvasSourceStageX.fromContentStage(stage),
          markdown: switch (stage) {
            V3ContentStage.raw => note.rawBody,
            V3ContentStage.summary => note.summaryBody!,
            V3ContentStage.sprout => note.sproutReport!.markdown,
          },
          partRevisionId: external
              ? note.articleRevisionId!
              : switch (stage) {
                  V3ContentStage.raw => note.rawPartRevisionId!,
                  V3ContentStage.summary => note.outlinePartRevisionId!,
                  V3ContentStage.sprout => note.germinationPartRevisionId!,
                },
          sourceMode: AssetCanvasInitialSourceMode.generateTranscript,
        );
        expect(library.noteForId(note.id)!.rawBody, note.rawBody);
        if (external) {
          expect(
            AssetCanvasSeed.tryFromItem(
              item: note.copyWith(rawBody: ''),
              stage: V3ContentStage.raw,
            ),
            isNull,
          );
          expect(
            AssetCanvasSeed.tryFromItem(
              item: note,
              stage: V3ContentStage.summary,
            ),
            isNull,
          );
          expect(
            AssetCanvasSeed.tryFromItem(
              item: note,
              stage: V3ContentStage.sprout,
            ),
            isNull,
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final completed in <bool>[true, false]) {
    testWidgets(
      'detail shares complete Markdown attachment completed=$completed',
      (tester) async {
        final note = V3FeedItem(
          id: 'markdown-share-note',
          title: '我的定位笔记',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 9, 5),
          rawBody: '${'完整正文' * 200}\n正文末尾\nfile:///Users/run/private.txt',
          summaryBody: '定位纲要',
          sproutTopic: '点火结论',
          topics: const <String>['个人定位'],
        );
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
        );
        final exporter = _DetailMarkdownExporter();
        final sharePort = _DetailDocumentSharePort();
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              resolvedDeviceIdProvider.overrideWithValue('share-device'),
              authenticatedUserDataScopeProvider.overrideWithValue(
                'share-user',
              ),
              knowledgeLibraryControllerProvider.overrideWith((ref) => library),
              profileHubControllerProvider.overrideWith(
                (ref) => ProfileHubController(),
              ),
              knowledgeDocumentExportServiceProvider.overrideWithValue(
                exporter,
              ),
              nativePreparedDocumentSharePortProvider.overrideWithValue(
                sharePort,
              ),
              knowledgeSharePortProvider.overrideWith(
                (ref) => throw StateError('Must not share text'),
              ),
            ],
            child: MaterialApp(home: V3FeedItemDetailPage(itemId: note.id)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('note-more-share')));
        await tester.pumpAndSettle();
        expect(exporter.formats, <KnowledgeExportFormat>[
          KnowledgeExportFormat.markdown,
        ]);
        final markdown = KnowledgeDocumentSerializer().serializeMarkdown(
          exporter.documents.single,
        );
        expect(markdown, contains('# 我的定位笔记'));
        expect(markdown, contains('正文末尾'));
        expect(markdown, contains('定位纲要'));
        expect(markdown, contains('点火结论'));
        expect(markdown, contains('个人定位'));
        expect(markdown, isNot(contains('/Users/run')));
        expect(sharePort.calls, <String>[
          '${exporter.prepared.opaqueExportRef}|我的定位笔记.md|text/markdown',
        ]);
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ListTile>(find.byKey(const ValueKey('note-more-share')))
              .onTap,
          isNull,
        );
        expect(exporter.documents, hasLength(1));
        Navigator.of(
          tester.element(find.byKey(const ValueKey('note-more-share'))),
        ).pop();
        sharePort.result.complete(NativeFileResult<bool>.success(completed));
        await tester.pumpAndSettle();
        expect(
          exporter.discarded,
          completed ? isEmpty : <PreparedKnowledgeExport>[exporter.prepared],
        );
        expect(
          find.text(completed ? '已打开 Markdown 文件分享' : '已取消分享'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('M01 text capture matches the Mobile V5 writing canvas', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final note = V3FeedItem(
      id: 'm01-text-capture-golden',
      title: '给今天留一点空白',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 8, 24, 15, 4),
      rawBody:
          '真正有价值的笔记，不只是把信息存下来。\n\n当不同时间写下的想法再次相遇，它们会产生新的联系，也会提醒我：整理本身就是一次新的思考。',
    );
    final library = KnowledgeLibraryController(initialNotes: [note]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp(
          theme: figmaGoldenTheme(),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(402, 874),
              padding: EdgeInsets.only(top: 54, bottom: 34),
            ),
            child: V3NotePage(itemId: 'm01-text-capture-golden'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('文字'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('note-title-field')))
          .controller!
          .text,
      '给今天留一点空白',
    );
    await expectLater(
      find.byType(V3NotePage),
      matchesGoldenFile('goldens/note_capture_text.png'),
    );

    final body = find.byKey(const ValueKey('note-body-field'));
    await tester.tap(find.byTooltip('快速插入待办'));
    await tester.pump();
    expect(tester.widget<TextField>(body).controller!.text, contains('- [ ] '));
    await tester.tap(find.byTooltip('插入图片'));
    await tester.pump();
    expect(
      tester.widget<TextField>(body).controller!.text,
      contains('![图片]()'),
    );
  });

  testWidgets('new editor hydrates a compact text draft', (tester) async {
    final library = KnowledgeLibraryController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: const MaterialApp(
          home: V3NotePage(initialTitle: '弹窗标题', initialBody: '弹窗正文'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('note-title-field')))
          .controller!
          .text,
      '弹窗标题',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('note-body-field')))
          .controller!
          .text,
      '弹窗正文',
    );
  });

  testWidgets(
    'Knowledge Square detail resolves a Markdown image through exact assets',
    (tester) async {
      final article = V3FeedItem(
        id: 'subscription-image-note',
        title: '带图文章',
        source: V3MaterialSource.knowledgeSquare,
        ownership: V3NoteOwnership.knowledgeSquare,
        createdAt: DateTime.utc(2026, 8, 8),
        rawBody: '![文章配图](images/article.png)',
        publicationId: 'publication-image-1',
        articleId: 'article-image-1',
        articleRevisionId: 'article-revision-image-1',
        subscriptionArticleAssets: <V3SubscriptionArticleAssetRef>[
          V3SubscriptionArticleAssetRef(
            fileKey: 'image-file-1',
            logicalPath: 'images/article.png',
          ),
        ],
      );
      final port = _DetailImageSubscriptionPort(article);
      final library = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        subscriptionPort: port,
      );
      await library.reloadSubscriptions();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: const MaterialApp(
            home: V3FeedItemDetailPage(itemId: 'subscription-image-note'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(port.assetCalls, 1);
      expect(
        find.byKey(
          const ValueKey(
            'subscription-article-image-subscription-image-note-images/article.png',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey(
              'subscription-article-image-subscription-image-note-images/article.png',
            ),
          ),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(find.text('images/article.png'), findsNothing);
    },
  );

  testWidgets(
    'Knowledge Square detail renders an unreferenced revision image as lead media',
    (tester) async {
      final article = V3FeedItem(
        id: 'subscription-lead-image-note',
        title: '后端附件图片文章',
        source: V3MaterialSource.knowledgeSquare,
        ownership: V3NoteOwnership.knowledgeSquare,
        createdAt: DateTime.utc(2026, 8, 8),
        rawBody: '# 文章正文\n\n后端没有在 Markdown 中给出图片占位符。',
        publicationId: 'publication-lead-image-1',
        articleId: 'article-lead-image-1',
        articleRevisionId: 'article-revision-lead-image-1',
        subscriptionArticleAssets: <V3SubscriptionArticleAssetRef>[
          V3SubscriptionArticleAssetRef(
            fileKey: 'lead-image-file-1',
            logicalPath: 'assets/lead-image.webp',
          ),
        ],
      );
      final port = _DetailImageSubscriptionPort(article);
      final library = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        subscriptionPort: port,
      );
      await library.reloadSubscriptions();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: const MaterialApp(
            home: V3FeedItemDetailPage(itemId: 'subscription-lead-image-note'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(port.assetCalls, 1);
      await tester.dragUntilVisible(
        find.byKey(
          const ValueKey(
            'subscription-article-image-subscription-lead-image-note-assets/lead-image.webp',
          ),
        ),
        find.byKey(const ValueKey('detail-external-reader')),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey(
            'subscription-article-image-subscription-lead-image-note-assets/lead-image.webp',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey(
              'subscription-article-image-subscription-lead-image-note-assets/lead-image.webp',
            ),
          ),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(find.text('assets/lead-image.webp'), findsNothing);
    },
  );

  testWidgets('editor is a compact full-screen writing surface', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(375, 667)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(top: 20);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewInsets);

    final library = KnowledgeLibraryController(initialNotes: const []);
    final router = _noteTestRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp.router(
          theme: HuahuoV3Theme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('note-editor-surface'));
    final title = find.byKey(const ValueKey('note-title-field'));
    final titleShell = find.byKey(const ValueKey('note-title-shell'));
    final body = find.byKey(const ValueKey('note-body-field'));
    expect(surface, findsOneWidget);
    expect(title, findsOneWidget);
    expect(body, findsOneWidget);
    expect(
      find.descendant(of: surface, matching: find.byType(V3Card)),
      findsNothing,
    );
    expect(find.byType(V3Card), findsNothing);

    final surfaceRect = tester.getRect(surface);
    final titleRect = tester.getRect(titleShell);
    final bodyRect = tester.getRect(body);
    expect(titleRect.left, surfaceRect.left);
    expect(titleRect.right, surfaceRect.right);
    expect(bodyRect.left, surfaceRect.left);
    expect(bodyRect.right, surfaceRect.right);
    expect((bodyRect.top - titleRect.bottom).abs(), lessThanOrEqualTo(1.5));
    expect((bodyRect.bottom - surfaceRect.bottom).abs(), lessThanOrEqualTo(.5));
    expect(bodyRect.height, greaterThan(400));
    final titleField = tester.widget<TextField>(title);
    expect(titleField.minLines, 1);
    expect(titleField.maxLines, 2);
    expect(titleField.decoration?.filled, isFalse);
    final titleEditable = tester
        .state<EditableTextState>(
          find.descendant(of: title, matching: find.byType(EditableText)),
        )
        .renderEditable;
    final titleLine = titleEditable.localToGlobal(
      titleEditable.getLocalRectForCaret(const TextPosition(offset: 0)).center,
    );
    expect(titleLine.dy, closeTo(titleRect.center.dy, 1));
    expect(
      tester.widget<TextField>(body).textAlignVertical,
      TextAlignVertical.top,
    );
    expect(tester.widget<TextField>(body).decoration?.filled, isFalse);
    expect(find.byKey(const ValueKey('note-save-button')), findsOneWidget);
    expect(find.text('文字'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.byTooltip('更多工具'), findsOneWidget);
    expect(find.byTooltip('快速插入待办'), findsOneWidget);
    expect(find.byTooltip('插入图片'), findsOneWidget);
    expect(find.byTooltip('笔记属性'), findsNothing);

    await tester.tap(body);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(body).focusNode?.hasFocus, isTrue);
    expect(tester.getSize(body).height, greaterThan(120));
    final markdownToolbar = find.byKey(const ValueKey('note-markdown-toolbar'));
    expect(markdownToolbar, findsOneWidget);
    expect(
      tester.getRect(markdownToolbar).bottom,
      lessThanOrEqualTo(667 - 260 + 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('deep link waits for cache restore before hydrating the editor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cache = _DelayedKnowledgeLibraryCache();
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      cache: cache,
    );
    final related = V3FeedItem(
      id: 'cached-related',
      title: '缓存关联笔记',
      source: V3MaterialSource.meeting,
      createdAt: DateTime(2026, 7, 14, 8),
      rawBody: '关联正文',
    );
    final cached = V3FeedItem(
      id: 'cached-note',
      title: '缓存深链笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 14, 9),
      rawBody: '# 恢复后的正文',
      topics: const ['缓存标签'],
      contentLineId: 'line-cache',
      contentLineName: '缓存内容线',
      folderId: 'folder-cache',
      folderName: '缓存文件夹',
      linkedMaterials: [
        V3LinkedMaterialRef(
          id: related.id,
          source: related.source,
          title: related.title,
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: '/edit',
      routes: [
        GoRoute(
          path: '/edit',
          builder: (context, state) => const V3NotePage(itemId: 'cached-note'),
        ),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) =>
              Text('detail:${state.pathParameters['itemId']}'),
        ),
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const Text('思想图谱'),
        ),
      ],
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
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    expect(find.text('正在加载笔记'), findsOneWidget);
    expect(find.text('笔记不存在'), findsNothing);

    cache.complete([cached, related]);
    await tester.pumpAndSettle();

    expect(find.text('文字'), findsOneWidget);
    expect(find.text('笔记不存在'), findsNothing);
    final fields = find.byType(TextField);
    expect(
      tester.widget<TextField>(fields.at(0)).controller!.text,
      cached.title,
    );
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      cached.rawBody,
    );
    expect(find.text('缓存标签'), findsNothing);
    expect(find.text('缓存标签'), findsNothing);
    expect(find.byTooltip('笔记属性'), findsNothing);

    await tester.enterText(fields.at(1), '# 已安全编辑缓存正文');
    await tester.tap(find.byKey(const ValueKey('note-save-button')));
    await tester.pumpAndSettle();
    await library.flushPersistence();

    expect(library.noteForId(cached.id)?.rawBody, '# 已安全编辑缓存正文');
    expect(library.noteForId(cached.id)?.topics, cached.topics);
    expect(library.noteForId(cached.id)?.contentLineName, '缓存内容线');
    expect(library.noteForId(cached.id)?.folderName, isNull);
    expect(library.depositRecordFor(cached.id)?.folderId, isNull);
    expect(library.noteForId(cached.id)?.linkedMaterials.single.id, related.id);
    expect(
      cache.saved.singleWhere((note) => note.id == cached.id).rawBody,
      '# 已安全编辑缓存正文',
    );
    expect(find.text('detail:${cached.id}'), findsOneWidget);
  });

  testWidgets('lightweight Markdown renders the complete editor subset', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: V3AssistantReplyMarkdown(
              source:
                  '## 账号定位\n'
                  '### 内容方向\n'
                  '> 关键判断\n'
                  '1. 第一项\n'
                  '- 普通列表\n'
                  '- [ ] 待处理\n'
                  '- [x] 已完成\n'
                  '*斜体*、**粗体**、~~删除线~~、`行内代码`、<u>下划线</u>、'
                  '<span data-hh-fg="#1769AA">蓝色文字</span>与'
                  '<span data-hh-bg="#FFF0A8">高亮文字</span>，'
                  '以及[参考链接](https://example.com)\n'
                  '<div align="center">\n'
                  '居中内容\n'
                  '</div>\n'
                  '![图片](app-private-canvas-image://missing.png?width=0.5)\n'
                  '---\n'
                  '| 阶段 | 负责人 |\n'
                  '| --- | --- |\n'
                  '| 调研 | **小周** |\n'
                  '名称\t状态\n'
                  '方案 A\t已完成\n'
                  '```\n'
                  'final answer = 42;\n'
                  '```',
            ),
          ),
        ),
      ),
    );

    expect(find.text('账号定位'), findsOneWidget);
    expect(find.text('内容方向'), findsOneWidget);
    expect(find.text('## 账号定位'), findsNothing);
    expect(find.text('### 内容方向'), findsNothing);
    for (final value in ['关键判断', '第一项', '普通列表', '待处理']) {
      expect(find.text(value), findsOneWidget);
    }
    expect(find.text('已完成'), findsNWidgets(2));
    expect(find.textContaining('参考链接'), findsOneWidget);
    expect(find.textContaining('删除线'), findsOneWidget);
    expect(find.textContaining('下划线'), findsOneWidget);
    expect(find.textContaining('蓝色文字'), findsOneWidget);
    expect(find.textContaining('高亮文字'), findsOneWidget);
    expect(find.textContaining('居中内容'), findsOneWidget);
    expect(find.textContaining('行内代码'), findsOneWidget);
    expect(find.textContaining('app-private-canvas-image://'), findsNothing);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.byType(Table), findsNWidgets(2));
    expect(find.text('负责人'), findsOneWidget);
    expect(find.text('方案 A'), findsOneWidget);
    expect(find.textContaining('final answer = 42;'), findsOneWidget);
    expect(find.textContaining('~~'), findsNothing);
    expect(find.textContaining('```'), findsNothing);
  });

  testWidgets('lightweight Markdown recovers flattened AI reply blocks', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: V3AssistantReplyMarkdown(
            source:
                '我已经阅读了你的 Workspace 资产： '
                '## 资产概览 '
                '### 定位画像： - 业务方向：内容生产 '
                '1. 明确目标 2. 记录基线 '
                '> 关键判断 **先验证价值** `关键指标`',
          ),
        ),
      ),
    );

    for (final value in <String>[
      '资产概览',
      '定位画像：',
      '业务方向：内容生产',
      '明确目标',
      '记录基线',
      '关键判断',
      '先验证价值',
      '关键指标',
    ]) {
      expect(find.textContaining(value), findsOneWidget);
    }
    expect(find.textContaining('## 资产概览'), findsNothing);
    expect(find.textContaining('### 定位画像'), findsNothing);
  });

  testWidgets(
    'lightweight Markdown repairs opted-in AI headings without mutating source',
    (tester) async {
      const source =
          '##### 五级标题\n'
          '###### 六级标题\n'
          '###无空格标题\n'
          '###\n\n'
          '1. 有编号内容\n'
          '```\n'
          '### 原样代码\n'
          '```';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: V3AssistantReplyMarkdown(source: source)),
        ),
      );

      for (final text in <String>['五级标题', '六级标题', '无空格标题', '1. 有编号内容']) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.text('##### 五级标题'), findsNothing);
      expect(find.text('###### 六级标题'), findsNothing);
      expect(find.text('###无空格标题'), findsNothing);
      expect(find.text('###'), findsNothing);
      expect(find.text('### 原样代码'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('1. 有编号内容')).style?.fontWeight,
        FontWeight.w700,
      );
      expect(
        tester
            .widget<V3AssistantReplyMarkdown>(
              find.byType(V3AssistantReplyMarkdown),
            )
            .source,
        source,
      );
    },
  );

  testWidgets('lightweight Markdown recovers streamed and omitted tables', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: V3AssistantReplyMarkdown(
              source:
                  '| 要素 | 建议 |\n'
                  '|---|---||机位|手持，模拟后座视角|\n'
                  '| 光线 | 自然光，保留真实感 |\n\n'
                  '| 角色 | 动作 |\n'
                  '| 主讲人 | 保持自然表达 |\n'
                  '| 观众 | 专注倾听 |',
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Table), findsNWidgets(2));
    for (final value in <String>['要素', '机位', '自然光，保留真实感', '主讲人', '专注倾听']) {
      expect(find.text(value), findsOneWidget);
    }
  });

  testWidgets('lightweight Markdown recovers stacked streamed table rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: V3AssistantReplyMarkdown(
              source:
                  '| 类别\n'
                  '| 识别 | 新增 | 合并更新 | 未写入 |\n'
                  '| --- | ---: | ---: | ---: | ---: |\n'
                  '| 经历\n'
                  '| 0 | 0 | 0 | 0 |\n'
                  '| 知识\n'
                  '| 3 | 3 | 0 | 0 |',
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Table), findsOneWidget);
    for (final value in <String>['类别', '识别', '经历', '知识']) {
      expect(find.text(value), findsOneWidget);
    }
    expect(find.textContaining('| 经历'), findsNothing);
  });

  testWidgets('detail section deep link scrolls its exact heading into view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final longBody = <String>[
      for (var index = 0; index < 36; index++) '第 $index 段用于验证滚动定位。',
      '# 目标章节',
      '这是目标章节正文。',
    ].join('\n\n');
    final note = V3FeedItem(
      id: 'section-scroll-note',
      title: '章节定位笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 18),
      rawBody: longBody,
    );
    final library = KnowledgeLibraryController(initialNotes: [note]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: const MaterialApp(
          home: V3FeedItemDetailPage(
            itemId: 'section-scroll-note',
            initialStage: V3ContentStage.raw,
            initialSectionId: 'raw-目标章节',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final target = find.text('目标章节');
    expect(target, findsOneWidget);
    final targetTop = tester.getTopLeft(target).dy;
    expect(targetTop, greaterThanOrEqualTo(0));
    expect(targetTop, lessThan(760));
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor omits deposit controls and preserves an assignment', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = KnowledgeLibraryController(initialNotes: const []);
    final folder = library.createDepositFolder('已有沉淀位置')!;
    final note = library.createManualNote(title: '已沉淀笔记', rawBody: '正文');
    library.depositContent(note.id, folderId: folder.id);
    final router = GoRouter(
      initialLocation: '/edit',
      routes: [
        GoRoute(
          path: '/edit',
          builder: (context, state) => V3NotePage(itemId: note.id),
        ),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) =>
              Text('detail:${state.pathParameters['itemId']}'),
        ),
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const Text('思想图谱'),
        ),
      ],
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
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('文件夹'), findsNothing);
    expect(find.byTooltip('沉淀到...'), findsNothing);
    await tester.enterText(find.byType(TextField).at(1), '编辑后仍在原沉淀位置');
    await tester.tap(find.byKey(const ValueKey('note-save-button')));
    await tester.pumpAndSettle();

    expect(library.depositRecordFor(note.id)?.folderId, folder.id);
    expect(find.text('detail:${note.id}'), findsOneWidget);
  });

  testWidgets('toolbar supports heading history and structured note metadata', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(800, 1200)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(bottom: 34)
      ..viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final related = V3FeedItem(
      id: 'meeting-related',
      title: '客户启动会议',
      source: V3MaterialSource.meeting,
      createdAt: DateTime(2026, 7, 14),
      rawBody: '确认试点范围',
      contentLineId: 'line-client',
      contentLineName: '客户经营',
      folderId: 'folder-case',
      folderName: '客户案例',
    );
    final library = KnowledgeLibraryController(initialNotes: [related]);
    final router = GoRouter(
      initialLocation: '/new',
      routes: [
        GoRoute(path: '/new', builder: (context, state) => const V3NotePage()),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) =>
              Text('detail:${state.pathParameters['itemId']}'),
        ),
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const Text('思想图谱'),
        ),
      ],
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
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final bodyFinder = find.byType(TextField).at(1);
    await tester.tap(find.byTooltip('更多工具'));
    await tester.pumpAndSettle();
    expect(find.text('文字工具'), findsOneWidget);
    final markdownTools = find.byKey(
      const ValueKey('note-markdown-tools-panel'),
    );
    expect(
      tester.getRect(markdownTools).bottom,
      lessThanOrEqualTo(
        MediaQuery.sizeOf(tester.element(markdownTools)).height - 34,
      ),
    );
    await tester.tap(find.byTooltip('二级标题'));
    await tester.pump();
    expect(tester.widget<TextField>(bodyFinder).controller!.text, '## ');
    await tester.tap(find.byTooltip('撤销'));
    await tester.pump();
    expect(tester.widget<TextField>(bodyFinder).controller!.text, isEmpty);
    await tester.tap(find.byTooltip('重做'));
    await tester.pump();
    expect(tester.widget<TextField>(bodyFinder).controller!.text, '## ');

    final bodyController = tester.widget<TextField>(bodyFinder).controller!;
    final toolbarCases = <String, String>{
      '一级标题': '# 内容',
      '二级标题': '## 内容',
      '三级标题': '### 内容',
      '加粗': '**内容**',
      '斜体': '*内容*',
      '删除线': '~~内容~~',
      '行内代码': '`内容`',
      '引用': '> 内容',
      '有序列表': '1. 内容',
      '无序列表': '- 内容',
      '待办事项': '- [ ] 内容',
      '链接': '[内容](https://)',
      '代码块': '```\n内容\n```',
      '分隔线': '内容\n\n---',
    };
    for (final entry in toolbarCases.entries) {
      bodyController.value = const TextEditingValue(
        text: '内容',
        selection: TextSelection(baseOffset: 0, extentOffset: 2),
      );
      await tester.pump();
      final action = find.byTooltip(entry.key);
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pump();
      expect(bodyController.text, entry.value, reason: entry.key);
    }
    bodyController.value = const TextEditingValue(
      text: '内容',
      selection: TextSelection(baseOffset: 0, extentOffset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    final boldAction = find.byTooltip('加粗');
    await tester.ensureVisible(boldAction);
    await tester.tap(boldAction);
    await tester.pump();
    expect(bodyController.text, '**内容**');
    expect(bodyController.value.composing, TextRange.empty);
    expect(tester.widget<TextField>(bodyFinder).focusNode?.hasFocus, isTrue);
    final undoAction = find.byTooltip('撤销');
    await tester.ensureVisible(undoAction);
    await tester.tap(undoAction);
    await tester.pump();
    expect(bodyController.text, '内容');

    bodyController.value = const TextEditingValue(
      text: '尾部',
      selection: TextSelection.collapsed(offset: -1),
    );
    final italicAction = find.byTooltip('斜体');
    await tester.ensureVisible(italicAction);
    await tester.tap(italicAction);
    await tester.pump();
    expect(bodyController.text, '尾部**');
    await tester.ensureVisible(undoAction);
    await tester.tap(undoAction);
    await tester.pump();
    expect(bodyController.text, '尾部');
    await tester.enterText(bodyFinder, '# 结构化复盘\n正文');
    await tester.tapAt(const Offset(12, 120));
    await tester.pumpAndSettle();

    expect(find.byTooltip('笔记属性'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('note-save-button')));
    await tester.pumpAndSettle();

    final saved = library.notes.firstWhere(
      (note) => note.id != related.id && note.title == '结构化复盘',
    );
    expect(saved.topics, isEmpty);
    expect(saved.contentLineName, isNull);
    expect(saved.folderName, isNull);
    expect(library.depositRecordFor(saved.id)?.contentId, saved.id);
    expect(saved.linkedMaterials, isEmpty);
    expect(find.text('detail:${saved.id}'), findsOneWidget);
  });

  testWidgets('save waits for cache and ignores duplicate taps', (
    tester,
  ) async {
    final cache = _ControlledKnowledgeLibraryCache();
    final gate = Completer<void>();
    cache.gate = gate;
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      cache: cache,
    );
    final router = _noteTestRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '只保存一次');
    final save = find.byKey(const ValueKey('note-save-button'));
    await tester.tap(save);
    await tester.tap(save);
    await tester.pump();

    expect(find.text('文字整理中...'), findsOneWidget);
    expect(find.byKey(const ValueKey('note-save-button')), findsNothing);
    expect(cache.saveCalls, 1);
    expect(
      library.notes.where((note) => note.rawBody == '只保存一次'),
      hasLength(1),
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('detail:manual-'), findsOneWidget);
  });

  testWidgets('cache failure keeps editor content available for retry', (
    tester,
  ) async {
    final cache = _ControlledKnowledgeLibraryCache()..failSaves = true;
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      cache: cache,
    );
    final router = _noteTestRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    final body = find.byType(TextField).at(1);
    await tester.enterText(body, '保存失败也不能丢失');
    await tester.tap(find.byKey(const ValueKey('note-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('保存失败，内容仍保留，请重试'), findsOneWidget);
    expect(tester.widget<TextField>(body).controller?.text, '保存失败也不能丢失');
    expect(find.text('完成'), findsOneWidget);
    expect(cache.saveCalls, 1);

    final pending = library.notes.singleWhere(
      (note) => note.rawBody == '保存失败也不能丢失',
    );
    cache.failSaves = false;
    await tester.tap(find.byKey(const ValueKey('note-save-button')));
    await tester.pumpAndSettle();
    expect(cache.saveCalls, 2);
    expect(library.noteForId(pending.id)?.localRevision, pending.localRevision);
    expect(find.text('detail:${pending.id}'), findsOneWidget);
  });

  testWidgets(
    'creates a shared note with a derived title in the pure Markdown editor',
    (tester) async {
      final library = KnowledgeLibraryController();
      final profile = ProfileHubController(referenceDay: DateTime(2026, 7, 13));
      final router = GoRouter(
        initialLocation: '/new',
        routes: [
          GoRoute(
            path: '/new',
            builder: (context, state) => const V3NotePage(),
          ),
          GoRoute(
            path: '/v3/feed',
            builder: (context, state) => const Scaffold(body: Text('思想图谱')),
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (context, state) =>
                Text('detail:${state.pathParameters['itemId']}'),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            profileHubControllerProvider.overrideWith((ref) => profile),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      final body = tester.widget<TextField>(find.byType(TextField).at(1));
      await tester.tap(find.byTooltip('更多工具'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('一级标题'));
      expect(body.controller!.text, '# ');
      await tester.tapAt(const Offset(12, 120));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).at(1),
        '# 试点复盘\n\n**先验证一线价值**\n- 记录基线\n- 明确负责人',
      );
      expect(find.text('预览'), findsNothing);
      expect(find.byType(V3AssistantReplyMarkdown), findsNothing);

      await tester.tap(find.byKey(const ValueKey('note-save-button')));
      await tester.pumpAndSettle();

      final saved = library.mineNotes.firstWhere(
        (item) => item.rawBody.contains('先验证一线价值'),
      );
      expect(saved.title, '试点复盘');
      expect(saved.rawBody, contains('**先验证一线价值**'));
      expect(
        profile.activities.any((activity) => activity.feedItemId == saved.id),
        isTrue,
      );
      expect(find.text('detail:${saved.id}'), findsOneWidget);
    },
  );

  testWidgets('detail deletion confirms before clearing the shared note', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = KnowledgeLibraryController();
    final profile = ProfileHubController(referenceDay: DateTime(2026, 7, 13));
    final note = library.createManualNote(
      title: '待删除笔记',
      rawBody: '删除后不应留在记忆库里。',
      createdAt: DateTime(2026, 7, 13, 10),
    );
    profile.recordActivity(
      V3ProfileActivity(
        id: 'delete-detail-activity',
        occurredAt: note.createdAt,
        type: V3ProfileActivityType.raw,
        title: note.title,
        feedItemId: note.id,
      ),
    );
    final router = GoRouter(
      initialLocation: '/v3/feed',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (context, state) => V3FeedItemDetailPage(itemId: note.id),
        ),
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/detail'),
              child: const Text('思想图谱'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith((ref) => profile),
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
    await tester.tap(find.text('思想图谱'));
    await tester.pumpAndSettle();

    // Personal content enters the total deposited library exactly once.
    expect(library.depositRecordFor(note.id)?.contentId, note.id);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-more-delete')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('删除笔记'));
    await tester.pumpAndSettle();
    expect(find.text('删除笔记'), findsOneWidget);
    expect(find.byType(V3GlassDialog), findsOneWidget);
    expect(find.text('确定删除“${note.title}”？'), findsOneWidget);
    expect(find.textContaining('不提供恢复入口'), findsNothing);
    expect(library.noteForId(note.id), isNotNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(library.noteForId(note.id), isNotNull);
    expect(
      profile.activities.where((activity) => activity.feedItemId == note.id),
      isNotEmpty,
    );
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(library.noteForId(note.id), isNull);
    expect(
      profile.activities.where((activity) => activity.feedItemId == note.id),
      isEmpty,
    );
    expect(find.text('思想图谱'), findsOneWidget);
  });

  testWidgets('dirty back requires explicit discard', (tester) async {
    final library = KnowledgeLibraryController();
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/new'),
                child: const Text('打开笔记'),
              ),
            ),
          ),
        ),
        GoRoute(path: '/new', builder: (context, state) => const V3NotePage()),
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const Text('思想图谱'),
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
    await tester.tap(find.text('打开笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '还没有保存的正文');

    await tester.tap(find.byTooltip('收起文字编辑'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('文字'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      '还没有保存的正文',
    );

    await tester.tap(find.byTooltip('收起文字编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();

    expect(find.text('打开笔记'), findsOneWidget);
    expect(library.notes.where((note) => note.rawBody == '还没有保存的正文'), isEmpty);
  });

  testWidgets('dirty note foreground ingress requires explicit discard', (
    tester,
  ) async {
    final library = KnowledgeLibraryController();
    final coordinator = ForegroundIngressCoordinator();
    final router = GoRouter(
      initialLocation: '/new',
      routes: [
        GoRoute(path: '/new', builder: (context, state) => const V3NotePage()),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) =>
              Text('detail:${state.pathParameters['itemId']}'),
        ),
        GoRoute(path: '/v3', builder: (context, state) => const Text('思想图谱')),
      ],
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
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => ForegroundIngressScope(
            coordinator: coordinator,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).at(1), '入口前未保存的内容');

    final cancelled = coordinator.requestNavigation();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await cancelled, isFalse);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      '入口前未保存的内容',
    );

    final allowed = coordinator.requestNavigation();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('放弃修改并查看'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await allowed, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      isEmpty,
    );
  });

  testWidgets('subscribed detail keeps its reader and adds Agent assistance', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final original = V3FeedItem(
      id: 'subscribed-detail-note',
      title: '订阅原文',
      source: V3MaterialSource.subscription,
      ownership: V3NoteOwnership.subscribed,
      createdAt: DateTime(2026, 7, 20),
      rawBody: '作者原始正文',
      summaryBody: '作者纲要',
    );
    final library = KnowledgeLibraryController(initialNotes: [original]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: const MaterialApp(
          home: V3FeedItemDetailPage(itemId: 'subscribed-detail-note'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('订阅原文'), findsOneWidget);
    expect(find.text('作者原始正文'), findsOneWidget);
    expect(find.text('作者纲要'), findsNothing);
    for (final stage in ['原始', '纲要', '深度洞察']) {
      expect(find.text(stage), findsNothing);
    }
    expect(
      find.byKey(const ValueKey('detail-external-read-content')),
      findsOneWidget,
    );
    expect(find.text('沉淀到我的资产'), findsNothing);
    expect(find.byType(V3ChatEntry), findsNothing);
    expect(find.byKey(const ValueKey('detail-chat-entry')), findsNothing);
    expect(find.text('聊一聊'), findsNothing);
    expect(find.text('进入创作空间'), findsNothing);
    expect(
      find.byKey(const ValueKey('external-article-agent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('detail-floating-action-Agent 自由创作')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'owned detail keeps labels read-only and renders unframed stage bodies',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final note = V3FeedItem(
        id: 'fixed-label-detail',
        title: '多标签笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 7, 21),
        rawBody: '笔记原始内容\n\n正文',
        summaryBody: '纲要\n\n摘要正文',
        remoteNoteId: 'remote-fixed-label-detail',
        rawPartRevisionId: 'raw-fixed-label-detail-1',
        outlinePartRevisionId: 'outline-fixed-label-detail-1',
        germinationPartRevisionId: 'germination-fixed-label-detail-1',
        sproutStatus: V3SproutTaskStatus.succeeded,
        sproutReport: V3SproutReport(
          id: 'fixed-label-detail-sprout',
          noteId: 'fixed-label-detail',
          title: '点火报告',
          markdown: '点火\n\n点火正文',
          generatedAt: DateTime(2026, 7, 21, 12),
        ),
      );
      final library = KnowledgeLibraryController(initialNotes: [note]);
      final historyRepository = ChatThreadAliasRepository(
        dao: UserMetadataDao(AppDatabase()),
        preferencesDao: AppPreferencesDao(AppDatabase()),
        userScope: 'detail-note-history-user',
      );
      historyRepository.saveThreadAssetReference(
        scene: ChatScene.feedAi,
        threadId: 'note-history-thread',
        assetId: note.id,
      );
      final historyApi = _NoteHistoryChatApi();
      final historyController = ChatController(
        api: historyApi,
        scene: ChatScene.feedAi,
        aliasRepository: historyRepository,
        initialAgentProfileId: standardCreationChatAgentProfileId,
      );
      String? openedThreadId;
      Uri? openedChatUri;
      Uri? openedCanvasUri;
      Object? openedCanvasExtra;
      var openedChatCount = 0;
      final router = GoRouter(
        initialLocation: '/detail',
        routes: [
          GoRoute(
            path: '/detail',
            builder: (context, state) => V3FeedItemDetailPage(itemId: note.id),
          ),
          GoRoute(
            path: '/v3/feed/note/:itemId',
            builder: (context, state) => const Text('edit'),
          ),
          GoRoute(
            path: '/v3/feed',
            builder: (context, state) => const Text('feed'),
          ),
          GoRoute(
            path: '/v3/workbench/canvas',
            builder: (context, state) {
              openedCanvasUri = state.uri;
              openedCanvasExtra = state.extra;
              return const Text('创作输入');
            },
          ),
          GoRoute(
            path: '/v3/feed/chat',
            builder: (context, state) {
              openedChatCount += 1;
              openedChatUri = state.uri;
              openedThreadId = state.uri.queryParameters['threadId'];
              return Text(
                'chat:'
                '${state.uri.queryParameters['itemId'] ?? ''}:'
                '${state.uri.queryParameters['skill'] ?? ''}:'
                '${state.uri.queryParameters['materialIds'] ?? ''}:'
                '${state.uri.queryParameters['agentProfileId'] ?? ''}:'
                '${state.uri.queryParameters['prompt'] ?? ''}:'
                '${state.uri.queryParameters['autoSend'] ?? ''}',
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            chatThreadAliasRepositoryProvider.overrideWithValue(
              historyRepository,
            ),
            feedAiChatControllerProvider.overrideWith(
              (ref) => historyController,
            ),
            chatRepositoryProvider.overrideWithValue(historyApi),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('资料详情'), findsOneWidget);
      expect(find.text('笔记 · 7月21日 · 经历 · 创作'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('detail-asset-label-strip')),
        findsNothing,
      );
      expect(find.text('笔记原始内容'), findsNothing);
      expect(find.text('正文'), findsOneWidget);
      final rawContent = find.byKey(const ValueKey('detail-raw-content'));
      expect(rawContent, findsOneWidget);
      expect(
        find.ancestor(of: rawContent, matching: find.byType(V3Card)),
        findsNothing,
      );
      expect(find.byType(V3ChatEntry), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-chat-entry')), findsOneWidget);
      final assistantAction = find.byKey(
        const ValueKey('detail-floating-action-Agent 辅助创作'),
      );
      final freeCreationAction = find.byKey(
        const ValueKey('detail-floating-action-Agent 自由创作'),
      );
      expect(assistantAction, findsOneWidget);
      expect(freeCreationAction, findsOneWidget);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('detail-chat-entry')))
            .overlaps(tester.getRect(assistantAction)),
        isFalse,
      );
      expect(
        tester
            .getRect(assistantAction)
            .overlaps(tester.getRect(freeCreationAction)),
        isFalse,
      );

      await tester.tap(assistantAction);
      await tester.pumpAndSettle();
      expect(find.text('选择 Agent'), findsOneWidget);
      expect(find.text('个人 IP 设计 Agent'), findsOneWidget);
      expect(find.text('获客营销选题 Agent'), findsOneWidget);
      expect(find.text('视觉设计 Agent'), findsNothing);
      await tester.tap(find.text('获客营销选题 Agent'));
      await tester.pumpAndSettle();
      expect(find.text('选择创作方式'), findsNothing);
      expect(find.text('直接生成'), findsNothing);
      expect(
        find.text(
          'chat::lead:fixed-label-detail::'
          '现在开始做获客营销选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。:1',
        ),
        findsOneWidget,
      );
      expect(
        openedChatUri?.queryParameters['entry'],
        'agent-assisted-creation',
      );
      expect(openedChatUri?.queryParameters['materialIds'], note.id);
      expect(openedChatUri?.queryParameters['analyzeAssets'], isNull);
      expect(openedChatUri?.queryParameters['autoSend'], '1');
      expect(
        openedChatUri?.queryParameters['prompt'],
        '现在开始做获客营销选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(assistantAction);
      await tester.pumpAndSettle();
      await tester.tap(find.text('个人 IP 设计 Agent'));
      await tester.pumpAndSettle();
      expect(openedChatUri?.queryParameters['skill'], 'persona');
      expect(openedChatUri?.queryParameters['materialIds'], note.id);
      expect(openedChatUri?.queryParameters['analyzeAssets'], isNull);
      expect(openedChatUri?.queryParameters['autoSend'], '1');
      expect(
        openedChatUri?.queryParameters['prompt'],
        '现在开始做选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('detail-chat-entry')));
      await tester.pumpAndSettle();
      expect(find.text('猜你想问'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('detail-chat-prompt-input')),
        findsOneWidget,
      );
      await tester.tap(find.text('这条笔记的核心判断是什么？'));
      await tester.pumpAndSettle();
      expect(find.text('这条笔记的核心判断是什么？'), findsOneWidget);
      expect(find.text('重新发送'), findsOneWidget);
      expect(find.textContaining('chat:'), findsNothing);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('detail-chat-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(find.text('历史记录'), findsOneWidget);
      expect(find.text('最近对话'), findsOneWidget);
      expect(find.text('当前笔记历史'), findsOneWidget);
      expect(find.text('猜你想问'), findsNothing);
      expect(find.textContaining('chat:'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('detail-chat-history-back')));
      await tester.pumpAndSettle();
      expect(find.text('猜你想问'), findsOneWidget);
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('detail-chat-history-note-history-thread')),
      );
      await tester.pumpAndSettle();
      expect(openedThreadId, 'note-history-thread');
      expect(
        find.text('chat:fixed-label-detail:::self_media_creation_standard::'),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.text('纲要'));
      await tester.pumpAndSettle();
      final summaryContent = find.byKey(
        const ValueKey('detail-summary-content'),
      );
      expect(summaryContent, findsOneWidget);
      expect(
        find.descendant(of: summaryContent, matching: find.text('纲要')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: summaryContent, matching: find.text('摘要正文')),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: summaryContent, matching: find.byType(V3Card)),
        findsNothing,
      );

      await tester.tap(find.text('深度洞察').first);
      await tester.pumpAndSettle();
      expect(find.text('点火正文'), findsOneWidget);
      final sproutContent = find.byKey(const ValueKey('detail-sprout-content'));
      expect(sproutContent, findsOneWidget);
      expect(
        find.ancestor(of: sproutContent, matching: find.byType(V3Card)),
        findsNothing,
      );

      final chatCountBeforeFreeCreation = openedChatCount;
      await tester.tap(freeCreationAction);
      await tester.pumpAndSettle();
      expect(find.text('创作输入'), findsOneWidget);
      expect(find.text('选择创作方式'), findsNothing);
      expect(openedCanvasUri?.path, '/v3/workbench/canvas');
      expect(openedCanvasUri?.queryParameters['importAssetId'], note.id);
      final sproutSeed = openedCanvasExtra! as AssetCanvasSeed;
      expect(sproutSeed.stage, AssetCanvasSourceStage.sprout);
      expect(sproutSeed.sourceMarkdown, note.sproutReport!.markdown);
      expect(sproutSeed.partRevisionId, note.germinationPartRevisionId);
      expect(
        sproutSeed.sourceHash,
        AssetCanvasSeed.hashSourceMarkdown(note.sproutReport!.markdown),
      );
      expect(sproutSeed.linkedReference.id, note.id);
      expect(
        sproutSeed.initialSourceMode,
        AssetCanvasInitialSourceMode.generateTranscript,
      );
      expect(openedChatCount, chatCountBeforeFreeCreation);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('多标签笔记'), findsOneWidget);

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('detail-asset-labels-action')),
        findsNothing,
      );
      expect(find.text('资产分类'), findsNothing);
    },
  );

  testWidgets('free creation locks the exact visible asset stage snapshot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = V3FeedItem(
      id: 'three-stage-free-creation',
      title: '三阶段资料',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 9, 4),
      rawBody: '# 原始正文\n\n原始阶段内容',
      summaryBody: '# 纲要正文\n\n纲要阶段内容',
      remoteNoteId: 'remote-three-stage-free-creation',
      rawPartRevisionId: 'raw-three-stage-1',
      outlinePartRevisionId: 'outline-three-stage-1',
      germinationPartRevisionId: 'germination-three-stage-1',
      sproutStatus: V3SproutTaskStatus.succeeded,
      sproutReport: V3SproutReport(
        id: 'three-stage-sprout',
        noteId: 'three-stage-free-creation',
        title: '点火结果',
        markdown: '# 点火正文\n\n点火阶段内容',
        generatedAt: DateTime(2026, 9, 4, 12),
      ),
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    AssetCanvasSeed? openedSeed;
    final router = GoRouter(
      initialLocation: '/detail',
      routes: <RouteBase>[
        GoRoute(
          path: '/detail',
          builder: (context, state) => V3FeedItemDetailPage(itemId: note.id),
        ),
        GoRoute(
          path: '/v3/workbench/canvas',
          builder: (context, state) {
            openedSeed = state.extra! as AssetCanvasSeed;
            return const Text('创作输入');
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final freeCreation = find.byKey(
      const ValueKey<String>('detail-floating-action-Agent 自由创作'),
    );
    await tester.tap(freeCreation);
    await tester.pumpAndSettle();
    expect(find.text('创作输入'), findsOneWidget);
    expect(find.text('选择创作方式'), findsNothing);
    _expectAssetCanvasSeed(
      openedSeed!,
      item: note,
      stage: AssetCanvasSourceStage.raw,
      markdown: note.rawBody,
      partRevisionId: note.rawPartRevisionId!,
      sourceMode: AssetCanvasInitialSourceMode.generateTranscript,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    openedSeed = null;

    await tester.tap(find.text('纲要').first);
    await tester.pumpAndSettle();
    await tester.tap(freeCreation);
    await tester.pumpAndSettle();
    _expectAssetCanvasSeed(
      openedSeed!,
      item: note,
      stage: AssetCanvasSourceStage.outline,
      markdown: note.summaryBody!,
      partRevisionId: note.outlinePartRevisionId!,
      sourceMode: AssetCanvasInitialSourceMode.generateTranscript,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    openedSeed = null;

    await tester.tap(find.text('深度洞察').first);
    await tester.pumpAndSettle();
    await tester.tap(freeCreation);
    await tester.pumpAndSettle();
    _expectAssetCanvasSeed(
      openedSeed!,
      item: note,
      stage: AssetCanvasSourceStage.sprout,
      markdown: note.sproutReport!.markdown,
      partRevisionId: note.germinationPartRevisionId!,
      sourceMode: AssetCanvasInitialSourceMode.generateTranscript,
    );
    expect(
      AssetCanvasSeed.tryFromItem(
        item: note.copyWith(clearOutlinePartRevisionId: true),
        stage: V3ContentStage.summary,
      ),
      isNull,
    );
  });

  testWidgets('free creation disables only the invalid selected stage', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = V3FeedItem(
      id: 'empty-outline-free-creation',
      title: '只有原始正文的资料',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 9, 4),
      rawBody: '这段原始正文有效，但不能替代用户选中的空纲要。',
      summaryBody: '   ',
      remoteNoteId: 'remote-empty-outline-free-creation',
      rawPartRevisionId: 'raw-empty-outline-free-creation-1',
      outlinePartRevisionId: 'outline-empty-outline-free-creation-1',
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    var canvasBuildCount = 0;
    final router = GoRouter(
      initialLocation: '/detail',
      routes: <RouteBase>[
        GoRoute(
          path: '/detail',
          builder: (context, state) => V3FeedItemDetailPage(itemId: note.id),
        ),
        GoRoute(
          path: '/v3/workbench/canvas',
          builder: (context, state) {
            canvasBuildCount += 1;
            return const Text('不应打开创作空间');
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('纲要').first);
    await tester.pumpAndSettle();
    final freeCreation = find.byKey(
      const ValueKey<String>('detail-floating-action-Agent 自由创作'),
    );
    final actionInkWell = find.descendant(
      of: freeCreation,
      matching: find.byType(InkWell),
    );
    final actionIcon = find.descendant(
      of: freeCreation,
      matching: find.byType(Icon),
    );
    final actionSemantics = find.descendant(
      of: freeCreation,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Agent 自由创作',
      ),
    );
    final disabledIconColor = tester.widget<Icon>(actionIcon).color;
    expect(tester.widget<InkWell>(actionInkWell).onTap, isNull);
    expect(
      tester.getSemantics(actionSemantics),
      matchesSemantics(
        label: 'Agent 自由创作',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );

    await tester.tap(freeCreation);
    await tester.pump();
    expect(find.text('只有原始正文的资料'), findsOneWidget);
    expect(canvasBuildCount, 0);
    expect(find.text('当前纲要内容尚未准备完成'), findsNothing);

    await tester.tap(find.text('原始').first);
    await tester.pumpAndSettle();
    expect(tester.widget<InkWell>(actionInkWell).onTap, isNotNull);
    expect(tester.widget<Icon>(actionIcon).color, isNot(disabledIconColor));
    expect(
      tester.getSemantics(actionSemantics),
      matchesSemantics(
        label: 'Agent 自由创作',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(freeCreation);
    await tester.pumpAndSettle();
    expect(find.text('不应打开创作空间'), findsOneWidget);
    expect(canvasBuildCount, 1);
  });
}

void _expectAssetCanvasSeed(
  AssetCanvasSeed seed, {
  required V3FeedItem item,
  required AssetCanvasSourceStage stage,
  required String markdown,
  required String partRevisionId,
  required AssetCanvasInitialSourceMode sourceMode,
}) {
  expect(seed.isValid, isTrue);
  expect(seed.assetId, item.id);
  expect(seed.title, item.title);
  expect(seed.stage, stage);
  expect(seed.sourceMarkdown, markdown);
  expect(seed.partRevisionId, partRevisionId);
  expect(seed.sourceHash, AssetCanvasSeed.hashSourceMarkdown(markdown));
  expect(seed.linkedReference.id, item.id);
  expect(seed.linkedReference.source, item.source);
  expect(seed.linkedReference.title, item.title);
  expect(seed.initialSourceMode, sourceMode);
}

final class _DelayedKnowledgeLibraryCache implements KnowledgeLibraryCache {
  final Completer<List<V3FeedItem>?> _load = Completer<List<V3FeedItem>?>();
  List<V3FeedItem> saved = const [];

  void complete(List<V3FeedItem> notes) => _load.complete(notes);

  @override
  Future<List<V3FeedItem>?> load() => _load.future;

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    saved = List<V3FeedItem>.of(notes);
  }
}

final class _ControlledKnowledgeLibraryCache implements KnowledgeLibraryCache {
  Completer<void>? gate;
  bool failSaves = false;
  int saveCalls = 0;

  @override
  Future<List<V3FeedItem>?> load() async => null;

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    saveCalls++;
    if (failSaves) throw StateError('save failed');
    await gate?.future;
  }
}

final class _DetailImageSubscriptionPort implements MobileSubscriptionPort {
  _DetailImageSubscriptionPort(this.article);

  final V3FeedItem article;
  int assetCalls = 0;

  @override
  bool get isDemo => false;

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() async {
    return MobileSubscriptionCatalogResult.success(
      <MobileSubscriptionPublication>[
        MobileSubscriptionPublication(
          publicationId: 'publication-image-1',
          title: '图片测试出版物',
          sectionCount: 1,
          articleCount: 1,
          updatedAt: article.updatedAt,
          articles: <V3FeedItem>[article],
          followed: false,
          available: true,
        ),
      ],
    );
  }

  @override
  Future<MobileSubscriptionActionResult> loadArticle(
    V3FeedItem article,
  ) async => MobileSubscriptionActionResult.success(article);

  @override
  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset({
    required V3FeedItem article,
    required V3SubscriptionArticleAssetRef asset,
  }) async {
    assetCalls += 1;
    return MobileSubscriptionArticleAssetResult.success(
      MobileSubscriptionArticleAsset(
        bytes: Uint8List.fromList(<int>[
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
          0,
          0,
          0,
          13,
          73,
          72,
          68,
          82,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          1,
          8,
          6,
          0,
          0,
          0,
          31,
          21,
          196,
          137,
          0,
          0,
          0,
          13,
          73,
          68,
          65,
          84,
          8,
          215,
          99,
          248,
          207,
          192,
          240,
          31,
          0,
          5,
          0,
          1,
          255,
          137,
          153,
          61,
          29,
          0,
          0,
          0,
          0,
          73,
          69,
          78,
          68,
          174,
          66,
          96,
          130,
        ]),
        mimeType: 'image/png',
      ),
    );
  }

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

final class _NoteHistoryChatApi extends Fake implements ChatRepository {
  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async => ApiResult<ChatThreadPage>.success(
    data: ChatThreadPage(
      items: <ChatThread>[
        ChatThread(
          threadId: 'note-history-thread',
          scene: scene,
          title: '当前笔记历史',
          updatedAt: DateTime(2026, 8, 23, 10, 24),
          agentProfileId: standardCreationChatAgentProfileId,
        ),
      ],
    ),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final class _DetailMarkdownExporter extends Fake
    implements KnowledgeDocumentExportService {
  final documents = <KnowledgeExportDocument>[];
  final formats = <KnowledgeExportFormat>[];
  final discarded = <PreparedKnowledgeExport>[];
  final prepared = const PreparedKnowledgeExport(
    opaqueExportRef:
        'app-private-export://knowledge/cache/export-detail-share/knowledge.md',
    displayName: '我的定位笔记.md',
    mimeType: 'text/markdown',
    sizeBytes: 2048,
    format: KnowledgeExportFormat.markdown,
  );

  @override
  Future<KnowledgeExportResult<PreparedKnowledgeExport>> prepare(
    KnowledgeExportDocument document,
    KnowledgeExportFormat format,
  ) async {
    documents.add(document);
    formats.add(format);
    return KnowledgeExportResult<PreparedKnowledgeExport>.success(prepared);
  }

  @override
  Future<void> discard(PreparedKnowledgeExport export) async {
    discarded.add(export);
  }
}

final class _DetailDocumentSharePort
    implements NativePreparedDocumentSharePort {
  final calls = <String>[];
  final result = Completer<NativeFileResult<bool>>();

  @override
  Future<NativeFileResult<bool>> sharePreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) {
    calls.add('$opaqueExportRef|$displayName|$mimeType');
    return result.future;
  }
}

GoRouter _noteTestRouter() => GoRouter(
  initialLocation: '/new',
  routes: [
    GoRoute(path: '/new', builder: (context, state) => const V3NotePage()),
    GoRoute(
      path: '/v3/feed/items/:itemId',
      builder: (context, state) =>
          Text('detail:${state.pathParameters['itemId']}'),
    ),
    GoRoute(path: '/v3/feed', builder: (context, state) => const Text('思想图谱')),
  ],
);
