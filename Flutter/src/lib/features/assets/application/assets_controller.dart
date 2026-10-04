import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/di/database_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../core/api/scoped_read_cache.dart';
import '../../../core/auth/session_store.dart';
import '../data/asset_api.dart'
    show
        AssetApi,
        AssetMarkdownReadLease,
        CancellableAssetApiPort,
        parsePersonalAssetMarkdown;
import '../domain/asset_models.dart';

export '../domain/asset_models.dart';

// resident-provider: Shares one asset api dependency for the full account session.
final assetApiProvider = Provider<AssetApiPort>((ref) {
  return AssetApi(apiClient: ref.watch(apiClientProvider));
});

// resident-provider: Shares one account-scoped assets read cache identity across dependent controllers.
final assetsReadCacheProvider = Provider<ScopedReadCache?>((ref) {
  final session = ref.watch(sessionStoreProvider).state;
  final workspaceId = session.workspace?.workspaceId?.trim();
  final userScope = ref.watch(authenticatedUserDataScopeProvider);
  if (session.authState != SessionAuthState.authenticated ||
      session.workspaceStatus != SessionWorkspaceStatus.ready ||
      workspaceId == null ||
      workspaceId.isEmpty ||
      userScope == 'anonymous') {
    return null;
  }
  return ScopedReadCache(
    dao: ref.watch(appPreferencesDaoProvider),
    userScope: userScope,
    workspaceScope: workspaceId,
    fallbackTtl: ref.watch(appCachePolicyProvider).cacheTtl,
  );
});

// resident-provider: Keeps the assets cache bypass value consistent across sibling route consumers.
/// Kept overridable at the visual runtime boundary so active asset work never
/// paints an otherwise valid five-minute snapshot as current data.
final assetsCacheBypassProvider = Provider<bool>((ref) => false);

// resident-provider: Keeps the assets cache revision value consistent across sibling route consumers.
/// Changes whenever an asset-affecting task changes its visible lifecycle.
/// Controllers capture this value with a GET so an obsolete response cannot
/// undo the cache invalidation that accompanied a newer task revision.
final assetsCacheRevisionProvider = Provider<String>((ref) => '');

// resident-provider: Preserves the assets controller state machine across route transitions.
final assetsControllerProvider = ChangeNotifierProvider<AssetsController>((
  ref,
) {
  return AssetsController(
    api: ref.watch(assetApiProvider),
    cache: ref.watch(assetsReadCacheProvider),
    cacheBypass: () => ref.read(assetsCacheBypassProvider),
    cacheRevision: () => ref.read(assetsCacheRevisionProvider),
  );
});

enum AssetsControllerStatus { idle, loading, ready, syncing, failed }

final class AssetsRequestOwner {
  bool _isActive = true;

  bool get isActive => _isActive;

  void deactivate() => _isActive = false;
}

final class AssetsState {
  const AssetsState({
    required this.status,
    this.document,
    this.lastSyncTask,
    this.errorCode,
  });

  const AssetsState.initial() : this(status: AssetsControllerStatus.idle);

  final AssetsControllerStatus status;
  final PersonalAssetMarkdown? document;
  final AssetSyncTask? lastSyncTask;
  final String? errorCode;

  bool get isLoading => status == AssetsControllerStatus.loading;
  bool get isSyncing => status == AssetsControllerStatus.syncing;
  bool get isRemoteBacked => document != null;
  bool get canRetrySync => document?.retryable ?? false;

  AssetsState copyWith({
    AssetsControllerStatus? status,
    PersonalAssetMarkdown? document,
    AssetSyncTask? lastSyncTask,
    String? errorCode,
    bool clearError = false,
  }) {
    return AssetsState(
      status: status ?? this.status,
      document: document ?? this.document,
      lastSyncTask: lastSyncTask ?? this.lastSyncTask,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
    );
  }
}

final class AssetsController extends ChangeNotifier {
  AssetsController({
    required AssetApiPort api,
    ScopedReadCache? cache,
    bool Function()? cacheBypass,
    String Function()? cacheRevision,
  }) : _api = api,
       _cache = cache,
       _cacheBypass = cacheBypass,
       _cacheRevision = cacheRevision;

