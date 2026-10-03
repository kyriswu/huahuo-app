import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../data/hotspot_note_repository.dart';
import '../data/knowledge_library_cache.dart';
import '../data/knowledge_user_metadata_repository.dart';
import '../data/ui_v3_mock_data.dart';
import '../data/v3_deposit_repository.dart';
import '../data/workspace_content_sync.dart';
import '../data/workspace_content_sync_store.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';
import '../domain/knowledge_trash_models.dart';
import '../domain/v3_deposit_models.dart';
import 'knowledge_library_query_controller.dart';
import 'knowledge_note_sync_service.dart';
import 'knowledge_note_port.dart';
import 'knowledge_library_runtime.dart';
import 'knowledge_subscription_controller.dart';
import 'subscription_port.dart';
import 'workspace_folder_port.dart';

export 'knowledge_library_runtime.dart';

bool _sameDerivedRefreshSnapshot(V3FeedItem left, V3FeedItem right) {
  final leftReport = left.sproutReport;
  final rightReport = right.sproutReport;
  final sameReport = leftReport == null || rightReport == null
      ? leftReport == rightReport
      : leftReport.id == rightReport.id &&
            leftReport.noteId == rightReport.noteId &&
            leftReport.title == rightReport.title &&
            leftReport.markdown == rightReport.markdown &&
            leftReport.generatedAt == rightReport.generatedAt;
  if (!sameReport ||
      left.syncState != right.syncState ||
      left.remoteNoteId != right.remoteNoteId ||
      left.remoteSourceKind != right.remoteSourceKind ||
      left.noteRevisionId != right.noteRevisionId ||
      left.rawPartRevisionId != right.rawPartRevisionId ||
      left.outlinePartRevisionId != right.outlinePartRevisionId ||
      left.germinationPartRevisionId != right.germinationPartRevisionId ||
      left.etag != right.etag ||
      left.contentCursor != right.contentCursor ||
      left.summaryBody != right.summaryBody ||
      left.summaryError != right.summaryError ||
      left.minutesStatus != right.minutesStatus ||
      left.summaryStatus != right.summaryStatus ||
      left.sproutStatus != right.sproutStatus ||
      left.sproutError != right.sproutError ||
      left.sproutTopic != right.sproutTopic ||
      left.activeDerivedTasksAuthoritative !=
          right.activeDerivedTasksAuthoritative ||
      left.activeDerivedTasks.length != right.activeDerivedTasks.length) {
    return false;
  }
  for (var index = 0; index < left.activeDerivedTasks.length; index += 1) {
    final a = left.activeDerivedTasks[index];
    final b = right.activeDerivedTasks[index];
    if (a.fileAgentRunId != b.fileAgentRunId ||
        a.agentRunId != b.agentRunId ||
        a.stage != b.stage ||
        a.status != b.status) {
      return false;
    }
  }
  return true;
}

typedef WorkspaceContentSyncFactory =
    WorkspaceContentSync? Function(KnowledgeLibraryController controller);

// resident-provider: Keeps account-scoped Workspace synchronization wiring stable across sibling routes.
final workspaceContentSyncFactoryProvider =
    Provider<WorkspaceContentSyncFactory>(
      (ref) =>
          (_) => null,
    );

// resident-provider: Shares one durable Knowledge sync journal identity for the full account session.
final knowledgeNoteSyncJournalProvider = Provider<KnowledgeNoteSyncJournal?>(
  (ref) => null,
);

// Account-lived: this controller owns sync, conflict recovery, and persistence
// queues across route transitions.
// resident-provider: Preserves the account Knowledge facade and its persistence queues across route transitions.
final knowledgeLibraryControllerProvider =
    ChangeNotifierProvider<KnowledgeLibraryController>((ref) {
      final cacheScope = ref.watch(knowledgeLibraryCacheScopeProvider);
      final controller = KnowledgeLibraryController(
        hotspotRepository: ref.read(hotspotNoteRepositoryProvider),
        cache: ApplicationSupportKnowledgeLibraryCache(scopeId: cacheScope),
        userMetadataRepository: ref.watch(
          knowledgeUserMetadataRepositoryProvider,
        ),
        notePort: ref.watch(knowledgeNotePortProvider),
        subscriptionPort: ref.watch(mobileSubscriptionPortProvider),
        depositRepository: ref.watch(knowledgeDepositRepositoryProvider),
        workspaceFolderPort: ref.watch(workspaceFolderPortProvider),
        trashRepository: ref.watch(knowledgeTrashRepositoryProvider),
        noteSyncJournal: ref.watch(knowledgeNoteSyncJournalProvider),
        includeDemoFixtures: ref.watch(
          knowledgeLibraryDemoFixturesEnabledProvider,
        ),
        autoSyncOwnedChanges: ref.watch(
          knowledgeLibraryAutoSyncOwnedChangesProvider,
        ),
        remoteCacheTtlResolver: ref.watch(
          knowledgeLibraryRemoteCacheTtlProvider,
        ),
      );
      final workspaceContentSync = ref.watch(
        workspaceContentSyncFactoryProvider,
      )(controller);
      if (workspaceContentSync != null) {
        controller.attachWorkspaceContentSync(workspaceContentSync);
      }
      unawaited(controller.initialize());
      return controller;
    });

// resident-provider: Keeps command consumers bound to the same account Knowledge facade across sibling routes.
/// Command-side dependency without a broad mutable-state subscription.
final knowledgeLibraryCommandsProvider = Provider<KnowledgeLibraryController>(
  (ref) => ref.watch(knowledgeLibraryControllerProvider.notifier),
);

final knowledgeNoteIndexProvider =
    Provider.autoDispose<KnowledgeNoteIndexSnapshot>((ref) {
      return ref.watch(
        knowledgeLibraryControllerProvider.select(
          (controller) => controller.noteIndexSnapshot,
        ),
      );
    });

final knowledgeNoteProvider = Provider.autoDispose.family<V3FeedItem?, String>((
  ref,
  noteId,
) {
  final normalized = noteId.trim();
  if (normalized.isEmpty) return null;
  return ref.watch(
    knowledgeLibraryControllerProvider.select(
      (controller) => controller.noteForId(normalized),
    ),
  );
});

@immutable
final class V3SproutSubmissionSnapshot {
  const V3SproutSubmissionSnapshot({
    required this.operationId,
    required this.noteId,
    required this.status,
    required this.startedAt,
    this.errorCode,
  });

  final String operationId;
  final String noteId;
  final V3SproutTaskStatus status;
  final DateTime startedAt;
  final String? errorCode;

  V3SproutSubmissionSnapshot failed(String code) => V3SproutSubmissionSnapshot(
    operationId: operationId,
    noteId: noteId,
    status: V3SproutTaskStatus.failed,
    startedAt: startedAt,
    errorCode: code,
  );
}

/// Opaque handle for one uncommitted manual Note mutation.
///
/// The staged [note] may be shown to the caller, but only the controller that
/// created this handle can finalize or roll it back.
@immutable
final class KnowledgeManualNoteStage {
  const KnowledgeManualNoteStage._({
    required this.note,
    required this.createdNewNote,
  });

  final V3FeedItem note;
  final bool createdNewNote;
}

typedef KnowledgeManualNoteWriteAhead =
    Future<void> Function(V3FeedItem candidate);

final class _KnowledgeManualNoteStageSnapshot {
  _KnowledgeManualNoteStageSnapshot({
    required this.previousNote,
    required this.previousConflict,
    required this.stagedConflict,
    required this.previousSyncError,
    required this.stagedSyncError,
    required this.previousPendingUpsert,
    required this.stagedPendingUpsert,
    required this.previousPendingDelete,
    required this.stagedPendingDelete,
    required this.memberships,
    required this.depositRecords,
    required this.growthEntries,
    required this.depositPersistenceErrorCode,
    required this.clearConflictOnFinalize,
  });

  final V3FeedItem? previousNote;
  final KnowledgeNoteConflictSnapshot? previousConflict;
  final KnowledgeNoteConflictSnapshot? stagedConflict;
  final String? previousSyncError;
  final String? stagedSyncError;
  final bool previousPendingUpsert;
  final bool stagedPendingUpsert;
  final bool previousPendingDelete;
  final bool stagedPendingDelete;
  final List<V3LibraryMembership> memberships;
  final List<V3DepositRecord> depositRecords;
  final List<GrowthLedgerEntry> growthEntries;
  final String? depositPersistenceErrorCode;
  final bool clearConflictOnFinalize;
  bool persistenceAcknowledged = false;
  bool rollbackApplied = false;
}

final class KnowledgeLibraryController extends ChangeNotifier {
  KnowledgeLibraryController({
    HotspotNoteRepository? hotspotRepository,
    KnowledgeLibraryCache? cache,
    KnowledgeUserMetadataRepository? userMetadataRepository,
    KnowledgeNotePort? notePort,
    MobileSubscriptionPort? subscriptionPort,
    V3DepositRepository? depositRepository,
    WorkspaceFolderPort? workspaceFolderPort,
    KnowledgeTrashRepository? trashRepository,
    KnowledgeNoteSyncJournal? noteSyncJournal,
    Iterable<V3FeedItem>? initialNotes,
    bool includeDemoFixtures = true,
    bool autoSyncOwnedChanges = false,
    Duration remoteCacheTtl = const Duration(minutes: 5),
    Duration Function()? remoteCacheTtlResolver,
    DateTime Function()? now,
  }) : _hotspotRepository =
           hotspotRepository ?? const UnavailableHotspotNoteRepository(),
       _cache = cache,
       _userMetadataRepository = userMetadataRepository,
       _notePort = notePort ?? const UnavailableKnowledgeNotePort(),
       _depositRepository = depositRepository,
       _workspaceFolderPort =
           workspaceFolderPort ?? const UnavailableWorkspaceFolderPort(),
       _trashRepository = trashRepository,
       _noteSyncService = noteSyncJournal == null
           ? null
           : KnowledgeNoteSyncService(noteSyncJournal),
       _now = now ?? DateTime.now,
       _includeDemoFixtures = includeDemoFixtures,
       _autoSyncOwnedChanges = autoSyncOwnedChanges,
       _remoteCacheTtl = remoteCacheTtl,
       _remoteCacheTtlResolver = remoteCacheTtlResolver,
       _mergeDefaultFixtureOnRestore =
           initialNotes == null && includeDemoFixtures,
       _restoreComplete = cache == null,
       _graphSourceState = initialNotes != null || cache == null
           ? KnowledgeGraphSourceState.ready
           : KnowledgeGraphSourceState.loading,
       _notes =
           (initialNotes ??
                   (includeDemoFixtures
                       ? <V3FeedItem>[
                           ...v3KnowledgeNotes,
                           ..._buildKnowledgeChannelArticles(),
                         ]
                       : const <V3FeedItem>[]))
               .map(_normalizeSeedNote)
               .toList(growable: true) {
    _seedNotes.addAll(_notes);
    _indexedNotes = List<V3FeedItem>.of(_notes, growable: false);
    _noteIndex = <String, V3FeedItem>{for (final note in _notes) note.id: note};
    _noteIndexRevision = 1;
    _noteIndexSnapshot = KnowledgeNoteIndexSnapshot(
      ids: _notes.map((note) => note.id),
      revision: _noteIndexRevision,
    );
    _queryController = KnowledgeLibraryQueryController(
      notes: () => _notes,
      hasMembership: _hasMembership,
      isDeposited: _isDepositedNote,
      folderNameFor: _depositFolderNameFor,
      folderIdFor: (contentId) => depositRecordFor(contentId)?.folderId,
      folderExists: (folderId) => depositFolderFor(folderId) != null,
      folderNames: () => <String>[
        for (final folder in _activeDepositFolders()) folder.name,
      ],
      effectiveTags: effectiveTags,
      now: _now,
    )..addListener(_handleQueryChanged);
    _subscriptionController = KnowledgeSubscriptionController(
      port: subscriptionPort ?? const DemoMobileSubscriptionPort(),
      onCatalogApplied: _removeLegacySubscriptionSnapshots,
      onSavedArticle: _adoptSavedSubscriptionArticle,
      now: _now,
    )..addListener(_handleSubscriptionChanged);
    _graphReadModel = KnowledgeGraphReadModel(
      const <V3FeedItem>[],
      sourceState: _graphSourceState,
    );
    _hydrateUserMetadata();
    _hydrateDepositMetadata();
    _migrateExistingNotesToCollections();
    _graphReadModel.replaceDepositedNotes(_notes.where(_isDepositedNote));
  }

  final HotspotNoteRepository _hotspotRepository;
  final KnowledgeLibraryCache? _cache;
  final KnowledgeUserMetadataRepository? _userMetadataRepository;
  final KnowledgeNotePort _notePort;
  final V3DepositRepository? _depositRepository;
  final WorkspaceFolderPort _workspaceFolderPort;
  final KnowledgeTrashRepository? _trashRepository;
  final KnowledgeNoteSyncService? _noteSyncService;
  final DateTime Function() _now;
  final bool _includeDemoFixtures;
  final bool _autoSyncOwnedChanges;
  final Duration _remoteCacheTtl;
  final Duration Function()? _remoteCacheTtlResolver;
  final bool _mergeDefaultFixtureOnRestore;
  final List<V3FeedItem> _seedNotes = <V3FeedItem>[];
  KnowledgeCardDisplayMode _cardDisplayMode = KnowledgeCardDisplayMode.expanded;
  final Map<String, List<String>> _readOnlyTagOverrides =
      <String, List<String>>{};
  final List<V3FeedItem> _notes;
  late List<V3FeedItem> _indexedNotes;
  late Map<String, V3FeedItem> _noteIndex;
  late KnowledgeNoteIndexSnapshot _noteIndexSnapshot;
  late final KnowledgeLibraryQueryController _queryController;
  late final KnowledgeSubscriptionController _subscriptionController;
  late final KnowledgeGraphReadModel _graphReadModel;
  int _noteIndexRevision = 0;
  final List<V3LibraryMembership> _memberships = <V3LibraryMembership>[];
  final List<V3DepositRecord> _depositRecords = <V3DepositRecord>[];
  final List<V3DepositFolder> _depositFolders = <V3DepositFolder>[];
  final List<GrowthLedgerEntry> _growthLedger = <GrowthLedgerEntry>[];
  final List<KnowledgeTrashEntry> _trashEntries = <KnowledgeTrashEntry>[];
  String? _depositPersistenceErrorCode;
  bool _loading = false;
  String? _loadErrorCode;
  String? _remoteLoadErrorCode;
  String? _persistenceErrorCode;
  WorkspaceContentSync? _workspaceContentSync;
  bool _workspaceFoldersReady = false;
  Map<String, WorkspaceContentRemoteFolder> _remoteFolderIndex =
      const <String, WorkspaceContentRemoteFolder>{};
  final Map<String, WorkspaceContentRemoteFolder> _workspaceTombstonedFolders =
      <String, WorkspaceContentRemoteFolder>{};
  String? _workspaceContentCursor;
  int _workspaceFolderMutationSequence = 0;
  final Map<String, String> _workspaceMutationRetryKeys = <String, String>{};
  Future<void> _workspaceContentTail = Future<void>.value();
  Future<bool>? _workspaceContentSyncOperation;
  bool _workspaceForceSnapshotRequested = false;
  Future<void>? _restoreOperation;
  Future<void> _saveQueue = Future<void>.value();
  Object? _pendingSaveBatch;
  Future<void> _trashSaveQueue = Future<void>.value();
  bool _restoreComplete;
  bool _cacheRestoreFailed = false;
  KnowledgeGraphSourceState _graphSourceState;
  String? _graphSourceErrorCode;
  final Set<String> _pendingUpserts = <String>{};
  final Set<String> _pendingDeletes = <String>{};
  final Map<String, KnowledgeNoteConflictSnapshot> _conflicts =
      <String, KnowledgeNoteConflictSnapshot>{};
  final Map<String, String> _syncErrors = <String, String>{};
  final Map<String, Future<KnowledgeNoteSyncResult>> _syncOperations =
      <String, Future<KnowledgeNoteSyncResult>>{};
  final Map<KnowledgeManualNoteStage, _KnowledgeManualNoteStageSnapshot>
  _manualNoteStages =
      <KnowledgeManualNoteStage, _KnowledgeManualNoteStageSnapshot>{};
  final Map<String, V3SproutSubmissionSnapshot> _sproutSubmissions =
      <String, V3SproutSubmissionSnapshot>{};
  bool _disposed = false;

  V3KnowledgeLibraryTab get tab => _queryController.tab;
  KnowledgeSourceCategory sourceCategoryFor(V3KnowledgeLibraryTab tab) =>
      _queryController.sourceCategoryFor(tab);
  KnowledgeSourceCategory get sourceCategory => _queryController.sourceCategory;
  KnowledgeSourceCategory get depositSourceCategory =>
      _queryController.depositSourceCategory;
  KnowledgeCardDisplayMode get cardDisplayMode => _cardDisplayMode;
  KnowledgeSourceFilter get sourceFilter => _queryController.sourceFilter;
  KnowledgeTimeFilter get timeFilter => _queryController.timeFilter;
  KnowledgeDateRange? get customTimeRange => _queryController.customTimeRange;
  V3KnowledgeGrouping get grouping => _queryController.grouping;
  V3KnowledgeSort get sort => _queryController.sort;
  String get query => _queryController.query;
  KnowledgeSourceFilter get depositSourceFilter =>
      _queryController.depositSourceFilter;
  KnowledgeTimeFilter get depositTimeFilter =>
      _queryController.depositTimeFilter;
  KnowledgeDateRange? get depositCustomTimeRange =>
      _queryController.depositCustomTimeRange;
  V3KnowledgeGrouping get depositGrouping => _queryController.depositGrouping;
  V3KnowledgeSort get depositSort => _queryController.depositSort;
  String get depositQuery => _queryController.depositQuery;
  bool get loading => _loading;
  bool get restoreComplete => _restoreComplete;
  bool get cacheRestoreSucceeded => _restoreComplete && !_cacheRestoreFailed;
  MobileSubscriptionRuntimeMode get subscriptionMode =>
      _subscriptionController.mode;
  List<MobileSubscriptionPublication> get subscriptionPublications =>
      _subscriptionController.publications;
  String? get subscriptionErrorCode => _subscriptionController.errorCode;
  String? get loadErrorCode => _loadErrorCode;
  String? get remoteLoadErrorCode => _remoteLoadErrorCode;
  String? get persistenceErrorCode => _persistenceErrorCode;
  String? get workspaceContentCursor => _workspaceContentCursor;
  bool get hasWorkspaceContentSync => _workspaceContentSync != null;
  bool get workspaceFoldersReady =>
      !hasWorkspaceContentSync || _workspaceFoldersReady;
  Map<String, WorkspaceContentRemoteFolder> get remoteFolderIndex =>
      Map<String, WorkspaceContentRemoteFolder>.unmodifiable(
        _remoteFolderIndex,
      );

  bool canRestoreWorkspaceDepositFolder(String folderId) =>
      _workspaceTombstonedFolders.containsKey(folderId.trim());
  String? get depositPersistenceErrorCode => _depositPersistenceErrorCode;
  KnowledgeNoteIndexSnapshot get noteIndexSnapshot => _noteIndexSnapshot;
  KnowledgeGraphReadModel get graphReadModel => _graphReadModel;
  List<V3FeedItem> get notes => List<V3FeedItem>.unmodifiable(_notes);
  List<V3FeedItem> get allNotes => notes;
  List<V3FeedItem> get mineNotes => List<V3FeedItem>.unmodifiable(
    _notes.where((note) => note.ownership == V3NoteOwnership.mine),
  );
  List<V3FeedItem> get myCreatedNotes => mineNotes;
  List<V3FeedItem> get allDepositedNotes =>
      List<V3FeedItem>.unmodifiable(_notes.where(_isDepositedNote));
  List<V3FeedItem> get masterpieceEligibleNotes {
    final deposited = _notes.where(_isDepositedNote);
    if (!_usesWorkspaceFolders) {
      return List<V3FeedItem>.unmodifiable(deposited);
    }
    final seenRemoteNoteIds = <String>{};
    return List<V3FeedItem>.unmodifiable(
      deposited.where((note) {
        final remoteNoteId = _nonEmpty(note.remoteNoteId);
        return note.syncState == NoteSyncState.synced &&
            remoteNoteId != null &&
            seenRemoteNoteIds.add(remoteNoteId);
      }),
    );
  }

  int get masterpieceUnsyncedCount => _notes
      .where(_isDepositedNote)
      .where((note) => note.syncState != NoteSyncState.synced)
      .length;

  int get masterpieceMissingRemoteIdCount => _notes
      .where(_isDepositedNote)
      .where(
        (note) =>
            note.syncState == NoteSyncState.synced &&
            _nonEmpty(note.remoteNoteId) == null,
      )
      .length;

  int get masterpieceDuplicateRemoteIdCount {
    final seenRemoteNoteIds = <String>{};
    var duplicates = 0;
    for (final note in _notes.where(_isDepositedNote)) {
      if (note.syncState != NoteSyncState.synced) continue;
      final remoteNoteId = _nonEmpty(note.remoteNoteId);
      if (remoteNoteId != null && !seenRemoteNoteIds.add(remoteNoteId)) {
        duplicates += 1;
      }
    }
    return duplicates;
  }

  int get masterpieceTemporarilyUnavailableCount =>
      allDepositedNotes.length - masterpieceEligibleNotes.length;

  List<V3FeedItem> get graphNotes => allDepositedNotes;
  V3DepositFilterKind get depositFilterKind =>
      _queryController.depositFilterKind;
  String? get depositFolderFilterId => _queryController.depositFolderFilterId;
  List<V3DepositFolder> get depositFolders =>
      List<V3DepositFolder>.unmodifiable(_activeDepositFolders());
  List<V3DepositRecord> get depositRecords =>
      List<V3DepositRecord>.unmodifiable(
        _usesWorkspaceFolders
            ? <V3DepositRecord>[
                for (final note in allDepositedNotes)
                  _workspaceDepositRecordFor(note),
              ]
            : _depositRecords,
      );
  List<V3LibraryMembership> get memberships =>
      List<V3LibraryMembership>.unmodifiable(_memberships);
  List<GrowthLedgerEntry> get growthLedgerEntries =>
      List<GrowthLedgerEntry>.unmodifiable(_growthLedger);
  int get growthLedgerCount => _growthLedger.length;
  List<KnowledgeTrashEntry> get trashEntries =>
      List<KnowledgeTrashEntry>.unmodifiable(_trashEntries);

  List<KnowledgeChannel> get subscribedChannels {
    final memberships =
        _memberships
            .where(
              (membership) =>
                  membership.collection == V3LibraryCollection.subscribed &&
                  membership.contentId.startsWith(_channelMembershipPrefix),
            )
            .toList(growable: false)
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return List<KnowledgeChannel>.unmodifiable(
      memberships
          .map(
            (membership) => KnowledgeChannel.fromId(
              membership.contentId.substring(_channelMembershipPrefix.length),
            ),
          )
          .whereType<KnowledgeChannel>(),
    );
  }

