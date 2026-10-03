import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_editor/huahuo_editor.dart';
import 'package:path_provider/path_provider.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_document_sync_port.dart';

abstract interface class DesktopDocumentOutboxStore {
  Future<DesktopDocumentOutbox> load(String scope);

  Future<void> save(String scope, DesktopDocumentOutbox outbox);
}

final class DesktopDocumentBinding {
  const DesktopDocumentBinding({
    required this.noteId,
    required this.etag,
    required this.serverRevision,
    this.localRevision = 0,
    this.rawPartRevisionId,
    this.outlinePartRevisionId,
    this.germinationPartRevisionId,
  });

  factory DesktopDocumentBinding.fromJson(Map<String, Object?> json) {
    final noteId = json['noteId'];
    final etag = json['etag'];
    final serverRevision = json['serverRevision'];
    final localRevision = json['localRevision'];
    final rawPartRevisionId = json['rawPartRevisionId'];
    final outlinePartRevisionId = json['outlinePartRevisionId'];
    final germinationPartRevisionId = json['germinationPartRevisionId'];
    if (noteId is! String ||
        etag is! String ||
        serverRevision is! String ||
        (localRevision != null && localRevision is! int) ||
        (rawPartRevisionId != null && rawPartRevisionId is! String) ||
        (outlinePartRevisionId != null && outlinePartRevisionId is! String) ||
        (germinationPartRevisionId != null &&
            germinationPartRevisionId is! String)) {
      throw const FormatException('Invalid Desktop document binding');
    }
    return DesktopDocumentBinding(
      noteId: noteId,
      etag: etag,
      serverRevision: serverRevision,
      localRevision: localRevision as int? ?? 0,
      rawPartRevisionId: rawPartRevisionId as String?,
      outlinePartRevisionId: outlinePartRevisionId as String?,
      germinationPartRevisionId: germinationPartRevisionId as String?,
    );
  }

  final String noteId;
  final String etag;
  final String serverRevision;
  final int localRevision;
  final String? rawPartRevisionId;
  final String? outlinePartRevisionId;
  final String? germinationPartRevisionId;

  String? partRevisionId(String part) => switch (part) {
    'raw' => rawPartRevisionId,
    'outline' => outlinePartRevisionId,
    'germination' => germinationPartRevisionId,
    _ => null,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'noteId': noteId,
    'etag': etag,
    'serverRevision': serverRevision,
    'localRevision': localRevision,
    if (rawPartRevisionId != null) 'rawPartRevisionId': rawPartRevisionId,
    if (outlinePartRevisionId != null)
      'outlinePartRevisionId': outlinePartRevisionId,
    if (germinationPartRevisionId != null)
      'germinationPartRevisionId': germinationPartRevisionId,
  };
}

final class DesktopDocumentOutboxEntry {
  const DesktopDocumentOutboxEntry({
    required this.localDocumentId,
    required this.mutationId,
    required this.snapshotJson,
  });

  factory DesktopDocumentOutboxEntry.fromJson(Map<String, Object?> json) {
    final localDocumentId = json['localDocumentId'];
    final mutationId = json['mutationId'];
    final snapshotJson = json['snapshot'];
    if (localDocumentId is! String ||
        mutationId is! String ||
        snapshotJson is! Map) {
      throw const FormatException('Invalid Desktop document outbox entry');
    }
    return DesktopDocumentOutboxEntry(
      localDocumentId: localDocumentId,
      mutationId: mutationId,
      snapshotJson: snapshotJson.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
    );
  }

  final String localDocumentId;
  final String mutationId;
  final Map<String, Object?> snapshotJson;

  HuahuoDocumentSnapshot get snapshot =>
      HuahuoDocumentSnapshot.fromJson(snapshotJson);

  Map<String, Object?> toJson() => <String, Object?>{
    'localDocumentId': localDocumentId,
    'mutationId': mutationId,
    'snapshot': snapshotJson,
  };
}

final class DesktopDocumentOutbox {
  const DesktopDocumentOutbox({
    this.pending = const <DesktopDocumentOutboxEntry>[],
    this.bindings = const <String, DesktopDocumentBinding>{},
    this.contentCursor,
  });

