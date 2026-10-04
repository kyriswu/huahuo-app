import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import '../application/knowledge_note_port.dart';
import '../application/knowledge_note_sync_service.dart';
import '../domain/feed_item_models.dart';
import 'workspace_content_sync_store.dart';

typedef WorkspaceContentProjectionReader =
    FutureOr<List<V3FeedItem>> Function();

typedef WorkspaceContentProjectionCursorReader = FutureOr<String?> Function();

typedef WorkspaceContentProjectionApplier =
    FutureOr<void> Function(WorkspaceContentProjection projection);

typedef WorkspaceFolderProjectionApplier =
    void Function(Map<String, WorkspaceContentRemoteFolder> folders);

const int _snapshotHNoteHydrationConcurrency = 6;

/// A full, app-ready remote projection. The applier owns controller mutation
/// and durable knowledge-library-cache writes.
final class WorkspaceContentProjection {
  const WorkspaceContentProjection({
    required this.notes,
    required this.folders,
    required this.contentCursor,
    required this.origin,
  });

  final List<V3FeedItem> notes;
  final Map<String, WorkspaceContentRemoteFolder> folders;
  final String contentCursor;
  final WorkspaceContentProjectionOrigin origin;
}

enum WorkspaceContentProjectionOrigin { snapshot, changes }

enum WorkspaceContentSyncStatus { synchronized, notModified, failure }

final class WorkspaceContentSyncResult {
  const WorkspaceContentSyncResult._({
    required this.status,
    this.contentCursor,
    this.errorCode,
    this.eventCount = 0,
    this.rebuiltFromSnapshot = false,
  });

  const WorkspaceContentSyncResult.synchronized({
    required String contentCursor,
    int eventCount = 0,
    bool rebuiltFromSnapshot = false,
  }) : this._(
         status: WorkspaceContentSyncStatus.synchronized,
         contentCursor: contentCursor,
         eventCount: eventCount,
         rebuiltFromSnapshot: rebuiltFromSnapshot,
       );

  const WorkspaceContentSyncResult.notModified({String? contentCursor})
    : this._(
        status: WorkspaceContentSyncStatus.notModified,
        contentCursor: contentCursor,
      );

  const WorkspaceContentSyncResult.failure(String errorCode)
    : this._(status: WorkspaceContentSyncStatus.failure, errorCode: errorCode);

  final WorkspaceContentSyncStatus status;
  final String? contentCursor;
  final String? errorCode;
  final int eventCount;
  final bool rebuiltFromSnapshot;

  bool get isSuccess => status != WorkspaceContentSyncStatus.failure;
}

/// Testable network boundary around [WorkspaceContentClient].
abstract interface class WorkspaceContentSyncRemotePort {
  Future<WorkspaceContentSnapshotResponse> contentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  });

  Future<WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>>
  changes(String workspaceId, {required String after});

  Future<WorkspaceContentRemoteResponse<SharedHNote>> note(
    String workspaceId,
    String noteId, {
    required String revisionId,
  });

  Future<WorkspaceContentRemoteResponse<SharedHNotePartView>> notePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  });

  Future<WorkspaceContentRemoteResponse<SharedWorkspaceFolder>> folder(
    String workspaceId,
    String folderId, {
    required String revisionId,
  });
}

/// Normalizes ordinary Workspace API failures for the synchronizer.
final class WorkspaceContentRemoteResponse<T> {
  const WorkspaceContentRemoteResponse.success(this.data)
    : errorCode = null,
      status = null,
      retryable = false;

  const WorkspaceContentRemoteResponse.failure({
    required this.errorCode,
    this.status,
    this.retryable = false,
  }) : data = null;

  final T? data;
  final String? errorCode;
  final int? status;
  final bool retryable;

  bool get ok => data != null && errorCode == null;
}

/// Optional low-cost version check for a durable Workspace projection.
///
/// The Workspace detail contract exposes the current content cursor. Remote
/// adapters that cannot provide it retain the regular delta path unchanged.
abstract interface class WorkspaceContentCursorProbePort {
  Future<WorkspaceContentRemoteResponse<String>> currentContentCursor(
    String workspaceId,
  );
}

/// One lifecycle-owned Workspace read without changing the established Future
/// APIs used by existing adapters and tests.
final class WorkspaceContentReadLease<T> {
  const WorkspaceContentReadLease({required this.result, required this.cancel});

  final Future<T> result;
  final void Function() cancel;
}

/// Optional cancellation capability for every GET used by a content sync.
abstract interface class WorkspaceContentSyncReadLeasePort {
  WorkspaceContentReadLease<WorkspaceContentRemoteResponse<String>>
  leaseCurrentContentCursor(String workspaceId);

  WorkspaceContentReadLease<WorkspaceContentSnapshotResponse>
  leaseContentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  });

  WorkspaceContentReadLease<
    WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>
  >
  leaseChanges(String workspaceId, {required String after});

  WorkspaceContentReadLease<WorkspaceContentRemoteResponse<SharedHNote>>
  leaseNote(String workspaceId, String noteId, {required String revisionId});

  WorkspaceContentReadLease<WorkspaceContentRemoteResponse<SharedHNotePartView>>
  leaseNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  });

  WorkspaceContentReadLease<
    WorkspaceContentRemoteResponse<SharedWorkspaceFolder>
  >
  leaseFolder(
    String workspaceId,
    String folderId, {
    required String revisionId,
  });
}