  List<V3FeedItem> channelArticlesFor(KnowledgeChannel channel) {
    final prefix = 'knowledge-channel-${channel.id}-';
    final values = _notes.where((note) => note.id.startsWith(prefix)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List<V3FeedItem>.unmodifiable(values);
  }

  List<V3FeedItem> get subscribedChannelArticles {
    final values = <V3FeedItem>[
      for (final channel in subscribedChannels) ...channelArticlesFor(channel),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List<V3FeedItem>.unmodifiable(values);
  }

  KnowledgeChannel? channelForArticle(String noteId) {
    for (final channel in KnowledgeChannel.values) {
      if (noteId.startsWith('knowledge-channel-${channel.id}-')) return channel;
    }
    return null;
  }

  bool isChannelSubscribed(KnowledgeChannel channel) => _hasMembership(
    '$_channelMembershipPrefix${channel.id}',
    V3LibraryCollection.subscribed,
  );

  bool subscribeChannel(KnowledgeChannel channel) {
    if (isChannelSubscribed(channel)) return true;
    final membership = V3LibraryMembership(
      contentId: '$_channelMembershipPrefix${channel.id}',
      collection: V3LibraryCollection.subscribed,
      createdAt: _now(),
    );
    try {
      _depositRepository?.saveMembership(membership);
    } catch (_) {
      _depositPersistenceErrorCode = 'KNOWLEDGE_CHANNEL_SUBSCRIBE_FAILED';
      notifyListeners();
      return false;
    }
    _memberships.add(membership);
    _depositPersistenceErrorCode = null;
    notifyListeners();
    return true;
  }

  bool unsubscribeChannel(KnowledgeChannel channel) {
    final contentId = '$_channelMembershipPrefix${channel.id}';
    if (!isChannelSubscribed(channel)) return true;
    try {
      _depositRepository?.deleteMembership(
        contentId: contentId,
        collection: V3LibraryCollection.subscribed,
      );
    } catch (_) {
      _depositPersistenceErrorCode = 'KNOWLEDGE_CHANNEL_UNSUBSCRIBE_FAILED';
      notifyListeners();
      return false;
    }
    _memberships.removeWhere(
      (membership) =>
          membership.contentId == contentId &&
          membership.collection == V3LibraryCollection.subscribed,
    );
    _depositPersistenceErrorCode = null;
    notifyListeners();
    return true;
  }

  DateTime assetStatisticsStart(
    V3AssetStatisticsPeriod period, {
    DateTime? reference,
  }) {
    final now = reference ?? _now();
    return switch (period) {
      V3AssetStatisticsPeriod.week => DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: now.weekday - 1)),
      V3AssetStatisticsPeriod.month => DateTime(now.year, now.month),
    };
  }

  int newDepositCount(V3AssetStatisticsPeriod period, {DateTime? reference}) {
    final start = assetStatisticsStart(period, reference: reference);
    return depositRecords
        .where((record) => !record.depositedAt.isBefore(start))
        .map((record) => record.contentId)
        .toSet()
        .length;
  }

  /// Returns one count per local calendar bucket for the selected asset period.
  ///
  /// The trend is intentionally based on unique deposit records rather than
  /// asset labels: a note can have many labels but is only one new asset.
  List<int> assetNewDepositTrend(
    V3AssetStatisticsPeriod period, {
    DateTime? reference,
  }) {
    final now = (reference ?? _now()).toLocal();
    final dayStart = DateTime(now.year, now.month, now.day);
    final periodStart = assetStatisticsStart(period, reference: now);
    final bucketCount = switch (period) {
      V3AssetStatisticsPeriod.week => 7,
      V3AssetStatisticsPeriod.month =>
        (DateTime(now.year, now.month + 1).difference(periodStart).inDays +
                6) ~/
            7,
    };
    final counts = List<int>.filled(bucketCount, 0);
    final countedContentIds = <String>{};

    for (final record in depositRecords) {
      if (!countedContentIds.add(record.contentId)) continue;
      final depositedAt = record.depositedAt.toLocal();
      if (depositedAt.isBefore(periodStart) || depositedAt.isAfter(now)) {
        continue;
      }
      final depositedDay = DateTime(
        depositedAt.year,
        depositedAt.month,
        depositedAt.day,
      );
      final dayOffset = depositedDay.difference(periodStart).inDays;
      final bucketIndex = switch (period) {
        V3AssetStatisticsPeriod.week => dayOffset,
        V3AssetStatisticsPeriod.month => dayOffset ~/ 7,
      };
      if (bucketIndex >= 0 && bucketIndex < counts.length) {
        counts[bucketIndex] += 1;
      }
    }

    // Keep the weekly curve scoped to today even when a corrupted cache holds
    // a future entry in the current calendar week.
    if (period == V3AssetStatisticsPeriod.week) {
      final todayIndex = dayStart.difference(periodStart).inDays;
      for (var index = todayIndex + 1; index < counts.length; index++) {
        counts[index] = 0;
      }
    }
    return List<int>.unmodifiable(counts);
  }

  List<V3AssetMediaResource> get assetMediaResources {
    final resources = <V3AssetMediaResource>[];
    final seen = <String>{};
    for (final note in allDepositedNotes) {
      if (note.ownership != V3NoteOwnership.mine) continue;
      for (final attachment in note.mediaAttachments) {
        final resourceId = attachment.privateUri.trim();
        if (resourceId.isEmpty || !seen.add(resourceId)) continue;
        resources.add(
          V3AssetMediaResource(
            resourceId: resourceId,
            contentId: note.id,
            displayName: attachment.displayName,
            kind: attachment.kind == V3MediaAttachmentKind.video
                ? V3AssetMediaKind.video
                : V3AssetMediaKind.image,
            createdAt: note.createdAt,
          ),
        );
      }
    }
    resources.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return List<V3AssetMediaResource>.unmodifiable(resources);
  }

  KnowledgeNoteConflictSnapshot? conflictFor(String noteId) =>
      _conflicts[noteId];

  String? syncErrorFor(String noteId) => _syncErrors[noteId];

  bool isSyncing(String noteId) => _syncOperations.containsKey(noteId);

  V3FeedItem? noteForId(String id) {
    final normalized = id.trim();
    return _noteIndex[normalized] ??
        _subscriptionController.articleForId(normalized);
  }

  V3SproutSubmissionSnapshot? sproutSubmissionFor(String noteId) =>
      _sproutSubmissions[noteId.trim()];

  void beginSproutSubmission({
    required String noteId,
    required String operationId,
  }) {
    final normalizedNoteId = noteId.trim();
    final normalizedOperationId = operationId.trim();
    if (_disposed ||
        normalizedNoteId.isEmpty ||
        normalizedOperationId.isEmpty) {
      return;
    }
    _sproutSubmissions[normalizedNoteId] = V3SproutSubmissionSnapshot(
      operationId: normalizedOperationId,
      noteId: normalizedNoteId,
      status: V3SproutTaskStatus.running,
      startedAt: _now(),
    );
    notifyListeners();
  }

  void failSproutSubmission({
    required String noteId,
    required String operationId,
    required String errorCode,
  }) {
    final current = _sproutSubmissions[noteId.trim()];
    if (_disposed || current == null || current.operationId != operationId) {
      return;
    }
    _sproutSubmissions[current.noteId] = current.failed(errorCode);
    notifyListeners();
  }

  void finishSproutSubmission({
    required String noteId,
    required String operationId,
  }) {
    final normalizedNoteId = noteId.trim();
    final current = _sproutSubmissions[normalizedNoteId];
    if (_disposed || current == null || current.operationId != operationId) {
      return;
    }
    _sproutSubmissions.remove(normalizedNoteId);
    notifyListeners();
  }

  /// Installs the authenticated Workspace synchronizer before initialization.
  /// It deliberately owns only remote HNote and Folder projection, never the
  /// user's local deposit-folder hierarchy.
  void attachWorkspaceContentSync(WorkspaceContentSync synchronizer) {
    if (_workspaceContentSync != null) {
      throw StateError('WORKSPACE_CONTENT_SYNC_ALREADY_ATTACHED');
    }
    _workspaceContentSync = synchronizer;
    _setGraphSourceState(KnowledgeGraphSourceState.loading);
  }

  Future<void> initialize() async {
    if (_cache != null ||
        _workspaceContentSync != null ||
        _notePort is KnowledgeNoteRemoteListPort) {
      _setGraphSourceState(KnowledgeGraphSourceState.loading);
    }
    if (_includeDemoFixtures) {
      await _loadStructuredDemoPersonCatalog();
      if (_disposed) return;
      await _loadStructuredChannelCatalog();
      if (_disposed) return;
    }
    await restore();
    if (_disposed) return;
    await _restoreTrash();
    if (_disposed) return;
    if (_workspaceContentSync != null) {
      await synchronizeWorkspaceContent();
    } else {
      final cacheIsFresh = await _isRemoteCacheFresh();
      if (cacheIsFresh) {
        _setGraphSourceState(KnowledgeGraphSourceState.ready);
        await _recoverPendingNoteSync();
      } else if (_notePort is KnowledgeNoteRemoteListPort) {
        await synchronizeWorkspaceContent();
      } else {
        _setGraphSourceState(KnowledgeGraphSourceState.ready);
        await _recoverPendingNoteSync();
      }
    }
    if (_disposed) return;
    await loadHotspots();
  }

  Future<void> ensureSubscriptionCatalogLoaded() =>
      _subscriptionController.ensureCatalogLoaded();

  Future<void> reloadSubscriptions() => _subscriptionController.reload();

  List<V3FeedItem> subscriptionArticlesFor(String publicationId) =>
      _subscriptionController.articlesFor(publicationId);

  List<V3FeedItem> get remoteSubscribedArticles =>
      _subscriptionController.followedArticles;

  bool isRemotePublicationFollowed(String publicationId) =>
      _subscriptionController.isPublicationFollowed(publicationId);

  bool isSubscriptionActionInFlight(String publicationId) =>
      _subscriptionController.isPublicationActionInFlight(publicationId);

  bool isSubscriptionArticleActionInFlight(String noteId) =>
      _subscriptionController.isArticleActionInFlight(noteId);

  Future<MobileSubscriptionActionResult> toggleRemotePublication(
    String publicationId,
  ) => _subscriptionController.togglePublication(publicationId);

  Future<MobileSubscriptionActionResult> loadRemoteSubscriptionArticle(
    String noteId,
  ) => _subscriptionController.loadArticle(noteId);

  Future<MobileSubscriptionArticleAssetResult>
  loadRemoteSubscriptionArticleAsset(String noteId, String logicalPath) {
    final note = noteForId(noteId);
    if (note != null && note.isSavedSubscriptionNote) {
      return _subscriptionController.loadSavedNoteAsset(note, logicalPath);
    }
    return _subscriptionController.loadArticleAsset(noteId, logicalPath);
  }

  Future<MobileSubscriptionArticleAssetResult>
  loadRemoteSubscriptionArticleLeadAsset(String noteId) =>
      _subscriptionController.loadArticleLeadAsset(noteId);

  Future<MobileSubscriptionActionResult> saveRemoteSubscriptionArticle(
    String noteId,
  ) async {
    final result = await _subscriptionController.saveArticle(noteId);
    final saved = result.item;
    if (result.status != MobileSubscriptionResultStatus.success ||
        saved == null) {
      return result;
    }
    final adopted = _localNoteForRemote(saved);
    return adopted == null
        ? const MobileSubscriptionActionResult.failure(
            'SUBSCRIPTION_SAVED_ASSET_DEPOSIT_FAILED',
          )
        : MobileSubscriptionActionResult.success(adopted);
  }

  void _handleQueryChanged() {
    if (!_disposed) notifyListeners();
  }

  void _handleSubscriptionChanged() {
    if (!_disposed) notifyListeners();
  }

  void _removeLegacySubscriptionSnapshots() {
    final ownedNoteCount = _notes.length;
    _notes.removeWhere(_isRemoteSubscriptionArticle);
    if (_notes.length != ownedNoteCount) _schedulePersist();
  }

  Future<String?> _adoptSavedSubscriptionArticle(V3FeedItem saved) async {
    final existing = _localNoteForRemote(saved);
    final adopted = existing == null
        ? saved
        : hasUnsyncedKnowledgeChanges(existing)
        ? existing
        : _mergeRemoteIntoExisting(existing, saved);
    _upsert(adopted, notify: false);
    final record = depositContent(adopted.id, depositedAt: adopted.updatedAt);
    if (record == null) return 'SUBSCRIPTION_SAVED_ASSET_DEPOSIT_FAILED';
    if (!await flushPersistenceResult()) {
      return 'SUBSCRIPTION_SAVED_ASSET_LOCAL_PERSIST_FAILED';
    }
    return null;
  }

  Future<bool> _loadRemoteNotes() async {
    final port = _notePort;
    if (port is! KnowledgeNoteRemoteListPort) return true;
    final loader = port as KnowledgeNoteRemoteListPort;
    KnowledgeNoteRemoteLoadResult result;
    try {
      result = await loader.loadNotes();
    } on Object {
      result = const KnowledgeNoteRemoteLoadResult.failure(
        'KNOWLEDGE_NOTE_LOAD_FAILED',
      );
    }
    if (_disposed) return false;
    if (result.status != KnowledgeNoteRemoteLoadStatus.success) {
      _remoteLoadErrorCode = result.errorCode ?? 'KNOWLEDGE_NOTE_LOAD_FAILED';
      return false;
    }

    var changed = false;
    for (final remote in result.notes) {
      final existing = _localNoteForRemote(remote);
      if (existing != null && hasUnsyncedKnowledgeChanges(existing)) continue;
      final merged = existing == null
          ? remote.copyWith(syncState: NoteSyncState.synced)
          : _mergeRemoteIntoExisting(existing, remote);
      _clearConflictState(merged.id);
      _upsert(merged, notify: false, persist: false);
      changed = true;
    }
    _remoteLoadErrorCode = null;
    if (_autoSyncOwnedChanges) {
      for (final note in List<V3FeedItem>.of(_notes)) {
        if (_nonEmpty(note.remoteNoteId) != null) {
          _scheduleAutomaticSync(note);
        }
      }
    }
    if (changed) _schedulePersist();
    return true;
  }

  Future<bool> _isRemoteCacheFresh() async {
    final cache = _cache;
    if (cache is! KnowledgeLibraryCacheFreshnessPort) return false;
    final freshnessCache = cache! as KnowledgeLibraryCacheFreshnessPort;
    final savedAt = await freshnessCache.lastSavedAt();
    if (savedAt == null) return false;
    return _now().toUtc().difference(savedAt) <= _effectiveRemoteCacheTtl;
  }

  Duration get _effectiveRemoteCacheTtl {
    try {
      final resolved = _remoteCacheTtlResolver?.call();
      if (resolved != null &&
          resolved > Duration.zero &&
          resolved <= const Duration(days: 1)) {
        return resolved;
      }
    } catch (_) {
      // An unavailable policy cannot make a persisted asset snapshot stale.
    }
    return _remoteCacheTtl;
  }

  /// Merges a snapshot or cursor delta. In production this replaces the legacy
  /// all-notes read; the narrow list fallback remains for existing isolated
  /// test doubles that do not install a Workspace sync service.
  Future<bool> synchronizeWorkspaceContent({bool forceSnapshot = false}) {
    if (forceSnapshot) _workspaceForceSnapshotRequested = true;
    final active = _workspaceContentSyncOperation;
    if (active != null) return active;
    final initialForceSnapshot = _workspaceForceSnapshotRequested;
    _workspaceForceSnapshotRequested = false;
    final operation = _drainWorkspaceContentSync(initialForceSnapshot);
    _workspaceContentSyncOperation = operation;
    unawaited(
      operation.then<void>(
        (_) => _clearWorkspaceContentSync(operation),
        onError: (Object _, StackTrace __) =>
            _clearWorkspaceContentSync(operation),
      ),
    );
    return operation;
  }

  Future<bool> _drainWorkspaceContentSync(bool forceSnapshot) async {
    var result = false;
    var forceNextPass = forceSnapshot;
    do {
      result = await _runWorkspaceContentSerial(() async {
        final synchronized = await _synchronizeWorkspaceContentUnlocked(
          forceSnapshot: forceNextPass,
        );
        await _recoverPendingNoteSyncUnlocked();
        return synchronized;
      });
      forceNextPass = _workspaceForceSnapshotRequested;
      _workspaceForceSnapshotRequested = false;
    } while (forceNextPass && !_disposed);
    return result;
  }

  void _clearWorkspaceContentSync(Future<bool> operation) {
    if (identical(_workspaceContentSyncOperation, operation)) {
      _workspaceContentSyncOperation = null;
    }
  }

  Future<bool> _synchronizeWorkspaceContentUnlocked({
    required bool forceSnapshot,
  }) async {
    _setGraphSourceState(KnowledgeGraphSourceState.loading);
    await restore();
    if (_disposed) return false;
    final synchronizer = _workspaceContentSync;
    if (synchronizer == null) {
      final loaded = await _loadRemoteNotes();
      if (_disposed) return false;
      if (!loaded) {
        _setGraphSourceState(
          KnowledgeGraphSourceState.failure,
          errorCode: _remoteLoadErrorCode ?? 'KNOWLEDGE_NOTE_LOAD_FAILED',
        );
        return false;
      }
      _remoteLoadErrorCode = null;
      _setGraphSourceState(KnowledgeGraphSourceState.ready);
      return true;
    }
    late final WorkspaceContentSyncResult result;
    try {
      result = await synchronizer.synchronize(forceSnapshot: forceSnapshot);
    } on Object {
      if (_disposed) return false;
      _remoteLoadErrorCode = 'WORKSPACE_CONTENT_SYNC_FAILED';
      _setGraphSourceState(
        KnowledgeGraphSourceState.failure,
        errorCode: _remoteLoadErrorCode,
      );
      return false;
    }
    if (_disposed) return false;
    if (!result.isSuccess) {
      _remoteLoadErrorCode =
          result.errorCode ?? 'WORKSPACE_CONTENT_SYNC_FAILED';
      _setGraphSourceState(
        KnowledgeGraphSourceState.failure,
        errorCode: _remoteLoadErrorCode,
      );
      return false;
    }
    _remoteLoadErrorCode = null;
    _setGraphSourceState(KnowledgeGraphSourceState.ready);
    return true;
  }

  Future<T> _runWorkspaceContentSerial<T>(Future<T> Function() operation) {
    final queued = _workspaceContentTail.then<T>((_) => operation());
    _workspaceContentTail = queued.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return queued;
  }

  Future<bool> reconcileRemoteNotesForChatReference() =>
      synchronizeWorkspaceContent();

  /// Applies a full HNote/folder projection and waits for the local note cache
  /// before allowing the cursor checkpoint to advance. In the authenticated
  /// mobile runtime, this index is the authority for folder metadata and HNote
  /// placement; legacy local deposit metadata remains only for isolated demos.
  Future<void> applyWorkspaceContentProjection(
    WorkspaceContentProjection projection,
  ) async {
    if (_disposed) throw StateError('KNOWLEDGE_LIBRARY_DISPOSED');
    _workspaceFoldersReady = true;
    _remoteFolderIndex = Map<String, WorkspaceContentRemoteFolder>.unmodifiable(
      projection.folders,
    );
    _workspaceTombstonedFolders.removeWhere(
      (folderId, _) => projection.folders.containsKey(folderId),
    );
    _notes
      ..clear()
      ..addAll(projection.notes.map(_normalizeOwnership));
    _migrateExistingNotesToCollections();
    _notes.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    _workspaceContentCursor = projection.contentCursor;
    _remoteLoadErrorCode = null;
    if (!_disposed) notifyListeners();

    final cache = _cache;
    if (cache == null) {
      await _discardWorkspaceTrashEntriesForLiveNotes();
      return;
    }
    var saved = false;
    final projectionCache = cache is KnowledgeLibraryWorkspaceProjectionCache
        ? cache as KnowledgeLibraryWorkspaceProjectionCache
        : null;
    late final Future<void> persisted;
    _pendingSaveBatch = null;
    persisted = _saveQueue = _saveQueue.then((_) async {
      try {
        final notes = List<V3FeedItem>.of(_notes);
        if (projectionCache != null) {
          await projectionCache.saveWorkspaceProjection(
            notes,
            contentCursor: projection.contentCursor,
          );
        } else {
          await cache.save(notes);
        }
        _persistenceErrorCode = null;
        saved = true;
      } on Object {
        _persistenceErrorCode = 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED';
      }
    });
    await persisted;
    if (!saved) throw StateError('KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED');
    await _discardWorkspaceTrashEntriesForLiveNotes();
  }

  void applyWorkspaceFolderProjection(
    Map<String, WorkspaceContentRemoteFolder> folders,
  ) {
    if (_disposed) throw StateError('KNOWLEDGE_LIBRARY_DISPOSED');
    _remoteFolderIndex = Map<String, WorkspaceContentRemoteFolder>.unmodifiable(
      folders,
    );
    _workspaceFoldersReady = true;
    notifyListeners();
  }

  /// Reconciles one owned cloud asset after a derived operation has timed out.
  /// This is deliberately read-only and never starts a File-Agent run.
  /// Success includes persistence of the reconciled revision to the local cache.
  Future<bool> refreshRemoteDerivedParts(String id) =>
      _runWorkspaceContentSerial(() => _refreshRemoteDerivedPartsUnlocked(id));

  Future<bool> _refreshRemoteDerivedPartsUnlocked(String id) async {
    final local = noteForId(id.trim());
    final remoteNoteId = _nonEmpty(local?.remoteNoteId);
    if (local == null ||
        local.isReadOnly ||
        remoteNoteId == null ||
        hasUnsyncedKnowledgeChanges(local)) {
      return false;
    }
    final port = _notePort;
    if (port is! KnowledgeNoteRemoteDetailPort) return false;
    final detailPort = port as KnowledgeNoteRemoteDetailPort;
    KnowledgeNotePortResult result;
    try {
      result = await detailPort.loadNote(
        remoteNoteId,
        localId: local.id,
        fallback: local,
      );
    } on Object {
      return false;
    }
    if (_disposed || result.status != KnowledgeNotePortStatus.success) {
      return false;
    }
    final remote = result.remoteNote;
    if (remote == null ||
        !isValidKnowledgeRemoteNote(remote, local.id, localBinding: local)) {
      return false;
    }
    final current = noteForId(local.id);
    if (current == null ||
        hasUnsyncedKnowledgeChanges(current) ||
        !sameKnowledgeEditableRevision(current, local) ||
        !_sameDerivedRefreshSnapshot(current, local)) {
      return false;
    }
    _clearConflictState(local.id);
    _upsert(_mergeRemoteIntoExisting(current, remote));
    return flushPersistenceResult();
  }

  V3FeedItem? adoptAppliedRawPartProposal({
    required String localNoteId,
    required String remoteNoteId,
    required String ownerRevisionId,
    required String rawPartRevisionId,
    required String rawBody,
  }) {
    final current = noteForId(localNoteId.trim());
    if (current == null ||
        current.isReadOnly ||
        _nonEmpty(current.remoteNoteId) != remoteNoteId.trim() ||
        _nonEmpty(rawPartRevisionId) == null ||
        _nonEmpty(ownerRevisionId) == null) {
      return null;
    }
    final applied = current.copyWith(
      rawBody: rawBody,
      noteRevisionId: ownerRevisionId.trim(),
      rawPartRevisionId: rawPartRevisionId.trim(),
      syncState: NoteSyncState.synced,
      updatedAt: _now(),
    );
    _clearConflictState(applied.id);
    _upsert(applied);
    return applied;
  }

