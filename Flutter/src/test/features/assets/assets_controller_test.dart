import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/api/scoped_read_cache.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/assets/application/assets_controller.dart';
import 'package:huahuoai_app/features/assets/data/asset_api.dart';

void main() {
  test(
    'AssetsController preserves the server document and refreshes after sync',
    () async {
      final api = _AssetApi();
      final controller = AssetsController(api: api);

      await controller.load(focus: AssetMarkdownFocus.profile);
      final task = await controller.sync();

      expect(api.requestedFocuses, <AssetMarkdownFocus?>[
        AssetMarkdownFocus.profile,
        null,
      ]);
      expect(task?.taskId, 'asset-task-1');
      expect(controller.state.document?.title, 'Personal assets');
      expect(controller.state.lastSyncTask?.status, 'queued');
      expect(controller.state.errorCode, isNull);
    },
  );

  test(
    'uses a scoped assets cache until refresh or sync invalidates it',
    () async {
      final api = _AssetApi();
      final cache = ScopedReadCache(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'asset-cache-user',
        workspaceScope: 'asset-cache-workspace',
        now: () => DateTime.utc(2026, 8, 19, 8),
      );
      final first = AssetsController(api: api, cache: cache);

      await first.load(focus: AssetMarkdownFocus.profile);
      final restored = AssetsController(api: api, cache: cache);
      await restored.load(focus: AssetMarkdownFocus.profile);
      await restored.load(focus: AssetMarkdownFocus.profile, force: true);
      await restored.sync();
      final afterSync = AssetsController(api: api, cache: cache);
      await afterSync.load(focus: AssetMarkdownFocus.profile);

      expect(api.requestedFocuses, <AssetMarkdownFocus?>[
        AssetMarkdownFocus.profile,
        AssetMarkdownFocus.profile,
        null,
        AssetMarkdownFocus.profile,
      ]);
      expect(afterSync.state.document?.title, 'Personal assets');
    },
  );

  test('live asset work bypasses a fresh scoped assets cache', () async {
    final api = _AssetApi();
    final cache = ScopedReadCache(
      dao: AppPreferencesDao(AppDatabase()),
      userScope: 'asset-live-cache-user',
      workspaceScope: 'asset-live-cache-workspace',
      now: () => DateTime.utc(2026, 8, 19, 8),
    );
    final first = AssetsController(api: api, cache: cache);
    await first.load(focus: AssetMarkdownFocus.profile);

    final live = AssetsController(
      api: api,
      cache: cache,
      cacheBypass: () => true,
    );
    await live.load(focus: AssetMarkdownFocus.profile);

    expect(api.requestedFocuses, <AssetMarkdownFocus?>[
      AssetMarkdownFocus.profile,
      AssetMarkdownFocus.profile,
    ]);
    expect(live.state.document?.title, 'Personal assets');
  });

  test(
    'an explicit refresh failure invalidates the scoped assets snapshot',
    () async {
      final api = _AssetApi();
      final cache = ScopedReadCache(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'asset-refresh-cache-user',
        workspaceScope: 'asset-refresh-cache-workspace',
        now: () => DateTime.utc(2026, 8, 19, 8),
      );
      final first = AssetsController(api: api, cache: cache);
      await first.load(focus: AssetMarkdownFocus.profile);

      api.failMarkdown = true;
      await first.load(
        focus: AssetMarkdownFocus.profile,
        force: true,
        invalidateCache: true,
      );

      final restored = AssetsController(api: api, cache: cache);
      await restored.load(focus: AssetMarkdownFocus.profile);

      expect(api.requestedFocuses, <AssetMarkdownFocus?>[
        AssetMarkdownFocus.profile,
        AssetMarkdownFocus.profile,
        AssetMarkdownFocus.profile,
      ]);
      expect(restored.state.status, AssetsControllerStatus.failed);
      expect(restored.state.document, isNull);
    },
  );

  test(
    'a newer invalidating assets refresh drops an older response and cache write',
    () async {
      final api = _AssetApi()..deferMarkdown = true;
      final cache = ScopedReadCache(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'asset-race-cache-user',
        workspaceScope: 'asset-race-cache-workspace',
        now: () => DateTime.utc(2026, 8, 19, 8),
      );
      var revision = 'recording:processing';
      final controller = AssetsController(
        api: api,
        cache: cache,
        cacheRevision: () => revision,
      );

      final older = controller.load(focus: AssetMarkdownFocus.profile);
      expect(api.pendingMarkdown, hasLength(1));

      revision = 'recording:completed';
      final newest = controller.load(
        focus: AssetMarkdownFocus.profile,
        force: true,
        invalidateCache: true,
      );
      expect(api.pendingMarkdown, hasLength(2));
      expect(api.cancelledMarkdownReads, 1);

      api.pendingMarkdown[0].complete(
        ApiResult<PersonalAssetMarkdown>.success(
          data: _document(title: 'Obsolete assets'),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      await older;

      expect(controller.state.document, isNull);
      expect(cache.read('assetsMarkdown', 'profile'), isNull);

      api.pendingMarkdown[1].complete(
        ApiResult<PersonalAssetMarkdown>.success(
          data: _document(title: 'Current assets'),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      await newest;

      expect(controller.state.document?.title, 'Current assets');
      final restored = AssetsController(api: api, cache: cache);
      await restored.load(focus: AssetMarkdownFocus.profile);
      expect(restored.state.document?.title, 'Current assets');
      expect(api.requestedFocuses, <AssetMarkdownFocus?>[
        AssetMarkdownFocus.profile,
        AssetMarkdownFocus.profile,
      ]);
    },
  );

  test('dispose releases an active rendered-markdown GET lease', () async {
    final api = _AssetApi()..deferMarkdown = true;
    final controller = AssetsController(api: api);

    final pending = controller.load(focus: AssetMarkdownFocus.profile);
    expect(api.pendingMarkdown, hasLength(1));

    controller.dispose();
    expect(api.cancelledMarkdownReads, 1);

    api.pendingMarkdown.single.complete(
      ApiResult<PersonalAssetMarkdown>.success(
        data: _document(title: 'Late assets'),
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      ),
    );
    await pending;
    expect(controller.state.document, isNull);
  });

  test('an outgoing owner cannot cancel a newer owner read', () async {
    final api = _AssetApi()..deferMarkdown = true;
    final controller = AssetsController(api: api);
    final outgoingOwner = AssetsRequestOwner();
    final currentOwner = AssetsRequestOwner();

    final outgoing = controller.load(
      focus: AssetMarkdownFocus.profile,
      requestOwner: outgoingOwner,
    );
    final current = controller.load(
      focus: AssetMarkdownFocus.overview,
      requestOwner: currentOwner,
    );
    expect(api.pendingMarkdown, hasLength(2));
    expect(api.cancelledMarkdownReads, 1);

    controller.cancelPendingLoadsForOwner(outgoingOwner);
    expect(api.cancelledMarkdownReads, 1);

    api.pendingMarkdown[0].complete(
      ApiResult<PersonalAssetMarkdown>.success(
        data: _document(title: 'Outgoing assets'),
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      ),
    );
    api.pendingMarkdown[1].complete(
      ApiResult<PersonalAssetMarkdown>.success(
        data: _document(title: 'Current assets'),
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      ),
    );
    await Future.wait(<Future<void>>[outgoing, current]);

    expect(controller.state.document?.title, 'Current assets');
  });

  test(
    'sync owner cancellation retains task but cancels its GET readback',
    () async {
      final api = _AssetApi()..deferMarkdown = true;
      final controller = AssetsController(api: api);
      final owner = AssetsRequestOwner();

      final sync = controller.sync(requestOwner: owner);
      await Future<void>.delayed(Duration.zero);
      expect(api.pendingMarkdown, hasLength(1));

      controller.cancelPendingLoadsForOwner(owner);
      expect(api.cancelledMarkdownReads, 1);
      api.pendingMarkdown.single.complete(
        ApiResult<PersonalAssetMarkdown>.success(
          data: _document(title: 'Late sync readback'),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );

      final task = await sync;
      expect(task?.taskId, 'asset-task-1');
      expect(controller.state.lastSyncTask?.taskId, 'asset-task-1');
      expect(controller.state.document, isNull);
    },
  );

  test(
    'accepted sync invalidates a GET started while its POST was pending',
    () async {
      final api = _AssetApi()
        ..deferMarkdown = true
        ..deferSync = true;
      final cache = ScopedReadCache(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'asset-sync-race-user',
        workspaceScope: 'asset-sync-race-workspace',
        now: () => DateTime.utc(2026, 8, 31, 8),
      );
      final controller = AssetsController(api: api, cache: cache);
      final owner = AssetsRequestOwner();

      final sync = controller.sync(requestOwner: owner);
      await Future<void>.delayed(Duration.zero);
      final staleRead = controller.load(
        focus: AssetMarkdownFocus.profile,
        force: true,
        requestOwner: owner,
      );
      expect(api.pendingMarkdown, hasLength(1));

      api.pendingSync!.complete(_successfulSyncResult());
      await Future<void>.delayed(Duration.zero);
      expect(api.cancelledMarkdownReads, 1);
      expect(api.pendingMarkdown, hasLength(2));

      api.pendingMarkdown[0].complete(
        ApiResult<PersonalAssetMarkdown>.success(
          data: _document(title: 'Pre-acceptance assets'),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      await staleRead;
      expect(controller.state.document, isNull);
      expect(cache.read('assetsMarkdown', 'profile'), isNull);

      api.pendingMarkdown[1].complete(
        ApiResult<PersonalAssetMarkdown>.success(
          data: _document(title: 'Authoritative assets'),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      expect((await sync)?.taskId, 'asset-task-1');
      expect(controller.state.document?.title, 'Authoritative assets');
      final cached = cache.read('assetsMarkdown', 'all');
      expect(
        cached?.payload['document'],
        containsPair('title', 'Authoritative assets'),
      );
    },
  );

  test(
    'accepted sync hands authoritative readback to the active owner',
    () async {
      final api = _AssetApi()
        ..deferMarkdown = true
        ..deferSync = true;
      final controller = AssetsController(api: api);
      final syncOwner = AssetsRequestOwner();
      final activeOwner = AssetsRequestOwner();

      final sync = controller.sync(requestOwner: syncOwner);
      await Future<void>.delayed(Duration.zero);
      controller.cancelPendingLoadsForOwner(syncOwner);
      final preAcceptanceRead = controller.load(
        focus: AssetMarkdownFocus.profile,
        force: true,
        requestOwner: activeOwner,
      );
      expect(api.pendingMarkdown, hasLength(1));

      api.pendingSync!.complete(_successfulSyncResult());
      await Future<void>.delayed(Duration.zero);
      expect(api.cancelledMarkdownReads, 1);
      expect(api.pendingMarkdown, hasLength(2));

      api.pendingMarkdown[0].complete(
        ApiResult<PersonalAssetMarkdown>.success(
          data: _document(title: 'Pre-acceptance owner B assets'),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      await preAcceptanceRead;
      expect(controller.state.document, isNull);

      api.pendingMarkdown[1].complete(
        ApiResult<PersonalAssetMarkdown>.success(
          data: _document(title: 'Authoritative owner B assets'),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      expect((await sync)?.taskId, 'asset-task-1');
      expect(controller.state.document?.title, 'Authoritative owner B assets');
    },
  );
}

final class _AssetApi implements AssetApiPort, CancellableAssetApiPort {
  final requestedFocuses = <AssetMarkdownFocus?>[];
  final pendingMarkdown = <Completer<ApiResult<PersonalAssetMarkdown>>>[];
  int cancelledMarkdownReads = 0;
  bool deferMarkdown = false;
  bool deferSync = false;
  bool failMarkdown = false;
  Completer<ApiResult<AssetSyncTask>>? pendingSync;

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
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<AssetPatchResult>> patchAsset({
    required EditableAssetType assetType,
    required String assetId,
    required int baseVersion,
    required EditableAssetPatch patch,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<PersonalAssetMarkdown>> getMarkdown({
    AssetMarkdownFocus? focus,
  }) async {
    requestedFocuses.add(focus);
    if (deferMarkdown) {
      final pending = Completer<ApiResult<PersonalAssetMarkdown>>();
      pendingMarkdown.add(pending);
      return pending.future;
    }
    if (failMarkdown) {
      return ApiResult<PersonalAssetMarkdown>.failure(
        error: const AppFailure(
          code: 'ASSETS_MARKDOWN_LOAD_FAILED',
          category: AppFailureCategory.api,
          message: 'failed',
          userMessageKey: 'assets.load.failed',
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
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
    if (deferSync) {
      final pending = Completer<ApiResult<AssetSyncTask>>();
      pendingSync = pending;
      return pending.future;
    }
    return _successfulSyncResult(idempotencyStore: idempotencyStore);
  }
}

ApiResult<AssetSyncTask> _successfulSyncResult({
  SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
}) {
  return ApiResult<AssetSyncTask>.success(
    data: const AssetSyncTask(taskId: 'asset-task-1', status: 'queued'),
    status: 200,
    idempotencyStore: idempotencyStore,
  );
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
    contentLines: const <AssetContentLineBrief>[],
    syncStatus: AssetSyncStatus.normal,
    stale: false,
    retryable: false,
  );
}