/// A conditional snapshot can be a fresh page, a 304, or a normal failure.
final class WorkspaceContentSnapshotResponse {
  const WorkspaceContentSnapshotResponse.success(this.data, {this.etag})
    : isNotModified = false,
      errorCode = null,
      status = null,
      retryable = false;

  const WorkspaceContentSnapshotResponse.notModified({this.etag})
    : data = null,
      isNotModified = true,
      errorCode = null,
      status = 304,
      retryable = false;

  const WorkspaceContentSnapshotResponse.failure({
    required this.errorCode,
    this.status,
    this.retryable = false,
  }) : data = null,
       etag = null,
       isNotModified = false;

  final SharedWorkspaceContentSnapshot? data;
  final String? etag;
  final bool isNotModified;
  final String? errorCode;
  final int? status;
  final bool retryable;

  bool get ok => data != null && errorCode == null;
}

/// Production adapter using the shared formal Workspace content client.
final class ApiWorkspaceContentSyncRemotePort
    implements
        WorkspaceContentSyncRemotePort,
        WorkspaceContentCursorProbePort,
        WorkspaceContentSyncReadLeasePort {
  ApiWorkspaceContentSyncRemotePort({
    required WorkspaceContentClient client,
    WorkspaceLifecycleClient? workspaceLifecycleClient,
  }) : _client = client,
       _workspaceLifecycleClient = workspaceLifecycleClient;

  factory ApiWorkspaceContentSyncRemotePort.fromApiClient(ApiClient client) {
    return ApiWorkspaceContentSyncRemotePort(
      client: WorkspaceContentClient(client),
      workspaceLifecycleClient: WorkspaceLifecycleClient(client),
    );
  }

  final WorkspaceContentClient _client;
  final WorkspaceLifecycleClient? _workspaceLifecycleClient;

  @override
  Future<WorkspaceContentRemoteResponse<String>> currentContentCursor(
    String workspaceId,
  ) async {
    final lifecycle = _workspaceLifecycleClient;
    if (lifecycle == null) {
      return const WorkspaceContentRemoteResponse<String>.failure(
        errorCode: 'WORKSPACE_CONTENT_CURSOR_PROBE_UNAVAILABLE',
      );
    }
    return _cursorResponse(await lifecycle.detail(workspaceId));
  }

  @override
  WorkspaceContentReadLease<WorkspaceContentRemoteResponse<String>>
  leaseCurrentContentCursor(String workspaceId) {
    final lifecycle = _workspaceLifecycleClient;
    if (lifecycle == null) {
      return WorkspaceContentReadLease<WorkspaceContentRemoteResponse<String>>(
        result: Future<WorkspaceContentRemoteResponse<String>>.value(
          const WorkspaceContentRemoteResponse<String>.failure(
            errorCode: 'WORKSPACE_CONTENT_CURSOR_PROBE_UNAVAILABLE',
          ),
        ),
        cancel: _noOpWorkspaceContentRead,
      );
    }
    final lease = lifecycle.leaseDetail(workspaceId);
    return WorkspaceContentReadLease<WorkspaceContentRemoteResponse<String>>(
      result: lease.result.then(_cursorResponse),
      cancel: lease.cancel,
    );
  }

  WorkspaceContentRemoteResponse<String> _cursorResponse(
    ApiResult<SharedWorkspaceDetail> result,
  ) {
    final cursor = result.data?.contentCursor;
    if (result.ok && cursor != null && _isCanonicalContentCursor(cursor)) {
      return WorkspaceContentRemoteResponse<String>.success(cursor);
    }
    return WorkspaceContentRemoteResponse<String>.failure(
      errorCode: result.error?.code ?? 'WORKSPACE_CONTENT_CURSOR_PROBE_FAILED',
      status: result.status,
      retryable: result.error?.isRetryable ?? false,
    );
  }

  @override
  Future<WorkspaceContentSnapshotResponse> contentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  }) async {
    return _snapshotResponse(
      await _client.conditionalContentSnapshot(
        workspaceId,
        pageToken: pageToken,
        ifNoneMatch: ifNoneMatch,
      ),
    );
  }

  @override
  WorkspaceContentReadLease<WorkspaceContentSnapshotResponse>
  leaseContentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  }) {
    final lease = _client.leaseConditionalContentSnapshot(
      workspaceId,
      pageToken: pageToken,
      ifNoneMatch: ifNoneMatch,
    );
    return WorkspaceContentReadLease<WorkspaceContentSnapshotResponse>(
      result: lease.result.then(_snapshotResponse),
      cancel: lease.cancel,
    );
  }

  WorkspaceContentSnapshotResponse _snapshotResponse(
    ApiConditionalResult<SharedWorkspaceContentSnapshot> result,
  ) {
    if (result.ok && result.isNotModified) {
      return WorkspaceContentSnapshotResponse.notModified(etag: result.etag);
    }
    final data = result.data;
    if (result.ok && data != null) {
      return WorkspaceContentSnapshotResponse.success(data, etag: result.etag);
    }
    return WorkspaceContentSnapshotResponse.failure(
      errorCode: result.error?.code ?? 'WORKSPACE_CONTENT_SNAPSHOT_FAILED',
      status: result.status,
      retryable: result.error?.isRetryable ?? false,
    );
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>>
  changes(String workspaceId, {required String after}) {
    return _ordinary(
      _client.changes(workspaceId, after: after),
      fallbackCode: 'WORKSPACE_CONTENT_CHANGES_FAILED',
    );
  }

  @override
  WorkspaceContentReadLease<
    WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>
  >
  leaseChanges(String workspaceId, {required String after}) {
    final lease = _client.leaseChanges(workspaceId, after: after);
    return WorkspaceContentReadLease<
      WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>
    >(
      result: lease.result.then(
        (result) => _ordinaryResult(
          result,
          fallbackCode: 'WORKSPACE_CONTENT_CHANGES_FAILED',
        ),
      ),
      cancel: lease.cancel,
    );
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedHNote>> note(
    String workspaceId,
    String noteId, {
    required String revisionId,
  }) {
    return _ordinary(
      _client.note(workspaceId, noteId, revisionId: revisionId),
      fallbackCode: 'WORKSPACE_CONTENT_NOTE_READ_FAILED',
    );
  }

  @override
  WorkspaceContentReadLease<WorkspaceContentRemoteResponse<SharedHNote>>
  leaseNote(String workspaceId, String noteId, {required String revisionId}) {
    final lease = _client.leaseNote(
      workspaceId,
      noteId,
      revisionId: revisionId,
    );
    return WorkspaceContentReadLease<
      WorkspaceContentRemoteResponse<SharedHNote>
    >(
      result: lease.result.then(
        (result) => _ordinaryResult(
          result,
          fallbackCode: 'WORKSPACE_CONTENT_NOTE_READ_FAILED',
        ),
      ),
      cancel: lease.cancel,
    );
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedHNotePartView>> notePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  }) {
    return _ordinary(
      _client.notePart(
        workspaceId,
        noteId,
        part,
        partRevisionId: partRevisionId,
      ),
      fallbackCode: 'WORKSPACE_CONTENT_NOTE_PART_READ_FAILED',
    );
  }

  @override
  WorkspaceContentReadLease<WorkspaceContentRemoteResponse<SharedHNotePartView>>
  leaseNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  }) {
    final lease = _client.leaseNotePart(
      workspaceId,
      noteId,
      part,
      partRevisionId: partRevisionId,
    );
    return WorkspaceContentReadLease<
      WorkspaceContentRemoteResponse<SharedHNotePartView>
    >(
      result: lease.result.then(
        (result) => _ordinaryResult(
          result,
          fallbackCode: 'WORKSPACE_CONTENT_NOTE_PART_READ_FAILED',
        ),
      ),
      cancel: lease.cancel,
    );
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedWorkspaceFolder>> folder(
    String workspaceId,
    String folderId, {
    required String revisionId,
  }) {
    return _ordinary(
      _client.folder(workspaceId, folderId, revisionId: revisionId),
      fallbackCode: 'WORKSPACE_CONTENT_FOLDER_READ_FAILED',
    );
  }

  @override
  WorkspaceContentReadLease<
    WorkspaceContentRemoteResponse<SharedWorkspaceFolder>
  >
  leaseFolder(
    String workspaceId,
    String folderId, {
    required String revisionId,
  }) {
    final lease = _client.leaseFolder(
      workspaceId,
      folderId,
      revisionId: revisionId,
    );
    return WorkspaceContentReadLease<
      WorkspaceContentRemoteResponse<SharedWorkspaceFolder>
    >(
      result: lease.result.then(
        (result) => _ordinaryResult(
          result,
          fallbackCode: 'WORKSPACE_CONTENT_FOLDER_READ_FAILED',
        ),
      ),
      cancel: lease.cancel,
    );
  }

  Future<WorkspaceContentRemoteResponse<T>> _ordinary<T>(
    Future<ApiResult<T>> request, {
    required String fallbackCode,
  }) async {
    return _ordinaryResult(await request, fallbackCode: fallbackCode);
  }

  WorkspaceContentRemoteResponse<T> _ordinaryResult<T>(
    ApiResult<T> result, {
    required String fallbackCode,
  }) {
    final data = result.data;
    if (result.ok && data != null) {
      return WorkspaceContentRemoteResponse<T>.success(data);
    }
    return WorkspaceContentRemoteResponse<T>.failure(
      errorCode: result.error?.code ?? fallbackCode,
      status: result.status,
      retryable: result.error?.isRetryable ?? false,
    );
  }
}

