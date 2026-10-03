import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_preferences_dao.dart';
import '../../../core/database/database_worker.dart';

enum KnowledgeNoteOutboxCommandKind { upsert, tombstone }

enum KnowledgeNoteInboxDisposition { accepted, resume, alreadyProcessed }

final class KnowledgeNoteOutboxCommand {
  const KnowledgeNoteOutboxCommand({
    required this.operationId,
    required this.kind,
    required this.localNoteId,
    required this.localRevision,
    required this.attemptCount,
    this.remoteNoteId,
    this.etag,
    this.idempotencyKey,
  });

  final String operationId;
  final KnowledgeNoteOutboxCommandKind kind;
  final String localNoteId;
  final int localRevision;
  final int attemptCount;
  final String? remoteNoteId;
  final String? etag;
  final String? idempotencyKey;
}

abstract interface class KnowledgeNoteSyncJournal {
  String get workspaceId;

  Future<KnowledgeNoteOutboxCommand> enqueueUpsert({
    required String localNoteId,
    required int localRevision,
  });

  Future<KnowledgeNoteOutboxCommand> enqueueTombstone({
    required String localNoteId,
    required int localRevision,
    required String remoteNoteId,
    required String etag,
    required String idempotencyKey,
  });

  Future<List<KnowledgeNoteOutboxCommand>> claim({
    String? operationId,
    int limit = 20,
  });

  Future<void> markSucceeded(KnowledgeNoteOutboxCommand command);

  Future<void> markRetry(
    KnowledgeNoteOutboxCommand command, {
    required String errorCode,
  });

  Future<KnowledgeNoteInboxDisposition> beginEvent({
    required String eventId,
    required DateTime occurredAt,
  });

  Future<void> markEventProcessed(String eventId);
}