  Future<void> _restoreTrash() async {
    final repository = _trashRepository;
    if (repository == null) return;
    try {
      final restored = await repository.load();
      final liveIds = _notes.map((note) => note.id).toSet();
      final now = _now();
      final retained =
          restored
              .where(
                (entry) =>
                    !entry.isExpiredAt(now) && !liveIds.contains(entry.id),
              )
              .toList()
            ..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      _trashEntries
        ..clear()
        ..addAll(retained);
      if (retained.length != restored.length) {
        await repository.save(List<KnowledgeTrashEntry>.of(retained));
      }
      if (!_disposed) notifyListeners();
    } on Object {
      _persistenceErrorCode = 'KNOWLEDGE_TRASH_LOAD_FAILED';
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _loadStructuredDemoPersonCatalog() async {
    if (!_mergeDefaultFixtureOnRestore) return;
    try {
      final raw = await rootBundle.loadString(
        'assets/data/demo_person_assets_zh_CN.json',
      );
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['persona'] is! Map<String, dynamic> ||
          decoded['notes'] is! List) {
        return;
      }
      final persona = decoded['persona']! as Map<String, dynamic>;
      final noteValues = decoded['notes']! as List;
      if ('${persona['accountName'] ?? ''}'.trim() != '老周不劝你' ||
          noteValues.length != 90) {
        return;
      }
      final parsed = <V3FeedItem>[];
      final seenIds = <String>{};
      for (final value in noteValues) {
        if (value is! Map<String, dynamic>) return;
        final id = '${value['id'] ?? ''}'.trim();
        final title = '${value['title'] ?? ''}'.trim();
        final rawBody = '${value['rawBody'] ?? ''}'.trim();
        final summaryBody = '${value['summaryBody'] ?? ''}'.trim();
        final contentLineId = '${value['contentLineId'] ?? ''}'.trim();
        final contentLineName = '${value['contentLineName'] ?? ''}'.trim();
        final createdAt = DateTime.tryParse(
          '${value['createdAt'] ?? ''}',
        )?.toLocal();
        final updatedAt = DateTime.tryParse(
          '${value['updatedAt'] ?? ''}',
        )?.toLocal();
        final topicValues = value['topics'];
        if (!RegExp(r'^demo-laozhou-[0-9]{3}$').hasMatch(id) ||
            !seenIds.add(id) ||
            title.isEmpty ||
            rawBody.runes.length < 120 ||
            summaryBody.isEmpty ||
            contentLineId.isEmpty ||
            contentLineName.isEmpty ||
            createdAt == null ||
            updatedAt == null ||
            topicValues is! List) {
          return;
        }
        final topics = <String>[
          for (final topic in topicValues)
            if ('$topic'.trim().isNotEmpty) '$topic'.trim(),
        ];
        if (topics.isEmpty || topics.length != topicValues.length) return;
        parsed.add(
          V3FeedItem(
            id: id,
            title: title,
            source: V3MaterialSource.note,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rawBody: rawBody,
            summaryBody: summaryBody,
            topics: topics,
            contentLineId: contentLineId,
            contentLineName: contentLineName,
          ),
        );
      }
      if (parsed.length != 90) return;
      parsed.sort((left, right) => right.createdAt.compareTo(left.createdAt));
      bool fixtureOwnedNote(V3FeedItem note) =>
          note.ownership == V3NoteOwnership.mine &&
          (v3RetiredKnowledgeFixtureIds.contains(note.id) ||
              note.id.startsWith('demo-laozhou-'));
      _notes.removeWhere(fixtureOwnedNote);
      _seedNotes.removeWhere(fixtureOwnedNote);
      _notes.addAll(parsed);
      _seedNotes.addAll(parsed);
      _migrateExistingNotesToCollections();
      if (!_disposed) notifyListeners();
    } catch (_) {
      // The concise compiled persona remains available if the asset is corrupt.
    }
  }

  Future<void> _loadStructuredChannelCatalog() async {
    if (!_mergeDefaultFixtureOnRestore) return;
    try {
      final raw = await rootBundle.loadString(
        'assets/data/knowledge_channels_zh_CN.json',
      );
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['channels'] is! List) {
        return;
      }
      final channelValues = decoded['channels']! as List;
      final parsed = <V3FeedItem>[];
      final parsedChannelIds = <String>{};
      for (final value in channelValues) {
        if (value is! Map<String, dynamic>) return;
        final channel = KnowledgeChannel.fromId('${value['id'] ?? ''}');
        final articles = value['articles'];
        if (channel == null || articles is! List || articles.length != 12) {
          return;
        }
        parsedChannelIds.add(channel.id);
        for (final articleValue in articles) {
          if (articleValue is! Map<String, dynamic>) return;
          final id = '${articleValue['id'] ?? ''}'.trim();
          final title = '${articleValue['title'] ?? ''}'.trim();
          final body = '${articleValue['body'] ?? ''}'.trim();
          final summary = '${articleValue['summary'] ?? ''}'.trim();
          final publishedAt = DateTime.tryParse(
            '${articleValue['publishedAt'] ?? ''}',
          )?.toLocal();
          if (id.isEmpty ||
              !id.startsWith('knowledge-channel-${channel.id}-') ||
              title.isEmpty ||
              body.runes.length < 500 ||
              body.runes.length > 900 ||
              publishedAt == null) {
            return;
          }
          parsed.add(
            V3FeedItem(
              id: id,
              title: title,
              source: V3MaterialSource.knowledgeSquare,
              ownership: V3NoteOwnership.knowledgeSquare,
              createdAt: publishedAt,
              updatedAt: publishedAt,
              rawBody: body,
              summaryBody: summary,
              topics: <String>[channel.label, title],
            ),
          );
        }
      }
      if (parsedChannelIds.length != KnowledgeChannel.values.length ||
          parsed.length != KnowledgeChannel.values.length * 12) {
        return;
      }
      _notes.removeWhere((note) => note.id.startsWith('knowledge-channel-'));
      _seedNotes.removeWhere(
        (note) => note.id.startsWith('knowledge-channel-'),
      );
      _notes.addAll(parsed);
      _seedNotes.addAll(parsed);
      _migrateExistingNotesToCollections();
      if (!_disposed) notifyListeners();
    } catch (_) {
      // The compiled fixture remains available for a corrupt asset bundle.
    }
  }

  Future<void> restore() {
    return _restoreOperation ??= _restoreFromCache();
  }

  Future<bool> ensureCacheRestored({bool retryFailed = false}) async {
    if (_disposed) return false;
    if (retryFailed && _restoreComplete && _cacheRestoreFailed) {
      _restoreComplete = false;
      _restoreOperation = null;
    }
    await restore();
    return !_disposed && cacheRestoreSucceeded;
  }

  Future<void> flushPersistence() async {
    Future<void> observed;
    do {
      observed = _saveQueue;
      await observed;
    } while (!identical(observed, _saveQueue));
  }

  Future<bool> flushPersistenceResult() async {
    _pendingSaveBatch = null;
    await _saveQueue;
    final persisted = _persistenceErrorCode == null;
    if (persisted) {
      for (final snapshot in _manualNoteStages.values) {
        if (!snapshot.rollbackApplied) snapshot.persistenceAcknowledged = true;
      }
    }
    return persisted;
  }

  Future<void> _restoreFromCache() async {
    final cache = _cache;
    if (cache == null) return;
    var changed = false;
    var fixtureMergeSaveFailed = false;
    try {
      final restored = await cache.load();
      final projectionCache = cache is KnowledgeLibraryWorkspaceProjectionCache
          ? cache as KnowledgeLibraryWorkspaceProjectionCache
          : null;
      if (projectionCache != null) {
        _workspaceContentCursor = projectionCache.workspaceContentCursor;
      }
      if (restored != null) {
        final pendingValues = <String, V3FeedItem>{
          for (final note in _notes)
            if (_pendingUpserts.contains(note.id)) note.id: note,
        };
        final readOnlySeeds = _notes.where((note) => note.isReadOnly).toList();
        _notes
          ..clear()
          ..addAll(restored.map(_normalizeOwnership));
        final restoredCount = _notes.length;
        _notes.removeWhere(_isRemoteSubscriptionArticle);
        if (!_includeDemoFixtures) {
          _notes.removeWhere(_isBundledDemoFixture);
        }
        final restoreSeeds = _mergeDefaultFixtureOnRestore
            ? _seedNotes
            : readOnlySeeds;
        if (_mergeDefaultFixtureOnRestore) {
          _notes.removeWhere(
            (note) => v3RetiredKnowledgeFixtureIds.contains(note.id),
          );
        }
        var normalizedCache = _notes.length != restoredCount;
        for (final seed in restoreSeeds) {
          if (_notes.any((note) => note.id == seed.id)) continue;
          _notes.add(seed);
          if (_mergeDefaultFixtureOnRestore) normalizedCache = true;
        }
        for (final entry in pendingValues.entries) {
          final index = _notes.indexWhere((note) => note.id == entry.key);
          if (index == -1) {
            _notes.add(entry.value);
          } else {
            _notes[index] = entry.value;
          }
        }
        _notes.removeWhere((note) => _pendingDeletes.contains(note.id));
        _migrateExistingNotesToCollections();
        _notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        if (normalizedCache) {
          try {
            await cache.save(List<V3FeedItem>.of(_notes));
          } catch (_) {
            fixtureMergeSaveFailed = true;
            _persistenceErrorCode = 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED';
          }
        }
        changed = true;
      }
      _cacheRestoreFailed = false;
      if (!fixtureMergeSaveFailed) _persistenceErrorCode = null;
    } catch (_) {
      _workspaceContentCursor = null;
      _cacheRestoreFailed = true;
      _persistenceErrorCode = 'KNOWLEDGE_LIBRARY_CACHE_LOAD_FAILED';
      changed = true;
    } finally {
      _restoreComplete = true;
      _pendingUpserts.clear();
      _pendingDeletes.clear();
    }
    if (changed && !_disposed) notifyListeners();
  }

  bool _isBundledDemoFixture(V3FeedItem note) =>
      v3RetiredKnowledgeFixtureIds.contains(note.id) ||
      note.id.startsWith('demo-laozhou-') ||
      note.id.startsWith('knowledge-channel-') ||
      v3KnowledgeNoteForId(note.id) != null;

  bool _isRemoteSubscriptionArticle(V3FeedItem note) =>
      note.isReadOnly && note.articleId?.trim().isNotEmpty == true;

  Future<void> loadHotspots() async {
    if (_disposed || _loading) return;
    _loading = true;
    _loadErrorCode = null;
    notifyListeners();
    try {
      final hotspots = await _hotspotRepository.loadHotspots();
      if (_disposed) return;
      for (final note in hotspots) {
        _upsert(note, notify: false, persist: false);
      }
      _loading = false;
      notifyListeners();
    } catch (_) {
      if (_disposed) return;
      _loading = false;
      _loadErrorCode = 'HOTSPOT_NOTES_LOAD_FAILED';
      notifyListeners();
    }
  }

  void setTab(V3KnowledgeLibraryTab value) => _queryController.setTab(value);

  void setSourceCategory(
    V3KnowledgeLibraryTab tab,
    KnowledgeSourceCategory value,
  ) => _queryController.setSourceCategory(tab, value);

  void setDepositSourceCategory(KnowledgeSourceCategory value) =>
      _queryController.setDepositSourceCategory(value);

  bool setCardDisplayMode(KnowledgeCardDisplayMode value) {
    if (_cardDisplayMode == value) return true;
    try {
      _userMetadataRepository?.saveCardDisplayMode(value, updatedAt: _now());
    } catch (_) {
      return false;
    }
    _cardDisplayMode = value;
    notifyListeners();
    return true;
  }

  bool isSubscribed(String contentId) =>
      _hasMembership(contentId.trim(), V3LibraryCollection.subscribed);

  bool canDepositReadOnlyContent(String contentId) =>
      switch (noteForId(contentId.trim())?.ownership) {
        V3NoteOwnership.subscribed || V3NoteOwnership.knowledgeSquare => true,
        _ => false,
      };

  bool subscribeToSquare(String contentId, {DateTime? subscribedAt}) {
    final note = noteForId(contentId.trim());
    if (note == null ||
        !_hasMembership(note.id, V3LibraryCollection.square) ||
        isSubscribed(note.id)) {
      return false;
    }
    final membership = V3LibraryMembership(
      contentId: note.id,
      collection: V3LibraryCollection.subscribed,
      createdAt: subscribedAt ?? _now(),
    );
    try {
      _depositRepository?.saveMembership(membership);
    } catch (_) {
      _depositPersistenceErrorCode = 'KNOWLEDGE_SUBSCRIBE_FAILED';
      notifyListeners();
      return false;
    }
    _memberships.add(membership);
    _depositPersistenceErrorCode = null;
    notifyListeners();
    return true;
  }

  bool unsubscribeFromSquare(String contentId) {
    final note = noteForId(contentId.trim());
    if (note == null ||
        !_hasMembership(note.id, V3LibraryCollection.square) ||
        !isSubscribed(note.id)) {
      return false;
    }
    try {
      _depositRepository?.deleteMembership(
        contentId: note.id,
        collection: V3LibraryCollection.subscribed,
      );
    } catch (_) {
      _depositPersistenceErrorCode = 'KNOWLEDGE_UNSUBSCRIBE_FAILED';
      notifyListeners();
      return false;
    }
    _memberships.removeWhere(
      (membership) =>
          membership.contentId == note.id &&
          membership.collection == V3LibraryCollection.subscribed,
    );
    _depositPersistenceErrorCode = null;
    notifyListeners();
    return true;
  }

  V3DepositRecord? depositRecordFor(String contentId) {
    final normalized = contentId.trim();
    if (_usesWorkspaceFolders) {
      final note = noteForId(normalized);
      return note == null || !_isWorkspaceDepositedNote(note)
          ? null
          : _workspaceDepositRecordFor(note);
    }
    for (final record in _depositRecords) {
      if (record.contentId == normalized) return record;
    }
    return null;
  }

  V3DepositFolder? depositFolderFor(String folderId) {
    final normalized = folderId.trim();
    for (final folder in _activeDepositFolders()) {
      if (folder.id == normalized) return folder;
    }
    return null;
  }

  /// Returns only the folders directly inside [parentFolderId]. A null parent
  /// represents the Deposited root, not an implicit synthetic folder.
  List<V3DepositFolder> depositFoldersIn(String? parentFolderId) {
    final parentId = _normalizedFolderParentId(parentFolderId);
    final folders =
        _activeDepositFolders()
            .where((folder) => folder.parentFolderId == parentId)
            .toList(growable: false)
          ..sort((left, right) {
            final byName = left.name.compareTo(right.name);
            return byName != 0 ? byName : left.id.compareTo(right.id);
          });
    return List<V3DepositFolder>.unmodifiable(folders);
  }

  /// Lists the root-to-leaf path while guarding malformed persisted cycles.
  List<V3DepositFolder> depositFolderAncestors(String folderId) {
    final ancestors = <V3DepositFolder>[];
    final visited = <String>{};
    var current = depositFolderFor(folderId);
    while (current != null && visited.add(current.id)) {
      ancestors.add(current);
      final parentId = current.parentFolderId;
      current = parentId == null ? null : depositFolderFor(parentId);
    }
    return List<V3DepositFolder>.unmodifiable(ancestors.reversed.toList());
  }

  String depositFolderPath(String folderId) =>
      depositFolderAncestors(folderId).map((folder) => folder.name).join(' / ');

  int depositFolderDepth(String folderId) =>
      (depositFolderAncestors(folderId).length - 1).clamp(0, 999).toInt();

  int depositFolderChildCount(String folderId) =>
      depositFoldersIn(folderId).length;

  bool canUseDepositFolderName({
    required String name,
    String? parentFolderId,
    String? excludingFolderId,
  }) {
    final normalizedName = _normalizeFolderName(name);
    final normalizedParentId = _normalizedFolderParentId(parentFolderId);
    if (normalizedName == null ||
        (normalizedParentId != null &&
            depositFolderFor(normalizedParentId) == null)) {
      return false;
    }
    return !_activeDepositFolders().any(
      (folder) =>
          folder.id != excludingFolderId &&
          folder.parentFolderId == normalizedParentId &&
          folder.name.toLowerCase() == normalizedName.toLowerCase(),
    );
  }

  bool isDeposited(String contentId) {
    final normalized = contentId.trim();
    final note = noteForId(normalized);
    if (note?.source == V3MaterialSource.hotspot) return false;
    if (_usesWorkspaceFolders) {
      return note != null && _isWorkspaceDepositedNote(note);
    }
    return _hasDepositMetadata(normalized);
  }

  bool _hasDepositMetadata(String contentId) {
    return _hasMembership(contentId, V3LibraryCollection.deposits) &&
        depositRecordFor(contentId) != null;
  }

  bool _isDepositedNote(V3FeedItem note) {
    if (_usesWorkspaceFolders) return _isWorkspaceDepositedNote(note);
    return note.source != V3MaterialSource.hotspot &&
        _hasDepositMetadata(note.id);
  }

  List<V3FeedItem> depositedNotes({String? folderId}) =>
      List<V3FeedItem>.unmodifiable(
        _notes.where(
          (note) =>
              _isDepositedNote(note) &&
              depositRecordFor(note.id)?.folderId == folderId,
        ),
      );

  String? depositFolderNameFor(String contentId) =>
      _depositFolderNameFor(contentId);

  int depositFolderNoteCount(String folderId) {
    final normalized = folderId.trim();
    if (normalized.isEmpty || depositFolderFor(normalized) == null) return 0;
    return depositedNotes(folderId: normalized).length;
  }

  int get unclassifiedDepositCount => depositedNotes().length;

  void showDepositFolderBrowser() =>
      _queryController.showDepositFolderBrowser();

  void setDepositFolderFilter(String? folderId) =>
      _queryController.setDepositFolderFilter(folderId);

  void showUnclassifiedDeposits() =>
      _queryController.showUnclassifiedDeposits();

  void showAllDeposits() => _queryController.showAllDeposits();

  void setGrouping(V3KnowledgeGrouping value) =>
      _queryController.setGrouping(value);

  void setSourceFilter(KnowledgeSourceFilter value) =>
      _queryController.setSourceFilter(value);

  void setTimeFilter(KnowledgeTimeFilter value) =>
      _queryController.setTimeFilter(value);

  void setCustomTimeRange(KnowledgeDateRange value) =>
      _queryController.setCustomTimeRange(value);

  void setSort(V3KnowledgeSort value) => _queryController.setSort(value);

  void setQuery(String value) => _queryController.setQuery(value);

  void setDepositGrouping(V3KnowledgeGrouping value) =>
      _queryController.setDepositGrouping(value);

  void setDepositSourceFilter(KnowledgeSourceFilter value) =>
      _queryController.setDepositSourceFilter(value);

  void setDepositTimeFilter(KnowledgeTimeFilter value) =>
      _queryController.setDepositTimeFilter(value);

  void setDepositCustomTimeRange(KnowledgeDateRange value) =>
      _queryController.setDepositCustomTimeRange(value);

  void setDepositSort(V3KnowledgeSort value) =>
      _queryController.setDepositSort(value);

  void setDepositQuery(String value) => _queryController.setDepositQuery(value);

  List<V3FeedItem> get filteredNotes => filteredNotesFor(tab);

  List<V3FeedItem> filteredNotesFor(
    V3KnowledgeLibraryTab tab, {
    String? queryOverride,
  }) => _queryController.filteredNotesFor(tab, queryOverride: queryOverride);

  List<V3FeedItem> get filteredDepositNotes =>
      _queryController.filteredDepositNotes;

  List<String> effectiveTags(V3FeedItem note) {
    if (!note.isReadOnly) {
      return _mergeTags(note.topics, const <String>[]);
    }
    return _mergeTags(note.topics, _readOnlyTagOverrides[note.id] ?? const []);
  }

  bool updateEffectiveTags(String noteId, Iterable<String> tags) {
    final note = noteForId(noteId.trim());
    if (note == null) return false;
    late final List<String> normalized;
    try {
      normalized = normalizeKnowledgeTags(tags);
    } on ArgumentError {
      return false;
    }

    if (!note.isReadOnly) {
      if (listEquals(note.topics, normalized)) return true;
      final updated = note.copyWith(
        topics: normalized,
        localRevision: note.localRevision + 1,
        syncState: NoteSyncState.pending,
        updatedAt: _now(),
      );
      _clearConflictState(note.id);
      _upsert(updated);
      return true;
    }

    final authorTags = <String>{
      for (final tag in note.topics) tag.trim().toLowerCase(),
    };
    final customTags = List<String>.unmodifiable(
      normalized.where((tag) => !authorTags.contains(tag.toLowerCase())),
    );
    if (listEquals(
      _readOnlyTagOverrides[note.id] ?? const <String>[],
      customTags,
    )) {
      return true;
    }
    try {
      _userMetadataRepository?.saveTagOverride(
        contentId: note.id,
        tags: customTags,
        updatedAt: _now(),
      );
    } catch (_) {
      return false;
    }
    if (customTags.isEmpty) {
      _readOnlyTagOverrides.remove(note.id);
    } else {
      _readOnlyTagOverrides[note.id] = customTags;
    }
    notifyListeners();
    return true;
  }

  V3FeedItem? createEditableCopy(String noteId) {
    final original = noteForId(noteId.trim());
    if (original == null || !original.isReadOnly) return null;
    final createdAt = _now();
    final baseId =
        'copy-${_stableNoteId('${original.id}|${createdAt.microsecondsSinceEpoch}')}';
    var id = baseId;
    var duplicateIndex = 2;
    while (noteForId(id) != null) {
      id = '$baseId-$duplicateIndex';
      duplicateIndex += 1;
    }
    final linkedMaterials = _uniqueLinkedMaterials(<V3LinkedMaterialRef>[
      ...original.linkedMaterials,
      V3LinkedMaterialRef(
        id: original.id,
        source: original.source,
        title: original.title,
        summary: original.summaryBody,
      ),
    ]);
    final report = original.sproutReport;
    final copy = V3FeedItem(
      id: id,
      title: '${original.title}（副本）',
      source: original.source,
      createdAt: createdAt,
      rawBody: original.rawBody,
      summaryBody: original.summaryBody,
      summaryError: original.summaryError,
      linkedMaterials: linkedMaterials,
      sproutStatus: original.sproutStatus,
      sproutError: original.sproutError,
      sproutTopic: original.sproutTopic,
      mediaAttachments: original.mediaAttachments,
      remoteMediaAttachments: original.remoteMediaAttachments,
      ownership: V3NoteOwnership.mine,
      contentLineId: original.contentLineId,
      contentLineName: original.contentLineName,
      folderId: original.folderId,
      folderName: original.folderName,
      copiedFromContentId: original.id,
      publicUrl: original.publicUrl,
      topics: effectiveTags(original),
      localRevision: 1,
      syncState: NoteSyncState.pending,
      updatedAt: createdAt,
      sproutReport: report == null
          ? null
          : V3SproutReport(
              id: '$id-sprout',
              noteId: id,
              title: report.title,
              markdown: report.markdown,
              generatedAt: report.generatedAt,
            ),
    );
    _upsert(copy);
    return copy;
  }

  V3FeedItem? depositSubscribedSnapshot(
    String noteId, {
    String? folderId,
    DateTime? depositedAt,
  }) {
    final original = noteForId(noteId.trim());
    if (original == null ||
        !original.isReadOnly ||
        original.articleId != null ||
        !canDepositReadOnlyContent(original.id)) {
      return null;
    }
    if (_usesWorkspaceFolders && folderId != null) {
      _depositPersistenceErrorCode = 'WORKSPACE_FOLDER_REMOTE_REQUIRED';
      return null;
    }
    for (final candidate in _notes) {
      if (candidate.ownership != V3NoteOwnership.mine ||
          candidate.copiedFromContentId != original.id) {
        continue;
      }
      if (folderId != null &&
          depositContent(
                candidate.id,
                folderId: folderId,
                depositedAt: depositedAt,
              ) ==
              null) {
        return null;
      }
      return candidate;
    }
    final snapshot = createEditableCopy(original.id);
    if (snapshot == null) return null;
    final resolvedFolder = _normalizedDepositFolderId(folderId);
    if (folderId != null && resolvedFolder == null) {
      deleteNote(snapshot.id);
      return null;
    }
    if (resolvedFolder != null) {
      final moved = depositContent(
        snapshot.id,
        folderId: resolvedFolder,
        depositedAt: depositedAt,
      );
      if (moved == null) {
        deleteNote(snapshot.id);
        return null;
      }
    }
    return snapshot;
  }

