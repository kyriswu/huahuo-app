import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/subscription_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_library_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_item_detail_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_deposit_picker.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_library_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_local_surfaces.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_remote_detail.dart';

import '../../support/figma_golden_test_support.dart';

const _surface = Size(402, 874);

void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets('external Canvas ingress long card fits text scale $scale', (
      tester,
    ) async {
      final fixture = await _pumpWorld(
        tester,
        square: true,
        publications: _compactPublications(followed: true),
        surface: const Size(402, 874),
        textScaler: TextScaler.linear(scale),
      );
      addTearDown(fixture.dispose);
      final card = find.byKey(
        const ValueKey('remote-knowledge-world-random-compact-article'),
      );
      await tester.dragUntilVisible(
        card,
        find.byKey(const PageStorageKey<String>('remote-knowledge-world-home')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      final footer = find.descendant(
        of: card,
        matching: find.text('6 分钟阅读  ·  今日'),
      );
      expect(footer, findsOneWidget);
      expect(
        tester.getBottomRight(footer).dy,
        lessThanOrEqualTo(tester.getBottomRight(card).dy),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(card.hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('external-article-deposit')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('local distillation supports help, cancel and queued states', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => showV3DistillationFlow(
                  context: context,
                  ref: ref,
                  noteId: 'note-for-distillation',
                ),
                child: const Text('蒸馏'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('蒸馏'));
    await tester.pumpAndSettle();
    final help = find.byKey(const ValueKey('distillation-confirm-help'));
    await tester.ensureVisible(help);
    await tester.tap(help);
    await tester.pumpAndSettle();
    expect(find.text('人生故事'), findsOneWidget);
    final helpDone = find.byKey(const ValueKey('distillation-help-done'));
    await tester.ensureVisible(helpDone);
    await tester.tap(helpDone);
    await tester.pumpAndSettle();
    final cancel = find.text('暂不蒸馏');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(container.read(v3LocalDistillationQueueProvider), isEmpty);

    await tester.tap(find.text('蒸馏'));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('distillation-confirm'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.text('已加入蒸馏队列'), findsOneWidget);
    expect(
      container.read(v3LocalDistillationQueueProvider),
      contains('note-for-distillation'),
    );
    final queuedDone = find.byKey(const ValueKey('distillation-queued-done'));
    await tester.ensureVisible(queuedDone);
    expect(queuedDone.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(queuedDone);
    await tester.pumpAndSettle();
  });

  testWidgets('M07 subscribed home', (tester) async {
    final fixture = await _pumpWorld(tester);
    addTearDown(fixture.dispose);
    await _golden(tester, 'm07_subscribed_home.png');
  });

  testWidgets('M07 subscribed card and selected row enter directly', (
    tester,
  ) async {
    final fixture = await _pumpWorld(tester);
    addTearDown(fixture.dispose);
    for (final key in [
      'remote-subscribed-publication-ai-depth',
      'remote-subscribed-selected-publication',
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(find.byType(V3RemoteKnowledgeWorldDetailPage), findsOneWidget);
      expect(
        tester
            .widget<V3RemoteKnowledgeWorldDetailPage>(
              find.byType(V3RemoteKnowledgeWorldDetailPage),
            )
            .publicationId,
        'ai-depth',
      );
      expect(find.text('进入栏目'), findsNothing);
      expect(
        find.byKey(const ValueKey('knowledge-channel-opening-ai-depth')),
        findsNothing,
      );
      fixture.router.pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('M07 knowledge square', (tester) async {
    final fixture = await _pumpWorld(tester, square: true);
    addTearDown(fixture.dispose);
    await _golden(tester, 'm07_knowledge_square.png');
  });

  testWidgets('M07 hero preview', (tester) async {
    final fixture = await _pumpWorld(tester, square: true);
    addTearDown(fixture.dispose);
    final hero = find.byKey(
      const ValueKey('remote-knowledge-world-hero-agent-delivery'),
    );
    expect(
      find.descendant(
        of: hero,
        matching: find.byIcon(Icons.north_east_rounded),
      ),
      findsNothing,
    );
    await tester.tap(hero);
    await tester.pumpAndSettle();
    await _golden(tester, 'm07_hero_preview.png', overlay: true);
  });

  testWidgets('M07 channel information', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      location: AppRoutePaths.knowledgeWorldDetail(publicationId: 'ai-depth'),
    );
    addTearDown(fixture.dispose);
    await _golden(tester, 'm07_channel_information.png');
  });

  testWidgets('M07 channel depth articles', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      location: AppRoutePaths.knowledgeWorldDetail(publicationId: 'ai-depth'),
    );
    addTearDown(fixture.dispose);
    await tester.tap(find.text('深度文章'));
    await tester.pumpAndSettle();
    await _golden(tester, 'm07_channel_depth.png');
  });

  testWidgets('M07 subscribe confirmation', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      followed: false,
      location: AppRoutePaths.knowledgeWorldDetail(publicationId: 'ai-depth'),
    );
    addTearDown(fixture.dispose);
    await _tapChannelFollow(tester, 'ai-depth');
    await _golden(tester, 'm07_subscribe_confirmation.png', overlay: true);
  });

  testWidgets('M07 subscribe success', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      followed: false,
      location: AppRoutePaths.knowledgeWorldDetail(publicationId: 'ai-depth'),
    );
    addTearDown(fixture.dispose);
    await _tapChannelFollow(tester, 'ai-depth');
    await tester.tap(find.byKey(const ValueKey('subscription-sheet-confirm')));
    await tester.pumpAndSettle();
    await _golden(tester, 'm07_subscribe_success.png', overlay: true);
  });

  testWidgets('M07 subscription management', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      location: AppRoutePaths.knowledgeWorldDetail(publicationId: 'ai-depth'),
    );
    addTearDown(fixture.dispose);
    await _tapChannelFollow(tester, 'ai-depth');
    await _golden(tester, 'm07_subscription_management.png', overlay: true);
  });

  testWidgets('M07 subscription management toggles', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      location: AppRoutePaths.knowledgeWorldDetail(publicationId: 'ai-depth'),
    );
    addTearDown(fixture.dispose);
    await _tapChannelFollow(tester, 'ai-depth');
    await tester.tap(find.text('置顶栏目'));
    await tester.pump();
    await _golden(
      tester,
      'm07_subscription_management_toggles.png',
      overlay: true,
    );
  });

  testWidgets('M07 unsubscribe confirmation', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      location: AppRoutePaths.knowledgeWorldDetail(publicationId: 'ai-depth'),
    );
    addTearDown(fixture.dispose);
    await _tapChannelFollow(tester, 'ai-depth');
    await tester.tap(find.byKey(const ValueKey('subscription-manage-cancel')));
    await tester.pumpAndSettle();
    await _golden(tester, 'm07_unsubscribe_confirmation.png', overlay: true);
  });

  testWidgets('M07 unsubscribed channel', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      followed: false,
      location: AppRoutePaths.knowledgeWorldDetail(publicationId: 'ai-depth'),
    );
    addTearDown(fixture.dispose);
    await _golden(tester, 'm07_channel_unsubscribed.png');
  });

  testWidgets('M07 article reader', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      location: AppRoutePaths.feedItem('claude-watermark'),
    );
    addTearDown(fixture.dispose);
    await _golden(tester, 'm07_article_reader.png');
  });

  testWidgets('M07 article deposit destination', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      location: AppRoutePaths.feedItem('claude-watermark'),
    );
    addTearDown(fixture.dispose);
    await tester.tap(find.byKey(const ValueKey('external-article-deposit')));
    await tester.pumpAndSettle();
    expect(find.text('保存位置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('deposit-picker-asset-label-knowledge')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('deposit-picker-folder-unclassified')),
      findsOneWidget,
    );
    final distillation = tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(const ValueKey('deposit-distillation-option')),
        matching: find.byType(Checkbox),
      ),
    );
    expect(distillation.value, isFalse);
    await tester.tap(find.byKey(const ValueKey('deposit-distillation-help')));
    await tester.pumpAndSettle();
    expect(find.text('什么叫蒸馏到数字孪生？'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('distillation-help-done')));
    await tester.pumpAndSettle();
    await _golden(tester, 'm07_article_deposit_destination.png', overlay: true);
  });

  testWidgets('M07 article deposit success', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      location: AppRoutePaths.feedItem('claude-watermark'),
    );
    addTearDown(fixture.dispose);
    await tester.tap(find.byKey(const ValueKey('external-article-deposit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('deposit-picker-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('已沉淀到笔记'), findsOneWidget);
    await _golden(tester, 'm07_article_deposit_success.png', overlay: true);
  });

  testWidgets('M07 square search results', (tester) async {
    final fixture = await _pumpWorld(tester, square: true);
    addTearDown(fixture.dispose);
    await tester.enterText(
      find.byKey(const ValueKey('remote-knowledge-world-search')),
      'Claude',
    );
    await tester.pumpAndSettle();
    await _golden(tester, 'm07_square_search.png');
  });

  testWidgets('M07 subscription loading', (tester) async {
    final pending = Completer<MobileSubscriptionCatalogResult>();
    final fixture = await _pumpWorld(tester, pending: pending);
    addTearDown(fixture.dispose);
    await _golden(
      tester,
      'm07_subscription_loading.png',
      precacheImages: false,
    );
  });

  testWidgets('M07 subscription error', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      result: const MobileSubscriptionCatalogResult.failure(
        'SUBSCRIPTION_CATALOG_UNAVAILABLE',
      ),
    );
    addTearDown(fixture.dispose);
    await _golden(tester, 'm07_subscription_error.png');
  });

  testWidgets('M07 subscription empty', (tester) async {
    final fixture = await _pumpWorld(
      tester,
      result: const MobileSubscriptionCatalogResult.success(
        <MobileSubscriptionPublication>[],
      ),
    );
    addTearDown(fixture.dispose);
    await _golden(tester, 'm07_subscription_empty.png');
  });

  testWidgets('compact External World keeps scaled cards and previews usable', (
    tester,
  ) async {
    final fixture = await _pumpWorld(
      tester,
      publications: _compactPublications(followed: true),
      surface: const Size(320, 568),
      textScaler: const TextScaler.linear(1.3),
    );
    addTearDown(fixture.dispose);

    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(
        const ValueKey('remote-subscribed-publication-compact-publication'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(V3RemoteKnowledgeWorldDetailPage), findsOneWidget);
    expect(find.text('进入栏目'), findsNothing);
    expect(tester.takeException(), isNull);
    fixture.router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('knowledge-tab-square')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('remote-knowledge-world-hero-compact-article')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('knowledge-hero-preview-open')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('knowledge-hero-preview-open')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey('knowledge-hero-preview-close')),
    );
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('随手读一篇'),
      find.byKey(const PageStorageKey<String>('remote-knowledge-world-home')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    final randomCard = find.byKey(
      const ValueKey('remote-knowledge-world-random-compact-article'),
    );
    expect(tester.getSize(randomCard).height, greaterThan(208));
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape External World enters a subscribed column directly', (
    tester,
  ) async {
    final fixture = await _pumpWorld(
      tester,
      publications: _compactPublications(followed: true),
      surface: const Size(568, 320),
      textScaler: const TextScaler.linear(1.3),
    );
    addTearDown(fixture.dispose);

    final publication = find.byKey(
      const ValueKey('remote-subscribed-publication-compact-publication'),
    );
    await tester.ensureVisible(publication);
    await tester.tap(publication);
    await tester.pumpAndSettle();

    expect(find.byType(V3RemoteKnowledgeWorldDetailPage), findsOneWidget);
    expect(find.text('进入栏目'), findsNothing);
    expect(fixture.router.canPop(), isTrue);
    expect(tester.takeException(), isNull);
    fixture.router.pop();
    await tester.pumpAndSettle();
    expect(publication, findsOneWidget);
  });

  testWidgets('landscape deposit success keeps navigation action reachable', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final article = _compactPublications(followed: true).single.articles.single;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showV3KnowledgeDepositSuccessSheet(
                context,
                article: article,
                depositedNoteId: 'deposited-article-note',
              ),
              child: const Text('显示沉淀成功'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示沉淀成功'));
    await tester.pumpAndSettle();
    final navigate = find.text('去笔记查看');
    await tester.ensureVisible(navigate);
    expect(navigate.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(navigate).dy, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact subscription sheets keep every terminal action reachable',
    (tester) async {
      final fixture = await _pumpWorld(
        tester,
        followed: false,
        publications: _compactPublications(followed: false),
        location: AppRoutePaths.knowledgeWorldDetail(
          publicationId: 'compact-publication',
        ),
        surface: const Size(320, 568),
        textScaler: const TextScaler.linear(1.3),
      );
      addTearDown(fixture.dispose);

      await _tapChannelFollow(tester, 'compact-publication');
      final confirm = find.byKey(const ValueKey('subscription-sheet-confirm'));
      expect(confirm.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(find.text('继续浏览').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('继续浏览'));
      await tester.pumpAndSettle();

      await _tapChannelFollow(tester, 'compact-publication');
      final manageCancel = find.byKey(
        const ValueKey('subscription-manage-cancel'),
      );
      expect(manageCancel.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(manageCancel);
      await tester.pumpAndSettle();

      final cancelConfirm = find.byKey(
        const ValueKey('subscription-cancel-confirm'),
      );
      expect(cancelConfirm.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('继续订阅'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('compact scaled Knowledge Square uses a safe topic grid', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: V3KnowledgeSquarePage(
              controller: controller,
              active: true,
              query: '',
              category: V3SquareExploreCategory.all,
              showAllUpdates: false,
              onAction: (_, __) async {},
              onQueryChanged: (_) {},
              onCategoryChanged: (_) {},
              onShowAllUpdatesChanged: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = find.byKey(
      const ValueKey('knowledge-square-category-treasure'),
    );
    final fifth = find.byKey(
      const ValueKey('knowledge-square-category-literature'),
    );
    expect(
      tester.getTopLeft(fifth).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _tapChannelFollow(
  WidgetTester tester,
  String publicationId,
) async {
  await tester.tap(find.byKey(ValueKey('subscription-follow-$publicationId')));
  await tester.pumpAndSettle();
}

Future<void> _golden(
  WidgetTester tester,
  String name, {
  bool overlay = false,
  bool precacheImages = true,
}) async {
  if (precacheImages) await precacheFigmaFixtureImages(tester);
  await expectLater(
    overlay ? find.byType(Overlay).first : find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name'),
  );
}

Future<_WorldFixture> _pumpWorld(
  WidgetTester tester, {
  bool square = false,
  bool followed = true,
  String? location,
  MobileSubscriptionCatalogResult? result,
  Completer<MobileSubscriptionCatalogResult>? pending,
  List<MobileSubscriptionPublication>? publications,
  Size surface = _surface,
  TextScaler? textScaler,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final catalog = publications ?? _publications(followed: followed);
  final port = _WorldSubscriptionPort(
    result ?? MobileSubscriptionCatalogResult.success(catalog),
    pending: pending,
  );
  final controller = KnowledgeLibraryController(
    initialNotes: const <V3FeedItem>[],
    subscriptionPort: port,
  );
  await controller.createWorkspaceDepositFolder('行业资料');
  await controller.createWorkspaceDepositFolder('灵感收藏');
  if (pending == null) await controller.reloadSubscriptions();
  final router = GoRouter(
    initialLocation:
        location ??
        (square ? AppRoutePaths.knowledgeSquare : AppRoutePaths.knowledge),
    routes: [
      GoRoute(
        path: AppRoutePaths.knowledge,
        builder: (context, state) => V3KnowledgeLibraryPage(
          initialTab: state.uri.queryParameters['tab'] == 'square'
              ? V3KnowledgeLibraryTab.square
              : V3KnowledgeLibraryTab.subscribed,
        ),
      ),
      GoRoute(
        path: AppRoutePaths.knowledgeWorld,
        builder: (context, state) => V3RemoteKnowledgeWorldDetailPage(
          publicationId: state.uri.queryParameters['publicationId'],
          query: state.uri.queryParameters['q'] ?? '',
        ),
      ),
      GoRoute(
        path: '/v3/feed/items/:itemId',
        builder: (context, state) =>
            V3FeedItemDetailPage(itemId: state.pathParameters['itemId']!),
      ),
      GoRoute(
        path: AppRoutePaths.assets,
        builder: (_, __) => const Scaffold(body: Text('我的资产')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        resolvedDeviceIdProvider.overrideWithValue('m07-visual-fixture'),
        knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
        profileHubControllerProvider.overrideWith(
          (ref) => ProfileHubController(),
        ),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: figmaGoldenTheme(),
        routerConfig: router,
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
      ),
    ),
  );
  if (pending == null) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
  }
  return _WorldFixture(controller: controller, port: port, router: router);
}

List<MobileSubscriptionPublication> _compactPublications({
  required bool followed,
}) {
  final article = _article(
    id: 'compact-article',
    title: '一篇在紧凑屏幕上仍需完整保留层级关系的深度观察文章',
    summary:
        '这段摘要刻意覆盖多行文本，验证栏目名称、文章标题、摘要和操作按钮在窄屏以及放大文字时仍能保持清晰边界。'
        '当内容继续增长时，界面应该提供滚动能力，而不是裁掉最后几行或让按钮离开可操作区域。'
        '同一份内容也用于验证全屏推荐预览能够从底部显示阅读入口。',
    publicationId: 'compact-publication',
    author: '外部世界响应式布局审计编辑部',
  );
  return <MobileSubscriptionPublication>[
    MobileSubscriptionPublication(
      publicationId: 'compact-publication',
      title: '人工智能产品实践与长期行业变化深度观察栏目',
      summary:
          '持续跟进模型能力、产品交付、组织协作和真实应用中的长期变化，提供足够长的栏目说明来覆盖紧凑窗口。'
          '这里继续增加一段说明，以验证全屏推荐预览在动态内容超过短屏高度时仍能滚动到阅读操作。',
      sectionCount: 128,
      articleCount: 123456,
      updatedAt: DateTime.utc(2026, 9, 3, 9),
      articles: <V3FeedItem>[article],
      followed: followed,
      available: true,
    ),
  ];
}

List<MobileSubscriptionPublication> _publications({required bool followed}) {
  final articles = <V3FeedItem>[
    _article(
      id: 'claude-watermark',
      title: 'Claude 输出加水印，AI 使用者为何反弹',
      summary: '水印争议表面是一项合规更新，真正触动的是创作者对自主权与作品归属的担忧。',
      coreJudgment: '产品必须同时交代合规边界、作品归属与用户选择权。',
      publicationId: 'ai-depth',
      author: '花火编辑部',
    ),
    _article(
      id: 'agent-delivery',
      title: 'AI Agent 产品从演示走向交付',
      summary: '企业真正开始购买的是稳定流程结果。',
      publicationId: 'ai-depth',
      author: '行业动态',
    ),
    _article(
      id: 'model-law',
      title: '开源模型正在重写成本结构',
      summary: '模型能力、部署成本和治理方式正在同时变化。',
      publicationId: 'law-observer',
      author: '法治观察',
    ),
    _article(
      id: 'culture-city',
      title: '古罗马建筑如何塑造欧洲城市',
      summary: '从城市与历史的视角理解空间秩序。',
      publicationId: 'chinese-culture',
      author: '中国文化',
    ),
  ];
  return <MobileSubscriptionPublication>[
    MobileSubscriptionPublication(
      publicationId: 'ai-depth',
      title: 'AI 深度',
      summary: '产品、模型与真实案例',
      sectionCount: 3,
      articleCount: 128,
      updatedAt: DateTime.utc(2026, 8, 24, 9),
      articles: articles.take(2).toList(growable: false),
      followed: followed,
      available: true,
    ),
    MobileSubscriptionPublication(
      publicationId: 'chinese-culture',
      title: '中国文化',
      summary: '历史、人文与城市观察',
      sectionCount: 3,
      articleCount: 126,
      updatedAt: DateTime.utc(2026, 8, 23, 9),
      articles: <V3FeedItem>[articles[3]],
      followed: followed,
      available: true,
    ),
    MobileSubscriptionPublication(
      publicationId: 'law-observer',
      title: '法治观察',
      summary: '规则变化与真实判例',
      sectionCount: 2,
      articleCount: 84,
      updatedAt: DateTime.utc(2026, 8, 22, 9),
      articles: <V3FeedItem>[articles[2]],
      followed: followed,
      available: true,
    ),
    MobileSubscriptionPublication(
      publicationId: 'business-growth',
      title: '创业商业',
      summary: '增长、产品与组织',
      sectionCount: 2,
      articleCount: 62,
      updatedAt: DateTime.utc(2026, 8, 21, 9),
      articles: const <V3FeedItem>[],
      followed: followed,
      available: true,
    ),
  ];
}

V3FeedItem _article({
  required String id,
  required String title,
  required String summary,
  required String publicationId,
  required String author,
  String? coreJudgment,
}) {
  return V3FeedItem(
    id: id,
    title: title,
    source: V3MaterialSource.knowledgeSquare,
    createdAt: DateTime.utc(2026, 8, 21, 9),
    updatedAt: DateTime.utc(2026, 8, 24, 9),
    rawBody:
        '$summary\n\n这项变化不仅影响产品功能，也改变了用户与工具之间原本默认的信任关系。\n\n进一步观察，需要把技术约束、产品选择和真实使用场景放在一起判断。'
        '${coreJudgment == null ? '' : '\n\n## 核心判断\n\n$coreJudgment'}',
    summaryBody: summary,
    author: author,
    ownership: V3NoteOwnership.knowledgeSquare,
    publicationId: publicationId,
    articleId: 'article-$id',
    articleRevisionId: 'revision-$id',
  );
}

final class _WorldFixture {
  const _WorldFixture({
    required this.controller,
    required this.port,
    required this.router,
  });

  final KnowledgeLibraryController controller;
  final _WorldSubscriptionPort port;
  final GoRouter router;

  void dispose() {
    router.dispose();
  }
}

final class _WorldSubscriptionPort implements MobileSubscriptionPort {
  _WorldSubscriptionPort(this.result, {this.pending});

  MobileSubscriptionCatalogResult result;
  final Completer<MobileSubscriptionCatalogResult>? pending;

  @override
  bool get isDemo => false;

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() =>
      pending?.future ?? Future.value(result);

  @override
  Future<MobileSubscriptionActionResult> loadArticle(
    V3FeedItem article,
  ) async => MobileSubscriptionActionResult.success(article);

  @override
  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset({
    required V3FeedItem article,
    required V3SubscriptionArticleAssetRef asset,
  }) async => const MobileSubscriptionArticleAssetResult.unavailable(
    'VISUAL_FIXTURE_NO_REMOTE_ASSET',
  );

  @override
  Future<MobileSubscriptionActionResult> saveArticleAsNote({
    required V3FeedItem article,
    required String actionId,
  }) async => MobileSubscriptionActionResult.success(
    article.copyWith(
      ownership: V3NoteOwnership.mine,
      source: V3MaterialSource.subscription,
      copiedFromContentId: article.id,
      remoteNoteId: 'saved-${article.id}',
      noteRevisionId: 'note-revision-${article.id}',
      rawPartRevisionId: 'raw-revision-${article.id}',
      etag: '"saved-${article.id}"',
      contentCursor: '200',
      syncState: NoteSyncState.synced,
    ),
  );

  @override
  Future<MobileSubscriptionActionResult> setPublicationFollowed({
    required String publicationId,
    required bool followed,
    required String actionId,
  }) async => const MobileSubscriptionActionResult.success();
}