void _noOpWorkspaceContentRead() {}

/// Mobile single-flight snapshot-and-delta synchronizer.
///
/// It does not mutate UI state directly. The injected applier is called before
/// checkpoint persistence, allowing the owner to save the knowledge cache and
/// update its controller as one acknowledged projection.
final class WorkspaceContentSync {
  WorkspaceContentSync({
    required WorkspaceContentSyncRemotePort remote,
    required WorkspaceContentSyncStore store,
    required String workspaceId,
    required WorkspaceContentProjectionReader readProjection,
    required WorkspaceContentProjectionCursorReader readProjectionCursor,
    required WorkspaceContentProjectionApplier applyProjection,
    WorkspaceFolderProjectionApplier? applyFolderProjection,
    KnowledgeNoteSyncJournal? noteSyncJournal,
  }) : _remote = remote,
       _store = store,
       _workspaceId = _requiredWorkspaceId(workspaceId),
       _readProjection = readProjection,
       _readProjectionCursor = readProjectionCursor,
       _applyProjection = applyProjection,
       _applyFolderProjection = applyFolderProjection,
       _noteSyncService = noteSyncJournal == null
           ? null
           : KnowledgeNoteSyncService(noteSyncJournal) {
    if (_store.workspaceId != _workspaceId) {
      throw ArgumentError.value(
        workspaceId,
        'workspaceId',
        'must match the checkpoint store scope',
      );
    }
    if (noteSyncJournal != null &&
        noteSyncJournal.workspaceId != _workspaceId) {
      throw ArgumentError.value(
        noteSyncJournal.workspaceId,
        'noteSyncJournal.workspaceId',
        'must match the synchronizer Workspace',
      );
    }
  }

