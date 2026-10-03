import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/app/navigation/app_routes.dart';
import 'package:huahuoai_app/app/navigation/legacy_route_redirect.dart';
import 'package:huahuoai_app/app/navigation/route_parameter_parser.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  testWidgets('retired trash links return to account services', (tester) async {
    final sectionRoute =
        buildAppRoutes(
          splashBuilder: _placeholder,
          restoreFailedBuilder: _placeholder,
          workspaceRetryBuilder: _placeholder,
        ).whereType<GoRoute>().singleWhere(
          (route) => route.path == '/v3/profile/:section',
        );
    final router = GoRouter(
      initialLocation: '/v3/profile/${Uri.encodeComponent('回收站')}',
      redirect: (context, state) => v3LocationForLegacyMainUri(state.uri),
      routes: [
        GoRoute(
          path: '/v3/profile/account',
          builder: (context, state) => const Text('account-destination'),
        ),
        GoRoute(
          path: sectionRoute.path,
          redirect: sectionRoute.redirect,
          builder: (context, state) => Text(state.pathParameters['section']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('account-destination'), findsOneWidget);
    expect(find.text('回收站'), findsNothing);

    router.go('/main/placeholder/${Uri.encodeComponent('回收站')}');
    await tester.pumpAndSettle();
    expect(find.text('account-destination'), findsOneWidget);
    expect(find.text('回收站'), findsNothing);

    router.go('/v3/profile/${Uri.encodeComponent('设置')}');
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('account-destination'), findsNothing);
  });

  test('canonical route registry has no duplicate paths', () {
    final routes = RouteBase.routesRecursively(
      buildAppRoutes(
        splashBuilder: _placeholder,
        restoreFailedBuilder: _placeholder,
        workspaceRetryBuilder: _placeholder,
      ),
    ).whereType<GoRoute>().toList(growable: false);
    final paths = routes.map((route) => route.path).toList(growable: false);

    expect(routes, hasLength(79));
    expect(paths, contains('/v3/profile/recordings'));
    expect(paths.toSet(), hasLength(paths.length));
  });

  group('legacy V2 main route aliases', () {
    test('maps maintained V2 entry points to their V3 replacements', () {
      expect(v3LocationForLegacyMainUri(Uri.parse('/main')), '/v3');
      expect(v3LocationForLegacyMainUri(Uri.parse('/main/home')), '/v3');
      expect(v3LocationForLegacyMainUri(Uri.parse('/main/work-ai')), '/v3');
      expect(v3LocationForLegacyMainUri(Uri.parse('/main/creation')), '/v3');
      expect(
        v3LocationForLegacyMainUri(Uri.parse('/main/assets')),
        '/v3/assets?focus=overview',
      );
      expect(
        v3LocationForLegacyMainUri(Uri.parse('/main/feed-ai/graph')),
        '/v3/feed/graph',
      );
      expect(
        v3LocationForLegacyMainUri(Uri.parse('/main/feed-ai/import')),
        '/v3/feed/import/documents',
      );
      expect(
        v3LocationForLegacyMainUri(Uri.parse('/main/quick-recording')),
        '/v3/feed/record-source',
      );
      expect(
        v3LocationForLegacyMainUri(Uri.parse('/main/recording-card/connect')),
        '/v3/recording-card/control',
      );
    });

    test('does not translate removed standalone recording-library routes', () {
      expect(v3LocationForLegacyMainUri(Uri.parse('/main/recordings')), isNull);
      expect(
        v3LocationForLegacyMainUri(Uri.parse('/main/recordings/recording-1')),
        isNull,
      );
    });

    test('maps diagnostics through the same legacy translator', () {
      expect(
        v3LocationForLegacyMainUri(Uri.parse('/main/settings/diagnostics')),
        '/v3/profile/${Uri.encodeComponent('诊断')}',
      );
    });

    test('encodes Chinese profile sections exactly once', () {
      expect(
        v3LocationForLegacyMainUri(
          Uri.parse('/main/placeholder/${Uri.encodeComponent('设置')}'),
        ),
        '/v3/profile/${Uri.encodeComponent('设置')}',
      );
    });

    test('redirects selected creation to the free canvas with its asset', () {
      expect(
        v3LocationForLegacyMainUri(
          Uri.parse('/main/creation/selected?feedItemId=note-1'),
        ),
        '/v3/workbench/canvas?importAssetId=note-1',
      );
    });

    test(
      'redirects every retired creation deep link to the current canvas',
      () {
        for (final location in <String>[
          '/main/creation/materials',
          '/main/creation/create/opinion',
          '/main/creation/result/topic',
          '/main/creation/unknown/nested/path',
        ]) {
          expect(
            v3LocationForLegacyMainUri(Uri.parse(location)),
            AppRoutePaths.canvas,
            reason: location,
          );
        }
      },
    );

    test('preserves safe legacy Chat thread identities', () {
      expect(
        v3LocationForLegacyMainUri(
          Uri.parse('/main/feed-ai/thread/thread_feed_1'),
        ),
        '/v3/feed/chat?threadId=thread_feed_1&purpose=general',
      );
      expect(
        v3LocationForLegacyMainUri(
          Uri.parse('/main/work-ai/thread/thread_work_1'),
        ),
        '/v3/feed/chat?threadId=thread_work_1&purpose=deep-positioning',
      );
      expect(
        v3LocationForLegacyMainUri(
          Uri.parse('/main/feed-ai/thread/unsafe%2Fthread'),
        ),
        '/v3/feed/chat?threadId',
      );
      expect(
        v3LocationForLegacyMainUri(
          Uri.parse('/main/feed-ai/thread/thread_feed_1/extra'),
        ),
        '/v3/feed/chat?threadId',
      );
    });
  });

  group('canonical home locations', () {
    test('keeps one home route with a mode-only initialization query', () {
      expect(AppRoutePaths.homeForMode('feed'), '/v3');
      expect(AppRoutePaths.homeForMode('workbench'), '/v3?mode=workbench');
      expect(AppRoutePaths.homeForMode('masterpiece'), '/v3?mode=masterpiece');
      expect(AppRoutePaths.homeForMode('unknown'), '/v3');
    });

    test('fails closed for malformed typed query values', () {
      expect(routeCanvasTopicId('note-1'), 'note-1');
      expect(routeCanvasTopicId('../note'), isNull);
      expect(routePhotoAlbumResourceId('resource-1'), 'resource-1');
      expect(routePhotoAlbumResourceId('../resource'), isNull);
      expect(routePhotoAlbumResourceId(' resource-1'), isNull);
      expect(routePhotoAlbumResourceId('r' * 161), isNull);
      expect(routeCanvasTopicTitle('  选题  '), '选题');
      expect(routeCalendarDate('2026-08-12'), DateTime(2026, 8, 12));
      expect(routeCalendarDate('2026-02-30'), isNull);
      expect(isSafeChatIdentifier('t' * 128), isTrue);
      expect(isSafeChatIdentifier('t' * 129), isFalse);
    });

    test('builds typed media and workbench secondary locations', () {
      expect(AppRoutePaths.workbench, '/v3?mode=workbench');
      expect(
        AppRoutePaths.photoAlbumPreview('resource:cover-1'),
        '/v3/assets/media/resource%3Acover-1',
      );
      expect(
        AppRoutePaths.workbenchMaterials('persona'),
        '/v3/workbench/materials/persona',
      );
      expect(
        AppRoutePaths.workbenchGenerating('persona'),
        '/v3/workbench/generating/persona',
      );
      expect(
        AppRoutePaths.workbenchGenerated('persona'),
        '/v3/workbench/generated/persona',
      );
    });
  });

  group('Canvas entry intent normalization', () {
    const sourceMarkdown = '# 当前纲要\n\n只使用这个阶段。';
    late AssetCanvasSeed assetSeed;
    late Map<String, V3FeedItem> compatibilityNotes;

    V3FeedItem? sourceNoteForId(String id) => compatibilityNotes[id];

    setUp(() {
      assetSeed = AssetCanvasSeed(
        assetId: 'asset-1',
        title: '资产一',
        stage: AssetCanvasSourceStage.outline,
        sourceMarkdown: sourceMarkdown,
        partRevisionId: 'outline-revision-1',
        sourceHash: AssetCanvasSeed.hashSourceMarkdown(sourceMarkdown),
        linkedReference: const V3LinkedMaterialRef(
          id: 'asset-1',
          source: V3MaterialSource.note,
          title: '资产一',
        ),
      );
      compatibilityNotes = <String, V3FeedItem>{
        'asset-1': V3FeedItem(
          id: 'asset-1',
          title: '资产一',
          source: V3MaterialSource.documentImport,
          createdAt: DateTime.utc(2026, 9, 4),
          rawBody: '# 资产原文\n\n冻结这一版。',
          summaryBody: '不应使用的资产摘要',
          rawPartRevisionId: 'asset-raw-r1',
        ),
        'topic-1': V3FeedItem(
          id: 'topic-1',
          title: '知识库选题',
          source: V3MaterialSource.hotspot,
          createdAt: DateTime.utc(2026, 9, 4),
          rawBody: '旧入口锁存的选题原文',
          summaryBody: '不应回退的选题摘要',
          rawPartRevisionId: 'topic-raw-r1',
        ),
      };
    });

    test('uses API-width typed IDs without weakening exact Asset IDs', () {
      final apiWidthId = List<String>.filled(256, 'a').join();
      final daily = resolveCanvasEntryIntent(
        extra: CanvasEntryIntent.dailyTopic(
          DailyTopicCanvasSeed(
            recommendationId: apiWidthId,
            topicId: apiWidthId,
            title: '最长合法选题',
            briefMarkdown: '选题方向',
            sourceRefs: const <DailyTopicCanvasSourceRef>[],
          ),
        ),
        queryParametersAll: const <String, List<String>>{},
      );
      final paddedAsset = AssetCanvasSeed(
        assetId: ' asset-1 ',
        title: '资产一',
        stage: AssetCanvasSourceStage.outline,
        sourceMarkdown: sourceMarkdown,
        partRevisionId: 'outline-revision-1',
        sourceHash: AssetCanvasSeed.hashSourceMarkdown(sourceMarkdown),
        linkedReference: const V3LinkedMaterialRef(
          id: 'asset-1',
          source: V3MaterialSource.note,
          title: '资产一',
        ),
      );
      final invalidAsset = resolveCanvasEntryIntent(
        extra: paddedAsset,
        queryParametersAll: const <String, List<String>>{},
      );

      expect(daily, isA<CanvasDailyTopicEntryIntent>());
      expect(daily.isValid, isTrue);
      expect(invalidAsset, isA<CanvasBlankEntryIntent>());
    });

    test(
      'keeps typed generation and direct-open intents mutually exclusive',
      () {
        final asset = resolveCanvasEntryIntent(
          extra: assetSeed,
          queryParametersAll: const <String, List<String>>{
            'importAssetId': <String>['asset-1'],
          },
        );
        final daily = resolveCanvasEntryIntent(
          extra: DailyTopicCanvasSeed(
            recommendationId: 'recommendation-1',
            topicId: 'topic-1',
            title: '选题一',
            briefMarkdown: '选题方向',
            sourceRefs: const <DailyTopicCanvasSourceRef>[],
          ),
          queryParametersAll: const <String, List<String>>{},
        );
        final assistant = resolveCanvasEntryIntent(
          extra: const CanvasEntryIntent.assistantReply(
            AssistantReplyCanvasSeed(title: '回复', markdown: '已有成稿'),
          ),
          queryParametersAll: const <String, List<String>>{},
        );
        final blank = resolveCanvasEntryIntent(
          extra: const CanvasEntryIntent.blank(),
          queryParametersAll: const <String, List<String>>{},
        );
        final existing = resolveCanvasEntryIntent(
          extra: const CanvasEntryIntent.existingNote('note-1'),
          queryParametersAll: const <String, List<String>>{},
        );
        final history = resolveCanvasEntryIntent(
          extra: const CanvasEntryIntent.history('history-1'),
          queryParametersAll: const <String, List<String>>{},
        );
        expect(asset, isA<CanvasAssetEntryIntent>());
        expect(asset.requiresInitialDraftGeneration, isTrue);
        expect(
          (asset as CanvasAssetEntryIntent).seed.sourceMarkdown,
          sourceMarkdown,
        );
        expect(daily, isA<CanvasDailyTopicEntryIntent>());
        expect(daily.requiresInitialDraftGeneration, isTrue);
        expect(assistant, isA<CanvasAssistantReplyEntryIntent>());
        expect(assistant.requiresInitialDraftGeneration, isFalse);
        expect(blank, isA<CanvasBlankEntryIntent>());
        expect(blank.requiresInitialDraftGeneration, isFalse);
        expect(existing, isA<CanvasExistingNoteEntryIntent>());
        expect(existing.requiresInitialDraftGeneration, isFalse);
        expect(history, isA<CanvasHistoryEntryIntent>());
        expect(history.requiresInitialDraftGeneration, isFalse);
      },
    );

    test('converts each single legacy identity to one typed intent', () {
      final asset = resolveCanvasEntryIntent(
        extra: null,
        queryParametersAll: const <String, List<String>>{
          'importAssetId': <String>['asset-1'],
        },
        sourceNoteForId: sourceNoteForId,
      );
      final existing = resolveCanvasEntryIntent(
        extra: null,
        queryParametersAll: const <String, List<String>>{
          'initialNoteId': <String>['note-1'],
        },
      );
      final history = resolveCanvasEntryIntent(
        extra: null,
        queryParametersAll: const <String, List<String>>{
          'historyId': <String>['history-1'],
        },
      );
      final topic = resolveCanvasEntryIntent(
        extra: null,
        queryParametersAll: const <String, List<String>>{
          'topicId': <String>['topic-1'],
          'topicTitle': <String>['旧选题'],
        },
        sourceNoteForId: sourceNoteForId,
      );

      expect(asset, isA<CanvasAssetEntryIntent>());
      final assetSnapshot = (asset as CanvasAssetEntryIntent).seed;
      expect(assetSnapshot.stage, AssetCanvasSourceStage.raw);
      expect(assetSnapshot.sourceMarkdown, '# 资产原文\n\n冻结这一版。');
      expect(assetSnapshot.partRevisionId, 'asset-raw-r1');
      expect(
        assetSnapshot.sourceHash,
        AssetCanvasSeed.hashSourceMarkdown(assetSnapshot.sourceMarkdown),
      );
      expect(asset.requiresInitialDraftGeneration, isTrue);
      expect(existing, isA<CanvasExistingNoteEntryIntent>());
      expect(existing.requiresInitialDraftGeneration, isFalse);
      expect(history, isA<CanvasHistoryEntryIntent>());
      expect(history.requiresInitialDraftGeneration, isFalse);
      expect(topic, isA<CanvasDailyTopicEntryIntent>());
      final topicSnapshot = (topic as CanvasDailyTopicEntryIntent).seed;
      expect(topicSnapshot.title, '旧选题');
      expect(topicSnapshot.briefMarkdown, '旧入口锁存的选题原文');
      expect(topicSnapshot.sourceRevisionId, 'topic-raw-r1');
      expect(
        topicSnapshot.sourceHash,
        AssetCanvasSeed.hashSourceMarkdown(topicSnapshot.editableMarkdown),
      );
      expect(topicSnapshot.linkedReference?.id, 'topic-1');
      expect(topicSnapshot.linkedReference?.source, V3MaterialSource.hotspot);
      expect(topic.requiresInitialDraftGeneration, isTrue);
    });

    test('defers valid legacy sources while Knowledge lookup is cold', () {
      final asset = resolveCanvasRouteEntry(
        extra: null,
        queryParametersAll: const <String, List<String>>{
          'importAssetId': <String>['asset-1'],
        },
        sourceLookupReady: false,
      );
      final topic = resolveCanvasRouteEntry(
        extra: null,
        queryParametersAll: const <String, List<String>>{
          'topicId': <String>['topic-1'],
          'topicTitle': <String>['冷启动选题'],
        },
        sourceLookupReady: false,
      );
      final conflict = resolveCanvasRouteEntry(
        extra: null,
        queryParametersAll: const <String, List<String>>{
          'importAssetId': <String>['asset-1'],
          'topicId': <String>['topic-1'],
        },
        sourceLookupReady: false,
      );

      expect(asset.intent, isNull);
      expect(asset.deferredSource?.kind, CanvasLegacyRouteSourceKind.asset);
      expect(asset.deferredSource?.sourceId, 'asset-1');
      expect(topic.intent, isNull);
      expect(
        topic.deferredSource?.kind,
        CanvasLegacyRouteSourceKind.dailyTopic,
      );
      expect(topic.deferredSource?.sourceId, 'topic-1');
      expect(topic.deferredSource?.topicTitle, '冷启动选题');
      expect(conflict.deferredSource, isNull);
      expect(conflict.intent, isA<CanvasBlankEntryIntent>());
    });

    test(
      'query generation sources fail closed without an exact raw revision',
      () {
        compatibilityNotes.addAll(<String, V3FeedItem>{
          'summary-only': V3FeedItem(
            id: 'summary-only',
            title: '只有摘要',
            source: V3MaterialSource.hotspot,
            createdAt: DateTime.utc(2026, 9, 4),
            rawBody: '   ',
            summaryBody: '绝不能用这段摘要生成',
            rawPartRevisionId: 'summary-only-raw-r1',
          ),
          'missing-revision': V3FeedItem(
            id: 'missing-revision',
            title: '缺少版本',
            source: V3MaterialSource.documentImport,
            createdAt: DateTime.utc(2026, 9, 4),
            rawBody: '有正文但没有 Raw revision',
          ),
        });

        for (final intent in <CanvasEntryIntent>[
          resolveCanvasEntryIntent(
            extra: null,
            queryParametersAll: const <String, List<String>>{
              'topicId': <String>['summary-only'],
            },
            sourceNoteForId: sourceNoteForId,
          ),
          resolveCanvasEntryIntent(
            extra: null,
            queryParametersAll: const <String, List<String>>{
              'importAssetId': <String>['missing-revision'],
            },
            sourceNoteForId: sourceNoteForId,
          ),
          resolveCanvasEntryIntent(
            extra: null,
            queryParametersAll: const <String, List<String>>{
              'importAssetId': <String>['missing-note'],
            },
            sourceNoteForId: sourceNoteForId,
          ),
          resolveCanvasEntryIntent(
            extra: null,
            queryParametersAll: <String, List<String>>{
              'topicId': const <String>['topic-1'],
              'topicTitle': <String>['x' * 121],
            },
            sourceNoteForId: sourceNoteForId,
          ),
        ]) {
          expect(intent, isA<CanvasBlankEntryIntent>());
        }
      },
    );

    test('fails closed for conflicting or mismatched Canvas identities', () {
      for (final intent in <CanvasEntryIntent>[
        resolveCanvasEntryIntent(
          extra: null,
          queryParametersAll: const <String, List<String>>{
            'initialNoteId': <String>['note-1'],
            'historyId': <String>['history-1'],
          },
        ),
        resolveCanvasEntryIntent(
          extra: null,
          queryParametersAll: const <String, List<String>>{
            'initialNoteId': <String>['note-1', 'note-2'],
          },
        ),
        resolveCanvasEntryIntent(
          extra: assetSeed,
          queryParametersAll: const <String, List<String>>{
            'importAssetId': <String>['other-asset'],
          },
        ),
        resolveCanvasEntryIntent(
          extra: null,
          queryParametersAll: const <String, List<String>>{
            'importAssetId': <String>['../unsafe'],
          },
        ),
        resolveCanvasEntryIntent(
          extra: const Object(),
          queryParametersAll: const <String, List<String>>{},
        ),
      ]) {
        expect(intent, isA<CanvasBlankEntryIntent>());
      }
    });
  });

  group('Canvas route-extra restoration codec', () {
    const assetMarkdown = '# 点火结果\n\n只恢复这一阶段。';
    final assetSeed = AssetCanvasSeed(
      assetId: 'asset-restored',
      title: '恢复资产',
      stage: AssetCanvasSourceStage.sprout,
      sourceMarkdown: assetMarkdown,
      partRevisionId: 'sprout-r7',
      sourceHash: AssetCanvasSeed.hashSourceMarkdown(assetMarkdown),
      linkedReference: const V3LinkedMaterialRef(
        id: 'asset-restored',
        source: V3MaterialSource.documentImport,
        title: '恢复资产',
        summary: '保留摘要元数据',
      ),
      initialSourceMode: AssetCanvasInitialSourceMode.generateTranscript,
    );
    final dailySeed = DailyTopicCanvasSeed(
      recommendationId: 'recommendation-restored',
      topicId: 'topic-restored',
      title: '恢复选题',
      briefMarkdown: '完整的选题方向',
      sourceRefs: const <DailyTopicCanvasSourceRef>[
        DailyTopicCanvasSourceRef(hotspotId: 'hotspot-1', label: '行业热点'),
      ],
      sourceRevisionId: 'topic-r3',
      linkedReference: const V3LinkedMaterialRef(
        id: 'topic-restored',
        source: V3MaterialSource.hotspot,
        title: '恢复选题',
        summary: '热点摘要',
      ),
    );

    test('round-trips all typed intents and every immutable seed field', () {
      final intents = <CanvasEntryIntent>[
        const CanvasEntryIntent.blank(),
        CanvasEntryIntent.dailyTopic(dailySeed),
        CanvasEntryIntent.asset(assetSeed),
        const CanvasEntryIntent.existingNote('note-restored'),
        const CanvasEntryIntent.history('history-restored'),
        const CanvasEntryIntent.assistantReply(
          AssistantReplyCanvasSeed(title: '承接回复', markdown: '已生成且可继续编辑的正文'),
        ),
      ];

      final restored = intents
          .map(
            (intent) =>
                appRouteExtraCodec.decode(appRouteExtraCodec.encode(intent)),
          )
          .toList(growable: false);

      expect(
        restored.map((value) => value.runtimeType),
        intents.map((value) => value.runtimeType),
      );
      expect(
        restored.whereType<CanvasEntryIntent>().map(
          (intent) => intent.stableSourceId,
        ),
        intents.map((intent) => intent.stableSourceId),
      );

      final restoredAsset = restored[2] as CanvasAssetEntryIntent;
      expect(restoredAsset.seed.stage, AssetCanvasSourceStage.sprout);
      expect(restoredAsset.seed.sourceMarkdown, assetMarkdown);
      expect(restoredAsset.seed.partRevisionId, 'sprout-r7');
      expect(restoredAsset.seed.sourceHash, assetSeed.sourceHash);
      expect(
        restoredAsset.seed.initialSourceMode,
        AssetCanvasInitialSourceMode.generateTranscript,
      );
      expect(
        restoredAsset.seed.linkedReference.source,
        V3MaterialSource.documentImport,
      );
      expect(restoredAsset.seed.linkedReference.summary, '保留摘要元数据');

      final restoredDaily = restored[1] as CanvasDailyTopicEntryIntent;
      expect(restoredDaily.seed.briefMarkdown, '完整的选题方向');
      expect(restoredDaily.seed.sourceRevisionId, 'topic-r3');
      expect(restoredDaily.seed.sourceHash, dailySeed.sourceHash);
      expect(restoredDaily.seed.sourceRefs.single.hotspotId, 'hotspot-1');
      expect(restoredDaily.seed.sourceRefs.single.label, '行业热点');
      expect(
        restoredDaily.seed.linkedReference?.source,
        V3MaterialSource.hotspot,
      );
      expect(restoredDaily.seed.linkedReference?.summary, '热点摘要');
    });

    test('round-trips both source modes and accepts a legacy missing mode', () {
      for (final mode in AssetCanvasInitialSourceMode.values) {
        final restored = appRouteExtraCodec.decode(
          appRouteExtraCodec.encode(
            CanvasEntryIntent.asset(assetSeed.withInitialSourceMode(mode)),
          ),
        );
        expect(
          (restored! as CanvasAssetEntryIntent).seed.initialSourceMode,
          mode,
        );
      }

      final encoded = Map<String, Object?>.from(
        appRouteExtraCodec.encode(CanvasEntryIntent.asset(assetSeed))!
            as Map<Object?, Object?>,
      );
      final payload = Map<String, Object?>.from(
        encoded['payload']! as Map<Object?, Object?>,
      );
      final seed = Map<String, Object?>.from(
        payload['seed']! as Map<Object?, Object?>,
      )..remove('initialSourceMode');
      payload['seed'] = seed;
      encoded['payload'] = payload;
      final restored = appRouteExtraCodec.decode(encoded);
      expect(
        (restored! as CanvasAssetEntryIntent).seed.initialSourceMode,
        isNull,
      );
    });

    test('normalizes accepted seed extras and preserves compact text maps', () {
      expect(
        appRouteExtraCodec.decode(appRouteExtraCodec.encode(assetSeed)),
        isA<CanvasAssetEntryIntent>(),
      );
      expect(
        appRouteExtraCodec.decode(appRouteExtraCodec.encode(dailySeed)),
        isA<CanvasDailyTopicEntryIntent>(),
      );
      expect(
        appRouteExtraCodec.decode(
          appRouteExtraCodec.encode(
            const AssistantReplyCanvasSeed(title: '标题', markdown: '正文'),
          ),
        ),
        isA<CanvasAssistantReplyEntryIntent>(),
      );

      final restoredDraft = appRouteExtraCodec.decode(
        appRouteExtraCodec.encode(<String, String>{
          'title': '临时文本',
          'body': '正文',
        }),
      );
      expect(restoredDraft, isA<Map<String, String>>());
      expect(restoredDraft, <String, String>{'title': '临时文本', 'body': '正文'});
    });

    test('fails closed for malformed or future envelopes', () {
      expect(
        appRouteExtraCodec.decode(const <String, Object?>{
          'schema': 'huahuo-route-extra',
          'version': 2,
          'kind': 'canvasEntryIntent',
          'payload': <String, Object?>{'type': 'blank'},
        }),
        isNull,
      );
      final encodedAsset = appRouteExtraCodec.encode(
        CanvasEntryIntent.asset(assetSeed),
      );
      final envelope = Map<String, Object?>.from(
        encodedAsset! as Map<Object?, Object?>,
      );
      final payload = Map<String, Object?>.from(
        envelope['payload']! as Map<Object?, Object?>,
      );
      final seed = Map<String, Object?>.from(
        payload['seed']! as Map<Object?, Object?>,
      )..['stage'] = 'summary';
      payload['seed'] = seed;
      envelope['payload'] = payload;
      expect(appRouteExtraCodec.decode(envelope), isNull);

      final futureModeEnvelope = Map<String, Object?>.from(
        encodedAsset as Map<Object?, Object?>,
      );
      final futureModePayload = Map<String, Object?>.from(
        futureModeEnvelope['payload']! as Map<Object?, Object?>,
      );
      final futureModeSeed = Map<String, Object?>.from(
        futureModePayload['seed']! as Map<Object?, Object?>,
      )..['initialSourceMode'] = 'future_mode';
      futureModePayload['seed'] = futureModeSeed;
      futureModeEnvelope['payload'] = futureModePayload;
      expect(appRouteExtraCodec.decode(futureModeEnvelope), isNull);
    });

    testWidgets('GoRouter restores exact Asset and Daily-topic snapshots', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/',
        restorationScopeId: 'canvas-route-extra-test',
        extraCodec: appRouteExtraCodec,
        routes: <RouteBase>[
          GoRoute(path: '/', builder: _placeholder),
          GoRoute(
            path: '/daily',
            builder: (context, state) {
              final intent = state.extra as CanvasDailyTopicEntryIntent?;
              return Material(
                child: Text(
                  '${intent?.seed.sourceRevisionId}|'
                  '${intent?.seed.sourceRefs.single.label}|'
                  '${intent?.seed.linkedReference?.summary}',
                ),
              );
            },
          ),
          GoRoute(
            path: '/canvas',
            builder: (context, state) {
              final intent = state.extra as CanvasAssetEntryIntent?;
              return Material(
                child: Text(
                  '${intent?.seed.stage.name}|${intent?.seed.sourceMarkdown}',
                ),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          restorationScopeId: 'canvas-route-extra-app',
          routerConfig: router,
        ),
      );

      router.push<void>(
        '/daily',
        extra: CanvasEntryIntent.dailyTopic(dailySeed),
      );
      await tester.pumpAndSettle();
      expect(find.text('topic-r3|行业热点|热点摘要'), findsOneWidget);
      router.push<void>('/canvas', extra: CanvasEntryIntent.asset(assetSeed));
      await tester.pumpAndSettle();
      expect(find.text('sprout|$assetMarkdown'), findsOneWidget);

      await tester.restartAndRestore();
      await tester.pumpAndSettle();
      expect(find.text('sprout|$assetMarkdown'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('topic-r3|行业热点|热点摘要'), findsOneWidget);
    });
  });

  testWidgets(
    'exact Chat without purpose or Profile renders a contract failure',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/v3/feed/chat?threadId=thread-without-purpose',
        routes: buildAppRoutes(
          splashBuilder: _placeholder,
          restoreFailedBuilder: _placeholder,
          workspaceRetryBuilder: _placeholder,
        ),
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey<String>(
            'chat-route-failure-missingConversationIdentity',
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('无法打开会话'), findsOneWidget);
      expect(find.text('为避免打开错误会话，本次链接没有被执行。'), findsOneWidget);
    },
  );

  testWidgets('exact Chat rejects a skill that conflicts with its purpose', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation:
          '/v3/feed/chat?threadId=deep-thread&purpose=deep-positioning&skill=video-analysis',
      routes: buildAppRoutes(
        splashBuilder: _placeholder,
        restoreFailedBuilder: _placeholder,
        workspaceRetryBuilder: _placeholder,
      ),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const ValueKey<String>(
          'chat-route-failure-conflictingConversationIdentity',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('会话用途与 Agent 信息不一致，未尝试加载该会话。'), findsOneWidget);
  });

  testWidgets('an unregistered legacy URL is redirected before route failure', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/main/settings/diagnostics',
      redirect: (context, state) => v3LocationForLegacyMainUri(state.uri),
      routes: [
        GoRoute(
          path: '/v3/profile/:section',
          builder: (context, state) =>
              Scaffold(body: Text(state.pathParameters['section'] ?? '')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('诊断'), findsOneWidget);
  });

  testWidgets('legacy positioning report link commits the independent route', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation:
          '/v3/profile/digital-twin?file=social_positioning&focus=report&taskId=agent_run_1',
      routes: buildAppRoutes(
        splashBuilder: _placeholder,
        restoreFailedBuilder: _placeholder,
        workspaceRetryBuilder: _placeholder,
      ),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/v3/workbench/deep-positioning?focus=report&taskId=agent_run_1',
    );
    expect(find.text('社媒定位'), findsOneWidget);
  });
}

Widget _placeholder(BuildContext context, GoRouterState state) =>
    const SizedBox.shrink();
