import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/bootstrap/asset_projection_cache_scope.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/api/scoped_read_cache.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/assets/application/assets_controller.dart';
import 'package:huahuoai_app/features/assets/data/asset_api.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_assets_page.dart';

void main() {
  testWidgets(
    'V3 assets page loads the server document and starts asset sync',
    (tester) async {
      final api = _WidgetAssetApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            assetApiProvider.overrideWithValue(api),
            assetProjectionFreshnessProvider.overrideWithValue(
              const AssetProjectionFreshness(
                hasActiveWork: false,
                revision: 'idle',
              ),
            ),
          ],
          child: const MaterialApp(
            home: V3AssetsPage(focus: AssetMarkdownFocus.profile),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(api.focuses, <AssetMarkdownFocus?>[AssetMarkdownFocus.profile]);
      expect(find.text('Personal assets'), findsOneWidget);
      expect(find.text('Retail voice'), findsOneWidget);

      await tester.tap(find.byTooltip('资产操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同步资产'));
      await tester.pump();
      await tester.pump();

      expect(api.syncCalls, 1);
      expect(api.focuses, <AssetMarkdownFocus?>[
        AssetMarkdownFocus.profile,
        null,
      ]);
    },
  );

  testWidgets('V3 structured asset page submits a versioned editable patch', (
    tester,
  ) async {
    final api = _WidgetAssetApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[assetApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
          home: V3StructuredAssetDetailPage(
            assetType: EditableAssetType.contentLine,
            assetId: 'line-1',
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    expect(find.text('Retail voice'), findsOneWidget);

    await tester.tap(find.byTooltip('编辑资产'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'Updated retail voice',
    );
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump();

    expect(api.patchCalls, 1);
    expect(api.lastPatch?.fields['name'], 'Updated retail voice');
    expect(api.lastBaseVersion, 3);
    expect(api.lastIdempotency?.operation, 'assets.patch');
  });

  testWidgets('structured asset editor keeps save above a compact keyboard', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final api = _WidgetAssetApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[assetApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const V3StructuredAssetDetailPage(
            assetType: EditableAssetType.contentLine,
            assetId: 'line-1',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('编辑资产'));
    await tester.pumpAndSettle();
    final input = find.byType(TextField).first;
    await tester.tap(input);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();

    final scroll = find.byKey(const ValueKey('structured-asset-edit-scroll'));
    final save = find.widgetWithText(FilledButton, '保存');
    expect(scroll, findsOneWidget);
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(328));
    expect(tester.takeException(), isNull);

    await tester.enterText(input, 'Compact retail voice');
    await tester.tap(save);
    await tester.pump();
    await tester.pump();
    expect(api.patchCalls, 1);
    expect(api.lastPatch?.fields['name'], 'Compact retail voice');
  });

  testWidgets('visible assets reload after an asset-task revision', (
    tester,
  ) async {
    final api = _WidgetAssetApi();
    final cache = ScopedReadCache(
      dao: AppPreferencesDao(AppDatabase()),
      userScope: 'widget-assets-cache-user',
      workspaceScope: 'widget-assets-cache-workspace',
      now: () => DateTime.utc(2026, 8, 19, 8),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          assetApiProvider.overrideWithValue(api),
          assetsReadCacheProvider.overrideWithValue(cache),
          assetProjectionFreshnessProvider.overrideWith(
            (ref) => ref.watch(_assetFreshnessStateProvider),
          ),
        ],
        child: const AssetProjectionCacheScope(
          child: MaterialApp(
            home: V3AssetsPage(focus: AssetMarkdownFocus.profile),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    expect(api.focuses, <AssetMarkdownFocus?>[AssetMarkdownFocus.profile]);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(V3AssetsPage)),
    );
    container
        .read(_assetFreshnessStateProvider.notifier)
        .state = const AssetProjectionFreshness(
      hasActiveWork: true,
      revision: 'recording-run-1:processing',
    );
    await tester.pump();
    await tester.pump();

    expect(api.focuses, <AssetMarkdownFocus?>[
      AssetMarkdownFocus.profile,
      AssetMarkdownFocus.profile,
    ]);
  });

  testWidgets('live asset polling requires foreground current route', (
    tester,
  ) async {
    final api = _WidgetAssetApi();
    final activity = AppActivityCoordinator(binding: tester.binding);
    activity.updateLifecycle(AppLifecycleState.resumed);
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(activity.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          assetApiProvider.overrideWithValue(api),
          assetProjectionFreshnessProvider.overrideWithValue(
            const AssetProjectionFreshness(
              hasActiveWork: true,
              revision: 'asset-run:processing',
            ),
          ),
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: <NavigatorObserver>[appRouteObserver],
          home: const V3AssetsPage(focus: AssetMarkdownFocus.profile),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(api.focuses, <AssetMarkdownFocus?>[AssetMarkdownFocus.profile]);

    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    expect(api.focuses, hasLength(1));

    activity.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(api.focuses, hasLength(2));

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covering-route')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 11));
    expect(api.focuses, hasLength(2));

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(api.focuses, hasLength(3));
  });

  testWidgets('covering the assets route cancels its active document read', (
    tester,
  ) async {
    final api = _WidgetAssetApi()..deferMarkdown = true;
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          assetApiProvider.overrideWithValue(api),
          assetProjectionFreshnessProvider.overrideWithValue(
            const AssetProjectionFreshness(
              hasActiveWork: false,
              revision: 'idle',
            ),
          ),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: <NavigatorObserver>[appRouteObserver],
          home: const V3AssetsPage(focus: AssetMarkdownFocus.profile),
        ),
      ),
    );
    await tester.pump();
    expect(api.pendingMarkdown, hasLength(1));

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covering-route')),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.cancelledMarkdownReads, 1);
    api.pendingMarkdown.single.complete(_markdownResult('Late assets'));
    await tester.pump();
  });

  testWidgets('covering the route cancels only an accepted sync readback', (
    tester,
  ) async {
    final api = _WidgetAssetApi();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          assetApiProvider.overrideWithValue(api),
          assetProjectionFreshnessProvider.overrideWithValue(
            const AssetProjectionFreshness(
              hasActiveWork: false,
              revision: 'idle',
            ),
          ),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: <NavigatorObserver>[appRouteObserver],
          home: const V3AssetsPage(focus: AssetMarkdownFocus.profile),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    api.deferMarkdown = true;

    await tester.tap(find.byTooltip('资产操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步资产'));
    await tester.pump();
    await tester.pump();
    expect(api.syncCalls, 1);
    expect(api.pendingMarkdown, hasLength(1));

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covering-route')),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.cancelledMarkdownReads, 1);
    api.pendingMarkdown.single.complete(_markdownResult('Late sync readback'));
    await tester.pump();
  });

  testWidgets(
    'task completion queues an authoritative assets refresh after a pending read',
    (tester) async {
      final api = _WidgetAssetApi()..deferMarkdown = true;
      final cache = ScopedReadCache(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'widget-assets-race-user',
        workspaceScope: 'widget-assets-race-workspace',
        now: () => DateTime.utc(2026, 8, 19, 8),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            assetApiProvider.overrideWithValue(api),
            assetsReadCacheProvider.overrideWithValue(cache),
            assetProjectionFreshnessProvider.overrideWith(
              (ref) => ref.watch(_assetFreshnessStateProvider),
            ),
          ],
          child: const AssetProjectionCacheScope(
            child: MaterialApp(
              home: V3AssetsPage(focus: AssetMarkdownFocus.profile),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(api.pendingMarkdown, hasLength(1));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(V3AssetsPage)),
      );
      final freshness = container.read(_assetFreshnessStateProvider.notifier);
      freshness.state = const AssetProjectionFreshness(
        hasActiveWork: true,
        revision: 'recording-run-2:processing',
      );
      await tester.pump();
      freshness.state = const AssetProjectionFreshness(
        hasActiveWork: false,
        revision: 'recording-run-2:completed',
      );
      await tester.pump();

      api.pendingMarkdown[0].complete(_markdownResult('Obsolete assets'));
      await tester.pump();
      await tester.pump();

      expect(api.pendingMarkdown, hasLength(2));
      expect(find.text('Obsolete assets'), findsNothing);
      expect(cache.read('assetsMarkdown', 'profile'), isNull);

      api.pendingMarkdown[1].complete(_markdownResult('Current assets'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Current assets'), findsOneWidget);
      expect(cache.read('assetsMarkdown', 'profile'), isNotNull);
    },
  );

  testWidgets(
    'a mounted assets page loads its replacement controller after a workspace switch',
    (tester) async {
      final api = _WidgetAssetApi();
      final firstCache = _cacheForWorkspace('widget-workspace-a');
      final secondCache = _cacheForWorkspace('widget-workspace-b');
      final session =
          SessionStore(
            secureTokenStore: SecureTokenStore(
              driver: _NoopSecureTokenDriver(),
            ),
          )..refreshUserStatus(
            status: const SessionUserStatus(
              user: SessionUser(
                userId: 'widget-workspace-user',
                maskedPhoneNumber: '138****8000',
              ),
              workspace: SessionWorkspace(
                status: SessionWorkspaceStatus.ready,
                workspaceId: 'widget-workspace-a',
              ),
            ),
            updatedAt: DateTime.utc(2026, 8, 19, 8),
          );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            assetProjectionFreshnessProvider.overrideWithValue(
              const AssetProjectionFreshness(
                hasActiveWork: false,
                revision: 'idle',
              ),
            ),
            sessionStoreProvider.overrideWith((ref) => session),
            assetApiProvider.overrideWithValue(api),
            assetsReadCacheProvider.overrideWith((ref) {
              final workspaceId = ref
                  .watch(sessionStoreProvider)
                  .state
                  .workspace
                  ?.workspaceId;
              return workspaceId == 'widget-workspace-b'
                  ? secondCache
                  : firstCache;
            }),
          ],
          child: const MaterialApp(
            home: V3AssetsPage(focus: AssetMarkdownFocus.profile),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(V3AssetsPage)),
      );
      final firstController = container.read(assetsControllerProvider);
      expect(api.focuses, <AssetMarkdownFocus?>[AssetMarkdownFocus.profile]);

      session.refreshUserStatus(
        status: const SessionUserStatus(
          user: SessionUser(
            userId: 'widget-workspace-user',
            maskedPhoneNumber: '138****8000',
          ),
          workspace: SessionWorkspace(
            status: SessionWorkspaceStatus.ready,
            workspaceId: 'widget-workspace-b',
          ),
        ),
        updatedAt: DateTime.utc(2026, 8, 19, 8, 1),
      );
      await tester.pump();
      await tester.pump();

      final currentController = container.read(assetsControllerProvider);
      expect(identical(currentController, firstController), isFalse);
      expect(api.focuses, <AssetMarkdownFocus?>[
        AssetMarkdownFocus.profile,
        AssetMarkdownFocus.profile,
      ]);
      expect(currentController.state.status, AssetsControllerStatus.ready);
    },
  );
}