  final WorkspaceContentSyncRemotePort _remote;
  final WorkspaceContentSyncStore _store;
  final String _workspaceId;
  final WorkspaceContentProjectionReader _readProjection;
  final WorkspaceContentProjectionCursorReader _readProjectionCursor;
  final WorkspaceContentProjectionApplier _applyProjection;
  final WorkspaceFolderProjectionApplier? _applyFolderProjection;
  final KnowledgeNoteSyncService? _noteSyncService;
  final Set<void Function()> _activeReadCancellations = <void Function()>{};
  Future<WorkspaceContentSyncResult>? _inFlight;
  bool _disposed = false;
  int _generation = 0;

  bool get isDisposed => _disposed;

  /// Coalesces simultaneous calls. [forceSnapshot] is useful for a deliberate
  /// refresh: it sends the stored ETag only on the first snapshot page.
  Future<WorkspaceContentSyncResult> synchronize({bool forceSnapshot = false}) {
    if (_disposed) {
      return Future<WorkspaceContentSyncResult>.value(
        const WorkspaceContentSyncResult.failure(
          'WORKSPACE_CONTENT_SYNC_CANCELLED',
        ),
      );
    }
    final existing = _inFlight;
    if (existing != null) return existing;
    final generation = _generation;
    final future = _synchronize(
      forceSnapshot: forceSnapshot,
      generation: generation,
    );
    _inFlight = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_inFlight, future)) _inFlight = null;
      }),
    );
    return future;
  }

  Future<WorkspaceContentSyncResult> _synchronize({
    required bool forceSnapshot,
    required int generation,
  }) async {
    try {
      _ensureActive(generation);
      var state = _store.load();
      _ensureActive(generation);
      if (state.contentCursor != null) {
        final projectionCursor = await _readCurrentProjectionCursor(generation);
        if (projectionCursor != state.contentCursor) {
          _ensureActive(generation);
          _clearCheckpoint();
          state = const WorkspaceContentSyncState();
        }
      }
      if (forceSnapshot || state.contentCursor == null) {
        if (state.contentCursor != null) {
          _publishFolders(state.folders, generation);
        }
        return await _synchronizeSnapshot(
          state,
          generation: generation,
          useConditionalEtag:
              forceSnapshot &&
              state.contentCursor != null &&
              state.snapshotEtag != null,
        );
      }
      _publishFolders(state.folders, generation);
      final probeResult = await _probeCurrentCursor(
        state.contentCursor!,
        generation,
      );
      if (probeResult != null) return probeResult;
      return await _synchronizeChanges(state, generation);
    } on _WorkspaceContentSyncFailure catch (failure) {
      return WorkspaceContentSyncResult.failure(failure.code);
    } on Object {
      return const WorkspaceContentSyncResult.failure(
        'WORKSPACE_CONTENT_SYNC_FAILED',
      );
    }
  }

  void _publishFolders(
    Map<String, WorkspaceContentRemoteFolder> folders,
    int generation,
  ) {
    _ensureActive(generation);
    _applyFolderProjection?.call(
      Map<String, WorkspaceContentRemoteFolder>.unmodifiable(folders),
    );
    _ensureActive(generation);
  }

  Future<WorkspaceContentSyncResult?> _probeCurrentCursor(
    String localCursor,
    int generation,
  ) async {
    final remote = _remote;
    if (remote is! WorkspaceContentCursorProbePort) return null;
    final probe = remote as WorkspaceContentCursorProbePort;
    try {
      final response = await _readRemote(
        generation,
        read: () => probe.currentContentCursor(_workspaceId),
        lease: (leasePort) => leasePort.leaseCurrentContentCursor(_workspaceId),
      );
      final remoteCursor = response.data;
      if (response.ok &&
          remoteCursor != null &&
          _isCanonicalContentCursor(remoteCursor) &&
          remoteCursor == localCursor) {
        return WorkspaceContentSyncResult.notModified(
          contentCursor: localCursor,
        );
      }
    } on _WorkspaceContentSyncFailure {
      rethrow;
    } on Object {
      // A version probe is only an optimization. The established delta read
      // remains the compatibility path when this small read is unavailable.
    }
    return null;
  }

  Future<T> _readRemote<T>(
    int generation, {
    required Future<T> Function() read,
    required WorkspaceContentReadLease<T> Function(
      WorkspaceContentSyncReadLeasePort port,
    )
    lease,
  }) async {
    _ensureActive(generation);
    final remote = _remote;
    if (remote is! WorkspaceContentSyncReadLeasePort) {
      final result = await read();
      _ensureActive(generation);
      return result;
    }
    final leasePort = remote as WorkspaceContentSyncReadLeasePort;
    final request = lease(leasePort);
    final cancel = request.cancel;
    _activeReadCancellations.add(cancel);
    try {
      final result = await request.result;
      _ensureActive(generation);
      return result;
    } finally {
      _activeReadCancellations.remove(cancel);
    }
  }

  void _ensureActive(int generation) {
    if (_disposed || generation != _generation) {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_SYNC_CANCELLED',
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    final cancellations = _activeReadCancellations.toList(growable: false);
    _activeReadCancellations.clear();
    for (final cancel in cancellations) {
      try {
        cancel();
      } on Object {
        // Releasing one adapter cannot prevent the remaining reads releasing.
      }
    }
  }

  Future<WorkspaceContentSyncResult> _synchronizeSnapshot(
    WorkspaceContentSyncState prior, {
    required int generation,
    required bool useConditionalEtag,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _readAndApplySnapshot(
          prior,
          generation: generation,
          ifNoneMatch: attempt == 0 && useConditionalEtag
              ? prior.snapshotEtag
              : null,
        );
      } on _WorkspaceContentSyncFailure catch (failure) {
        if (attempt == 0 && failure.code == 'SNAPSHOT_EXPIRED') continue;
        rethrow;
      }
    }
    throw const _WorkspaceContentSyncFailure('SNAPSHOT_EXPIRED');
  }

  Future<WorkspaceContentSyncResult> _readAndApplySnapshot(
    WorkspaceContentSyncState prior, {
    required int generation,
    required String? ifNoneMatch,
  }) async {
    String? pageToken;
    String? snapshotId;
    String? atCursor;
    String? snapshotEtag;
    final pageTokens = <String>{};
    final folders = <String, WorkspaceContentRemoteFolder>{};
    final heads = <String, _HNoteHead>{};

    while (true) {
      final response = await _readRemote(
        generation,
        read: () => _remote.contentSnapshot(
          _workspaceId,
          pageToken: pageToken,
          ifNoneMatch: pageToken == null ? ifNoneMatch : null,
        ),
        lease: (remote) => remote.leaseContentSnapshot(
          _workspaceId,
          pageToken: pageToken,
          ifNoneMatch: pageToken == null ? ifNoneMatch : null,
        ),
      );
      if (response.isNotModified) {
        if (pageToken != null) {
          throw const _WorkspaceContentSyncFailure(
            'WORKSPACE_CONTENT_SNAPSHOT_PAGINATION_INVALID',
          );
        }
        return WorkspaceContentSyncResult.notModified(
          contentCursor: prior.contentCursor,
        );
      }
      final page = _requireSnapshot(response);
      snapshotId ??= page.snapshotId;
      atCursor ??= page.atCursor;
      snapshotEtag ??= _nonEmpty(response.etag);
      if (page.snapshotId != snapshotId || page.atCursor != atCursor) {
        throw const _WorkspaceContentSyncFailure(
          'WORKSPACE_CONTENT_SNAPSHOT_INCONSISTENT',
        );
      }
      for (final folder in page.folders) {
        _validateFolderWorkspace(folder);
        final projected = _remoteFolder(folder);
        if (_isLiveFolder(projected)) folders[projected.folderId] = projected;
      }
      for (final object in page.objects) {
        if (object.ownerRef.workspaceId != _workspaceId) {
          throw const _WorkspaceContentSyncFailure(
            'WORKSPACE_CONTENT_SNAPSHOT_WORKSPACE_INVALID',
          );
        }
        if (object.ownerRef.kind != 'hnote') continue;
        final noteId = _nonEmpty(object.ownerRef.id);
        final revisionId = _nonEmpty(object.revisionId);
        if (noteId == null || revisionId == null) {
          throw const _WorkspaceContentSyncFailure(
            'WORKSPACE_CONTENT_SNAPSHOT_REVISION_INVALID',
          );
        }
        final head = _HNoteHead(
          noteId: noteId,
          revisionId: revisionId,
          tombstone: object.tombstone,
          etag: object.etag,
        );
        final previous = heads[noteId];
        if (previous != null &&
            (previous.revisionId != head.revisionId ||
                previous.tombstone != head.tombstone)) {
          throw const _WorkspaceContentSyncFailure(
            'WORKSPACE_CONTENT_SNAPSHOT_DUPLICATE_OBJECT',
          );
        }
        heads[noteId] = head;
      }
      if (!page.hasMore) break;
      final next = _nonEmpty(page.nextPageToken);
      if (next == null || !pageTokens.add(next)) {
        throw const _WorkspaceContentSyncFailure(
          'WORKSPACE_CONTENT_SNAPSHOT_PAGINATION_INVALID',
        );
      }
      pageToken = next;
    }

    _publishFolders(folders, generation);
    final cursor = atCursor;
    var notes = List<V3FeedItem>.from(await _readCurrentNotes(generation));
    final hydrationTasks = <Future<V3FeedItem> Function()>[];
    for (final head in heads.values) {
      _ensureActive(generation);
      if (_hasProtectedNote(notes, head.noteId)) continue;
      final fallback = _fallbackFor(notes, head.noteId);
      notes = _withoutRemoteNote(notes, head.noteId);
      if (head.tombstone) continue;
      hydrationTasks.add(() async {
        final note = await _readExactHNote(head, generation);
        return _mapRemoteNote(note, fallback: fallback);
      });
    }
    for (
      var offset = 0;
      offset < hydrationTasks.length;
      offset += _snapshotHNoteHydrationConcurrency
    ) {
      _ensureActive(generation);
      final batchEnd = offset + _snapshotHNoteHydrationConcurrency;
      final batch = hydrationTasks.sublist(
        offset,
        batchEnd < hydrationTasks.length ? batchEnd : hydrationTasks.length,
      );
      notes.addAll(await Future.wait(batch.map((hydrate) => hydrate())));
    }
    // A full snapshot is authoritative for synchronized owned HNotes. This
    // also prevents a cached remote note from a previously selected Workspace
    // from surviving in the current Workspace projection.
    notes = _reconcileSnapshotHNotes(notes, heads);
    notes = _withFolderNames(notes, folders);
    await _applyAndSave(
      generation: generation,
      notes: notes,
      folders: folders,
      cursor: cursor,
      origin: WorkspaceContentProjectionOrigin.snapshot,
      snapshotEtag: snapshotEtag,
    );
    return WorkspaceContentSyncResult.synchronized(
      contentCursor: cursor,
      rebuiltFromSnapshot: true,
    );
  }

  Future<WorkspaceContentSyncResult> _synchronizeChanges(
    WorkspaceContentSyncState initial,
    int generation,
  ) async {
    var state = initial;
    var after = state.contentCursor!;
    var eventCount = 0;
    var notes = List<V3FeedItem>.from(await _readCurrentNotes(generation));
    var folders = <String, WorkspaceContentRemoteFolder>{...state.folders};
    final observedAfter = <String>{after};

    while (true) {
      final response = await _readRemote(
        generation,
        read: () => _remote.changes(_workspaceId, after: after),
        lease: (remote) => remote.leaseChanges(_workspaceId, after: after),
      );
      if (_isExpiredCursor(response)) {
        _ensureActive(generation);
        _clearCheckpoint();
        return _synchronizeSnapshot(
          const WorkspaceContentSyncState(),
          generation: generation,
          useConditionalEtag: false,
        );
      }
      final page = _requireRemote(
        response,
        fallback: 'WORKSPACE_CONTENT_CHANGES_FAILED',
      );
      final admittedEventIds = <String>[];
      for (final event in page.events) {
        _ensureActive(generation);
        _validateEventWorkspace(event);
        final shouldApply = await _admitEvent(event, generation);
        if (!shouldApply) continue;
        admittedEventIds.add(event.eventId);
        if (event.objectKind == 'hnote') {
          notes = await _applyHNoteEvent(notes, event, generation);
        } else if (event.objectKind == 'folder') {
          folders = await _applyFolderEvent(folders, event, generation);
        }
      }
      final nextAfter = _nonEmpty(page.nextAfter);
      if (nextAfter == null ||
          (page.hasMore && !observedAfter.add(nextAfter))) {
        throw const _WorkspaceContentSyncFailure(
          'WORKSPACE_CONTENT_DELTA_PAGINATION_INVALID',
        );
      }
      notes = _withFolderNames(notes, folders);
      await _applyAndSave(
        generation: generation,
        notes: notes,
        folders: folders,
        cursor: nextAfter,
        origin: WorkspaceContentProjectionOrigin.changes,
        snapshotEtag: state.snapshotEtag,
      );
      await _markEventsProcessed(admittedEventIds, generation);
      state = WorkspaceContentSyncState(
        contentCursor: nextAfter,
        snapshotEtag: state.snapshotEtag,
        folders: Map<String, WorkspaceContentRemoteFolder>.unmodifiable(
          folders,
        ),
      );
      after = nextAfter;
      eventCount += page.events.length;
      if (!page.hasMore) break;
    }
    return WorkspaceContentSyncResult.synchronized(
      contentCursor: after,
      eventCount: eventCount,
    );
  }

  Future<bool> _admitEvent(
    SharedWorkspaceContentEvent event,
    int generation,
  ) async {
    final service = _noteSyncService;
    if (service == null) return true;
    final admitted = await service.admitEvent(
      eventId: event.eventId,
      occurredAt: event.occurredAt,
    );
    _ensureActive(generation);
    return admitted;
  }

  Future<void> _markEventsProcessed(
    List<String> eventIds,
    int generation,
  ) async {
    await _noteSyncService?.markEventsProcessed(eventIds);
    _ensureActive(generation);
  }

  Future<List<V3FeedItem>> _applyHNoteEvent(
    List<V3FeedItem> notes,
    SharedWorkspaceContentEvent event,
    int generation,
  ) async {
    if (_hasProtectedNote(notes, event.objectId)) return notes;
    final tombstoned = event.tombstone || event.changeType == 'tombstoned';
    if (tombstoned) return _withoutRemoteNote(notes, event.objectId);
    final revisionId = _nonEmpty(event.revisionId);
    if (revisionId == null) {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_EVENT_REVISION_INVALID',
      );
    }
    final previous = _fallbackFor(notes, event.objectId);
    final exact = await _readExactHNote(
      _HNoteHead(noteId: event.objectId, revisionId: revisionId),
      generation,
    );
    final next = _withoutRemoteNote(notes, event.objectId);
    next.add(_mapRemoteNote(exact, fallback: previous));
    return next;
  }

  Future<Map<String, WorkspaceContentRemoteFolder>> _applyFolderEvent(
    Map<String, WorkspaceContentRemoteFolder> folders,
    SharedWorkspaceContentEvent event,
    int generation,
  ) async {
    final next = <String, WorkspaceContentRemoteFolder>{...folders};
    if (event.tombstone || event.changeType == 'tombstoned') {
      next.remove(event.objectId);
      return next;
    }
    final revisionId = _nonEmpty(event.revisionId);
    if (revisionId == null) {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_EVENT_REVISION_INVALID',
      );
    }
    final response = await _readRemote(
      generation,
      read: () =>
          _remote.folder(_workspaceId, event.objectId, revisionId: revisionId),
      lease: (remote) => remote.leaseFolder(
        _workspaceId,
        event.objectId,
        revisionId: revisionId,
      ),
    );
    final folder = _requireRemote(
      response,
      fallback: 'WORKSPACE_CONTENT_FOLDER_READ_FAILED',
    );
    _validateFolderWorkspace(folder);
    if (folder.folderId != event.objectId ||
        folder.currentRevisionId != revisionId) {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_FOLDER_EVENT_REVISION_MISMATCH',
      );
    }
    final projected = _remoteFolder(folder);
    if (_isLiveFolder(projected)) {
      next[projected.folderId] = projected;
    } else {
      next.remove(event.objectId);
    }
    return next;
  }

  Future<SharedHNote> _readExactHNote(_HNoteHead head, int generation) async {
    final response = await _readRemote(
      generation,
      read: () =>
          _remote.note(_workspaceId, head.noteId, revisionId: head.revisionId),
      lease: (remote) => remote.leaseNote(
        _workspaceId,
        head.noteId,
        revisionId: head.revisionId,
      ),
    );
    final note = _requireRemote(
      response,
      fallback: 'WORKSPACE_CONTENT_NOTE_READ_FAILED',
    );
    if (note.noteId != head.noteId ||
        (note.workspaceId != null && note.workspaceId != _workspaceId) ||
        note.noteRevisionId != head.revisionId) {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_EXACT_REVISION_MISMATCH',
      );
    }
    if (head.etag != null && head.etag != note.etag) {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_EXACT_ETAG_MISMATCH',
      );
    }
    if (!_isReadableHNote(note.state)) {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_NOTE_STATE_INVALID',
      );
    }
    try {
      final hydrated = await hydrateWorkspaceHNoteParts(
        note,
        readPart:
            ({
              required String noteId,
              required String part,
              required String partRevisionId,
            }) async {
              final partResponse = await _readRemote(
                generation,
                read: () => _remote.notePart(
                  _workspaceId,
                  noteId,
                  part,
                  partRevisionId: partRevisionId,
                ),
                lease: (remote) => remote.leaseNotePart(
                  _workspaceId,
                  noteId,
                  part,
                  partRevisionId: partRevisionId,
                ),
              );
              return _requireRemote(
                partResponse,
                fallback: 'WORKSPACE_CONTENT_NOTE_PART_READ_FAILED',
              );
            },
      );
      _ensureActive(generation);
      return hydrated;
    } on FormatException {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_NOTE_PART_REVISION_MISMATCH',
      );
    }
  }

  Future<void> _applyAndSave({
    required int generation,
    required List<V3FeedItem> notes,
    required Map<String, WorkspaceContentRemoteFolder> folders,
    required String cursor,
    required WorkspaceContentProjectionOrigin origin,
    required String? snapshotEtag,
  }) async {
    _ensureActive(generation);
    final safeNotes = List<V3FeedItem>.unmodifiable(
      await _preserveCurrentUnsyncedNotes(notes, generation),
    );
    final safeFolders = Map<String, WorkspaceContentRemoteFolder>.unmodifiable(
      folders,
    );
    try {
      _ensureActive(generation);
      await _applyProjection(
        WorkspaceContentProjection(
          notes: safeNotes,
          folders: safeFolders,
          contentCursor: cursor,
          origin: origin,
        ),
      );
      _ensureActive(generation);
    } on Object {
      _ensureActive(generation);
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_PROJECTION_APPLY_FAILED',
      );
    }
    try {
      _ensureActive(generation);
      _store.save(
        WorkspaceContentSyncState(
          contentCursor: cursor,
          snapshotEtag: _nonEmpty(snapshotEtag),
          folders: safeFolders,
        ),
      );
    } on Object {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_CHECKPOINT_SAVE_FAILED',
      );
    }
  }

  /// A page can be on the wire while the user starts an edit locally. Preserve
  /// that newer local state at commit time instead of replacing it with the
  /// projection calculated from the earlier read.
  Future<List<V3FeedItem>> _preserveCurrentUnsyncedNotes(
    List<V3FeedItem> projected,
    int generation,
  ) async {
    final current = await _readCurrentNotes(generation);
    final protected = current
        .where((note) => note.syncState != NoteSyncState.synced)
        .toList(growable: false);
    if (protected.isEmpty) return projected;
    return <V3FeedItem>[
      for (final note in projected)
        if (!protected.any((local) => _sharesProtectedIdentity(note, local)))
          note,
      ...protected,
    ];
  }

  Future<List<V3FeedItem>> _readCurrentNotes(int generation) async {
    try {
      final notes = List<V3FeedItem>.from(await _readProjection());
      _ensureActive(generation);
      return notes;
    } on Object {
      _ensureActive(generation);
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_PROJECTION_READ_FAILED',
      );
    }
  }

  Future<String?> _readCurrentProjectionCursor(int generation) async {
    try {
      final cursor = _nonEmpty(await _readProjectionCursor());
      _ensureActive(generation);
      return cursor;
    } on Object {
      _ensureActive(generation);
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_PROJECTION_CURSOR_READ_FAILED',
      );
    }
  }

  void _clearCheckpoint() {
    try {
      _store.clear();
    } on Object {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_CHECKPOINT_CLEAR_FAILED',
      );
    }
  }

  void _validateEventWorkspace(SharedWorkspaceContentEvent event) {
    if (event.workspaceId != _workspaceId) {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_EVENT_WORKSPACE_INVALID',
      );
    }
  }

  void _validateFolderWorkspace(SharedWorkspaceFolder folder) {
    if (folder.workspaceId != null && folder.workspaceId != _workspaceId) {
      throw const _WorkspaceContentSyncFailure(
        'WORKSPACE_CONTENT_FOLDER_WORKSPACE_INVALID',
      );
    }
  }
}