  factory DesktopDocumentOutbox.fromJson(Map<String, Object?> json) {
    if (json['formatVersion'] != 1 &&
        json['formatVersion'] != 2 &&
        json['formatVersion'] != 3 &&
        json['formatVersion'] != 4) {
      throw const FormatException('Unsupported Desktop outbox format');
    }
    final rawPending = json['pending'];
    final rawBindings = json['bindings'];
    if (rawPending is! List || rawBindings is! Map) {
      throw const FormatException('Invalid Desktop outbox');
    }
    final contentCursor = json['contentCursor'];
    if (contentCursor != null && contentCursor is! String) {
      throw const FormatException('Invalid Desktop content cursor');
    }
    return DesktopDocumentOutbox(
      pending: rawPending
          .map((raw) {
            if (raw is! Map) {
              throw const FormatException('Invalid Desktop outbox entry');
            }
            return DesktopDocumentOutboxEntry.fromJson(
              raw.map((key, value) => MapEntry(key.toString(), value)),
            );
          })
          .toList(growable: false),
      bindings: rawBindings.map((key, value) {
        if (value is! Map) {
          throw const FormatException('Invalid Desktop outbox binding');
        }
        return MapEntry(
          key.toString(),
          DesktopDocumentBinding.fromJson(
            value.map((key, value) => MapEntry(key.toString(), value)),
          ),
        );
      }),
      contentCursor: json['formatVersion'] == 4
          ? contentCursor as String?
          : null,
    );
  }

  final List<DesktopDocumentOutboxEntry> pending;
  final Map<String, DesktopDocumentBinding> bindings;
  final String? contentCursor;