  final AssetApiPort _api;
  final ScopedReadCache? _cache;
  final bool Function()? _cacheBypass;
  final String Function()? _cacheRevision;
  SubmissionKeyStore _idempotencyStore = SubmissionKeyStore.empty;
  AssetsState _state = const AssetsState.initial();
  AssetMarkdownReadLease? _pendingMarkdownRead;
  AssetsRequestOwner? _requestOwner;
  int _requestGeneration = 0;
  bool _disposed = false;

  AssetsState get state => _state;

  Future<ApiResult<StructuredAssetDetail>> loadDetail({
    required EditableAssetType assetType,
    required String assetId,
  }) => _api.getAssetDetail(assetType: assetType, assetId: assetId);

  Future<ApiResult<AssetPatchResult>> patchDetail({
    required StructuredAssetDetail detail,
    required EditableAssetPatch patch,
  }) => _api.patchAsset(
    assetType: detail.assetType,
    assetId: detail.assetId,
    baseVersion: detail.baseVersion,
    patch: patch,
    idempotency: IdempotencyRequestContext(
      operation: 'assets.patch',
      businessEntityId: detail.assetId,
      scene: 'assets',
    ),
  );

  Future<void> load({
    AssetMarkdownFocus? focus,
    bool force = false,
    bool invalidateCache = false,
    AssetsRequestOwner? requestOwner,
  }) async {
    if (requestOwner?.isActive == false) return;
    _cancelPendingMarkdownRead();
    final generation = ++_requestGeneration;
    _requestOwner = requestOwner;
    final cacheRevision = _currentCacheRevision();
    if (invalidateCache) invalidateAssetsMarkdownCache(_cache);
    if (!_isCurrentRequest(generation, cacheRevision)) return;
    final cache = _cache;
    final cacheKey = _cacheKeyForFocus(focus);
    PersonalAssetMarkdown? cachedDocument;
    if (!force && !_shouldBypassCache() && cache != null) {
      final freshEntry = cache.readFallback('assetsMarkdown', cacheKey);
      final cachedEntry = freshEntry ?? cache.read('assetsMarkdown', cacheKey);
      if (cachedEntry != null) {
        cachedDocument = parsePersonalAssetMarkdown(cachedEntry.payload);
        if (cachedDocument == null) {
          cache.invalidate('assetsMarkdown', cacheKey);
        } else {
          if (!_isCurrentRequest(generation, cacheRevision)) return;
          _update(
            _state.copyWith(
              status: AssetsControllerStatus.ready,
              document: cachedDocument,
              clearError: true,
            ),
          );
          if (freshEntry != null) return;
        }
      }
    }
    if (!_isCurrentRequest(generation, cacheRevision)) return;
    _update(
      _state.copyWith(
        status: cachedDocument == null
            ? AssetsControllerStatus.loading
            : AssetsControllerStatus.ready,
        clearError: true,
      ),
    );
    final result = await _readMarkdown(focus);
    if (!_isCurrentRequest(generation, cacheRevision)) return;
    if (!result.ok || result.data == null) {
      _update(
        _state.copyWith(
          status: _state.document == null
              ? AssetsControllerStatus.failed
              : AssetsControllerStatus.ready,
          errorCode: result.error?.code ?? 'ASSETS_MARKDOWN_LOAD_FAILED',
        ),
      );
      return;
    }
    _writeCachedDocument(cacheKey, result.data!);
    _update(
      _state.copyWith(
        status: AssetsControllerStatus.ready,
        document: result.data,
        clearError: true,
      ),
    );
  }