  Map<String, List<V3FeedItem>> get groupedNotes {
    return groupedNotesFor(tab);
  }

  Map<String, List<V3FeedItem>> groupedNotesFor(V3KnowledgeLibraryTab tab) =>
      _queryController.groupedNotesFor(tab);

  Map<String, List<V3FeedItem>> get groupedDepositNotes =>
      _queryController.groupedDepositNotes;

  Future<WorkspaceFolderPortResult<V3DepositFolder>>
  createWorkspaceDepositFolder(String name, {String? parentFolderId}) =>
      _runWorkspaceContentSerial(
        () => _createWorkspaceDepositFolderUnlocked(
          name,
          parentFolderId: parentFolderId,
        ),
      );

  Future<WorkspaceFolderPortResult<V3DepositFolder>>
  _createWorkspaceDepositFolderUnlocked(
    String name, {
    String? parentFolderId,
  }) async {
    final normalizedName = _normalizeFolderName(name);
    final normalizedParentId = _normalizedFolderParentId(parentFolderId);
    if (normalizedName == null ||
        !canUseDepositFolderName(
          name: normalizedName,
          parentFolderId: normalizedParentId,
        )) {
      return const WorkspaceFolderPortResult<V3DepositFolder>.failure(
        'WORKSPACE_FOLDER_NAME_INVALID',
      );
    }
    if (!_usesWorkspaceFolders) {
      final folder = createDepositFolder(
        normalizedName,
        parentFolderId: normalizedParentId,
      );
      return folder == null
          ? const WorkspaceFolderPortResult<V3DepositFolder>.failure(
              'DEPOSIT_FOLDER_CREATE_FAILED',
            )
          : WorkspaceFolderPortResult<V3DepositFolder>.success(folder);
    }
    final mutationSubject = '$normalizedParentId|$normalizedName';
    final result = await _workspaceFolderPort.createFolder(
      displayName: normalizedName,
      parentFolderId: normalizedParentId,
      idempotencyKey: _workspaceFolderMutationKey('create', mutationSubject),
    );
    if (!result.isSuccess || result.data == null) {
      return _workspaceFolderFailure(result.status, result.errorCode);
    }
    final remote = _workspaceFolderFromApi(result.data!);
    _completeWorkspaceMutationKey('create', mutationSubject);
    _putWorkspaceFolder(remote);
    notifyListeners();
    await _refreshWorkspaceProjectionAfterMutation();
    return WorkspaceFolderPortResult<V3DepositFolder>.success(
      _depositFolderFromWorkspace(remote),
    );
  }

  Future<WorkspaceFolderPortResult<V3DepositFolder>>
  renameWorkspaceDepositFolder({
    required String folderId,
    required String name,
  }) => _runWorkspaceContentSerial(
    () => _renameWorkspaceDepositFolderUnlocked(folderId: folderId, name: name),
  );

  Future<WorkspaceFolderPortResult<V3DepositFolder>>
  _renameWorkspaceDepositFolderUnlocked({
    required String folderId,
    required String name,
  }) async {
    final folder = depositFolderFor(folderId);
    final normalizedName = _normalizeFolderName(name);
    if (folder == null ||
        normalizedName == null ||
        !canUseDepositFolderName(
          name: normalizedName,
          parentFolderId: folder.parentFolderId,
          excludingFolderId: folder.id,
        )) {
      return const WorkspaceFolderPortResult<V3DepositFolder>.failure(
        'WORKSPACE_FOLDER_NAME_INVALID',
      );
    }
    if (folder.name == normalizedName) {
      return WorkspaceFolderPortResult<V3DepositFolder>.success(folder);
    }
    if (!_usesWorkspaceFolders) {
      return renameDepositFolder(folderId: folder.id, name: normalizedName)
          ? WorkspaceFolderPortResult<V3DepositFolder>.success(
              depositFolderFor(folder.id)!,
            )
          : const WorkspaceFolderPortResult<V3DepositFolder>.failure(
              'DEPOSIT_FOLDER_RENAME_FAILED',
            );
    }
    final remote = _remoteFolderFor(folder.id);
    if (remote == null) {
      return const WorkspaceFolderPortResult<V3DepositFolder>.failure(
        'WORKSPACE_FOLDER_NOT_FOUND',
      );
    }
    final mutationSubject = '${remote.folderId}|$normalizedName|${remote.etag}';
    final result = await _workspaceFolderPort.renameFolder(
      folderId: remote.folderId,
      displayName: normalizedName,
      etag: remote.etag,
      idempotencyKey: _workspaceFolderMutationKey('rename', mutationSubject),
    );
    if (!result.isSuccess || result.data == null) {
      return _workspaceFolderFailure(result.status, result.errorCode);
    }
    final renamed = _workspaceFolderFromApi(result.data!);
    _completeWorkspaceMutationKey('rename', mutationSubject);
    _putWorkspaceFolder(renamed);
    _replaceWorkspaceFolderNameInNotes(renamed);
    notifyListeners();
    await _refreshWorkspaceProjectionAfterMutation();
    return WorkspaceFolderPortResult<V3DepositFolder>.success(
      _depositFolderFromWorkspace(renamed),
    );
  }

  Future<WorkspaceFolderPortResult<bool>> deleteWorkspaceDepositFolder(
    String folderId,
  ) => _runWorkspaceContentSerial(
    () => _deleteWorkspaceDepositFolderUnlocked(folderId),
  );

  Future<WorkspaceFolderPortResult<bool>> _deleteWorkspaceDepositFolderUnlocked(
    String folderId,
  ) async {
    final folder = depositFolderFor(folderId);
    if (folder == null) {
      return const WorkspaceFolderPortResult<bool>.failure(
        'WORKSPACE_FOLDER_NOT_FOUND',
      );
    }
    if (!_usesWorkspaceFolders) {
      return deleteDepositFolder(folder.id)
          ? const WorkspaceFolderPortResult<bool>.success(true)
          : const WorkspaceFolderPortResult<bool>.failure(
              'DEPOSIT_FOLDER_DELETE_FAILED',
            );
    }
    final remote = _remoteFolderFor(folder.id);
    if (remote == null) {
      return const WorkspaceFolderPortResult<bool>.failure(
        'WORKSPACE_FOLDER_NOT_FOUND',
      );
    }
    final mutationSubject = '${remote.folderId}|${remote.etag}';
    final result = await _workspaceFolderPort.deleteFolder(
      folderId: remote.folderId,
      etag: remote.etag,
      idempotencyKey: _workspaceFolderMutationKey('delete', mutationSubject),
    );
    if (!result.isSuccess) {
      return _workspaceFolderFailure(result.status, result.errorCode);
    }
    _completeWorkspaceMutationKey('delete', mutationSubject);
    final tombstoned = await _workspaceFolderPort.folder(
      folderId: remote.folderId,
    );
    final tombstonedFolder = tombstoned.data;
    if (tombstoned.isSuccess &&
        tombstonedFolder != null &&
        tombstonedFolder.state == 'tombstoned') {
      _workspaceTombstonedFolders[remote.folderId] = _workspaceFolderFromApi(
        tombstonedFolder,
      );
    }
    final deletedIds = _workspaceFolderSubtreeIds(remote.folderId);
    _removeWorkspaceFolderSubtree(deletedIds);
    _notes.removeWhere(
      (note) =>
          note.syncState == NoteSyncState.synced &&
          _nonEmpty(note.folderId) != null &&
          deletedIds.contains(note.folderId),
    );
    final selectedFolderId = _queryController.depositFolderFilterId;
    if (selectedFolderId != null && deletedIds.contains(selectedFolderId)) {
      _queryController.showDepositFolderBrowser();
    }
    _schedulePersist();
    notifyListeners();
    await _refreshWorkspaceProjectionAfterMutation();
    return const WorkspaceFolderPortResult<bool>.success(true);
  }

  Future<WorkspaceFolderPortResult<bool>> restoreWorkspaceDepositFolder(
    String folderId,
  ) => _runWorkspaceContentSerial(
    () => _restoreWorkspaceDepositFolderUnlocked(folderId),
  );

  Future<WorkspaceFolderPortResult<bool>>
  _restoreWorkspaceDepositFolderUnlocked(String folderId) async {
    final normalizedFolderId = folderId.trim();
    if (!_usesWorkspaceFolders) {
      return const WorkspaceFolderPortResult<bool>.failure(
        'WORKSPACE_FOLDER_RESTORE_UNAVAILABLE',
      );
    }
    final tombstoned = _workspaceTombstonedFolders[normalizedFolderId];
    if (tombstoned == null || tombstoned.state != 'tombstoned') {
      return const WorkspaceFolderPortResult<bool>.failure(
        'WORKSPACE_FOLDER_RESTORE_NOT_AVAILABLE',
      );
    }
    final mutationSubject = '${tombstoned.folderId}|${tombstoned.etag}';
    final result = await _workspaceFolderPort.restoreFolder(
      folderId: tombstoned.folderId,
      etag: tombstoned.etag,
      idempotencyKey: _workspaceFolderMutationKey('restore', mutationSubject),
    );
    if (!result.isSuccess) {
      return _workspaceFolderFailure(result.status, result.errorCode);
    }
    _completeWorkspaceMutationKey('restore', mutationSubject);
    _workspaceTombstonedFolders.remove(tombstoned.folderId);
    await _refreshWorkspaceProjectionAfterMutation();
    if (!_disposed) notifyListeners();
    return const WorkspaceFolderPortResult<bool>.success(true);
  }

  Future<WorkspaceFolderPortResult<V3DepositRecord>>
  moveDepositContentToWorkspaceFolder({
    required String contentId,
    required String? folderId,
  }) => _runWorkspaceContentSerial(
    () => _moveDepositContentToWorkspaceFolderUnlocked(
      contentId: contentId,
      folderId: folderId,
    ),
  );

  Future<WorkspaceFolderPortResult<V3DepositRecord>>
  _moveDepositContentToWorkspaceFolderUnlocked({
    required String contentId,
    required String? folderId,
  }) async {
    final note = noteForId(contentId.trim());
    if (note == null || !_isDepositedNote(note)) {
      return const WorkspaceFolderPortResult<V3DepositRecord>.failure(
        'WORKSPACE_NOTE_NOT_FOUND',
      );
    }
    final targetFolderId = _normalizedFolderParentId(folderId);
    if (targetFolderId != null && depositFolderFor(targetFolderId) == null) {
      return const WorkspaceFolderPortResult<V3DepositRecord>.failure(
        'WORKSPACE_FOLDER_NOT_FOUND',
      );
    }
    if (!_usesWorkspaceFolders) {
      final record = depositContent(note.id, folderId: targetFolderId);
      return record == null
          ? const WorkspaceFolderPortResult<V3DepositRecord>.failure(
              'DEPOSIT_FOLDER_ASSIGN_FAILED',
            )
          : WorkspaceFolderPortResult<V3DepositRecord>.success(record);
    }
    final remoteNoteId = _nonEmpty(note.remoteNoteId);
    final etag = _nonEmpty(note.etag);
    if (remoteNoteId == null ||
        etag == null ||
        note.syncState != NoteSyncState.synced) {
      return const WorkspaceFolderPortResult<V3DepositRecord>.unavailable(
        'WORKSPACE_NOTE_SYNC_REQUIRED',
      );
    }
    final currentFolderId = _remoteFolderIdFor(note);
    if (currentFolderId == targetFolderId) {
      return WorkspaceFolderPortResult<V3DepositRecord>.success(
        _workspaceDepositRecordFor(note),
      );
    }
    final mutationSubject = '$remoteNoteId|$targetFolderId|$etag';
    final result = await _workspaceFolderPort.moveNotes(
      folderId: targetFolderId,
      notes: <SharedHNoteBatchMoveInput>[
        SharedHNoteBatchMoveInput(noteId: remoteNoteId, etag: etag),
      ],
      idempotencyKey: _workspaceFolderMutationKey('note-move', mutationSubject),
    );
    if (!result.isSuccess || result.data == null) {
      return _workspaceFolderFailure(result.status, result.errorCode);
    }
    SharedHNoteBatchMoveReceipt? receipt;
    for (final candidate in result.data!.notes) {
      if (candidate.noteId == remoteNoteId) {
        receipt = candidate;
        break;
      }
    }
    if (receipt == null) {
      return const WorkspaceFolderPortResult<V3DepositRecord>.failure(
        'WORKSPACE_NOTE_MOVE_RESPONSE_INVALID',
      );
    }
    _completeWorkspaceMutationKey('note-move', mutationSubject);
    final targetName = targetFolderId == null
        ? null
        : depositFolderFor(targetFolderId)?.name;
    final moved = note.copyWith(
      folderId: targetFolderId,
      folderName: targetName,
      noteRevisionId: receipt.noteRevisionId,
      etag: receipt.etag,
      contentCursor: receipt.contentCursor,
      syncState: NoteSyncState.synced,
      updatedAt: _now(),
      clearFolder: targetFolderId == null,
    );
    _upsert(moved);
    await _refreshWorkspaceProjectionAfterMutation();
    return WorkspaceFolderPortResult<V3DepositRecord>.success(
      _workspaceDepositRecordFor(moved),
    );
  }