  DesktopDocumentOutbox enqueue(HuahuoDocumentSnapshot snapshot) {
    final mutationId = _mutationId(snapshot);
    if (pending.any((entry) => entry.mutationId == mutationId)) return this;
    final isBound = bindings.containsKey(snapshot.id);
    return DesktopDocumentOutbox(
      pending: <DesktopDocumentOutboxEntry>[
        for (final entry in pending)
          if (!isBound || entry.localDocumentId != snapshot.id) entry,
        DesktopDocumentOutboxEntry(
          localDocumentId: snapshot.id,
          mutationId: mutationId,
          snapshotJson: snapshot.toJson(),
        ),
      ],
      bindings: bindings,
      contentCursor: contentCursor,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': 4,
    'pending': pending.map((entry) => entry.toJson()).toList(growable: false),
    'bindings': bindings.map(
      (localId, binding) => MapEntry(localId, binding.toJson()),
    ),
    if (contentCursor != null) 'contentCursor': contentCursor,
  };
}

final class LocalDesktopDocumentOutboxStore
    implements DesktopDocumentOutboxStore {
  LocalDesktopDocumentOutboxStore({
    Future<Directory> Function()? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  Future<File> _file(String scope) async {
    final support = await _supportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}document-sync',
    );
    if (!directory.existsSync()) await directory.create(recursive: true);
    final safeScope = base64Url.encode(utf8.encode(scope)).replaceAll('=', '');
    return File(
      '${directory.path}${Platform.pathSeparator}outbox-$safeScope.json',
    );
  }

  @override
  Future<DesktopDocumentOutbox> load(String scope) async {
    final file = await _file(scope);
    final backup = File('${file.path}.bak');
    final legacy = File(
      '${file.parent.path}${Platform.pathSeparator}outbox.json',
    );
    if (scope == 'unbound' &&
        !file.existsSync() &&
        !backup.existsSync() &&
        legacy.existsSync()) {
      final migrated = await _read(legacy);
      await legacy.rename(file.path);
      return migrated;
    }
    if (!file.existsSync() && backup.existsSync()) {
      final recovered = await _read(backup);
      await backup.rename(file.path);
      return recovered;
    }
    try {
      return await _read(file);
    } on Object {
      if (!backup.existsSync()) rethrow;
      final recovered = await _read(backup);
      if (file.existsSync()) await file.delete();
      await backup.rename(file.path);
      return recovered;
    }
  }

  @override
  Future<void> save(String scope, DesktopDocumentOutbox outbox) async {
    final file = await _file(scope);
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temporary.writeAsString(jsonEncode(outbox.toJson()), flush: true);
    if (!file.existsSync()) {
      await temporary.rename(file.path);
      return;
    }
    if (backup.existsSync()) await backup.delete();
    await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
    } on Object {
      if (!file.existsSync() && backup.existsSync()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }

  Future<DesktopDocumentOutbox> _read(File file) async {
    if (!file.existsSync()) return const DesktopDocumentOutbox();
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('Invalid Desktop outbox');
    return DesktopDocumentOutbox.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }
}

final class UnavailableDesktopDocumentSyncPort
    implements DesktopDocumentSyncPort {
  UnavailableDesktopDocumentSyncPort({DesktopDocumentOutboxStore? outboxStore})
    : _outboxStore = outboxStore ?? LocalDesktopDocumentOutboxStore();

  final DesktopDocumentOutboxStore _outboxStore;
  final _access = _SerializedOutboxAccess();
  String _scope = 'unbound';

  @override
  Future<void> bindAccount({
    required String userId,
    required String workspaceId,
  }) => _access.run(() async => _scope = '$userId:$workspaceId');

  @override
  Future<void> clearAccount() => _access.run(() async => _scope = 'unbound');

  @override
  Future<DesktopDocumentRemoteReference?> remoteReferenceFor({
    required String localDocumentId,
    String part = 'raw',
  }) async => null;

  @override
  Future<DesktopServiceResult<DesktopDocumentPullBatch>> pullRemote({
    required DesktopDocumentPullApplier apply,
  }) async => const DesktopServiceResult<DesktopDocumentPullBatch>.unavailable(
    code: 'DESKTOP_DOCUMENT_PULL_UNAVAILABLE',
    message: '云端文稿读取服务尚未配置，本地文稿保持不变',
  );

  @override
  Future<DesktopServiceResult<DesktopDocumentSyncState>> enqueue(
    HuahuoDocumentSnapshot snapshot,
  ) => _access.run(() async {
    final scope = _scope;
    final outbox = (await _outboxStore.load(scope)).enqueue(snapshot);
    await _outboxStore.save(scope, outbox);
    return DesktopServiceResult<DesktopDocumentSyncState>.queued(
      data: DesktopDocumentSyncState(
        phase: DesktopDocumentSyncPhase.waitingForService,
        pendingCount: outbox.pending.length,
      ),
      code: 'DESKTOP_DOCUMENT_SYNC_UNAVAILABLE',
      message: '文稿已保存在本地，等待服务支持',
    );
  });

  @override
  Future<DesktopServiceResult<DesktopDocumentSyncState>> retryPending() =>
      _access.run(() async {
        final outbox = await _outboxStore.load(_scope);
        return DesktopServiceResult<DesktopDocumentSyncState>.queued(
          data: DesktopDocumentSyncState(
            phase: DesktopDocumentSyncPhase.waitingForService,
            pendingCount: outbox.pending.length,
          ),
          code: 'DESKTOP_DOCUMENT_SYNC_UNAVAILABLE',
          message: '本地队列仍在等待服务支持',
        );
      });
}

final class RemoteDesktopDocumentSyncPort implements DesktopDocumentSyncPort {
  RemoteDesktopDocumentSyncPort(
    ApiClient apiClient, {
    required this.remoteWriteEnabled,
    DesktopDocumentOutboxStore? outboxStore,
    DateTime Function()? now,
  }) : _apiClient = apiClient,
       _workspace = WorkspaceContentClient(apiClient),
       _outboxStore = outboxStore ?? LocalDesktopDocumentOutboxStore(),
       _now = now ?? DateTime.now;

  final ApiClient _apiClient;
  final WorkspaceContentClient _workspace;
  final DesktopDocumentOutboxStore _outboxStore;
  final bool remoteWriteEnabled;
  final DateTime Function() _now;
  final _access = _SerializedOutboxAccess();
  String? _userId;
  String? _workspaceId;

  String get _scope => _userId == null || _workspaceId == null
      ? 'unbound'
      : '${_userId!}:${_workspaceId!}';

  @override
  Future<void> bindAccount({
    required String userId,
    required String workspaceId,
  }) => _access.run(() async {
    _userId = userId;
    _workspaceId = workspaceId;
  });

  @override
  Future<void> clearAccount() => _access.run(() async {
    _userId = null;
    _workspaceId = null;
  });

  @override
  Future<DesktopDocumentRemoteReference?> remoteReferenceFor({
    required String localDocumentId,
    String part = 'raw',
  }) => _access.run(() async {
    final binding = (await _outboxStore.load(_scope)).bindings[localDocumentId];
    final revision = binding?.partRevisionId(part);
    if (binding == null || revision == null) return null;
    return DesktopDocumentRemoteReference(
      noteId: binding.noteId,
      part: part,
      partRevisionId: revision,
      localRevision: binding.localRevision,
    );
  });

  @override
  Future<DesktopServiceResult<DesktopDocumentPullBatch>> pullRemote({
    required DesktopDocumentPullApplier apply,
  }) => _access.run(() async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) {
      return const DesktopServiceResult<DesktopDocumentPullBatch>.unavailable(
        code: 'DESKTOP_DOCUMENT_ACCOUNT_UNBOUND',
        message: '尚未绑定 Workspace，本地文稿保持不变',
      );
    }
    final scope = _scope;
    final outbox = await _outboxStore.load(scope);
    late final _DesktopDocumentPullPlan plan;
    try {
      plan = outbox.contentCursor == null
          ? await _buildSnapshotPlan(workspaceId, outbox)
          : await _buildDeltaPlan(workspaceId, outbox);
    } on _DesktopDocumentPullFailure catch (failure) {
      return DesktopServiceResult<DesktopDocumentPullBatch>.failure(
        code: failure.code,
        message: failure.message,
        retryable: failure.retryable,
      );
    } on Object {
      return const DesktopServiceResult<DesktopDocumentPullBatch>.failure(
        code: 'DESKTOP_DOCUMENT_PULL_RESPONSE_INVALID',
        message: '云端文稿响应无法解析，本地文稿保持不变',
      );
    }
    try {
      await apply(plan.batch);
    } on Object {
      return const DesktopServiceResult<DesktopDocumentPullBatch>.failure(
        code: 'DESKTOP_DOCUMENT_PULL_APPLY_FAILED',
        message: '云端文稿未能保存到本地，原有文稿保持可用',
        retryable: true,
      );
    }
    await _outboxStore.save(scope, plan.outbox);
    return DesktopServiceResult<DesktopDocumentPullBatch>.success(plan.batch);
  });