final class DatabaseKnowledgeNoteSyncJournal
    implements KnowledgeNoteSyncJournal {
  DatabaseKnowledgeNoteSyncJournal({
    required DatabaseSyncJournalPort database,
    required String userScope,
    required String workspaceId,
    DateTime Function()? now,
  }) : _database = database,
       _userScope = _requiredScope(userScope, 'userScope'),
       workspaceId = _requiredScope(workspaceId, 'workspaceId'),
       _now = now ?? DateTime.now;

  static const _topic = 'knowledge_note_v1';
  static const _payloadVersion = 1;

  final DatabaseSyncJournalPort _database;
  final String _userScope;
  @override
  final String workspaceId;
  final DateTime Function() _now;

  @override
  Future<KnowledgeNoteOutboxCommand> enqueueUpsert({
    required String localNoteId,
    required int localRevision,
  }) {
    return _enqueue(
      kind: KnowledgeNoteOutboxCommandKind.upsert,
      localNoteId: localNoteId,
      localRevision: localRevision,
    );
  }

  @override
  Future<KnowledgeNoteOutboxCommand> enqueueTombstone({
    required String localNoteId,
    required int localRevision,
    required String remoteNoteId,
    required String etag,
    required String idempotencyKey,
  }) {
    return _enqueue(
      kind: KnowledgeNoteOutboxCommandKind.tombstone,
      localNoteId: localNoteId,
      localRevision: localRevision,
      remoteNoteId: remoteNoteId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<KnowledgeNoteOutboxCommand> _enqueue({
    required KnowledgeNoteOutboxCommandKind kind,
    required String localNoteId,
    required int localRevision,
    String? remoteNoteId,
    String? etag,
    String? idempotencyKey,
  }) async {
    final normalizedId = _requiredJournalText(localNoteId, 'localNoteId', 240);
    if (localRevision < 0) {
      throw ArgumentError.value(localRevision, 'localRevision');
    }
    final remoteId = _optionalJournalText(remoteNoteId, 'remoteNoteId', 240);
    final remoteEtag = _optionalJournalText(etag, 'etag', 1024);
    final key = _optionalJournalText(idempotencyKey, 'idempotencyKey', 240);
    if (kind == KnowledgeNoteOutboxCommandKind.tombstone &&
        (remoteId == null || remoteEtag == null || key == null)) {
      throw ArgumentError('Tombstone commands require remote identity');
    }
    final identity = <String>[
      _topic,
      _userScope,
      workspaceId,
      kind.name,
      normalizedId,
      '$localRevision',
      remoteId ?? '',
      remoteEtag ?? '',
      key ?? '',
    ].join('\u0000');
    final digest = sha256.convert(utf8.encode(identity)).toString();
    final operationId = 'knowledge-note-${digest.substring(0, 48)}';
    final timestamp = _now().toUtc();
    await _database.enqueueOutbox(
      DatabaseOutboxEntry(
        operationId: operationId,
        userScope: _userScope,
        topic: _topic,
        dedupeKey: operationId,
        payload: <String, Object?>{
          'version': _payloadVersion,
          'workspaceId': workspaceId,
          'kind': kind.name,
          'localNoteId': normalizedId,
          'localRevision': localRevision,
          if (remoteId != null) 'remoteNoteId': remoteId,
          if (remoteEtag != null) 'etag': remoteEtag,
          if (key != null) 'idempotencyKey': key,
        },
        availableAt: timestamp,
        createdAt: timestamp,
      ),
    );
    return KnowledgeNoteOutboxCommand(
      operationId: operationId,
      kind: kind,
      localNoteId: normalizedId,
      localRevision: localRevision,
      attemptCount: 0,
      remoteNoteId: remoteId,
      etag: remoteEtag,
      idempotencyKey: key,
    );
  }

  @override
  Future<List<KnowledgeNoteOutboxCommand>> claim({
    String? operationId,
    int limit = 20,
  }) async {
    final claimed = await _database.claimOutbox(
      userScope: _userScope,
      now: _now().toUtc(),
      leaseDuration: const Duration(seconds: 30),
      limit: limit,
      topic: _topic,
      operationId: operationId,
    );
    return List<KnowledgeNoteOutboxCommand>.unmodifiable(
      claimed.map(_decodeCommand),
    );
  }

  KnowledgeNoteOutboxCommand _decodeCommand(ClaimedDatabaseOutboxEntry entry) {
    final payload = entry.payload;
    if (entry.topic != _topic ||
        payload['version'] != _payloadVersion ||
        payload['workspaceId'] != workspaceId) {
      throw const FormatException('KNOWLEDGE_NOTE_OUTBOX_PAYLOAD_INVALID');
    }
    final kind = switch (payload['kind']) {
      'upsert' => KnowledgeNoteOutboxCommandKind.upsert,
      'tombstone' => KnowledgeNoteOutboxCommandKind.tombstone,
      _ => throw const FormatException('KNOWLEDGE_NOTE_OUTBOX_PAYLOAD_INVALID'),
    };
    final localNoteId = _requiredJournalText(
      payload['localNoteId'],
      'localNoteId',
      240,
    );
    final localRevision = payload['localRevision'];
    if (localRevision is! int || localRevision < 0) {
      throw const FormatException('KNOWLEDGE_NOTE_OUTBOX_PAYLOAD_INVALID');
    }
    final remoteNoteId = _optionalJournalText(
      payload['remoteNoteId'],
      'remoteNoteId',
      240,
    );
    final etag = _optionalJournalText(payload['etag'], 'etag', 1024);
    final idempotencyKey = _optionalJournalText(
      payload['idempotencyKey'],
      'idempotencyKey',
      240,
    );
    if (kind == KnowledgeNoteOutboxCommandKind.tombstone &&
        (remoteNoteId == null || etag == null || idempotencyKey == null)) {
      throw const FormatException('KNOWLEDGE_NOTE_OUTBOX_PAYLOAD_INVALID');
    }
    return KnowledgeNoteOutboxCommand(
      operationId: entry.operationId,
      kind: kind,
      localNoteId: localNoteId,
      localRevision: localRevision,
      attemptCount: entry.attemptCount,
      remoteNoteId: remoteNoteId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    );
  }

  @override
  Future<void> markSucceeded(KnowledgeNoteOutboxCommand command) async {
    final updated = await _database.markOutboxSucceeded(
      operationId: command.operationId,
      updatedAt: _now().toUtc(),
    );
    if (!updated) throw StateError('KNOWLEDGE_NOTE_OUTBOX_ACK_REJECTED');
  }

  @override
  Future<void> markRetry(
    KnowledgeNoteOutboxCommand command, {
    required String errorCode,
  }) async {
    final now = _now().toUtc();
    final exponent = command.attemptCount.clamp(1, 6).toInt() - 1;
    final baseSeconds = 5 * (1 << exponent);
    final jitterSeconds = command.operationId.codeUnits.fold<int>(
      0,
      (sum, value) => (sum + value) % 7,
    );
    final updated = await _database.markOutboxRetry(
      operationId: command.operationId,
      availableAt: now.add(Duration(seconds: baseSeconds + jitterSeconds)),
      updatedAt: now,
      errorCode: _safeJournalErrorCode(errorCode),
    );
    if (!updated) throw StateError('KNOWLEDGE_NOTE_OUTBOX_RETRY_REJECTED');
  }

  @override
  Future<KnowledgeNoteInboxDisposition> beginEvent({
    required String eventId,
    required DateTime occurredAt,
  }) async {
    final disposition = await _database.beginInbox(
      userScope: _userScope,
      eventId: eventId,
      topic: _topic,
      receivedAt: occurredAt.toUtc(),
    );
    return switch (disposition) {
      DatabaseInboxDisposition.accepted =>
        KnowledgeNoteInboxDisposition.accepted,
      DatabaseInboxDisposition.resume => KnowledgeNoteInboxDisposition.resume,
      DatabaseInboxDisposition.alreadyProcessed =>
        KnowledgeNoteInboxDisposition.alreadyProcessed,
    };
  }

  @override
  Future<void> markEventProcessed(String eventId) async {
    final updated = await _database.markInboxProcessed(
      userScope: _userScope,
      eventId: eventId,
      processedAt: _now().toUtc(),
    );
    if (!updated) throw StateError('KNOWLEDGE_NOTE_INBOX_ACK_REJECTED');
  }
}

String _requiredJournalText(Object? value, String name, int maximum) {
  if (value is! String) throw ArgumentError.value(value, name);
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maximum ||
      normalized.contains('\u0000')) {
    throw ArgumentError.value(value, name);
  }
  return normalized;
}

String? _optionalJournalText(Object? value, String name, int maximum) {
  if (value == null) return null;
  return _requiredJournalText(value, name, maximum);
}

String _safeJournalErrorCode(String value) {
  final normalized = value.trim().toUpperCase();
  if (RegExp(r'^[A-Z0-9][A-Z0-9_]{0,127}$').hasMatch(normalized)) {
    return normalized;
  }
  return 'KNOWLEDGE_NOTE_SYNC_RETRY';
}

/// A safe, app-local projection of one remote Workspace Folder.
///
/// This is intentionally separate from the user's local knowledge categories.
final class WorkspaceContentRemoteFolder {
  const WorkspaceContentRemoteFolder({
    required this.folderId,
    required this.parentFolderId,
    required this.displayName,
    required this.normalizedName,
    required this.state,
    required this.currentRevisionId,
    required this.etag,
    required this.contentCursor,
    this.systemSeedKey,
  });

  final String folderId;
  final String? parentFolderId;
  final String displayName;
  final String normalizedName;
  final String state;
  final String currentRevisionId;
  final String etag;
  final String contentCursor;
  final String? systemSeedKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'folderId': folderId,
    'parentFolderId': parentFolderId,
    'displayName': displayName,
    'normalizedName': normalizedName,
    'state': state,
    'currentRevisionId': currentRevisionId,
    'etag': etag,
    'contentCursor': contentCursor,
    if (systemSeedKey != null) 'systemSeedKey': systemSeedKey,
  };

  static WorkspaceContentRemoteFolder? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = Map<Object?, Object?>.from(value);
    final folderId = _boundedText(json['folderId'], 256);
    final displayName = _boundedText(json['displayName'], 512);
    final normalizedName = _boundedText(json['normalizedName'], 512);
    final state = _boundedText(json['state'], 80);
    final revision = _boundedText(json['currentRevisionId'], 512);
    final etag = _boundedText(json['etag'], 1024);
    final cursor = _boundedText(json['contentCursor'], 512);
    final parent = _nullableBoundedText(json['parentFolderId'], 256);
    final systemSeedKey = _nullableBoundedText(json['systemSeedKey'], 256);
    if (folderId == null ||
        displayName == null ||
        normalizedName == null ||
        state == null ||
        revision == null ||
        etag == null ||
        cursor == null) {
      return null;
    }
    return WorkspaceContentRemoteFolder(
      folderId: folderId,
      parentFolderId: parent,
      displayName: displayName,
      normalizedName: normalizedName,
      state: state,
      currentRevisionId: revision,
      etag: etag,
      contentCursor: cursor,
      systemSeedKey: systemSeedKey,
    );
  }
}