  V3DepositFolder? createDepositFolder(
    String name, {
    String? parentFolderId,
    DateTime? createdAt,
  }) {
    if (_usesWorkspaceFolders) {
      _depositPersistenceErrorCode = 'WORKSPACE_FOLDER_REMOTE_REQUIRED';
      return null;
    }
    final normalizedName = _normalizeFolderName(name);
    final normalizedParentId = _normalizedFolderParentId(parentFolderId);
    if (normalizedName == null ||
        !canUseDepositFolderName(
          name: normalizedName,
          parentFolderId: normalizedParentId,
        )) {
      return null;
    }
    final timestamp = createdAt ?? _now();
    final baseId = _stableNoteId(
      '${timestamp.microsecondsSinceEpoch}|$normalizedParentId|$normalizedName',
    );
    var id = 'folder-$baseId';
    var duplicateIndex = 2;
    while (depositFolderFor(id) != null) {
      id = 'folder-$baseId-$duplicateIndex';
      duplicateIndex++;
    }
    final folder = V3DepositFolder(
      id: id,
      name: normalizedName,
      parentFolderId: normalizedParentId,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    try {
      _depositRepository?.saveFolder(folder);
    } catch (_) {
      _depositPersistenceErrorCode = 'DEPOSIT_FOLDER_CREATE_FAILED';
      notifyListeners();
      return null;
    }
    _depositFolders.add(folder);
    _sortDepositFolders();
    _depositPersistenceErrorCode = null;
    notifyListeners();
    return folder;
  }

  bool renameDepositFolder({
    required String folderId,
    required String name,
    DateTime? updatedAt,
  }) {
    if (_usesWorkspaceFolders) {
      _depositPersistenceErrorCode = 'WORKSPACE_FOLDER_REMOTE_REQUIRED';
      return false;
    }
    final folder = depositFolderFor(folderId);
    final normalizedName = _normalizeFolderName(name);
    if (folder == null || normalizedName == null) return false;
    if (!canUseDepositFolderName(
      name: normalizedName,
      parentFolderId: folder.parentFolderId,
      excludingFolderId: folder.id,
    )) {
      return false;
    }
    if (folder.name == normalizedName) return true;
    final next = folder.copyWith(
      name: normalizedName,
      updatedAt: updatedAt ?? _now(),
    );
    try {
      _depositRepository?.saveFolder(next);
    } catch (_) {
      _depositPersistenceErrorCode = 'DEPOSIT_FOLDER_RENAME_FAILED';
      notifyListeners();
      return false;
    }
    final index = _depositFolders.indexWhere((item) => item.id == folder.id);
    _depositFolders[index] = next;
    _sortDepositFolders();
    _depositPersistenceErrorCode = null;
    notifyListeners();
    return true;
  }

  bool deleteDepositFolder(String folderId, {DateTime? updatedAt}) {
    if (_usesWorkspaceFolders) {
      _depositPersistenceErrorCode = 'WORKSPACE_FOLDER_REMOTE_REQUIRED';
      return false;
    }
    final folder = depositFolderFor(folderId);
    if (folder == null) return false;
    final timestamp = updatedAt ?? _now();
    try {
      _depositRepository?.deleteFolder(folder.id, updatedAt: timestamp);
    } catch (_) {
      _depositPersistenceErrorCode = 'DEPOSIT_FOLDER_DELETE_FAILED';
      notifyListeners();
      return false;
    }
    _depositFolders.removeWhere((item) => item.id == folder.id);
    for (var index = 0; index < _depositFolders.length; index++) {
      final candidate = _depositFolders[index];
      if (candidate.parentFolderId != folder.id) continue;
      _depositFolders[index] = candidate.copyWith(
        parentFolderId: folder.parentFolderId,
        clearParentFolder: folder.parentFolderId == null,
        updatedAt: timestamp,
      );
    }
    for (var index = 0; index < _depositRecords.length; index++) {
      final record = _depositRecords[index];
      if (record.folderId != folder.id) continue;
      _depositRecords[index] = record.copyWith(
        folderId: folder.parentFolderId,
        clearFolder: folder.parentFolderId == null,
        updatedAt: timestamp,
      );
    }
    if (_queryController.depositFolderFilterId == folder.id) {
      _queryController.setDepositFolderFilter(folder.parentFolderId);
    }
    _sortDepositFolders();
    _depositPersistenceErrorCode = null;
    notifyListeners();
    return true;
  }

  bool assignToDepositFolder({
    required String contentId,
    String? folderId,
    DateTime? updatedAt,
  }) {
    if (_usesWorkspaceFolders) {
      _depositPersistenceErrorCode = 'WORKSPACE_FOLDER_REMOTE_REQUIRED';
      return false;
    }
    final item = noteForId(contentId);
    if (item == null || !_isDepositedNote(item)) return false;
    return depositContent(
          item.id,
          folderId: folderId,
          depositedAt: updatedAt,
        ) !=
        null;
  }

  V3DepositRecord? depositContent(
    String contentId, {
    String? folderId,
    DateTime? depositedAt,
  }) {
    final item = noteForId(contentId.trim());
    if (item == null ||
        item.ownership != V3NoteOwnership.mine ||
        item.source == V3MaterialSource.hotspot) {
      return null;
    }
    if (_usesWorkspaceFolders) {
      if (folderId != null) {
        _depositPersistenceErrorCode = 'WORKSPACE_FOLDER_REMOTE_REQUIRED';
        return null;
      }
      _depositPersistenceErrorCode = null;
      return _workspaceDepositRecordFor(item);
    }
    final normalizedFolderId = _normalizedDepositFolderId(folderId);
    if (folderId != null && normalizedFolderId == null) return null;
    if (normalizedFolderId != null && item.ownership != V3NoteOwnership.mine) {
      return null;
    }
    final timestamp = depositedAt ?? _now();
    final existingRecord = depositRecordFor(item.id);
    final existingMembership = _membershipFor(
      item.id,
      V3LibraryCollection.deposits,
    );
    if (existingRecord?.folderId == normalizedFolderId &&
        existingMembership != null) {
      return existingRecord;
    }
    final membership =
        existingMembership ??
        V3LibraryMembership(
          contentId: item.id,
          collection: V3LibraryCollection.deposits,
          createdAt: timestamp,
        );
    final record = existingRecord == null
        ? V3DepositRecord(
            contentId: item.id,
            folderId: normalizedFolderId,
            depositedAt: timestamp,
            updatedAt: timestamp,
          )
        : existingRecord.copyWith(
            folderId: normalizedFolderId,
            clearFolder: normalizedFolderId == null,
            updatedAt: timestamp,
          );
    try {
      _depositRepository?.saveDeposit(membership: membership, record: record);
    } catch (_) {
      _depositPersistenceErrorCode = existingRecord == null
          ? 'DEPOSIT_CREATE_FAILED'
          : 'DEPOSIT_FOLDER_ASSIGN_FAILED';
      notifyListeners();
      return null;
    }
    if (existingMembership == null) _memberships.add(membership);
    final recordIndex = _depositRecords.indexWhere(
      (candidate) => candidate.contentId == item.id,
    );
    if (recordIndex == -1) {
      _depositRecords.add(record);
    } else {
      _depositRecords[recordIndex] = record;
    }
    if (_growthLedger.every((entry) => entry.contentId != item.id)) {
      _growthLedger.add(
        GrowthLedgerEntry(contentId: item.id, firstDepositedAt: timestamp),
      );
    }
    _depositPersistenceErrorCode = null;
    notifyListeners();
    return record;
  }

  V3FeedItem? depositLibraryEntry(
    V3KnowledgeLibraryEntry entry, {
    String? folderId,
    DateTime? depositedAt,
  }) {
    if (entry.source == V3MaterialSource.hotspot) return null;
    final normalizedFolderId = _normalizedDepositFolderId(folderId);
    if (folderId != null && normalizedFolderId == null) return null;
    final timestamp = depositedAt ?? _now();
    final existing = noteForId(entry.feedItemId ?? entry.id);
    if (existing?.source == V3MaterialSource.hotspot) return null;
    if (existing?.isReadOnly == true) {
      return depositSubscribedSnapshot(
        existing!.id,
        folderId: normalizedFolderId,
        depositedAt: timestamp,
      );
    }
    final item =
        existing ??
        V3FeedItem(
          id: entry.feedItemId ?? entry.id,
          title: entry.title,
          source: entry.source,
          createdAt: timestamp,
          rawBody: entry.summary,
          summaryBody: entry.summary,
          ownership: switch (entry.tab) {
            V3KnowledgeLibraryTab.mine => V3NoteOwnership.mine,
            V3KnowledgeLibraryTab.subscribed => V3NoteOwnership.subscribed,
            V3KnowledgeLibraryTab.square => V3NoteOwnership.knowledgeSquare,
          },
          updatedAt: timestamp,
        );
    if (normalizedFolderId != null && item.ownership != V3NoteOwnership.mine) {
      return null;
    }
    _upsert(item, notify: false);
    if (item.isReadOnly) {
      return depositSubscribedSnapshot(
        item.id,
        folderId: normalizedFolderId,
        depositedAt: timestamp,
      );
    }
    final record = depositContent(
      item.id,
      folderId: normalizedFolderId,
      depositedAt: timestamp,
    );
    return record == null ? null : item;
  }

  bool removeFromDeposits(String contentId) {
    if (_usesWorkspaceFolders) {
      _depositPersistenceErrorCode = 'WORKSPACE_FOLDER_REMOTE_REQUIRED';
      return false;
    }
    final normalized = contentId.trim();
    if (!isDeposited(normalized)) return false;
    try {
      _depositRepository?.deleteDeposit(normalized);
    } catch (_) {
      _depositPersistenceErrorCode = 'DEPOSIT_REMOVE_FAILED';
      notifyListeners();
      return false;
    }
    _depositRecords.removeWhere((record) => record.contentId == normalized);
    _memberships.removeWhere(
      (membership) =>
          membership.contentId == normalized &&
          membership.collection == V3LibraryCollection.deposits,
    );
    _depositPersistenceErrorCode = null;
    notifyListeners();
    return true;
  }

  V3FeedItem importDocument({
    required String pickerRef,
    required String displayName,
    required String rawBody,
    String? mimeType,
    DateTime? importedAt,
  }) {
    final id = 'document-${_stableNoteId(pickerRef)}';
    final description = mimeType == null || mimeType.trim().isEmpty
        ? '本地导入资料'
        : '本地导入资料 · ${mimeType.trim()}';
    final resolvedImportedAt = importedAt ?? _now();
    final item = V3FeedItem(
      id: id,
      title: displayName.trim().isEmpty ? '未命名导入资料' : displayName.trim(),
      source: V3MaterialSource.documentImport,
      createdAt: resolvedImportedAt,
      rawBody: rawBody.trim().isEmpty ? '该资料正在解析中。' : rawBody.trim(),
      summaryBody: description,
      updatedAt: resolvedImportedAt,
    );
    _upsert(item);
    _scheduleAutomaticSync(item);
    return item;
  }

  V3FeedItem importMedia({
    required String pickerRef,
    required String displayName,
    required V3MediaAttachment attachment,
    DateTime? importedAt,
  }) {
    final id = 'media-${_stableNoteId(pickerRef)}';
    final title = displayName.trim().isEmpty ? '未命名相册资料' : displayName.trim();
    final resolvedImportedAt = importedAt ?? _now();
    final item = V3FeedItem(
      id: id,
      title: title,
      source: V3MaterialSource.mediaImport,
      createdAt: resolvedImportedAt,
      rawBody:
          '媒体类型：${attachment.kind == V3MediaAttachmentKind.image ? '图片' : '视频'}\n\n解析中：已保存《$title》，内容解析将在资料能力接入后补充。',
      summaryBody: '本地媒体导入 · 解析中',
      mediaAttachments: <V3MediaAttachment>[attachment],
      updatedAt: resolvedImportedAt,
    );
    _upsert(item);
    return item;
  }

  V3FeedItem upsertProcessedTranscription({
    required String id,
    required String title,
    required String rawBody,
    String? outlineBody,
    String? sproutBody,
    String? recordingId,
    String? minutesStatus,
    String? summaryStatus,
    DateTime? createdAt,
    bool preserveUserEdits = false,
  }) {
    final normalizedId = id.trim();
    final existing = noteForId(normalizedId);
    if (existing != null && hasUnsyncedKnowledgeChanges(existing)) {
      return existing;
    }
    final item = V3FeedItem(
      id: normalizedId,
      title: title.trim().isEmpty ? '独白转写' : title.trim(),
      source: V3MaterialSource.monologue,
      createdAt: createdAt ?? existing?.createdAt ?? _now(),
      rawBody: rawBody.trim(),
      summaryBody: _nonEmpty(outlineBody) ?? existing?.summaryBody,
      recordingId: recordingId ?? existing?.recordingId,
      minutesStatus: minutesStatus ?? existing?.minutesStatus,
      summaryStatus: summaryStatus ?? existing?.summaryStatus,
      linkedMaterials:
          existing?.linkedMaterials ?? const <V3LinkedMaterialRef>[],
      sproutStatus: _nonEmpty(sproutBody) == null
          ? existing?.sproutStatus ?? V3SproutTaskStatus.notStarted
          : V3SproutTaskStatus.succeeded,
      sproutTopic: _nonEmpty(sproutBody) ?? existing?.sproutTopic,
      ownership: existing?.ownership ?? V3NoteOwnership.mine,
      contentLineId: existing?.contentLineId,
      contentLineName: existing?.contentLineName,
      folderId: existing?.folderId,
      folderName: existing?.folderName,
      topics: existing?.topics ?? const <String>[],
      updatedAt: _now(),
      sproutReport: existing?.sproutReport,
      localRevision: preserveUserEdits
          ? (existing?.localRevision ?? 0) + 1
          : existing?.localRevision ?? 0,
      syncState: preserveUserEdits
          ? NoteSyncState.pending
          : existing?.syncState ?? NoteSyncState.synced,
    );
    _upsert(item);
    _scheduleAutomaticSync(item);
    return item;
  }

  V3FeedItem createManualNote({
    required String title,
    required String rawBody,
    DateTime? createdAt,
    V3ContentOrigin contentOrigin = V3ContentOrigin.standard,
  }) {
    return createManualNoteDraft(
      V3NoteDraft(title: title, rawBody: rawBody),
      createdAt: createdAt,
      contentOrigin: contentOrigin,
    );
  }

  V3FeedItem createManualNoteDraft(
    V3NoteDraft draft, {
    DateTime? createdAt,
    V3ContentOrigin contentOrigin = V3ContentOrigin.standard,
    bool scheduleAutomaticSync = true,
    String? creationKey,
  }) => _createManualNoteDraft(
    draft,
    createdAt: createdAt,
    contentOrigin: contentOrigin,
    scheduleAutomaticSync: scheduleAutomaticSync,
    creationKey: creationKey,
  );

  V3FeedItem _createManualNoteDraft(
    V3NoteDraft draft, {
    DateTime? createdAt,
    required V3ContentOrigin contentOrigin,
    required bool scheduleAutomaticSync,
    String? creationKey,
    bool maintainDepositMetadata = true,
    bool clearConflictOnUpdate = true,
  }) {
    final resolvedCreatedAt = createdAt ?? _now();
    final resolvedTitle = _manualNoteTitle(draft.title, draft.rawBody);
    final normalizedCreationKey = _nonEmpty(creationKey);
    if (creationKey != null &&
        (normalizedCreationKey == null || normalizedCreationKey.length > 240)) {
      throw ArgumentError.value(
        creationKey,
        'creationKey',
        'must contain 1-240 non-whitespace characters',
      );
    }
    final baseId = _stableNoteId(
      normalizedCreationKey == null
          ? '${resolvedCreatedAt.microsecondsSinceEpoch}|$resolvedTitle|${draft.rawBody.trim()}'
          : 'manual-note-creation|$normalizedCreationKey',
    );
    var id = 'manual-$baseId';
    if (normalizedCreationKey == null) {
      var duplicateIndex = 2;
      while (noteForId(id) != null) {
        id = 'manual-$baseId-$duplicateIndex';
        duplicateIndex++;
      }
    } else if (noteForId(id) case final existing?) {
      if (existing.isReadOnly || existing.contentOrigin != contentOrigin) {
        throw StateError('MANUAL_NOTE_CREATION_KEY_CONFLICT');
      }
      final replayed = _updateManualNoteDraft(
        id: id,
        draft: draft,
        scheduleAutomaticSync: false,
        maintainDepositMetadata: maintainDepositMetadata,
        clearConflict: clearConflictOnUpdate,
      )!;
      if (scheduleAutomaticSync) _scheduleAutomaticSync(replayed);
      return replayed;
    }
    final item = V3FeedItem(
      id: id,
      title: resolvedTitle,
      source: V3MaterialSource.note,
      createdAt: resolvedCreatedAt,
      rawBody: draft.rawBody.trim(),
      linkedMaterials: _uniqueLinkedMaterials(draft.linkedMaterials),
      contentLineId: _nonEmpty(draft.contentLineId),
      contentLineName: _nonEmpty(draft.contentLineName),
      folderId: _nonEmpty(draft.folderId),
      folderName: _nonEmpty(draft.folderName),
      topics: _uniqueTopics(draft.topics),
      localRevision: 1,
      syncState: NoteSyncState.pending,
      contentOrigin: contentOrigin,
      updatedAt: resolvedCreatedAt,
    );
    _upsert(item, maintainDepositMetadata: maintainDepositMetadata);
    if (scheduleAutomaticSync) _scheduleAutomaticSync(item);
    return item;
  }

  V3FeedItem? updateManualNote({
    required String id,
    required String title,
    required String rawBody,
  }) {
    final existing = noteForId(id.trim());
    if (existing == null || existing.isReadOnly) {
      return null;
    }
    return updateManualNoteDraft(
      id: id,
      draft: V3NoteDraft(
        title: title,
        rawBody: rawBody,
        linkedMaterials: existing.linkedMaterials,
        contentLineId: existing.contentLineId,
        contentLineName: existing.contentLineName,
        folderId: existing.folderId,
        folderName: existing.folderName,
        topics: existing.topics,
      ),
    );
  }

  V3FeedItem? updateManualNoteDraft({
    required String id,
    required V3NoteDraft draft,
    bool scheduleAutomaticSync = true,
  }) => _updateManualNoteDraft(
    id: id,
    draft: draft,
    scheduleAutomaticSync: scheduleAutomaticSync,
  );

  V3FeedItem? _updateManualNoteDraft({
    required String id,
    required V3NoteDraft draft,
    required bool scheduleAutomaticSync,
    bool maintainDepositMetadata = true,
    bool clearConflict = true,
  }) {
    final existing = noteForId(id.trim());
    if (existing == null || existing.isReadOnly) return null;
    final updated = _manualNoteUpdateCandidate(existing, draft);
    if (identical(updated, existing)) {
      _schedulePersist();
      return existing;
    }
    if (clearConflict) _clearConflictState(existing.id);
    _upsert(updated, maintainDepositMetadata: maintainDepositMetadata);
    if (scheduleAutomaticSync) _scheduleAutomaticSync(updated);
    return updated;
  }

  V3FeedItem _manualNoteUpdateCandidate(
    V3FeedItem existing,
    V3NoteDraft draft, {
    bool rawOnly = false,
  }) {
    if (rawOnly) {
      final rawBody = draft.rawBody.trim();
      if (existing.rawBody == rawBody) return existing;
      return existing.copyWith(
        rawBody: rawBody,
        localRevision: existing.localRevision + 1,
        syncState: NoteSyncState.pending,
        pendingRawOnlyUpdate: true,
        updatedAt: _now(),
      );
    }
    final title = _manualNoteTitle(draft.title, draft.rawBody);
    final rawBody = draft.rawBody.trim();
    final linkedMaterials = _uniqueLinkedMaterials(
      draft.linkedMaterials,
    ).where((material) => material.id != existing.id).toList(growable: false);
    final contentLineId = _nonEmpty(draft.contentLineId);
    final contentLineName = _nonEmpty(draft.contentLineName);
    final folderId = _nonEmpty(draft.folderId);
    final folderName = _nonEmpty(draft.folderName);
    final topics = _uniqueTopics(draft.topics);
    if (existing.title == title &&
        existing.rawBody == rawBody &&
        sameKnowledgeLinkedMaterials(
          existing.linkedMaterials,
          linkedMaterials,
        ) &&
        existing.contentLineId == contentLineId &&
        existing.contentLineName == contentLineName &&
        existing.folderId == folderId &&
        existing.folderName == folderName &&
        listEquals(existing.topics, topics)) {
      return existing;
    }
    return existing.copyWith(
      title: title,
      rawBody: rawBody,
      linkedMaterials: linkedMaterials,
      contentLineId: contentLineId,
      contentLineName: contentLineName,
      folderId: folderId,
      folderName: folderName,
      topics: topics,
      localRevision: existing.localRevision + 1,
      syncState: NoteSyncState.pending,
      pendingRawOnlyUpdate: false,
      clearContentLine: contentLineName == null,
      clearFolder: folderName == null,
      updatedAt: _now(),
    );
  }

  /// Stages one create without publishing deposit or synchronization side
  /// effects. The caller must flush the Knowledge cache, then either finalize
  /// or roll back the returned opaque handle.
  Future<KnowledgeManualNoteStage> stageManualNoteCreation(
    V3NoteDraft draft, {
    DateTime? createdAt,
    V3ContentOrigin contentOrigin = V3ContentOrigin.standard,
    String? creationKey,
    KnowledgeManualNoteWriteAhead? beforeMutation,
  }) async {
    await _requireCacheRestoreForManualNoteStage();
    _requireNoActiveManualNoteStage();
    final resolvedCreatedAt = createdAt ?? _now();
    final resolvedTitle = _manualNoteTitle(draft.title, draft.rawBody);
    final normalizedCreationKey = _nonEmpty(creationKey);
    if (creationKey != null &&
        (normalizedCreationKey == null || normalizedCreationKey.length > 240)) {
      throw ArgumentError.value(
        creationKey,
        'creationKey',
        'must contain 1-240 non-whitespace characters',
      );
    }
    final baseId = _stableNoteId(
      normalizedCreationKey == null
          ? '${resolvedCreatedAt.microsecondsSinceEpoch}|$resolvedTitle|${draft.rawBody.trim()}'
          : 'manual-note-creation|$normalizedCreationKey',
    );
    var id = 'manual-$baseId';
    if (normalizedCreationKey == null) {
      var duplicateIndex = 2;
      while (noteForId(id) != null) {
        id = 'manual-$baseId-$duplicateIndex';
        duplicateIndex++;
      }
    }
    final candidate = V3FeedItem(
      id: id,
      title: resolvedTitle,
      source: V3MaterialSource.note,
      createdAt: resolvedCreatedAt,
      rawBody: draft.rawBody.trim(),
      linkedMaterials: _uniqueLinkedMaterials(draft.linkedMaterials),
      contentLineId: _nonEmpty(draft.contentLineId),
      contentLineName: _nonEmpty(draft.contentLineName),
      folderId: _nonEmpty(draft.folderId),
      folderName: _nonEmpty(draft.folderName),
      topics: _uniqueTopics(draft.topics),
      localRevision: 1,
      syncState: NoteSyncState.pending,
      contentOrigin: contentOrigin,
      updatedAt: resolvedCreatedAt,
    );
    final before = noteForId(id);
    if (before != null &&
        (normalizedCreationKey == null ||
            before.isReadOnly ||
            !sameKnowledgeEditableRevision(before, candidate))) {
      throw StateError('MANUAL_NOTE_CREATION_KEY_CONFLICT');
    }
    await beforeMutation?.call(before ?? candidate);
    _requireNoActiveManualNoteStage();
    final current = noteForId(id);
    if (current != null &&
        (normalizedCreationKey == null ||
            current.isReadOnly ||
            !sameKnowledgeEditableRevision(current, candidate))) {
      throw StateError('MANUAL_NOTE_CREATION_KEY_CONFLICT');
    }
    if (before != null &&
        (current == null || !sameKnowledgeEditableRevision(current, before))) {
      throw StateError('MANUAL_NOTE_CREATION_KEY_CONFLICT');
    }
    final notesBefore = <String, V3FeedItem>{
      if (current != null) current.id: current,
    };
    final conflictsBefore = Map<String, KnowledgeNoteConflictSnapshot>.of(
      _conflicts,
    );
    final syncErrorsBefore = Map<String, String>.of(_syncErrors);
    final pendingUpsertsBefore = Set<String>.of(_pendingUpserts);
    final pendingDeletesBefore = Set<String>.of(_pendingDeletes);
    final membershipsBefore = List<V3LibraryMembership>.of(_memberships);
    final depositRecordsBefore = List<V3DepositRecord>.of(_depositRecords);
    final growthEntriesBefore = List<GrowthLedgerEntry>.of(_growthLedger);
    final depositErrorBefore = _depositPersistenceErrorCode;

    if (current == null) {
      _upsert(candidate, maintainDepositMetadata: false);
    } else {
      _schedulePersist();
    }
    final stagedNote = noteForId(id)!;
    return _registerManualNoteStage(
      stagedNote: stagedNote,
      notesBefore: notesBefore,
      conflictsBefore: conflictsBefore,
      syncErrorsBefore: syncErrorsBefore,
      pendingUpsertsBefore: pendingUpsertsBefore,
      pendingDeletesBefore: pendingDeletesBefore,
      membershipsBefore: membershipsBefore,
      depositRecordsBefore: depositRecordsBefore,
      growthEntriesBefore: growthEntriesBefore,
      depositErrorBefore: depositErrorBefore,
      clearConflictOnFinalize: true,
    );
  }

  /// Stages one update while optionally retaining the current conflict until
  /// [finalizeManualNoteStage] crosses the caller's durable cache boundary.
  Future<KnowledgeManualNoteStage?> stageManualNoteUpdate({
    required String id,
    required V3NoteDraft draft,
    V3FeedItem? expectedNote,
    bool rawOnly = false,
    bool preserveConflictUntilFinalize = true,
    KnowledgeManualNoteWriteAhead? beforeMutation,
  }) async {
    final normalizedId = id.trim();
    final guardedNote = expectedNote ?? noteForId(normalizedId);
    await _requireCacheRestoreForManualNoteStage();
    final existing = noteForId(normalizedId);
    if (existing == null ||
        existing.isReadOnly ||
        guardedNote == null ||
        !sameKnowledgeEditableRevision(existing, guardedNote)) {
      return null;
    }
    if (rawOnly &&
        _nonEmpty(existing.remoteNoteId) != null &&
        existing.syncState != NoteSyncState.synced &&
        !existing.pendingRawOnlyUpdate) {
      return null;
    }
    _requireNoActiveManualNoteStage();
    final preparedCandidate = _manualNoteUpdateCandidate(
      existing,
      draft,
      rawOnly: rawOnly,
    );
    await beforeMutation?.call(preparedCandidate);
    _requireNoActiveManualNoteStage();
    final current = noteForId(normalizedId);
    if (current == null ||
        current.isReadOnly ||
        !sameKnowledgeEditableRevision(current, guardedNote) ||
        !sameKnowledgeEditableRevision(current, existing)) {
      return null;
    }
    final conflictsBefore = Map<String, KnowledgeNoteConflictSnapshot>.of(
      _conflicts,
    );
    final syncErrorsBefore = Map<String, String>.of(_syncErrors);
    final pendingUpsertsBefore = Set<String>.of(_pendingUpserts);
    final pendingDeletesBefore = Set<String>.of(_pendingDeletes);
    final membershipsBefore = List<V3LibraryMembership>.of(_memberships);
    final depositRecordsBefore = List<V3DepositRecord>.of(_depositRecords);
    final growthEntriesBefore = List<GrowthLedgerEntry>.of(_growthLedger);
    final depositErrorBefore = _depositPersistenceErrorCode;

    final candidate = _manualNoteUpdateCandidate(
      current,
      draft,
      rawOnly: rawOnly,
    );
    if (!identical(candidate, current)) {
      if (!preserveConflictUntilFinalize) _clearConflictState(current.id);
      _upsert(candidate, maintainDepositMetadata: false);
    } else {
      _schedulePersist();
    }
    final stagedNote = noteForId(normalizedId)!;
    return _registerManualNoteStage(
      stagedNote: stagedNote,
      notesBefore: <String, V3FeedItem>{normalizedId: current},
      conflictsBefore: conflictsBefore,
      syncErrorsBefore: syncErrorsBefore,
      pendingUpsertsBefore: pendingUpsertsBefore,
      pendingDeletesBefore: pendingDeletesBefore,
      membershipsBefore: membershipsBefore,
      depositRecordsBefore: depositRecordsBefore,
      growthEntriesBefore: growthEntriesBefore,
      depositErrorBefore: depositErrorBefore,
      clearConflictOnFinalize: preserveConflictUntilFinalize,
    );
  }

  Future<void> _requireCacheRestoreForManualNoteStage() async {
    if (await ensureCacheRestored()) return;
    if (_disposed) throw StateError('KNOWLEDGE_LIBRARY_DISPOSED');
    throw StateError(
      _persistenceErrorCode ?? 'KNOWLEDGE_LIBRARY_CACHE_LOAD_FAILED',
    );
  }

  /// Commits only a still-current staged mutation. Local deposit metadata and
  /// automatic synchronization begin here, after the caller has acknowledged
  /// its Knowledge cache write.
  bool finalizeManualNoteStage(
    KnowledgeManualNoteStage stage, {
    bool releaseToAutomaticSync = true,
  }) {
    final snapshot = _manualNoteStages[stage];
    if (snapshot == null || snapshot.rollbackApplied) return false;
    if (!snapshot.persistenceAcknowledged) return false;
    if (!_manualNoteStageIsCurrent(stage, snapshot)) {
      _manualNoteStages.remove(stage);
      return false;
    }
    final note = stage.note;
    _ensureCollectionMembershipsForNote(note, now: note.createdAt);
    _ensureOwnedNoteDeposited(note, depositedAt: note.createdAt);
    if (!_usesWorkspaceFolders && !isDeposited(note.id)) {
      _manualNoteStages.remove(stage);
      return false;
    }
    if (snapshot.clearConflictOnFinalize) _clearConflictState(note.id);
    _manualNoteStages.remove(stage);
    if (releaseToAutomaticSync) _scheduleAutomaticSync(note);
    notifyListeners();
    return true;
  }

  /// Restores the exact state captured before [stage] without entering Note
  /// deletion, trash, tombstone, or synchronization paths. The returned value
  /// reports whether the compensating cache snapshot was persisted; once the
  /// in-memory rollback is exact, its stage lock is retired either way.
  Future<bool> rollbackManualNoteStage(KnowledgeManualNoteStage stage) async {
    final snapshot = _manualNoteStages[stage];
    if (snapshot == null || snapshot.persistenceAcknowledged) return false;
    if (!snapshot.rollbackApplied) {
      if (!_manualNoteStageIsCurrent(stage, snapshot)) {
        _manualNoteStages.remove(stage);
        return false;
      }
      final index = _notes.indexWhere((note) => note.id == stage.note.id);
      if (index == -1) return false;
      final previous = snapshot.previousNote;
      if (previous == null) {
        _notes.removeAt(index);
      } else {
        _notes[index] = previous;
      }
      if (snapshot.previousConflict case final conflict?) {
        _conflicts[stage.note.id] = conflict;
      } else {
        _conflicts.remove(stage.note.id);
      }
      if (snapshot.previousSyncError case final error?) {
        _syncErrors[stage.note.id] = error;
      } else {
        _syncErrors.remove(stage.note.id);
      }
      _restorePendingMembership(
        _pendingUpserts,
        stage.note.id,
        snapshot.previousPendingUpsert,
      );
      _restorePendingMembership(
        _pendingDeletes,
        stage.note.id,
        snapshot.previousPendingDelete,
      );
      _depositPersistenceErrorCode = snapshot.depositPersistenceErrorCode;
      _notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _refreshNoteIndexIfChanged();
      snapshot.rollbackApplied = true;
      notifyListeners();
    } else {
      final current = noteForId(stage.note.id);
      if (snapshot.previousNote == null
          ? current != null
          : !identical(current, snapshot.previousNote)) {
        _manualNoteStages.remove(stage);
        return false;
      }
    }

    _schedulePersist();
    final persisted = await flushPersistenceResult();
    _manualNoteStages.remove(stage);
    return persisted;
  }

  KnowledgeManualNoteStage _registerManualNoteStage({
    required V3FeedItem stagedNote,
    required Map<String, V3FeedItem> notesBefore,
    required Map<String, KnowledgeNoteConflictSnapshot> conflictsBefore,
    required Map<String, String> syncErrorsBefore,
    required Set<String> pendingUpsertsBefore,
    required Set<String> pendingDeletesBefore,
    required List<V3LibraryMembership> membershipsBefore,
    required List<V3DepositRecord> depositRecordsBefore,
    required List<GrowthLedgerEntry> growthEntriesBefore,
    required String? depositErrorBefore,
    required bool clearConflictOnFinalize,
  }) {
    final stage = KnowledgeManualNoteStage._(
      note: stagedNote,
      createdNewNote: !notesBefore.containsKey(stagedNote.id),
    );
    _manualNoteStages[stage] = _KnowledgeManualNoteStageSnapshot(
      previousNote: notesBefore[stagedNote.id],
      previousConflict: conflictsBefore[stagedNote.id],
      stagedConflict: _conflicts[stagedNote.id],
      previousSyncError: syncErrorsBefore[stagedNote.id],
      stagedSyncError: _syncErrors[stagedNote.id],
      previousPendingUpsert: pendingUpsertsBefore.contains(stagedNote.id),
      stagedPendingUpsert: _pendingUpserts.contains(stagedNote.id),
      previousPendingDelete: pendingDeletesBefore.contains(stagedNote.id),
      stagedPendingDelete: _pendingDeletes.contains(stagedNote.id),
      memberships: membershipsBefore
          .where((value) => value.contentId == stagedNote.id)
          .toList(growable: false),
      depositRecords: depositRecordsBefore
          .where((value) => value.contentId == stagedNote.id)
          .toList(growable: false),
      growthEntries: growthEntriesBefore
          .where((value) => value.contentId == stagedNote.id)
          .toList(growable: false),
      depositPersistenceErrorCode: depositErrorBefore,
      clearConflictOnFinalize: clearConflictOnFinalize,
    );
    return stage;
  }

  void _requireNoActiveManualNoteStage() {
    if (_manualNoteStages.isNotEmpty) {
      throw StateError('MANUAL_NOTE_STAGE_ALREADY_ACTIVE');
    }
  }

  bool _manualNoteStageIsCurrent(
    KnowledgeManualNoteStage stage,
    _KnowledgeManualNoteStageSnapshot snapshot,
  ) {
    if (!identical(noteForId(stage.note.id), stage.note) ||
        !identical(_conflicts[stage.note.id], snapshot.stagedConflict) ||
        _syncErrors[stage.note.id] != snapshot.stagedSyncError ||
        _pendingUpserts.contains(stage.note.id) !=
            snapshot.stagedPendingUpsert ||
        _pendingDeletes.contains(stage.note.id) !=
            snapshot.stagedPendingDelete) {
      return false;
    }
    return _sameIdentityList(
          _memberships.where((value) => value.contentId == stage.note.id),
          snapshot.memberships,
        ) &&
        _sameIdentityList(
          _depositRecords.where((value) => value.contentId == stage.note.id),
          snapshot.depositRecords,
        ) &&
        _sameIdentityList(
          _growthLedger.where((value) => value.contentId == stage.note.id),
          snapshot.growthEntries,
        );
  }

  static bool _sameIdentityList<T>(Iterable<T> current, List<T> expected) {
    final values = current.toList(growable: false);
    if (values.length != expected.length) return false;
    for (var index = 0; index < values.length; index += 1) {
      if (!identical(values[index], expected[index])) return false;
    }
    return true;
  }

  static void _restorePendingMembership(
    Set<String> values,
    String id,
    bool contained,
  ) {
    if (contained) {
      values.add(id);
    } else {
      values.remove(id);
    }
  }

  /// Releases a locally persisted pending Note to the existing automatic
  /// synchronization path. Callers staging a manual save use this only after
  /// [flushPersistenceResult] succeeds.
  void releasePendingNoteToAutomaticSync(String id) {
    final note = noteForId(id.trim());
    if (note != null) _scheduleAutomaticSync(note);
  }

  V3FeedItem? renameNote({required String id, required String title}) {
    final existing = noteForId(id.trim());
    final normalizedTitle = title.trim();
    if (existing == null || existing.isReadOnly || normalizedTitle.isEmpty) {
      return null;
    }
    final updated = existing.copyWith(
      title: normalizedTitle,
      pendingRawOnlyUpdate: false,
      localRevision: existing.localRevision + 1,
      syncState: NoteSyncState.pending,
      updatedAt: _now(),
    );
    _clearConflictState(existing.id);
    _upsert(updated);
    _scheduleAutomaticSync(updated);
    return updated;
  }

  Future<KnowledgeNoteSyncResult> syncNote(String id) {
    final normalizedId = id.trim();
    final running = _syncOperations[normalizedId];
    if (running != null) return running;

    late final Future<KnowledgeNoteSyncResult> operation;
    operation = _performNoteSync(normalizedId).whenComplete(() {
      if (identical(_syncOperations[normalizedId], operation)) {
        _syncOperations.remove(normalizedId);
        if (!_disposed) notifyListeners();
      }
    });
    _syncOperations[normalizedId] = operation;
    if (!_disposed) notifyListeners();
    return operation;
  }

  Future<KnowledgeNoteSyncResult> resolveConflict(
    String id,
    KnowledgeNoteConflictResolution resolution,
  ) async {
    final normalizedId = id.trim();
    final conflict = _conflicts[normalizedId];
    final current = noteForId(normalizedId);
    if (conflict == null || current == null || current.isReadOnly) {
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.notEditable,
        note: current,
        errorCode: 'KNOWLEDGE_NOTE_CONFLICT_NOT_AVAILABLE',
      );
    }
    if (!sameKnowledgeEditableRevision(current, conflict.localNote)) {
      _clearConflictState(normalizedId);
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.superseded,
        note: current,
        errorCode: 'KNOWLEDGE_NOTE_CONFLICT_SUPERSEDED',
      );
    }