  Future<_DesktopDocumentPullPlan> _buildSnapshotPlan(
    String workspaceId,
    DesktopDocumentOutbox outbox,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _readSnapshotPlan(workspaceId, outbox);
      } on _DesktopDocumentPullFailure catch (failure) {
        if (attempt == 0 && failure.code == 'SNAPSHOT_EXPIRED') continue;
        rethrow;
      }
    }
    throw const _DesktopDocumentPullFailure(
      code: 'SNAPSHOT_EXPIRED',
      message: 'Workspace 快照已失效，请稍后重试',
      retryable: true,
    );
  }

  Future<_DesktopDocumentPullPlan> _readSnapshotPlan(
    String workspaceId,
    DesktopDocumentOutbox outbox,
  ) async {
    String? pageToken;
    String? snapshotId;
    String? atCursor;
    final seenPageTokens = <String>{};
    final heads = <String, _RemoteHNoteHead>{};
    final allHNoteIds = <String>{};
    while (true) {
      final result = await _workspace.contentSnapshot(
        workspaceId,
        pageToken: pageToken,
      );
      final page = _requirePullData(result, 'Workspace 快照读取失败');
      snapshotId ??= page.snapshotId;
      atCursor ??= page.atCursor;
      if (page.snapshotId != snapshotId || page.atCursor != atCursor) {
        throw const _DesktopDocumentPullFailure(
          code: 'DESKTOP_DOCUMENT_SNAPSHOT_INCONSISTENT',
          message: 'Workspace 快照分页不一致，本地文稿保持不变',
        );
      }
      for (final object in page.objects) {
        if (object.ownerRef.kind != 'hnote') continue;
        final noteId = object.ownerRef.id;
        allHNoteIds.add(noteId);
        final revisionId = object.revisionId;
        if (revisionId == null) {
          throw const _DesktopDocumentPullFailure(
            code: 'DESKTOP_DOCUMENT_REVISION_MISSING',
            message: '云端 HNote 缺少精确版本，本地文稿保持不变',
          );
        }
        heads[noteId] = _RemoteHNoteHead(
          noteId: noteId,
          revisionId: revisionId,
          tombstone: object.tombstone,
          etag: object.etag,
          modifiedAt: _now().toUtc(),
        );
      }
      if (!page.hasMore) break;
      final next = page.nextPageToken;
      if (next == null || next.isEmpty || !seenPageTokens.add(next)) {
        throw const _DesktopDocumentPullFailure(
          code: 'DESKTOP_DOCUMENT_SNAPSHOT_PAGINATION_INVALID',
          message: 'Workspace 快照分页无效，本地文稿保持不变',
        );
      }
      pageToken = next;
    }
    return _hydratePlan(
      workspaceId: workspaceId,
      outbox: outbox,
      cursor: atCursor,
      heads: heads,
      fullSnapshotHNoteIds: allHNoteIds,
      rebuiltFromSnapshot: true,
    );
  }

  Future<_DesktopDocumentPullPlan> _buildDeltaPlan(
    String workspaceId,
    DesktopDocumentOutbox outbox,
  ) async {
    var after = outbox.contentCursor!;
    final heads = <String, _RemoteHNoteHead>{};
    while (true) {
      final result = await _workspace.changes(workspaceId, after: after);
      if (_isExpiredCursor(result)) {
        return _buildSnapshotPlan(workspaceId, outbox);
      }
      final page = _requirePullData(result, 'Workspace 增量读取失败');
      for (final event in page.events) {
        if (event.objectKind != 'hnote') continue;
        final revisionId = event.revisionId;
        if (revisionId == null) {
          throw const _DesktopDocumentPullFailure(
            code: 'DESKTOP_DOCUMENT_REVISION_MISSING',
            message: '云端 HNote 事件缺少精确版本，本地文稿保持不变',
          );
        }
        heads[event.objectId] = _RemoteHNoteHead(
          noteId: event.objectId,
          revisionId: revisionId,
          tombstone: event.tombstone,
          modifiedAt: event.occurredAt.toUtc(),
        );
      }
      if (page.hasMore && page.nextAfter == after) {
        throw const _DesktopDocumentPullFailure(
          code: 'DESKTOP_DOCUMENT_DELTA_PAGINATION_INVALID',
          message: 'Workspace 增量游标未前进，本地文稿保持不变',
        );
      }
      after = page.nextAfter;
      if (!page.hasMore) break;
    }
    return _hydratePlan(
      workspaceId: workspaceId,
      outbox: outbox,
      cursor: after,
      heads: heads,
      rebuiltFromSnapshot: false,
    );
  }

  Future<_DesktopDocumentPullPlan> _hydratePlan({
    required String workspaceId,
    required DesktopDocumentOutbox outbox,
    required String cursor,
    required Map<String, _RemoteHNoteHead> heads,
    required bool rebuiltFromSnapshot,
    Set<String>? fullSnapshotHNoteIds,
  }) async {
    final pendingIds = outbox.pending
        .map((entry) => entry.localDocumentId)
        .toSet();
    final bindings = <String, DesktopDocumentBinding>{...outbox.bindings};
    final localIdByNoteId = <String, String>{
      for (final entry in bindings.entries) entry.value.noteId: entry.key,
    };
    final protectedIds = <String>{};
    final deletedIds = <String>{};
    final documents = <HuahuoDocumentSnapshot>[];

    if (fullSnapshotHNoteIds != null) {
      for (final entry in outbox.bindings.entries) {
        if (fullSnapshotHNoteIds.contains(entry.value.noteId)) continue;
        if (pendingIds.contains(entry.key)) {
          protectedIds.add(entry.key);
          continue;
        }
        bindings.remove(entry.key);
        deletedIds.add(entry.key);
      }
    }

    for (final head in heads.values) {
      final boundLocalId = localIdByNoteId[head.noteId];
      final localId = boundLocalId ?? head.noteId;
      if (pendingIds.contains(localId)) {
        protectedIds.add(localId);
        continue;
      }
      if (head.tombstone) {
        if (boundLocalId != null) {
          bindings.remove(boundLocalId);
          deletedIds.add(boundLocalId);
        }
        continue;
      }
      final note = _requirePullData(
        await _workspace.note(
          workspaceId,
          head.noteId,
          revisionId: head.revisionId,
        ),
        '云端 HNote 精确版本读取失败',
      );
      if (note.noteId != head.noteId ||
          (note.workspaceId != null && note.workspaceId != workspaceId) ||
          note.noteRevisionId != head.revisionId) {
        throw const _DesktopDocumentPullFailure(
          code: 'DESKTOP_DOCUMENT_EXACT_REVISION_MISMATCH',
          message: '云端 HNote 返回了非请求版本，本地文稿保持不变',
        );
      }
      if (head.etag != null && note.etag != head.etag) {
        throw const _DesktopDocumentPullFailure(
          code: 'DESKTOP_DOCUMENT_EXACT_ETAG_MISMATCH',
          message: '云端 HNote 版本标识不一致，本地文稿保持不变',
        );
      }
      if (note.state != 'active' && note.state != 'live') {
        throw const _DesktopDocumentPullFailure(
          code: 'DESKTOP_DOCUMENT_NOTE_STATE_INVALID',
          message: '云端 HNote 不可读取，本地文稿保持不变',
        );
      }
      final hydrated = await hydrateWorkspaceHNoteParts(
        note,
        readPart:
            ({
              required String noteId,
              required String part,
              required String partRevisionId,
            }) async => _requirePullData(
              await _workspace.notePart(
                workspaceId,
                noteId,
                part,
                partRevisionId: partRevisionId,
              ),
              '云端 HNote 正文版本读取失败',
            ),
      );
      final previous = bindings[localId];
      final localRevision = (previous?.localRevision ?? 0) + 1;
      documents.add(
        _documentSnapshotFromHNote(
          hydrated,
          localDocumentId: localId,
          localRevision: localRevision,
          modifiedAt: head.modifiedAt,
        ),
      );
      bindings[localId] = DesktopDocumentBinding(
        noteId: note.noteId,
        etag: note.etag,
        serverRevision: note.noteRevisionId,
        localRevision: localRevision,
        rawPartRevisionId: note.raw.partRevisionId,
        outlinePartRevisionId: note.outline.partRevisionId,
        germinationPartRevisionId: note.germination.partRevisionId,
      );
    }

    final batch = DesktopDocumentPullBatch(
      documents: List<HuahuoDocumentSnapshot>.unmodifiable(documents),
      deletedDocumentIds: Set<String>.unmodifiable(deletedIds),
      contentCursor: cursor,
      rebuiltFromSnapshot: rebuiltFromSnapshot,
      protectedPendingCount: protectedIds.length,
    );
    return _DesktopDocumentPullPlan(
      batch: batch,
      outbox: DesktopDocumentOutbox(
        pending: outbox.pending,
        bindings: Map<String, DesktopDocumentBinding>.unmodifiable(bindings),
        contentCursor: cursor,
      ),
    );
  }

  @override
  Future<DesktopServiceResult<DesktopDocumentSyncState>> enqueue(
    HuahuoDocumentSnapshot snapshot,
  ) => _access.run(() async {
    final scope = _scope;
    final outbox = (await _outboxStore.load(scope)).enqueue(snapshot);
    await _outboxStore.save(scope, outbox);
    return _flush(scope, outbox);
  });

  @override
  Future<DesktopServiceResult<DesktopDocumentSyncState>> retryPending() =>
      _access.run(() async {
        final scope = _scope;
        return _flush(scope, await _outboxStore.load(scope));
      });

  Future<DesktopServiceResult<DesktopDocumentSyncState>> _flush(
    String scope,
    DesktopDocumentOutbox outbox,
  ) async {
    final workspaceId = _workspaceId;
    if (!remoteWriteEnabled || workspaceId == null) {
      return DesktopServiceResult<DesktopDocumentSyncState>.queued(
        data: DesktopDocumentSyncState(
          phase: DesktopDocumentSyncPhase.waitingForService,
          pendingCount: outbox.pending.length,
        ),
        code: 'DESKTOP_DOCUMENT_WRITE_DISABLED',
        message: '文稿已进入本地队列，等待服务支持',
      );
    }
    var current = outbox;
    for (final entry in List<DesktopDocumentOutboxEntry>.from(outbox.pending)) {
      if (_containsPendingMedia(entry.snapshot)) {
        return DesktopServiceResult<DesktopDocumentSyncState>.queued(
          data: DesktopDocumentSyncState(
            phase: DesktopDocumentSyncPhase.waitingForService,
            pendingCount: current.pending.length,
          ),
          code: 'DESKTOP_DOCUMENT_MEDIA_UPLOAD_REQUIRED',
          message: '文稿包含尚未上传的图片，已保留本地队列',
        );
      }
      final binding = current.bindings[entry.localDocumentId];
      final result = binding == null
          ? await _createRemote(workspaceId, entry)
          : await _updateRemote(workspaceId, entry, binding);
      if (!result.ok) {
        final conflict =
            result.status == 409 ||
            result.status == 412 ||
            result.error?.code == 'CONFLICT' ||
            result.error?.code == 'PRECONDITION_FAILED';
        return DesktopServiceResult<DesktopDocumentSyncState>.failure(
          code: result.error?.code ?? 'DESKTOP_DOCUMENT_SYNC_FAILED',
          message: conflict ? '远端文稿已更新，请先处理冲突' : '文稿同步失败，已保留本地队列',
          retryable: result.error?.isRetryable ?? true,
          data: DesktopDocumentSyncState(
            phase: conflict
                ? DesktopDocumentSyncPhase.conflict
                : DesktopDocumentSyncPhase.queued,
            pendingCount: current.pending.length,
            serverRevision: binding?.serverRevision,
          ),
        );
      }
      final note = result.data!;
      current = DesktopDocumentOutbox(
        pending: current.pending
            .where((candidate) => candidate.mutationId != entry.mutationId)
            .toList(growable: false),
        bindings: <String, DesktopDocumentBinding>{
          ...current.bindings,
          entry.localDocumentId: DesktopDocumentBinding(
            noteId: note.noteId,
            etag: note.etag,
            serverRevision: note.noteRevisionId,
            localRevision: entry.snapshot.revision,
            rawPartRevisionId: note.rawPartRevisionId,
            outlinePartRevisionId: note.outlinePartRevisionId,
            germinationPartRevisionId: note.germinationPartRevisionId,
          ),
        },
        contentCursor: current.contentCursor,
      );
      await _outboxStore.save(scope, current);
    }
    final latestBinding = current.bindings.values.lastOrNull;
    return DesktopServiceResult<DesktopDocumentSyncState>.success(
      DesktopDocumentSyncState(
        phase: DesktopDocumentSyncPhase.synced,
        pendingCount: current.pending.length,
        serverRevision: latestBinding?.serverRevision,
      ),
    );
  }

  Future<ApiResult<SharedHNoteMutationReceipt>> _createRemote(
    String workspaceId,
    DesktopDocumentOutboxEntry entry,
  ) {
    return _apiClient.request<SharedHNoteMutationReceipt>(
      ApiRequestOptions<SharedHNoteMutationReceipt>(
        endpointId: 'createWorkspaceNote',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        body: _noteBody(entry.snapshot, isCreate: true),
        idempotency: IdempotencyRequestContext(
          explicitKey: entry.mutationId,
          operation: 'desktop.document.create',
          localDraftId: entry.localDocumentId,
        ),
        parseData: _parseNoteReceipt,
      ),
    );
  }

  Future<ApiResult<SharedHNoteMutationReceipt>> _updateRemote(
    String workspaceId,
    DesktopDocumentOutboxEntry entry,
    DesktopDocumentBinding binding,
  ) {
    return _apiClient.request<SharedHNoteMutationReceipt>(
      ApiRequestOptions<SharedHNoteMutationReceipt>(
        endpointId: 'updateWorkspaceNote',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': binding.noteId,
        },
        headers: <String, String>{'If-Match': binding.etag},
        body: _noteBody(entry.snapshot, isCreate: false),
        idempotency: IdempotencyRequestContext(
          explicitKey: entry.mutationId,
          operation: 'desktop.document.update',
          localDraftId: entry.localDocumentId,
        ),
        parseData: _parseNoteReceipt,
      ),
    );
  }
}