  Future<AssetSyncTask?> sync({AssetsRequestOwner? requestOwner}) async {
    if (requestOwner?.isActive == false) return null;
    supersedePendingLoads();
    _requestOwner = requestOwner;
    _update(
      _state.copyWith(status: AssetsControllerStatus.syncing, clearError: true),
    );
    final result = await _api.syncAssets(
      idempotency: const IdempotencyRequestContext(
        operation: 'assets.sync',
        scene: 'assets',
      ),
      idempotencyStore: _idempotencyStore,
    );
    _idempotencyStore = result.idempotencyStore;
    if (_disposed) return null;
    if (!result.ok || result.data == null) {
      _update(
        _state.copyWith(
          status: AssetsControllerStatus.failed,
          errorCode: result.error?.code ?? 'ASSETS_SYNC_FAILED',
        ),
      );
      return null;
    }
    final task = result.data!;
    final currentOwner = _requestOwner;
    final readbackOwner = requestOwner?.isActive == true
        ? requestOwner
        : currentOwner?.isActive == true
        ? currentOwner
        : null;
    final shouldReadback = requestOwner == null || readbackOwner != null;
    supersedePendingLoads();
    invalidateAssetsMarkdownCache(_cache);
    _update(
      _state.copyWith(
        status: AssetsControllerStatus.ready,
        lastSyncTask: task,
        clearError: true,
      ),
    );
    if (!shouldReadback) return task;
    await load(force: true, requestOwner: readbackOwner);
    return task;
  }

  AssetsState buildInitialState() => _state;