    if (resolution == KnowledgeNoteConflictResolution.useRemote) {
      final remote = conflict.remoteNote;
      final resolved = remote.copyWith(
        ownership: V3NoteOwnership.mine,
        copiedFromContentId: current.copiedFromContentId,
        publicUrl: current.publicUrl,
        localRevision: current.localRevision,
        remoteRevision: remote.remoteRevision,
        syncState: NoteSyncState.synced,
      );
      _clearConflictState(normalizedId);
      _upsert(resolved);
      final persisted = await flushPersistenceResult();
      return KnowledgeNoteSyncResult(
        outcome: persisted
            ? KnowledgeNoteSyncOutcome.synced
            : KnowledgeNoteSyncOutcome.failed,
        note: resolved,
        errorCode: persisted ? null : 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED',
      );
    }

    final pending = current.copyWith(
      remoteRevision: conflict.remoteNote.remoteRevision,
      remoteNoteId: conflict.remoteNote.remoteNoteId,
      noteRevisionId: conflict.remoteNote.noteRevisionId,
      rawPartRevisionId: conflict.remoteNote.rawPartRevisionId,
      etag: conflict.remoteNote.etag,
      contentCursor: conflict.remoteNote.contentCursor,
      syncState: NoteSyncState.pending,
    );
    _clearConflictState(normalizedId);
    _upsert(pending);
    return syncNote(normalizedId);
  }

  V3FeedItem? deleteNote(String id) {
    final normalizedId = id.trim();
    final index = _notes.indexWhere((note) => note.id == normalizedId);
    if (index == -1) return null;

    final candidate = _notes[index];
    if (candidate.isReadOnly) return null;

    if (!_usesWorkspaceFolders) {
      _depositRepository?.deleteContent(normalizedId);
    }
    final removed = _notes.removeAt(index);
    if (!_usesWorkspaceFolders) {
      _memberships.removeWhere(
        (membership) => membership.contentId == normalizedId,
      );
      _depositRecords.removeWhere((record) => record.contentId == normalizedId);
    }
    for (var noteIndex = 0; noteIndex < _notes.length; noteIndex++) {
      final note = _notes[noteIndex];
      final linkedMaterials = note.linkedMaterials
          .where((material) => material.id != normalizedId)
          .toList(growable: false);
      if (linkedMaterials.length != note.linkedMaterials.length) {
        _notes[noteIndex] = note.copyWith(
          linkedMaterials: linkedMaterials,
          localRevision: note.isReadOnly
              ? note.localRevision
              : note.localRevision + 1,
          syncState: note.isReadOnly ? note.syncState : NoteSyncState.pending,
          updatedAt: _now(),
        );
      }
    }
    _notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!_restoreComplete) {
      _pendingDeletes.add(normalizedId);
      _pendingUpserts.remove(normalizedId);
    }
    _clearConflictState(normalizedId);
    _schedulePersist();
    notifyListeners();
    return removed;
  }

  Future<KnowledgeNoteDeleteResult> deleteNoteDurably(String id) async {
    final normalizedId = id.trim();
    final candidate = noteForId(normalizedId);
    if (candidate == null || candidate.isReadOnly) {
      return const KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.notEditable,
        errorCode: 'KNOWLEDGE_NOTE_DELETE_NOT_ALLOWED',
      );
    }
    if (_usesWorkspaceFolders && _canUseRemoteHNoteLifecycle(candidate)) {
      return _runWorkspaceContentSerial(
        () => _deleteWorkspaceNoteWithJournalUnlocked(normalizedId),
      );
    }
    final entry = _createTrashEntry(candidate);
    final previousTrash = List<KnowledgeTrashEntry>.of(_trashEntries);
    final nextTrash = <KnowledgeTrashEntry>[
      entry,
      ...previousTrash.where((value) => value.id != normalizedId),
    ]..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    if (!await _persistTrash(nextTrash)) {
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
        note: candidate,
        errorCode: 'KNOWLEDGE_TRASH_SAVE_FAILED',
      );
    }
    _trashEntries
      ..clear()
      ..addAll(nextTrash);
    try {
      final result = await _deleteLiveNoteDurably(normalizedId);
      if (result.outcome == KnowledgeNoteDeleteOutcome.deleted) {
        if (!_disposed) notifyListeners();
        return result;
      }
      await _persistTrash(previousTrash);
      _trashEntries
        ..clear()
        ..addAll(previousTrash);
      return result;
    } on Object {
      await _persistTrash(previousTrash);
      _trashEntries
        ..clear()
        ..addAll(previousTrash);
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
        note: candidate,
        errorCode: 'KNOWLEDGE_NOTE_DELETE_FAILED',
      );
    }
  }

  Future<KnowledgeNoteDeleteResult> _deleteWorkspaceNoteWithJournalUnlocked(
    String normalizedId,
  ) {
    final service = _noteSyncService;
    final candidate = noteForId(normalizedId);
    if (service == null) {
      return _deleteWorkspaceNoteDurably(normalizedId);
    }
    return service.tombstone(
      localNoteId: normalizedId,
      local: candidate,
      readCurrent: noteForId,
      flushPersistence: flushPersistenceResult,
      fallbackDelete: _deleteWorkspaceNoteDurably,
      idempotencyKeyFor: (subject) =>
          _workspaceFolderMutationKey('note-tombstone', subject),
      deliver: (note, key) =>
          _deleteWorkspaceNoteDurably(note.id, idempotencyKey: key),
      completeMutation: (remoteNoteId, etag) => _completeWorkspaceMutationKey(
        'note-tombstone',
        '$remoteNoteId|$etag',
      ),
    );
  }

  Future<KnowledgeNoteDeleteResult> _deleteWorkspaceNoteDurably(
    String normalizedId, {
    String? idempotencyKey,
  }) async {
    final candidate = noteForId(normalizedId);
    if (candidate == null ||
        candidate.isReadOnly ||
        !_canUseRemoteHNoteLifecycle(candidate)) {
      return const KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.notEditable,
        errorCode: 'WORKSPACE_NOTE_SYNC_REQUIRED',
      );
    }
    final lifecycle = _notePort;
    if (lifecycle is! KnowledgeNoteLifecyclePort) {
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
        note: candidate,
        errorCode: 'WORKSPACE_NOTE_DELETE_UNAVAILABLE',
      );
    }
    final lifecyclePort = lifecycle as KnowledgeNoteLifecyclePort;
    final remoteNoteId = _nonEmpty(candidate.remoteNoteId)!;
    final subject = '$remoteNoteId|${candidate.etag}';
    final mutation = await lifecyclePort.tombstoneNote(
      note: candidate,
      idempotencyKey:
          idempotencyKey ??
          _workspaceFolderMutationKey('note-tombstone', subject),
    );
    if (!mutation.isSuccess ||
        _nonEmpty(mutation.etag) == null ||
        _nonEmpty(mutation.contentCursor) == null) {
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
        note: candidate,
        errorCode: mutation.errorCode ?? 'WORKSPACE_NOTE_TOMBSTONE_FAILED',
      );
    }
    final tombstoned = candidate.copyWith(
      noteRevisionId: mutation.noteRevisionId,
      rawPartRevisionId: mutation.rawPartRevisionId,
      etag: mutation.etag,
      contentCursor: mutation.contentCursor,
      syncState: NoteSyncState.synced,
      updatedAt: _now(),
    );
    final entry = _createTrashEntry(tombstoned);
    final previousTrash = List<KnowledgeTrashEntry>.of(_trashEntries);
    final nextTrash = <KnowledgeTrashEntry>[
      entry,
      ...previousTrash.where((value) => value.id != normalizedId),
    ]..sort((left, right) => right.deletedAt.compareTo(left.deletedAt));
    if (!await _persistTrash(nextTrash)) {
      await _rollbackWorkspaceDeleteAfterLocalFailure(
        lifecycle: lifecyclePort,
        tombstoned: tombstoned,
        tombstoneSubject: subject,
        tombstonedTrash: nextTrash,
      );
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
        note: candidate,
        errorCode: 'KNOWLEDGE_TRASH_SAVE_FAILED',
      );
    }
    _trashEntries
      ..clear()
      ..addAll(nextTrash);
    try {
      final local = await _deleteWorkspaceLiveNoteDurably(normalizedId);
      if (local.outcome == KnowledgeNoteDeleteOutcome.deleted) {
        _completeWorkspaceMutationKey('note-tombstone', subject);
        await _refreshWorkspaceProjectionAfterMutation();
        if (!_disposed) notifyListeners();
        return local;
      }
      await _rollbackWorkspaceDeleteAfterLocalFailure(
        lifecycle: lifecyclePort,
        tombstoned: tombstoned,
        tombstoneSubject: subject,
        tombstonedTrash: nextTrash,
      );
      return local;
    } on Object {
      await _rollbackWorkspaceDeleteAfterLocalFailure(
        lifecycle: lifecyclePort,
        tombstoned: tombstoned,
        tombstoneSubject: subject,
        tombstonedTrash: nextTrash,
      );
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
        note: candidate,
        errorCode: 'KNOWLEDGE_NOTE_DELETE_FAILED',
      );
    }
  }

  Future<void> _rollbackWorkspaceDeleteAfterLocalFailure({
    required KnowledgeNoteLifecyclePort lifecycle,
    required V3FeedItem tombstoned,
    required String tombstoneSubject,
    required List<KnowledgeTrashEntry> tombstonedTrash,
  }) async {
    final restoredNote = await _compensateWorkspaceTombstone(
      lifecycle: lifecycle,
      tombstoned: tombstoned,
      tombstoneSubject: tombstoneSubject,
    );
    final tombstoneEntry = tombstonedTrash.firstWhere(
      (entry) => entry.id == tombstoned.id,
    );
    if (restoredNote != null) {
      _restoreWorkspaceDeletedProjection(restoredNote, tombstoneEntry);
    } else {
      _removeWorkspaceDeletedProjection(tombstoned.id);
    }
    final cacheSaved = await _saveWorkspaceNoteSnapshot(
      List<V3FeedItem>.of(_notes),
    );
    final currentTrash = List<KnowledgeTrashEntry>.of(_trashEntries);
    final targetTrash = <KnowledgeTrashEntry>[
      if (restoredNote == null) tombstoneEntry,
      ...currentTrash.where((entry) => entry.id != tombstoned.id),
    ]..sort((left, right) => right.deletedAt.compareTo(left.deletedAt));
    var persisted = await _persistTrash(targetTrash);
    if (!persisted) persisted = await _persistTrash(targetTrash);
    final currentIndex = _trashEntries.indexWhere(
      (entry) => entry.id == tombstoned.id,
    );
    if (restoredNote != null) {
      if (currentIndex != -1) _trashEntries.removeAt(currentIndex);
    } else if (currentIndex == -1) {
      _trashEntries.add(tombstoneEntry);
    } else {
      _trashEntries[currentIndex] = tombstoneEntry;
    }
    if (cacheSaved && persisted) {
      _persistenceErrorCode = null;
    }
    if (!cacheSaved || !persisted || restoredNote == null) {
      await _refreshWorkspaceProjectionAfterMutation();
    }
    if (!_disposed) notifyListeners();
  }

  Future<V3FeedItem?> _compensateWorkspaceTombstone({
    required KnowledgeNoteLifecyclePort lifecycle,
    required V3FeedItem tombstoned,
    required String tombstoneSubject,
  }) async {
    // The delete intent has been compensated or is being reconciled; it must
    // never be replayed with the pre-tombstone ETag on a later user retry.
    _completeWorkspaceMutationKey('note-tombstone', tombstoneSubject);
    final restored = await _restoreWorkspaceTombstone(lifecycle, tombstoned);
    final restoredNote = restored?.note;
    if (restored?.isSuccess == true && restoredNote != null) {
      return restoredNote;
    }
    return null;
  }

  Future<KnowledgeNoteLifecycleResult?> _restoreWorkspaceTombstone(
    KnowledgeNoteLifecyclePort lifecycle,
    V3FeedItem tombstoned,
  ) async {
    final remoteNoteId = _nonEmpty(tombstoned.remoteNoteId);
    final etag = _nonEmpty(tombstoned.etag);
    if (remoteNoteId == null || etag == null) return null;
    final subject = '$remoteNoteId|$etag';
    try {
      final restored = await lifecycle.restoreNote(
        note: tombstoned,
        idempotencyKey: _workspaceFolderMutationKey('note-restore', subject),
      );
      if (restored.isSuccess) {
        _completeWorkspaceMutationKey('note-restore', subject);
      }
      return restored;
    } on Object {
      return null;
    }
  }

  KnowledgeTrashEntry _createTrashEntry(V3FeedItem candidate) {
    final backlinks = <KnowledgeTrashBacklink>[];
    for (final owner in _notes) {
      if (owner.id == candidate.id) continue;
      for (var index = 0; index < owner.linkedMaterials.length; index++) {
        final material = owner.linkedMaterials[index];
        if (material.id == candidate.id) {
          backlinks.add(
            KnowledgeTrashBacklink(
              ownerNoteId: owner.id,
              material: material,
              index: index,
            ),
          );
        }
      }
    }
    return KnowledgeTrashEntry(
      note: candidate,
      deletedAt: _now(),
      memberships: _memberships
          .where((membership) => membership.contentId == candidate.id)
          .toList(growable: false),
      depositRecord: depositRecordFor(candidate.id),
      backlinks: List<KnowledgeTrashBacklink>.unmodifiable(backlinks),
    );
  }

  Future<KnowledgeNoteDeleteResult> _deleteWorkspaceLiveNoteDurably(
    String id,
  ) async {
    final removed = deleteNote(id);
    if (removed == null) {
      return const KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.notEditable,
        errorCode: 'KNOWLEDGE_NOTE_DELETE_NOT_ALLOWED',
      );
    }
    if (await flushPersistenceResult()) {
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.deleted,
        note: removed,
      );
    }

    // The caller compensates the remote tombstone before adding this Note back.
    // Do not restore a whole stale snapshot and lose another Note's edit.
    return KnowledgeNoteDeleteResult(
      outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
      note: removed,
      errorCode: 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED',
    );
  }

  Future<KnowledgeNoteDeleteResult> _deleteLiveNoteDurably(String id) async {
    final normalizedId = id.trim();
    final notesBefore = List<V3FeedItem>.of(_notes);
    final conflictsBefore = Map<String, KnowledgeNoteConflictSnapshot>.of(
      _conflicts,
    );
    final errorsBefore = Map<String, String>.of(_syncErrors);
    final pendingUpsertsBefore = Set<String>.of(_pendingUpserts);
    final pendingDeletesBefore = Set<String>.of(_pendingDeletes);
    final membershipsBefore = List<V3LibraryMembership>.of(_memberships);
    final depositRecordsBefore = List<V3DepositRecord>.of(_depositRecords);
    final removed = deleteNote(normalizedId);
    if (removed == null) {
      return const KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.notEditable,
        errorCode: 'KNOWLEDGE_NOTE_DELETE_NOT_ALLOWED',
      );
    }

    if (await flushPersistenceResult()) {
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.deleted,
        note: removed,
      );
    }

    _notes
      ..clear()
      ..addAll(notesBefore);
    _conflicts
      ..clear()
      ..addAll(conflictsBefore);
    _syncErrors
      ..clear()
      ..addAll(errorsBefore);
    _pendingUpserts
      ..clear()
      ..addAll(pendingUpsertsBefore);
    _pendingDeletes
      ..clear()
      ..addAll(pendingDeletesBefore);
    _memberships
      ..clear()
      ..addAll(membershipsBefore);
    _depositRecords
      ..clear()
      ..addAll(depositRecordsBefore);
    if (!_usesWorkspaceFolders) {
      for (final membership in membershipsBefore) {
        if (membership.contentId == normalizedId) {
          _depositRepository?.saveMembership(membership);
        }
      }
      for (final record in depositRecordsBefore) {
        if (record.contentId == normalizedId) {
          _depositRepository?.saveDepositRecord(record);
        }
      }
    }
    if (!_disposed) notifyListeners();
    return KnowledgeNoteDeleteResult(
      outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
      note: removed,
      errorCode: 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED',
    );
  }

  Future<bool> restoreTrashEntry(String id) async {
    final normalizedId = id.trim();
    final index = _trashEntries.indexWhere((entry) => entry.id == normalizedId);
    if (index == -1 || noteForId(normalizedId) != null) return false;
    final entry = _trashEntries[index];
    if (_usesWorkspaceFolders && _canUseRemoteHNoteLifecycle(entry.note)) {
      return _runWorkspaceContentSerial(
        () => _restoreWorkspaceTrashEntry(index, entry),
      );
    }
    final nextNotes = List<V3FeedItem>.of(_notes)..add(entry.note);
    for (final backlink in entry.backlinks) {
      final ownerIndex = nextNotes.indexWhere(
        (note) => note.id == backlink.ownerNoteId,
      );
      if (ownerIndex == -1) continue;
      final owner = nextNotes[ownerIndex];
      if (owner.linkedMaterials.any(
        (material) => material.id == backlink.material.id,
      )) {
        continue;
      }
      final linked = List<V3LinkedMaterialRef>.of(owner.linkedMaterials);
      linked.insert(backlink.index.clamp(0, linked.length), backlink.material);
      nextNotes[ownerIndex] = owner.copyWith(
        linkedMaterials: linked,
        localRevision: owner.isReadOnly
            ? owner.localRevision
            : owner.localRevision + 1,
        syncState: owner.isReadOnly ? owner.syncState : NoteSyncState.pending,
        updatedAt: _now(),
      );
    }
    nextNotes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    try {
      if (!_usesWorkspaceFolders) {
        for (final membership in entry.memberships) {
          _depositRepository?.saveMembership(membership);
        }
        if (entry.depositRecord case final record?) {
          _depositRepository?.saveDepositRecord(record);
        }
      }
      await _cache?.save(nextNotes);
    } on Object {
      return false;
    }
    _notes
      ..clear()
      ..addAll(nextNotes);
    if (!_usesWorkspaceFolders) {
      for (final membership in entry.memberships) {
        if (!_memberships.any(
          (value) =>
              value.contentId == membership.contentId &&
              value.collection == membership.collection,
        )) {
          _memberships.add(membership);
        }
      }
      if (entry.depositRecord case final record?) {
        _depositRecords.removeWhere(
          (value) => value.contentId == record.contentId,
        );
        _depositRecords.add(record);
      }
    }
    _trashEntries.removeAt(index);
    await _persistTrash(List<KnowledgeTrashEntry>.of(_trashEntries));
    _persistenceErrorCode = null;
    notifyListeners();
    return true;
  }

  Future<bool> _restoreWorkspaceTrashEntry(
    int index,
    KnowledgeTrashEntry entry,
  ) async {
    if (index < 0 ||
        index >= _trashEntries.length ||
        _trashEntries[index].id != entry.id ||
        noteForId(entry.id) != null) {
      return false;
    }
    final lifecycle = _notePort;
    if (lifecycle is! KnowledgeNoteLifecyclePort) return false;
    final lifecyclePort = lifecycle as KnowledgeNoteLifecyclePort;
    final remoteNoteId = _nonEmpty(entry.note.remoteNoteId);
    final etag = _nonEmpty(entry.note.etag);
    if (remoteNoteId == null || etag == null) return false;
    final subject = '$remoteNoteId|$etag';
    final restored = await lifecyclePort.restoreNote(
      note: entry.note,
      idempotencyKey: _workspaceFolderMutationKey('note-restore', subject),
    );
    final restoredNote = restored.note;
    if (!restored.isSuccess || restoredNote == null) return false;

    final currentTrashIndex = _trashEntries.indexWhere(
      (candidate) => candidate.id == entry.id,
    );
    if (currentTrashIndex == -1) {
      await _rollbackWorkspaceRestoreAfterLocalFailure(
        lifecycle: lifecyclePort,
        restoredNote: restoredNote,
        restoreSubject: subject,
        entry: entry,
      );
      return false;
    }
    if (noteForId(entry.id) != null) {
      _completeWorkspaceMutationKey('note-restore', subject);
      await _discardWorkspaceTrashEntriesForLiveNotes();
      return false;
    }
    final nextNotes = _notesWithRestoredWorkspaceTrashEntry(
      _notes,
      restoredNote: restoredNote,
      entry: entry,
    );
    if (!await _saveWorkspaceNoteSnapshot(nextNotes)) {
      await _rollbackWorkspaceRestoreAfterLocalFailure(
        lifecycle: lifecyclePort,
        restoredNote: restoredNote,
        restoreSubject: subject,
        entry: entry,
      );
      return false;
    }
    final nextTrash = List<KnowledgeTrashEntry>.of(_trashEntries)
      ..removeAt(currentTrashIndex);
    if (!await _persistTrash(nextTrash)) {
      await _rollbackWorkspaceRestoreAfterLocalFailure(
        lifecycle: lifecyclePort,
        restoredNote: restoredNote,
        restoreSubject: subject,
        entry: entry,
      );
      return false;
    }
    final committedNotes = _notesWithRestoredWorkspaceTrashEntry(
      _notes,
      restoredNote: restoredNote,
      entry: entry,
    );
    _notes
      ..clear()
      ..addAll(committedNotes);
    _trashEntries.removeWhere((candidate) => candidate.id == entry.id);
    _completeWorkspaceMutationKey('note-restore', subject);
    final committedCacheSaved = await _saveWorkspaceNoteSnapshot(
      committedNotes,
    );
    if (committedCacheSaved) {
      _persistenceErrorCode = null;
    }
    await _refreshWorkspaceProjectionAfterMutation();
    notifyListeners();
    return true;
  }

  Future<void> _rollbackWorkspaceRestoreAfterLocalFailure({
    required KnowledgeNoteLifecyclePort lifecycle,
    required V3FeedItem restoredNote,
    required String restoreSubject,
    required KnowledgeTrashEntry entry,
  }) async {
    // Keep the original restore key until the compensating tombstone is known
    // to have succeeded. A transient failure can then replay the accepted
    // restore instead of issuing a new request with a stale tombstone ETag.
    final remoteNoteId = _nonEmpty(restoredNote.remoteNoteId);
    final etag = _nonEmpty(restoredNote.etag);
    if (remoteNoteId == null || etag == null) {
      await _refreshWorkspaceProjectionAfterMutation();
      return;
    }
    final tombstoneSubject = '$remoteNoteId|$etag';
    KnowledgeNoteLifecycleResult tombstone;
    try {
      tombstone = await lifecycle.tombstoneNote(
        note: restoredNote,
        idempotencyKey: _workspaceFolderMutationKey(
          'note-tombstone',
          tombstoneSubject,
        ),
      );
    } on Object {
      await _refreshWorkspaceProjectionAfterMutation();
      return;
    }
    final noteRevisionId = _nonEmpty(tombstone.noteRevisionId);
    final rawPartRevisionId = _nonEmpty(tombstone.rawPartRevisionId);
    final tombstoneEtag = _nonEmpty(tombstone.etag);
    final contentCursor = _nonEmpty(tombstone.contentCursor);
    if (!tombstone.isSuccess ||
        noteRevisionId == null ||
        rawPartRevisionId == null ||
        tombstoneEtag == null ||
        contentCursor == null) {
      await _refreshWorkspaceProjectionAfterMutation();
      return;
    }
    _completeWorkspaceMutationKey('note-restore', restoreSubject);
    _completeWorkspaceMutationKey('note-tombstone', tombstoneSubject);
    final tombstoned = restoredNote.copyWith(
      noteRevisionId: noteRevisionId,
      rawPartRevisionId: rawPartRevisionId,
      etag: tombstoneEtag,
      contentCursor: contentCursor,
      syncState: NoteSyncState.synced,
      updatedAt: _now(),
    );
    final refreshedEntry = KnowledgeTrashEntry(
      note: tombstoned,
      deletedAt: entry.deletedAt,
      memberships: entry.memberships,
      depositRecord: entry.depositRecord,
      backlinks: entry.backlinks,
    );
    final cacheSaved = await _saveWorkspaceNoteSnapshot(
      List<V3FeedItem>.of(_notes),
    );
    var trashSaved = true;
    final currentTrash = List<KnowledgeTrashEntry>.of(_trashEntries);
    final hadEntry = currentTrash.any((candidate) => candidate.id == entry.id);
    final rollbackTrash = <KnowledgeTrashEntry>[
      if (hadEntry) refreshedEntry,
      ...currentTrash.where((candidate) => candidate.id != entry.id),
    ]..sort((left, right) => right.deletedAt.compareTo(left.deletedAt));
    if (hadEntry) {
      trashSaved = await _persistTrash(rollbackTrash);
      if (!trashSaved) trashSaved = await _persistTrash(rollbackTrash);
      final currentIndex = _trashEntries.indexWhere(
        (candidate) => candidate.id == entry.id,
      );
      if (currentIndex != -1) _trashEntries[currentIndex] = refreshedEntry;
    }
    if (cacheSaved && trashSaved) _persistenceErrorCode = null;
    await _refreshWorkspaceProjectionAfterMutation();
  }

  List<V3FeedItem> _notesWithRestoredWorkspaceTrashEntry(
    Iterable<V3FeedItem> notes, {
    required V3FeedItem restoredNote,
    required KnowledgeTrashEntry entry,
  }) {
    final next = List<V3FeedItem>.of(notes);
    final restoredIndex = next.indexWhere((note) => note.id == entry.id);
    if (restoredIndex == -1) {
      next.add(restoredNote);
    } else {
      next[restoredIndex] = restoredNote;
    }
    for (final backlink in entry.backlinks) {
      final ownerIndex = next.indexWhere(
        (note) => note.id == backlink.ownerNoteId,
      );
      if (ownerIndex == -1) continue;
      final owner = next[ownerIndex];
      if (owner.linkedMaterials.any(
        (material) => material.id == backlink.material.id,
      )) {
        continue;
      }
      final linked = List<V3LinkedMaterialRef>.of(owner.linkedMaterials);
      linked.insert(backlink.index.clamp(0, linked.length), backlink.material);
      next[ownerIndex] = owner.copyWith(
        linkedMaterials: linked,
        localRevision: owner.isReadOnly
            ? owner.localRevision
            : owner.localRevision + 1,
        syncState: owner.isReadOnly ? owner.syncState : NoteSyncState.pending,
        updatedAt: _now(),
      );
    }
    next.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return next;
  }

  void _restoreWorkspaceDeletedProjection(
    V3FeedItem restoredNote,
    KnowledgeTrashEntry entry,
  ) {
    final nextNotes = _notesWithRestoredWorkspaceTrashEntry(
      _notes,
      restoredNote: restoredNote,
      entry: entry,
    );
    _notes
      ..clear()
      ..addAll(nextNotes);
    _pendingUpserts.remove(restoredNote.id);
    _pendingDeletes.remove(restoredNote.id);
    _clearConflictState(restoredNote.id);
  }

  void _removeWorkspaceDeletedProjection(String id) {
    final normalizedId = id.trim();
    final index = _notes.indexWhere((note) => note.id == normalizedId);
    if (index != -1) _notes.removeAt(index);
    for (var noteIndex = 0; noteIndex < _notes.length; noteIndex++) {
      final note = _notes[noteIndex];
      final linkedMaterials = note.linkedMaterials
          .where((material) => material.id != normalizedId)
          .toList(growable: false);
      if (linkedMaterials.length == note.linkedMaterials.length) continue;
      _notes[noteIndex] = note.copyWith(
        linkedMaterials: linkedMaterials,
        localRevision: note.isReadOnly
            ? note.localRevision
            : note.localRevision + 1,
        syncState: note.isReadOnly ? note.syncState : NoteSyncState.pending,
        updatedAt: _now(),
      );
    }
    _notes.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    _pendingUpserts.remove(normalizedId);
    _pendingDeletes.remove(normalizedId);
    _clearConflictState(normalizedId);
  }

  Future<bool> permanentlyDeleteTrashEntry(String id) async {
    final next = _trashEntries.where((entry) => entry.id != id.trim()).toList();
    if (next.length == _trashEntries.length || !await _persistTrash(next)) {
      return false;
    }
    _trashEntries
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  Future<bool> clearTrash() async {
    if (!await _persistTrash(const <KnowledgeTrashEntry>[])) return false;
    _trashEntries.clear();
    notifyListeners();
    return true;
  }

  Future<int> purgeExpiredTrash() async {
    final now = _now();
    final next = _trashEntries
        .where((entry) => !entry.isExpiredAt(now))
        .toList(growable: false);
    final removed = _trashEntries.length - next.length;
    if (removed == 0 || !await _persistTrash(next)) return 0;
    _trashEntries
      ..clear()
      ..addAll(next);
    notifyListeners();
    return removed;
  }

  Future<bool> _persistTrash(List<KnowledgeTrashEntry> entries) async {
    final repository = _trashRepository;
    if (repository == null) return true;
    var succeeded = true;
    _trashSaveQueue = _trashSaveQueue.catchError((Object _) {}).then((_) async {
      try {
        await repository.save(entries);
      } on Object {
        succeeded = false;
      }
    });
    await _trashSaveQueue;
    if (!succeeded) _persistenceErrorCode = 'KNOWLEDGE_TRASH_SAVE_FAILED';
    return succeeded;
  }

  Future<void> _discardWorkspaceTrashEntriesForLiveNotes() async {
    if (!_usesWorkspaceFolders || _trashEntries.isEmpty) return;
    final liveLocalIds = _notes.map((note) => note.id).toSet();
    final liveRemoteIds = _notes
        .map((note) => _nonEmpty(note.remoteNoteId))
        .whereType<String>()
        .toSet();
    final retained = _trashEntries
        .where((entry) {
          if (liveLocalIds.contains(entry.id)) return false;
          final remoteNoteId = _nonEmpty(entry.note.remoteNoteId);
          return remoteNoteId == null || !liveRemoteIds.contains(remoteNoteId);
        })
        .toList(growable: false);
    if (retained.length == _trashEntries.length) return;
    final persisted = await _persistTrash(retained);
    _trashEntries
      ..clear()
      ..addAll(retained);
    if (persisted) _persistenceErrorCode = null;
    if (!_disposed) notifyListeners();
  }

  void updateNote(V3FeedItem item) {
    final existing = noteForId(item.id);
    if (existing != null &&
        hasUnsyncedKnowledgeChanges(existing) &&
        item.syncState == NoteSyncState.synced) {
      return;
    }
    if (existing != null &&
        wouldDiscardKnowledgeRemoteBinding(existing, item)) {
      debugKnowledgeSync('ignored stale unbound snapshot');
      return;
    }
    _upsert(item);
  }

  V3FeedItem mergeRemoteNote(V3FeedItem item) {
    final existing = _localNoteForRemote(item);
    if (existing != null && hasUnsyncedKnowledgeChanges(existing)) {
      return existing;
    }
    final merged = existing == null
        ? item.copyWith(
            syncState: NoteSyncState.synced,
            remoteRevision: item.remoteRevision ?? item.localRevision,
          )
        : _mergeRemoteIntoExisting(existing, item);
    _clearConflictState(merged.id);
    _upsert(merged);
    return merged;
  }

  V3FeedItem? _localNoteForRemote(V3FeedItem remote) {
    final remoteId = _nonEmpty(remote.remoteNoteId) ?? remote.id;
    for (final note in _notes) {
      if (note.id == remote.id || _nonEmpty(note.remoteNoteId) == remoteId) {
        return note;
      }
    }
    return null;
  }

  V3FeedItem _mergeRemoteIntoExisting(V3FeedItem existing, V3FeedItem remote) {
    final retainLocalFayaReport =
        remote.sproutReport == null &&
        existing.sproutReport != null &&
        remote.rawPartRevisionId == existing.rawPartRevisionId;
    return V3FeedItem(
      id: existing.id,
      title: remote.title,
      source: existing.source,
      createdAt: remote.createdAt,
      updatedAt: remote.updatedAt,
      rawBody: remote.rawBody,
      summaryBody: remote.summaryBody,
      summaryError: remote.summaryError,
      recordingId: remote.recordingId ?? existing.recordingId,
      minutesStatus: remote.minutesStatus ?? existing.minutesStatus,
      summaryStatus: remote.summaryStatus ?? existing.summaryStatus,
      linkedMaterials: remote.linkedMaterials.isEmpty
          ? existing.linkedMaterials
          : remote.linkedMaterials,
      sproutStatus: retainLocalFayaReport
          ? existing.sproutStatus
          : remote.sproutStatus,
      sproutError: retainLocalFayaReport
          ? existing.sproutError
          : remote.sproutError,
      sproutTopic: retainLocalFayaReport
          ? existing.sproutTopic
          : remote.sproutTopic,
      sproutReport: retainLocalFayaReport
          ? existing.sproutReport
          : remote.sproutReport,
      activeDerivedTasks: remote.activeDerivedTasksAuthoritative
          ? remote.activeDerivedTasks
          : existing.activeDerivedTasks,
      activeDerivedTasksAuthoritative:
          remote.activeDerivedTasksAuthoritative ||
          existing.activeDerivedTasksAuthoritative,
      mediaAttachments: remote.mediaAttachments.isEmpty
          ? existing.mediaAttachments
          : remote.mediaAttachments,
      remoteMediaAttachments: remote.remoteMediaAttachments,
      ownership: V3NoteOwnership.mine,
      contentLineId: existing.contentLineId,
      contentLineName: existing.contentLineName,
      folderId: remote.folderId,
      folderName: existing.folderId == remote.folderId
          ? existing.folderName
          : remote.folderName,
      copiedFromContentId: existing.copiedFromContentId,
      publicUrl: existing.publicUrl,
      topics: remote.topics.isEmpty ? existing.topics : remote.topics,
      localRevision: existing.localRevision,
      remoteRevision: _maxLegacyRevision(
        existing.remoteRevision,
        remote.remoteRevision ?? remote.localRevision,
      ),
      remoteNoteId: remote.remoteNoteId ?? existing.remoteNoteId,
      remoteSourceKind: remote.remoteSourceKind ?? existing.remoteSourceKind,
      noteRevisionId: remote.noteRevisionId ?? existing.noteRevisionId,
      rawPartRevisionId: remote.rawPartRevisionId ?? existing.rawPartRevisionId,
      outlinePartRevisionId: remote.outlinePartRevisionId,
      germinationPartRevisionId: retainLocalFayaReport
          ? existing.germinationPartRevisionId
          : remote.germinationPartRevisionId,
      etag: remote.etag ?? existing.etag,
      contentCursor: remote.contentCursor ?? existing.contentCursor,
      syncState: NoteSyncState.synced,
      contentOrigin: existing.contentOrigin,
      publicationId: remote.publicationId ?? existing.publicationId,
      articleId: remote.articleId ?? existing.articleId,
      articleRevisionId: remote.articleRevisionId ?? existing.articleRevisionId,
      subscriptionArticleAssets: remote.subscriptionArticleAssets.isEmpty
          ? existing.subscriptionArticleAssets
          : remote.subscriptionArticleAssets,
      author: remote.author ?? existing.author,
    );
  }

  Future<KnowledgeNoteSyncResult> _performNoteSync(String id) {
    final captured = noteForId(id);
    return _runWorkspaceContentSerial(
      () => _performNoteSyncWithJournalUnlocked(id, captured: captured),
    );
  }

  Future<KnowledgeNoteSyncResult> _performNoteSyncWithJournalUnlocked(
    String id, {
    required V3FeedItem? captured,
  }) {
    final service = _noteSyncService;
    if (service == null) {
      return _performNoteSyncDirectUnlocked(id, captured: captured);
    }
    return service.synchronize(
      local: captured ?? noteForId(id),
      readCurrent: noteForId,
      flushPersistence: flushPersistenceResult,
      deliver: (note, identity) => _performNoteSyncDirectUnlocked(
        note.id,
        captured: note,
        mutationIdentity: identity,
      ),
      recordFailure: _recordSyncFailure,
    );
  }

  Future<KnowledgeNoteSyncResult> _performNoteSyncDirectUnlocked(
    String id, {
    required V3FeedItem? captured,
    String? mutationIdentity,
  }) async {
    final local = captured ?? noteForId(id);
    if (local == null || local.isReadOnly) {
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.notEditable,
        note: local,
        errorCode: 'KNOWLEDGE_NOTE_SYNC_NOT_ALLOWED',
      );
    }
    if (local.syncState == NoteSyncState.synced) {
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.synced,
        note: local,
      );
    }

    final request = KnowledgeNoteUpdateRequest(
      noteId: local.id,
      baseRevision: local.remoteRevision,
      localRevision: local.localRevision,
      draft: knowledgeNoteDraftFor(local),
      remoteNoteId: local.remoteNoteId,
      noteRevisionId: local.noteRevisionId,
      rawPartRevisionId: local.rawPartRevisionId,
      etag: local.etag,
      contentCursor: local.contentCursor,
      localNote: local,
      mutationIdentity: mutationIdentity,
    );
    KnowledgeNotePortResult portResult;
    try {
      portResult = await _notePort.updateNote(request);
    } catch (_) {
      portResult = const KnowledgeNotePortResult.failure(
        'KNOWLEDGE_NOTE_UPDATE_FAILED',
      );
    }
    debugKnowledgeSync('response status=${portResult.status.name}');
    if (_disposed) {
      debugKnowledgeSync('superseded because controller was disposed');
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.superseded,
        note: local,
        errorCode: 'KNOWLEDGE_NOTE_CONTROLLER_DISPOSED',
      );
    }

    final current = noteForId(id);
    if (current == null || current.isReadOnly) {
      debugKnowledgeSync('superseded because note is no longer editable');
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.notEditable,
        note: current,
        errorCode: 'KNOWLEDGE_NOTE_SYNC_NOT_ALLOWED',
      );
    }
    if (!sameKnowledgeEditableRevision(current, local)) {
      debugKnowledgeSync('superseded by a newer editable revision');
      if (_nonEmpty(local.remoteNoteId) == null &&
          hasExactKnowledgeRemoteBinding(portResult.remoteNote) &&
          isValidKnowledgeRemoteNote(portResult.remoteNote, id)) {
        _upsert(retainKnowledgeRemoteBinding(current, portResult.remoteNote!));
        debugKnowledgeSync('retained binding from superseded create');
      }
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.superseded,
        note: noteForId(id),
        errorCode: 'KNOWLEDGE_NOTE_SYNC_SUPERSEDED',
      );
    }

    switch (portResult.status) {
      case KnowledgeNotePortStatus.success:
        final remote = portResult.remoteNote;
        if (!isValidKnowledgeRemoteNote(remote, id, localBinding: current)) {
          debugKnowledgeSync(
            'rejected success response with incomplete binding',
          );
          return _recordSyncFailure(current, 'KNOWLEDGE_NOTE_RESPONSE_INVALID');
        }
        final synced = remote!.copyWith(
          ownership: V3NoteOwnership.mine,
          copiedFromContentId: current.copiedFromContentId,
          publicUrl: current.publicUrl,
          localRevision: current.localRevision,
          remoteRevision: remote.remoteRevision,
          syncState: NoteSyncState.synced,
          pendingRawOnlyUpdate: false,
        );
        _clearConflictState(id);
        _upsert(synced);
        debugKnowledgeSync('accepted exact remote binding');
        return KnowledgeNoteSyncResult(
          outcome: KnowledgeNoteSyncOutcome.synced,
          note: synced,
        );
      case KnowledgeNotePortStatus.conflict:
        final remote = portResult.remoteNote;
        if (!isValidKnowledgeRemoteNote(remote, id, localBinding: current)) {
          debugKnowledgeSync(
            'rejected conflict response with incomplete binding',
          );
          return _recordSyncFailure(
            current,
            'KNOWLEDGE_NOTE_CONFLICT_RESPONSE_INVALID',
          );
        }
        final conflicted = current.copyWith(syncState: NoteSyncState.conflict);
        final snapshot = KnowledgeNoteConflictSnapshot(
          noteId: id,
          localNote: conflicted,
          remoteNote: remote!,
          baseRevision: request.baseRevision,
          observedAt: _now(),
        );
        _conflicts[id] = snapshot;
        _syncErrors[id] =
            portResult.errorCode ?? 'KNOWLEDGE_NOTE_REVISION_CONFLICT';
        _upsert(conflicted);
        return KnowledgeNoteSyncResult(
          outcome: KnowledgeNoteSyncOutcome.conflict,
          note: conflicted,
          conflict: snapshot,
          errorCode: _syncErrors[id],
        );
      case KnowledgeNotePortStatus.unavailable:
        final code =
            portResult.errorCode ?? 'KNOWLEDGE_NOTE_UPDATE_UNAVAILABLE';
        _syncErrors[id] = code;
        debugKnowledgeSync('unavailable code=$code');
        return KnowledgeNoteSyncResult(
          outcome: KnowledgeNoteSyncOutcome.unavailable,
          note: current,
          errorCode: code,
        );
      case KnowledgeNotePortStatus.failure:
        debugKnowledgeSync(
          'failed code=${portResult.errorCode ?? 'KNOWLEDGE_NOTE_UPDATE_FAILED'}',
        );
        return _recordSyncFailure(
          current,
          portResult.errorCode ?? 'KNOWLEDGE_NOTE_UPDATE_FAILED',
        );
    }
  }

  Future<void> _recoverPendingNoteSync() =>
      _runWorkspaceContentSerial(_recoverPendingNoteSyncUnlocked);

  Future<void> _recoverPendingNoteSyncUnlocked() async {
    final service = _noteSyncService;
    if (service == null || _disposed) return;
    final recovered = await service.recover(
      notes: List<V3FeedItem>.of(_notes),
      readCurrent: noteForId,
      flushPersistence: flushPersistenceResult,
      deliverUpsert: (note, identity) => _performNoteSyncDirectUnlocked(
        note.id,
        captured: note,
        mutationIdentity: identity,
      ),
      deliverTombstone: (note, key) =>
          _deleteWorkspaceNoteDurably(note.id, idempotencyKey: key),
      recordFailure: _recordSyncFailure,
      recordCommandError: (id, errorCode) => _syncErrors[id] = errorCode,
      completeMutation: (remoteNoteId, etag) => _completeWorkspaceMutationKey(
        'note-tombstone',
        '$remoteNoteId|$etag',
      ),
      isDisposed: () => _disposed,
    );
    if (recovered && !_disposed) notifyListeners();
  }

  KnowledgeNoteSyncResult _recordSyncFailure(
    V3FeedItem note,
    String errorCode,
  ) {
    _syncErrors[note.id] = errorCode;
    return KnowledgeNoteSyncResult(
      outcome: KnowledgeNoteSyncOutcome.failed,
      note: note,
      errorCode: errorCode,
    );
  }

  void _scheduleAutomaticSync(V3FeedItem note) {
    if (!_autoSyncOwnedChanges ||
        _disposed ||
        note.isReadOnly ||
        note.syncState == NoteSyncState.synced) {
      return;
    }
    unawaited(syncNote(note.id));
  }

  void _clearConflictState(String id) {
    _conflicts.remove(id);
    _syncErrors.remove(id);
  }

  void _upsert(
    V3FeedItem item, {
    bool notify = true,
    bool persist = true,
    bool maintainDepositMetadata = true,
  }) {
    final normalized = _normalizeOwnership(item);
    final index = _notes.indexWhere((note) => note.id == normalized.id);
    if (index == -1) {
      _notes.add(normalized);
    } else {
      _notes[index] = normalized;
    }
    _ensureCollectionMembershipsForNote(normalized, now: normalized.createdAt);
    if (maintainDepositMetadata) {
      _ensureOwnedNoteDeposited(normalized, depositedAt: normalized.createdAt);
    }
    _notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _refreshNoteIndexIfChanged();
    if (!_restoreComplete) {
      _pendingUpserts.add(normalized.id);
      _pendingDeletes.remove(normalized.id);
    }
    if (persist) _schedulePersist();
    if (notify) notifyListeners();
  }

  Future<bool> _saveWorkspaceNoteSnapshot(List<V3FeedItem> notes) async {
    final cache = _cache;
    if (cache == null) return true;
    final snapshot = List<V3FeedItem>.unmodifiable(notes);
    var saved = false;
    late final Future<void> persisted;
    _pendingSaveBatch = null;
    persisted = _saveQueue = _saveQueue.then((_) async {
      try {
        await cache.save(snapshot);
        saved = true;
      } on Object {
        _persistenceErrorCode = 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED';
      }
    });
    await persisted;
    return saved;
  }

  void _schedulePersist() {
    final cache = _cache;
    if (cache == null || _pendingSaveBatch != null) return;
    final batch = Object();
    _pendingSaveBatch = batch;
    _saveQueue = _saveQueue.then((_) async {
      await restore();
      if (identical(_pendingSaveBatch, batch)) _pendingSaveBatch = null;
      try {
        await cache.save(List<V3FeedItem>.of(_notes));
        _persistenceErrorCode = null;
      } catch (_) {
        _persistenceErrorCode = 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED';
      }
    });
  }

  void _hydrateUserMetadata() {
    final repository = _userMetadataRepository;
    if (repository == null) return;
    try {
      _readOnlyTagOverrides.addAll(repository.loadTagOverrides());
      _cardDisplayMode = repository.loadCardDisplayMode();
    } catch (_) {
      _readOnlyTagOverrides.clear();
      _cardDisplayMode = KnowledgeCardDisplayMode.expanded;
    }
  }

  void _hydrateDepositMetadata() {
    final repository = _depositRepository;
    if (repository == null) return;
    _memberships.addAll(
      repository.loadMemberships().where(
        (membership) =>
            !_usesWorkspaceFolders ||
            membership.collection != V3LibraryCollection.deposits,
      ),
    );
    if (!_usesWorkspaceFolders) {
      _depositRecords.addAll(repository.loadDepositRecords());
      _depositFolders.addAll(repository.loadFolders());
      _repairDepositFolderHierarchy();
      _sortDepositFolders();
      _growthLedger.addAll(repository.loadGrowthLedger());
    }
    _discardLegacyHotspotDepositMetadata();
  }

  void _migrateExistingNotesToCollections() {
    for (final note in _notes) {
      _ensureCollectionMembershipsForNote(note, now: note.createdAt);
      if (note.isReadOnly) {
        _discardReadOnlyDepositMetadata(note.id);
      } else {
        _ensureOwnedNoteDeposited(note, depositedAt: note.createdAt);
      }
    }
  }

  void _ensureCollectionMembershipsForNote(
    V3FeedItem item, {
    required DateTime now,
  }) {
    switch (item.source) {
      case V3MaterialSource.subscription:
        _ensureMembership(
          item.id,
          V3LibraryCollection.subscribed,
          createdAt: now,
        );
      case V3MaterialSource.knowledgeSquare:
        _ensureMembership(item.id, V3LibraryCollection.square, createdAt: now);
      case V3MaterialSource.hotspot:
        _discardHotspotDepositMetadata(item.id);
      default:
        break;
    }
  }

  void _ensureOwnedNoteDeposited(
    V3FeedItem item, {
    required DateTime depositedAt,
  }) {
    if (item.ownership != V3NoteOwnership.mine ||
        item.source == V3MaterialSource.hotspot) {
      return;
    }
    if (_usesWorkspaceFolders) return;
    final existingMembership = _membershipFor(
      item.id,
      V3LibraryCollection.deposits,
    );
    final existingRecord = depositRecordFor(item.id);
    final hasGrowthEntry = _growthLedger.any(
      (entry) => entry.contentId == item.id,
    );
    final historicalDepositedAt = existingRecord?.depositedAt ?? depositedAt;
    final membership =
        existingMembership ??
        V3LibraryMembership(
          contentId: item.id,
          collection: V3LibraryCollection.deposits,
          createdAt: historicalDepositedAt,
        );
    final record =
        existingRecord ??
        V3DepositRecord(
          contentId: item.id,
          depositedAt: historicalDepositedAt,
          updatedAt: historicalDepositedAt,
        );
    if (existingMembership == null ||
        existingRecord == null ||
        !hasGrowthEntry) {
      try {
        _depositRepository?.saveDeposit(membership: membership, record: record);
      } catch (_) {
        _depositPersistenceErrorCode = 'AUTO_DEPOSIT_SAVE_FAILED';
        return;
      }
      if (existingMembership == null) _memberships.add(membership);
      if (existingRecord == null) _depositRecords.add(record);
    }
    if (!hasGrowthEntry) {
      _growthLedger.add(
        GrowthLedgerEntry(
          contentId: item.id,
          firstDepositedAt: historicalDepositedAt,
        ),
      );
    }
  }

  void _discardLegacyHotspotDepositMetadata() {
    for (final note in _notes) {
      if (note.source == V3MaterialSource.hotspot) {
        _discardHotspotDepositMetadata(note.id);
      }
    }
  }

  void _discardReadOnlyDepositMetadata(String contentId) {
    if (_usesWorkspaceFolders) return;
    if (!isDeposited(contentId)) return;
    try {
      _depositRepository?.deleteDeposit(contentId);
    } catch (_) {
      _depositPersistenceErrorCode = 'READ_ONLY_DEPOSIT_CLEANUP_FAILED';
      return;
    }
    _memberships.removeWhere(
      (membership) =>
          membership.contentId == contentId &&
          membership.collection == V3LibraryCollection.deposits,
    );
    _depositRecords.removeWhere((record) => record.contentId == contentId);
  }

  void _discardHotspotDepositMetadata(String contentId) {
    if (_usesWorkspaceFolders) return;
    final hasDepositMembership = _hasMembership(
      contentId,
      V3LibraryCollection.deposits,
    );
    final hasDepositRecord = depositRecordFor(contentId) != null;
    if (!hasDepositMembership && !hasDepositRecord) return;
    try {
      _depositRepository?.deleteDeposit(contentId);
      _depositPersistenceErrorCode = null;
    } catch (_) {
      _depositPersistenceErrorCode = 'HOTSPOT_DEPOSIT_CLEANUP_FAILED';
    }
    _memberships.removeWhere(
      (membership) =>
          membership.contentId == contentId &&
          membership.collection == V3LibraryCollection.deposits,
    );
    _depositRecords.removeWhere((record) => record.contentId == contentId);
  }

  void _ensureMembership(
    String contentId,
    V3LibraryCollection collection, {
    required DateTime createdAt,
  }) {
    if (_hasMembership(contentId, collection)) return;
    final membership = V3LibraryMembership(
      contentId: contentId,
      collection: collection,
      createdAt: createdAt,
    );
    _memberships.add(membership);
    _depositRepository?.saveMembership(membership);
  }

  bool _hasMembership(String contentId, V3LibraryCollection collection) =>
      _membershipFor(contentId, collection) != null;

  V3LibraryMembership? _membershipFor(
    String contentId,
    V3LibraryCollection collection,
  ) {
    for (final membership in _memberships) {
      if (membership.contentId == contentId &&
          membership.collection == collection) {
        return membership;
      }
    }
    return null;
  }

  bool get _usesWorkspaceFolders =>
      _workspaceFolderPort is! UnavailableWorkspaceFolderPort;

  bool _isWorkspaceDepositedNote(V3FeedItem note) =>
      note.ownership == V3NoteOwnership.mine &&
      note.source != V3MaterialSource.hotspot;

  bool _canUseRemoteHNoteLifecycle(V3FeedItem note) =>
      note.syncState == NoteSyncState.synced &&
      _nonEmpty(note.remoteNoteId) != null &&
      _nonEmpty(note.etag) != null;

  List<V3DepositFolder> _activeDepositFolders() {
    if (!_usesWorkspaceFolders) {
      return List<V3DepositFolder>.of(_depositFolders);
    }
    final folders =
        <V3DepositFolder>[
          for (final folder in _remoteFolderIndex.values)
            if (_isLiveWorkspaceFolder(folder))
              _depositFolderFromWorkspace(folder),
        ]..sort((left, right) {
          final byName = left.name.compareTo(right.name);
          return byName != 0 ? byName : left.id.compareTo(right.id);
        });
    return folders;
  }

  bool _isLiveWorkspaceFolder(WorkspaceContentRemoteFolder folder) =>
      folder.state == 'live' || folder.state == 'active';

  V3DepositFolder _depositFolderFromWorkspace(
    WorkspaceContentRemoteFolder folder,
  ) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return V3DepositFolder(
      id: folder.folderId,
      name: folder.displayName,
      parentFolderId: folder.parentFolderId,
      createdAt: epoch,
      updatedAt: epoch,
    );
  }

  WorkspaceContentRemoteFolder _workspaceFolderFromApi(
    SharedWorkspaceFolder folder,
  ) => WorkspaceContentRemoteFolder(
    folderId: folder.folderId,
    parentFolderId: folder.parentFolderId,
    displayName: folder.displayName,
    normalizedName: folder.normalizedName,
    state: folder.state,
    currentRevisionId: folder.currentRevisionId,
    etag: folder.etag,
    contentCursor: folder.contentCursor,
    systemSeedKey: folder.systemSeedKey,
  );

  WorkspaceContentRemoteFolder? _remoteFolderFor(String folderId) {
    final folder = _remoteFolderIndex[folderId.trim()];
    return folder != null && _isLiveWorkspaceFolder(folder) ? folder : null;
  }

  String? _remoteFolderIdFor(V3FeedItem note) {
    final folderId = _nonEmpty(note.folderId);
    return folderId == null || _remoteFolderFor(folderId) == null
        ? null
        : folderId;
  }

  V3DepositRecord _workspaceDepositRecordFor(V3FeedItem note) =>
      V3DepositRecord(
        contentId: note.id,
        folderId: _remoteFolderIdFor(note),
        depositedAt: note.createdAt,
        updatedAt: note.updatedAt,
      );

  void _putWorkspaceFolder(WorkspaceContentRemoteFolder folder) {
    _remoteFolderIndex = Map<String, WorkspaceContentRemoteFolder>.unmodifiable(
      <String, WorkspaceContentRemoteFolder>{
        ..._remoteFolderIndex,
        folder.folderId: folder,
      },
    );
  }

  void _replaceWorkspaceFolderNameInNotes(WorkspaceContentRemoteFolder folder) {
    var changed = false;
    for (var index = 0; index < _notes.length; index++) {
      final note = _notes[index];
      if (note.folderId != folder.folderId ||
          note.folderName == folder.displayName) {
        continue;
      }
      _notes[index] = note.copyWith(folderName: folder.displayName);
      changed = true;
    }
    if (changed) _schedulePersist();
  }

  Set<String> _workspaceFolderSubtreeIds(String rootFolderId) {
    final ids = <String>{rootFolderId};
    var found = true;
    while (found) {
      found = false;
      for (final folder in _remoteFolderIndex.values) {
        final parentId = folder.parentFolderId;
        if (parentId != null &&
            ids.contains(parentId) &&
            ids.add(folder.folderId)) {
          found = true;
        }
      }
    }
    return ids;
  }

  void _removeWorkspaceFolderSubtree(Set<String> folderIds) {
    _remoteFolderIndex = Map<String, WorkspaceContentRemoteFolder>.unmodifiable(
      <String, WorkspaceContentRemoteFolder>{
        for (final entry in _remoteFolderIndex.entries)
          if (!folderIds.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  String _workspaceFolderMutationKey(String operation, String subject) {
    final retryIdentity = '$operation|$subject';
    final existing = _workspaceMutationRetryKeys[retryIdentity];
    if (existing != null) return existing;
    if (_workspaceMutationRetryKeys.length >= 128) {
      _workspaceMutationRetryKeys.remove(
        _workspaceMutationRetryKeys.keys.first,
      );
    }
    final sequence = ++_workspaceFolderMutationSequence;
    final hash = _stableNoteId(
      '$operation|$subject|${_now().microsecondsSinceEpoch}|$sequence',
    );
    final key = 'mobile-workspace-$operation-$hash-$sequence';
    _workspaceMutationRetryKeys[retryIdentity] = key;
    return key;
  }

  void _completeWorkspaceMutationKey(String operation, String subject) {
    _workspaceMutationRetryKeys.remove('$operation|$subject');
  }

  WorkspaceFolderPortResult<T> _workspaceFolderFailure<T>(
    WorkspaceFolderPortStatus status,
    String? errorCode,
  ) {
    final code = errorCode ?? 'WORKSPACE_FOLDER_MUTATION_FAILED';
    if (code == 'PRECONDITION_FAILED' ||
        code == 'NOTE_BATCH_MOVE_CONFLICT' ||
        code == 'CONTENT_CURSOR_EXPIRED') {
      _scheduleWorkspaceFolderRefresh();
    }
    return status == WorkspaceFolderPortStatus.unavailable
        ? WorkspaceFolderPortResult<T>.unavailable(code)
        : WorkspaceFolderPortResult<T>.failure(code);
  }

  void _scheduleWorkspaceFolderRefresh() {
    if (_disposed || _workspaceContentSync == null) return;
    unawaited(synchronizeWorkspaceContent());
  }

  Future<void> _refreshWorkspaceProjectionAfterMutation() async {
    if (_disposed || _workspaceContentSync == null) return;
    final synchronized = await _synchronizeWorkspaceContentUnlocked(
      forceSnapshot: false,
    );
    if (!synchronized && !_disposed) {
      _scheduleWorkspaceFolderRefresh();
    }
  }

  String? _normalizedDepositFolderId(String? folderId) {
    final normalized = folderId?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return depositFolderFor(normalized) == null ? null : normalized;
  }

  String? _normalizedFolderParentId(String? folderId) {
    final normalized = folderId?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  String? _depositFolderNameFor(String contentId) {
    final folderId = depositRecordFor(contentId)?.folderId;
    return folderId == null ? null : depositFolderFor(folderId)?.name;
  }

  void _sortDepositFolders() {
    _depositFolders.sort((a, b) {
      final byName = a.name.compareTo(b.name);
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
  }

  void _repairDepositFolderHierarchy() {
    for (var index = 0; index < _depositFolders.length; index++) {
      final folder = _depositFolders[index];
      final parentId = _normalizedFolderParentId(folder.parentFolderId);
      if (parentId == folder.parentFolderId) continue;
      _depositFolders[index] = folder.copyWith(
        parentFolderId: parentId,
        clearParentFolder: parentId == null,
      );
    }
    final foldersById = <String, V3DepositFolder>{
      for (final folder in _depositFolders) folder.id: folder,
    };
    for (var index = 0; index < _depositFolders.length; index++) {
      final folder = _depositFolders[index];
      var parentId = folder.parentFolderId;
      final visited = <String>{folder.id};
      var hasInvalidParent = false;
      while (parentId != null) {
        if (!visited.add(parentId) || !foldersById.containsKey(parentId)) {
          hasInvalidParent = true;
          break;
        }
        parentId = foldersById[parentId]?.parentFolderId;
      }
      if (!hasInvalidParent) continue;
      _depositFolders[index] = folder.copyWith(clearParentFolder: true);
    }
  }

  void _refreshNoteIndexIfChanged() {
    if (sameKnowledgeNoteIdentities(_indexedNotes, _notes)) return;
    _indexedNotes = List<V3FeedItem>.of(_notes, growable: false);
    _noteIndex = <String, V3FeedItem>{for (final note in _notes) note.id: note};
    _noteIndexRevision += 1;
    _noteIndexSnapshot = KnowledgeNoteIndexSnapshot(
      ids: _notes.map((note) => note.id),
      revision: _noteIndexRevision,
    );
  }

  void _setGraphSourceState(
    KnowledgeGraphSourceState state, {
    String? errorCode,
  }) {
    if (_disposed) return;
    final nextErrorCode = state == KnowledgeGraphSourceState.failure
        ? errorCode ?? 'WORKSPACE_CONTENT_SYNC_FAILED'
        : null;
    if (_graphSourceState == state && _graphSourceErrorCode == nextErrorCode) {
      return;
    }
    _graphSourceState = state;
    _graphSourceErrorCode = nextErrorCode;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    _queryController.invalidate();
    _refreshNoteIndexIfChanged();
    _graphReadModel.replaceDepositedNotes(
      _notes.where(_isDepositedNote),
      sourceState: _graphSourceState,
      sourceErrorCode: _graphSourceErrorCode,
    );
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _workspaceContentSync?.dispose();
    _queryController
      ..removeListener(_handleQueryChanged)
      ..dispose();
    _subscriptionController
      ..removeListener(_handleSubscriptionChanged)
      ..dispose();
    _graphReadModel.dispose();
    super.dispose();
  }
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

List<String> _uniqueTopics(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final normalized = value.trim();
    if (normalized.isNotEmpty && seen.add(normalized)) result.add(normalized);
  }
  return List<String>.unmodifiable(result);
}

List<V3LinkedMaterialRef> _uniqueLinkedMaterials(
  Iterable<V3LinkedMaterialRef> values,
) {
  final result = <V3LinkedMaterialRef>[];
  final seen = <String>{};
  for (final value in values) {
    if (value.id.trim().isNotEmpty && seen.add(value.id)) result.add(value);
  }
  return List<V3LinkedMaterialRef>.unmodifiable(result);
}

String _manualNoteTitle(String title, String rawBody) {
  final suppliedTitle = title.trim();
  if (suppliedTitle.isNotEmpty) return suppliedTitle;
  for (final rawLine in rawBody.split('\n')) {
    final line = rawLine
        .trim()
        .replaceFirst(RegExp(r'^#{1,6}\s*'), '')
        .replaceFirst(RegExp(r'^[-*+]\s+'), '')
        .trim();
    if (line.isEmpty) continue;
    return line.length <= 48 ? line : '${line.substring(0, 48)}...';
  }
  return '未命名笔记';
}

String? _normalizeFolderName(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty || normalized.length > 40) return null;
  return normalized;
}

V3FeedItem _normalizeSeedNote(V3FeedItem note) {
  final normalized = _normalizeOwnership(note);
  if (normalized.folderName != null || normalized.contentLineName != null) {
    return normalized;
  }
  final hash = normalized.id.codeUnits.fold<int>(
    0,
    (value, unit) => value + unit,
  );
  const folders = <String>['客户案例', '行业观察', '内容方法', '未归档'];
  const lines = <String>['AI 落地', '可信内容', '客户增长'];
  return normalized.copyWith(
    folderId: 'folder-${hash % folders.length}',
    folderName: folders[hash % folders.length],
    contentLineId: 'content-line-${hash % lines.length}',
    contentLineName: lines[hash % lines.length],
  );
}

V3FeedItem _normalizeOwnership(V3FeedItem note) {
  if (note.ownership == V3NoteOwnership.mine &&
      (note.copiedFromContentId?.trim().isNotEmpty == true ||
          (note.source == V3MaterialSource.subscription &&
              note.remoteNoteId?.trim().isNotEmpty == true))) {
    return note;
  }
  final ownership = switch (note.source) {
    V3MaterialSource.subscription => V3NoteOwnership.subscribed,
    V3MaterialSource.knowledgeSquare => V3NoteOwnership.knowledgeSquare,
    V3MaterialSource.hotspot => V3NoteOwnership.hotspot,
    _ => note.ownership,
  };
  return note.copyWith(ownership: ownership);
}

List<String> _mergeTags(Iterable<String> first, Iterable<String> second) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in <Iterable<String>>[
    first,
    second,
  ].expand((value) => value)) {
    final tag = raw.trim();
    if (tag.isNotEmpty && seen.add(tag.toLowerCase())) result.add(tag);
  }
  return List<String>.unmodifiable(result);
}

int _maxLegacyRevision(int? existing, int remote) =>
    existing == null || remote > existing ? remote : existing;

String _stableNoteId(String value) {
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) % 1000000007;
  }
  return hash.toRadixString(16);
}

const _channelMembershipPrefix = 'knowledge-channel-subscription-';

const _channelArticleAngles = <String>[
  '从一件具体事开始建立理解',
  '十二个关键词构成的入门地图',
  '被忽略的日常细节为什么重要',
  '三个经典案例的共同结构',
  '如何辨别流行说法与可靠证据',
  '关键人物留下了什么方法',
  '一次观念变化的完整时间线',
  '普通人可以实践的观察清单',
  '跨学科阅读应该怎样开始',
  '争议背后真正不同的判断标准',
  '值得反复阅读的十条笔记',
  '把知识转化为个人表达的方法',
];

List<V3FeedItem> _buildKnowledgeChannelArticles() => <V3FeedItem>[
  for (final channel in KnowledgeChannel.values)
    for (var index = 0; index < _channelArticleAngles.length; index++)
      V3FeedItem(
        id: 'knowledge-channel-${channel.id}-${(index + 1).toString().padLeft(2, '0')}',
        title: '${channel.label} · ${_channelArticleAngles[index]}',
        source: V3MaterialSource.knowledgeSquare,
        ownership: V3NoteOwnership.knowledgeSquare,
        createdAt: DateTime(
          2026,
          7,
          28,
        ).subtract(Duration(days: channel.index * 2 + index)),
        rawBody: _channelArticleBody(
          channel,
          _channelArticleAngles[index],
          index,
        ),
        summaryBody:
            '从${_channelArticleAngles[index]}切入，整理${channel.label}领域可验证、可复用的观察方法。',
        topics: <String>[channel.label, _channelArticleAngles[index]],
      ),
];

String _channelArticleBody(KnowledgeChannel channel, String angle, int index) =>
    '''# $angle

${channel.description}理解${channel.label}并不需要先记住大量结论，更有效的起点是选择一个具体对象，记录它出现的背景、参与者、限制条件以及后来发生的变化。只有把抽象概念放回真实情境，知识才不会变成互不相连的标签。

## 从问题而不是答案开始

这篇文章选择“$angle”作为入口。先问三个问题：我们正在解释什么现象；现有材料能支持到哪一步；哪些判断仍然只是推测。这样的顺序能够避免先有立场再寻找证据，也能帮助读者区分事实、解释和价值判断。

## 建立可检查的材料链

阅读时可以把材料分成原始记录、研究整理和个人评论三层。原始记录回答发生了什么，研究整理提供比较框架，个人评论说明作者如何理解。三层材料彼此印证时，结论才更稳固；如果它们相互冲突，冲突本身就是继续追问的线索。

## 把宏大主题还原到日常

${channel.label}最有价值的部分，常常藏在普通人的选择、空间的使用方式和语言的细微变化中。与其追求覆盖所有知识，不如连续观察同一类细节：谁拥有决定权，谁承担成本，什么规则被默认，以及哪些经验没有被记录。

## 一份可执行的观察清单

第一，写下对象的时间和地点；第二，记录相关人物及其目标；第三，寻找至少两种不同来源；第四，标记尚未确认的信息；第五，用自己的话复述核心逻辑；第六，说明这条知识与今天的生活或创作有什么联系。第 ${index + 1} 组材料尤其适合用这份清单复核。

## 形成自己的表达

完成阅读后，不必立刻给出宏大结论。可以先写一段一百字摘要，再补充一个具体案例和一个仍未解决的问题。这样形成的笔记既保留证据边界，也留下继续生长的位置，未来沉淀到个人资产时能够直接参与新的内容连接。

## 结语

真正可靠的${channel.label}知识不是记住多少名词，而是逐渐形成一套能够重复使用的提问、核对和表达方法。下一次遇到相似主题时，从具体事实出发，保留不确定性，再把材料连接到自己的经验，理解就会比一次性的答案更持久。''';