final class _DesktopDocumentPullPlan {
  const _DesktopDocumentPullPlan({required this.batch, required this.outbox});

  final DesktopDocumentPullBatch batch;
  final DesktopDocumentOutbox outbox;
}

final class _RemoteHNoteHead {
  const _RemoteHNoteHead({
    required this.noteId,
    required this.revisionId,
    required this.tombstone,
    required this.modifiedAt,
    this.etag,
  });

  final String noteId;
  final String revisionId;
  final bool tombstone;
  final String? etag;
  final DateTime modifiedAt;
}

final class _DesktopDocumentPullFailure implements Exception {
  const _DesktopDocumentPullFailure({
    required this.code,
    required this.message,
    this.retryable = false,
  });

  final String code;
  final String message;
  final bool retryable;
}

T _requirePullData<T>(ApiResult<T> result, String fallbackMessage) {
  final data = result.data;
  if (result.ok && data != null) return data;
  final error = result.error;
  throw _DesktopDocumentPullFailure(
    code: error?.code ?? 'DESKTOP_DOCUMENT_PULL_FAILED',
    message: error?.message ?? fallbackMessage,
    retryable: error?.isRetryable ?? false,
  );
}

bool _isExpiredCursor<T>(ApiResult<T> result) =>
    result.status == 410 || result.error?.code == 'CONTENT_CURSOR_EXPIRED';