final class _HNoteHead {
  const _HNoteHead({
    required this.noteId,
    required this.revisionId,
    this.tombstone = false,
    this.etag,
  });

  final String noteId;
  final String revisionId;
  final bool tombstone;
  final String? etag;
}

final class _WorkspaceContentSyncFailure implements Exception {
  const _WorkspaceContentSyncFailure(this.code);

  final String code;
}

SharedWorkspaceContentSnapshot _requireSnapshot(
  WorkspaceContentSnapshotResponse response,
) {
  final data = response.data;
  if (response.ok && data != null) return data;
  if (response.errorCode == 'SNAPSHOT_EXPIRED' ||
      response.errorCode == 'CONTENT_SNAPSHOT_EXPIRED') {
    throw const _WorkspaceContentSyncFailure('SNAPSHOT_EXPIRED');
  }
  throw _WorkspaceContentSyncFailure(
    response.errorCode ?? 'WORKSPACE_CONTENT_SNAPSHOT_FAILED',
  );
}

T _requireRemote<T>(
  WorkspaceContentRemoteResponse<T> response, {
  required String fallback,
}) {
  final data = response.data;
  if (response.ok && data != null) return data;
  throw _WorkspaceContentSyncFailure(response.errorCode ?? fallback);
}

bool _isExpiredCursor<T>(WorkspaceContentRemoteResponse<T> response) =>
    response.status == 410 || response.errorCode == 'CONTENT_CURSOR_EXPIRED';