/// Durable checkpoint for one authenticated account and one Workspace.
final class WorkspaceContentSyncState {
  const WorkspaceContentSyncState({
    this.contentCursor,
    this.snapshotEtag,
    this.folders = const <String, WorkspaceContentRemoteFolder>{},
  });

  final String? contentCursor;
  final String? snapshotEtag;
  final Map<String, WorkspaceContentRemoteFolder> folders;

  WorkspaceContentSyncState copyWith({
    String? contentCursor,
    String? snapshotEtag,
    Map<String, WorkspaceContentRemoteFolder>? folders,
    bool clearContentCursor = false,
    bool clearSnapshotEtag = false,
  }) {
    return WorkspaceContentSyncState(
      contentCursor: clearContentCursor
          ? null
          : contentCursor ?? this.contentCursor,
      snapshotEtag: clearSnapshotEtag
          ? null
          : snapshotEtag ?? this.snapshotEtag,
      folders: Map<String, WorkspaceContentRemoteFolder>.unmodifiable(
        folders ?? this.folders,
      ),
    );
  }
}

/// Stores a Workspace content checkpoint in [AppPreferencesDao].
///
/// The preference key is opaque and scoped by both authenticated user and
/// Workspace, so a cursor issued in one Workspace cannot be read in another.
final class WorkspaceContentSyncStore {
  WorkspaceContentSyncStore({
    required AppPreferencesDao preferences,
    required String userScope,
    required String workspaceId,
    DateTime Function()? now,
  }) : _preferences = preferences,
       _userScope = _requiredScope(userScope, 'userScope'),
       _workspaceId = _requiredScope(workspaceId, 'workspaceId'),
       _now = now ?? DateTime.now;