  void _update(AssetsState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  /// Invalidates local projections after a confirmed write and prevents any
  /// already-issued GET from restoring an obsolete response.
  void invalidateCachedDocuments() {
    supersedePendingLoads();
    invalidateAssetsMarkdownCache(_cache);
  }

  /// Releases the production GET lease and prevents compatibility transports
  /// from applying a late result after this generation advances.
  void supersedePendingLoads({AssetsRequestOwner? owner}) {
    if (owner != null && !identical(_requestOwner, owner)) return;
    _cancelPendingMarkdownRead();
    _requestGeneration += 1;
    _requestOwner = null;
  }

  void cancelPendingLoadsForOwner(AssetsRequestOwner owner) {
    owner.deactivate();
    supersedePendingLoads(owner: owner);
  }

  Future<ApiResult<PersonalAssetMarkdown>> _readMarkdown(
    AssetMarkdownFocus? focus,
  ) async {
    final api = _api;
    if (api is! CancellableAssetApiPort) {
      return api.getMarkdown(focus: focus);
    }
    final lease = (api as CancellableAssetApiPort).leaseMarkdown(focus: focus);
    _pendingMarkdownRead = lease;
    try {
      return await lease.result;
    } finally {
      if (identical(_pendingMarkdownRead, lease)) {
        _pendingMarkdownRead = null;
      }
    }
  }

  void _cancelPendingMarkdownRead() {
    _pendingMarkdownRead?.cancel();
    _pendingMarkdownRead = null;
  }

  bool _isCurrentRequest(int generation, String cacheRevision) {
    return !_disposed &&
        generation == _requestGeneration &&
        cacheRevision == _currentCacheRevision();
  }

  bool _shouldBypassCache() {
    try {
      return _cacheBypass?.call() ?? false;
    } on Object {
      return false;
    }
  }

  String _currentCacheRevision() {
    try {
      return _cacheRevision?.call() ?? '';
    } on Object {
      return '';
    }
  }

  /// The remote result remains usable when the local read-through cache fails.
  void _writeCachedDocument(String cacheKey, PersonalAssetMarkdown document) {
    try {
      _cache?.write(
        'assetsMarkdown',
        cacheKey,
        etag: null,
        payload: _assetMarkdownCachePayload(document),
      );
    } on Object {
      // Caching is an optimization and must not turn a successful GET into a failure.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    supersedePendingLoads();
    super.dispose();
  }
}

String _cacheKeyForFocus(AssetMarkdownFocus? focus) => focus?.name ?? 'all';

/// Clears only rendered Personal Assets projections in this account/workspace
/// cache. Callers should keep task state and unrelated endpoint data intact.
void invalidateAssetsMarkdownCache(ScopedReadCache? cache) {
  if (cache == null) return;
  try {
    for (final focus in <AssetMarkdownFocus?>[
      null,
      ...AssetMarkdownFocus.values,
    ]) {
      cache.invalidate('assetsMarkdown', _cacheKeyForFocus(focus));
    }
  } on Object {
    // A failed cache invalidation must not turn a completed write into a failure.
  }
}

Map<String, Object?> _assetMarkdownCachePayload(
  PersonalAssetMarkdown document,
) => <String, Object?>{
  'document': <String, Object?>{
    'schemaVersion': 'personal_assets.markdown.v1',
    'documentId': document.documentId,
    'documentVersion': document.documentVersion,
    'locale': 'zh-CN',
    'title': document.title,
    'markdown': document.markdown,
    'renderedAt': document.renderedAt.toUtc().toIso8601String(),
    'allowedMarkdown': const <String>[
      'heading',
      'paragraph',
      'unordered_list',
      'ordered_list',
      'blockquote',
      'table',
      'emphasis',
      'strong',
      'inline_code',
      'code_block',
    ],
    'imagePolicy': 'none',
    'anchors': <Map<String, Object?>>[
      for (final anchor in document.anchors)
        <String, Object?>{
          'anchorId': anchor.anchorId,
          'title': anchor.title,
          'level': anchor.level,
        },
    ],
    'links': <Map<String, Object?>>[
      for (final link in document.links)
        <String, Object?>{
          'linkId': link.linkId,
          'href': link.href,
          'label': link.label,
          'target': _assetMarkdownLinkTargetCachePayload(link.target),
        },
    ],
  },
  'overview': <String, Object?>{
    'recordingCount': document.overview.recordingCount,
    'transcriptWordCount': document.overview.transcriptWordCount,
    'contentLineCount': document.overview.contentLineCount,
    'lifeEventCount': document.overview.lifeEventCount,
    'expressionCount': document.overview.expressionCount,
    'syncStatus': _assetSyncStatusWire(document.overview.syncStatus),
    if (document.overview.latestUpdatedAt != null)
      'latestUpdatedAt': document.overview.latestUpdatedAt!
          .toUtc()
          .toIso8601String(),
  },
  'contentLines': <Map<String, Object?>>[
    for (final line in document.contentLines)
      <String, Object?>{
        'contentLineId': line.contentLineId,
        'name': line.name,
        if (line.industry != null) 'industry': line.industry,
      },
  ],
  'sync': <String, Object?>{
    'status': _assetSyncStatusWire(document.syncStatus),
    'stale': document.stale,
    'retryable': document.retryable,
    if (document.latestUpdatedAt != null)
      'latestUpdatedAt': document.latestUpdatedAt!.toUtc().toIso8601String(),
    if (document.latestSyncTaskId != null)
      'latestSyncTaskId': document.latestSyncTaskId,
  },
};

Map<String, Object?> _assetMarkdownLinkTargetCachePayload(
  AssetMarkdownLinkTarget target,
) => switch (target.type) {
  AssetMarkdownLinkTargetType.markdownAnchor => <String, Object?>{
    'type': 'markdown_anchor',
    'anchorId': target.anchorId,
  },
  AssetMarkdownLinkTargetType.recordingDetail => <String, Object?>{
    'type': 'recording_detail',
    'recordingId': target.recordingId,
  },
  AssetMarkdownLinkTargetType.contentLineDetail => <String, Object?>{
    'type': 'content_line_detail',
    'contentLineId': target.contentLineId,
  },
  AssetMarkdownLinkTargetType.assetPage => <String, Object?>{
    'type': 'asset_page',
    if (target.focus != null) 'focus': _assetFocusWire(target.focus!),
  },
};

String _assetFocusWire(AssetMarkdownFocus focus) => switch (focus) {
  AssetMarkdownFocus.overview => 'overview',
  AssetMarkdownFocus.contentLine => 'content_line',
  AssetMarkdownFocus.recording => 'recording',
  AssetMarkdownFocus.profile => 'profile',
};

String _assetSyncStatusWire(AssetSyncStatus status) => switch (status) {
  AssetSyncStatus.normal => 'normal',
  AssetSyncStatus.syncing => 'syncing',
  AssetSyncStatus.syncFailed => 'sync_failed',
  AssetSyncStatus.empty => 'empty',
};