final _assetFreshnessStateProvider = StateProvider<AssetProjectionFreshness>(
  (ref) =>
      const AssetProjectionFreshness(hasActiveWork: false, revision: 'idle'),
);

final class _WidgetAssetApi implements AssetApiPort, CancellableAssetApiPort {
  final focuses = <AssetMarkdownFocus?>[];
  final pendingMarkdown = <Completer<ApiResult<PersonalAssetMarkdown>>>[];
  bool deferMarkdown = false;
  int cancelledMarkdownReads = 0;
  int syncCalls = 0;
  int patchCalls = 0;
  int? lastBaseVersion;
  EditableAssetPatch? lastPatch;
  IdempotencyRequestContext? lastIdempotency;
  StructuredAssetDetail _detail = _structuredDetail();

  @override
  AssetMarkdownReadLease leaseMarkdown({AssetMarkdownFocus? focus}) {
    return AssetMarkdownReadLease(
      result: getMarkdown(focus: focus),
      cancel: () => cancelledMarkdownReads += 1,
    );
  }

  @override
  Future<ApiResult<StructuredAssetDetail>> getAssetDetail({
    required EditableAssetType assetType,
    required String assetId,
  }) async {
    return ApiResult<StructuredAssetDetail>.success(
      data: _detail,
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AssetPatchResult>> patchAsset({
    required EditableAssetType assetType,
    required String assetId,
    required int baseVersion,
    required EditableAssetPatch patch,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    patchCalls += 1;
    lastBaseVersion = baseVersion;
    lastPatch = patch;
    lastIdempotency = idempotency;
    final nextAsset = <String, Object?>{..._detail.asset, ...patch.fields};
    _detail = StructuredAssetDetail(
      assetType: _detail.assetType,
      assetId: _detail.assetId,
      asset: nextAsset,
      editable: true,
      baseVersion: baseVersion + 1,
      sourceReferences: _detail.sourceReferences,
      updatedAt: DateTime.utc(2026, 7, 10, 1),
    );
    return ApiResult<AssetPatchResult>.success(
      data: AssetPatchResult(
        assetType: assetType,
        assetId: assetId,
        newVersion: baseVersion + 1,
        asset: nextAsset,
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }

  @override
  Future<ApiResult<PersonalAssetMarkdown>> getMarkdown({
    AssetMarkdownFocus? focus,
  }) async {
    focuses.add(focus);
    if (deferMarkdown) {
      final completion = Completer<ApiResult<PersonalAssetMarkdown>>();
      pendingMarkdown.add(completion);
      return completion.future;
    }
    return ApiResult<PersonalAssetMarkdown>.success(
      data: _document(),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AssetSyncTask>> syncAssets({
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    syncCalls += 1;
    return ApiResult<AssetSyncTask>.success(
      data: const AssetSyncTask(taskId: 'asset-task-1', status: 'queued'),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }
}

StructuredAssetDetail _structuredDetail() {
  return StructuredAssetDetail(
    assetType: EditableAssetType.contentLine,
    assetId: 'line-1',
    asset: const <String, Object?>{
      'name': 'Retail voice',
      'industry': 'Retail',
      'tags': <String>['retail'],
    },
    editable: true,
    baseVersion: 3,
    sourceReferences: const <AssetSourceReference>[],
    updatedAt: DateTime.utc(2026, 7, 10),
  );
}

ApiResult<PersonalAssetMarkdown> _markdownResult(String title) {
  return ApiResult<PersonalAssetMarkdown>.success(
    data: _document(title: title),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

ScopedReadCache _cacheForWorkspace(String workspaceId) {
  return ScopedReadCache(
    dao: AppPreferencesDao(AppDatabase()),
    userScope: 'widget-workspace-user',
    workspaceScope: workspaceId,
    now: () => DateTime.utc(2026, 8, 19, 8),
  );
}

final class _NoopSecureTokenDriver implements SecureTokenDriver {
  @override
  SecureTokenCredential? read({required String service}) => null;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) => true;

  @override
  bool clear({required String service}) => true;
}

PersonalAssetMarkdown _document({String title = 'Personal assets'}) {
  return PersonalAssetMarkdown(
    documentId: 'document-1',
    documentVersion: 1,
    title: title,
    markdown: '# Overview\nSafe text',
    renderedAt: DateTime.utc(2026, 7, 10),
    anchors: const <AssetMarkdownAnchor>[
      AssetMarkdownAnchor(anchorId: 'overview', title: 'Overview', level: 1),
    ],
    links: const <AssetMarkdownLink>[],
    overview: const AssetOverviewSummary(
      recordingCount: 2,
      transcriptWordCount: 20,
      contentLineCount: 1,
      lifeEventCount: 0,
      expressionCount: 0,
      syncStatus: AssetSyncStatus.normal,
    ),
    contentLines: const <AssetContentLineBrief>[
      AssetContentLineBrief(contentLineId: 'line-1', name: 'Retail voice'),
    ],
    syncStatus: AssetSyncStatus.normal,
    stale: false,
    retryable: false,
  );
}