HuahuoDocumentSnapshot _documentSnapshotFromHNote(
  SharedHNote note, {
  required String localDocumentId,
  required int localRevision,
  required DateTime modifiedAt,
}) {
  final rawMarkdown = note.raw.markdown;
  return HuahuoDocumentSnapshot(
    id: localDocumentId,
    title: note.title,
    deltaJson: HuahuoDocumentCodec.encodeDelta(
      HuahuoDocumentCodec.markdownToDelta(rawMarkdown),
    ),
    markdownProjection: rawMarkdown,
    summaryMarkdown: note.outline.markdown,
    sproutMarkdown: note.germination.markdown,
    revision: localRevision,
    createdAt: modifiedAt.toUtc(),
    modifiedAt: modifiedAt.toUtc(),
  );
}

Map<String, Object?> _noteBody(
  HuahuoDocumentSnapshot snapshot, {
  required bool isCreate,
}) {
  final raw =
      snapshot.markdownProjection ??
      HuahuoDocumentCodec.deltaToMarkdown(
        HuahuoDocumentCodec.decode(snapshot.deltaJson),
      );
  return <String, Object?>{
    'title': snapshot.title,
    if (isCreate) 'sourceKind': 'manual',
    'parts': <String, Object?>{
      'raw': raw,
      'outline': snapshot.summaryMarkdown ?? '',
      'germination': snapshot.sproutMarkdown ?? '',
    },
    if (isCreate) 'resourceRefs': const <Object?>[],
  };
}

SharedHNoteMutationReceipt? _parseNoteReceipt(Object? value) {
  final json = asObjectMap(value);
  return json == null ? null : SharedHNoteMutationReceipt.fromJson(json);
}

bool _containsPendingMedia(HuahuoDocumentSnapshot snapshot) {
  final decoded = jsonDecode(snapshot.deltaJson);
  if (decoded is! List) return true;
  return decoded.any((operation) {
    if (operation is! Map) return false;
    final insert = operation['insert'];
    return insert is Map &&
        (insert.containsKey('image') || insert.containsKey('canvas_image'));
  });
}

String _mutationId(HuahuoDocumentSnapshot snapshot) {
  final safeId = snapshot.id.replaceAll(RegExp(r'[^A-Za-z0-9._:-]'), '_');
  return 'desktop-document-$safeId-${snapshot.revision}';
}

final class _SerializedOutboxAccess {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