  static const _schema = 1;
  static final _contentCursorPattern = RegExp(r'^(?:0|[1-9][0-9]*)$');

  final AppPreferencesDao _preferences;
  final String _userScope;
  final String _workspaceId;
  final DateTime Function() _now;

  String get workspaceId => _workspaceId;

  WorkspaceContentSyncState load() {
    final raw = _preferences.readValue(_preferenceKey);
    if (raw == null) return const WorkspaceContentSyncState();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const WorkspaceContentSyncState();
      final json = Map<Object?, Object?>.from(decoded);
      if (json['schema'] != _schema) {
        return const WorkspaceContentSyncState();
      }
      final rawCursor = json['contentCursor'];
      final cursor = _nullableContentCursor(rawCursor);
      if (rawCursor != null && cursor == null) {
        return const WorkspaceContentSyncState();
      }
      final etag = _nullableBoundedText(json['snapshotEtag'], 1024);
      final foldersValue = json['folders'];
      if (foldersValue is! List) return const WorkspaceContentSyncState();
      final folders = <String, WorkspaceContentRemoteFolder>{};
      for (final value in foldersValue) {
        final folder = WorkspaceContentRemoteFolder.tryParse(value);
        if (folder != null) folders[folder.folderId] = folder;
      }
      return WorkspaceContentSyncState(
        contentCursor: cursor,
        snapshotEtag: etag,
        folders: Map<String, WorkspaceContentRemoteFolder>.unmodifiable(
          folders,
        ),
      );
    } on Object {
      return const WorkspaceContentSyncState();
    }
  }

  void save(WorkspaceContentSyncState state) {
    final cursor = _nullableContentCursor(state.contentCursor);
    if (state.contentCursor != null && cursor == null) {
      throw ArgumentError.value(
        state.contentCursor,
        'state.contentCursor',
        'must be a canonical content cursor',
      );
    }
    final etag = _nullableBoundedText(state.snapshotEtag, 1024);
    final folders = <String, WorkspaceContentRemoteFolder>{};
    for (final entry in state.folders.entries) {
      final key = _boundedText(entry.key, 256);
      final value = entry.value;
      if (key == null || key != value.folderId) {
        throw ArgumentError.value(state, 'state', 'contains an invalid folder');
      }
      folders[key] = value;
    }
    _preferences.upsertValue(
      preferenceKey: _preferenceKey,
      value: jsonEncode(<String, Object?>{
        'schema': _schema,
        if (cursor != null) 'contentCursor': cursor,
        if (etag != null) 'snapshotEtag': etag,
        'folders': folders.values
            .map((folder) => folder.toJson())
            .toList(growable: false),
      }),
      updatedAt: _now().toUtc().toIso8601String(),
    );
  }

  /// Deletes both cursor and ETag so the next snapshot cannot receive a 304
  /// for a projection whose cursor is no longer valid.
  void clear() => _preferences.deleteValue(_preferenceKey);

  String get _preferenceKey {
    final source =
        'workspace-content-sync-v$_schema\u0000$_userScope\u0000$_workspaceId';
    final digest = sha256.convert(utf8.encode(source)).toString();
    return 'workspace-content-sync-${digest.substring(0, 32)}';
  }
}

String? _nullableContentCursor(Object? value) {
  final cursor = _nullableBoundedText(value, 512);
  if (cursor == null ||
      !WorkspaceContentSyncStore._contentCursorPattern.hasMatch(cursor)) {
    return null;
  }
  return cursor;
}

String _requiredScope(String value, String name) {
  final normalized = _boundedText(value, 512);
  if (normalized == null || normalized == 'anonymous') {
    throw ArgumentError.value(
      value,
      name,
      'must identify an authenticated scope',
    );
  }
  return normalized;
}

String? _nullableBoundedText(Object? value, int maximum) {
  if (value == null) return null;
  return _boundedText(value, maximum);
}

String? _boundedText(Object? value, int maximum) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maximum) return null;
  return normalized;
}