WorkspaceContentRemoteFolder _remoteFolder(SharedWorkspaceFolder folder) {
  return WorkspaceContentRemoteFolder(
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
}

bool _isLiveFolder(WorkspaceContentRemoteFolder folder) =>
    folder.state == 'live' || folder.state == 'active';

bool _isReadableHNote(String state) => state == 'live' || state == 'active';

bool _hasProtectedNote(List<V3FeedItem> notes, String remoteNoteId) =>
    notes.any(
      (note) =>
          _matchesRemoteNote(note, remoteNoteId) &&
          note.syncState != NoteSyncState.synced,
    );

V3FeedItem? _fallbackFor(List<V3FeedItem> notes, String remoteNoteId) {
  for (final note in notes) {
    if (_matchesRemoteNote(note, remoteNoteId) &&
        note.syncState == NoteSyncState.synced) {
      return note;
    }
  }
  return null;
}

bool _matchesRemoteNote(V3FeedItem note, String remoteNoteId) {
  if (note.remoteNoteId == remoteNoteId) return true;
  return note.remoteNoteId == null &&
      note.syncState == NoteSyncState.synced &&
      note.source == V3MaterialSource.note &&
      note.id == remoteNoteId;
}

bool _sharesProtectedIdentity(V3FeedItem candidate, V3FeedItem local) {
  if (candidate.id == local.id) return true;
  final remoteNoteId = _nonEmpty(local.remoteNoteId);
  return remoteNoteId != null && _matchesRemoteNote(candidate, remoteNoteId);
}

List<V3FeedItem> _withoutRemoteNote(
  List<V3FeedItem> notes,
  String remoteNoteId,
) {
  return <V3FeedItem>[
    for (final note in notes)
      if (!_matchesRemoteNote(note, remoteNoteId) ||
          note.syncState != NoteSyncState.synced)
        note,
  ];
}

List<V3FeedItem> _reconcileSnapshotHNotes(
  List<V3FeedItem> notes,
  Map<String, _HNoteHead> heads,
) {
  return <V3FeedItem>[
    for (final note in notes)
      if (!_shouldRemoveFromSnapshot(note, heads)) note,
  ];
}

bool _shouldRemoveFromSnapshot(V3FeedItem note, Map<String, _HNoteHead> heads) {
  if (note.syncState != NoteSyncState.synced ||
      note.ownership != V3NoteOwnership.mine) {
    return false;
  }
  final remoteId = note.remoteNoteId;
  if (remoteId == null) return false;
  final head = heads[remoteId];
  return head == null || head.tombstone;
}

V3FeedItem _mapRemoteNote(SharedHNote note, {V3FeedItem? fallback}) {
  return mapRemoteHNoteToFeedItem(
    note,
    localId: fallback?.id ?? note.noteId,
    fallback: fallback,
    legacyRemoteRevision: fallback?.remoteRevision ?? 0,
  );
}

List<V3FeedItem> _withFolderNames(
  List<V3FeedItem> notes,
  Map<String, WorkspaceContentRemoteFolder> folders,
) {
  final resolved = <V3FeedItem>[];
  for (final note in notes) {
    // The folder index is remote Workspace metadata. Local deposit-folder
    // assignments, including pending/conflict edits, are intentionally opaque
    // to this projection and must retain their existing display names.
    if (note.syncState != NoteSyncState.synced || note.remoteNoteId == null) {
      resolved.add(note);
      continue;
    }
    final folderId = note.folderId;
    final folderName = folderId == null ? null : folders[folderId]?.displayName;
    resolved.add(
      folderName == note.folderName
          ? note
          : folderName == null
          ? note.copyWith(clearFolderName: true)
          : note.copyWith(folderName: folderName),
    );
  }
  return resolved;
}

String _requiredWorkspaceId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 256) {
    throw ArgumentError.value(value, 'workspaceId', 'must not be empty');
  }
  return normalized;
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

bool _isCanonicalContentCursor(String value) =>
    RegExp(r'^(?:0|[1-9][0-9]*)$').hasMatch(value);
