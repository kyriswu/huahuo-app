import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/feed_item_models.dart';
import '../domain/knowledge_trash_models.dart';
import '../domain/v3_deposit_models.dart';

abstract interface class KnowledgeLibraryCache {
  Future<List<V3FeedItem>?> load();

  Future<void> save(List<V3FeedItem> notes);
}

abstract interface class KnowledgeLibraryWorkspaceProjectionCache {
  String? get workspaceContentCursor;

  Future<void> saveWorkspaceProjection(
    List<V3FeedItem> notes, {
    required String contentCursor,
  });
}

abstract interface class KnowledgeLibraryCacheFreshnessPort {
  Future<DateTime?> lastSavedAt();
}

typedef KnowledgeLibraryDirectoryResolver = Future<Directory> Function();

abstract interface class KnowledgeTrashRepository {
  Future<List<KnowledgeTrashEntry>> load();

  Future<void> save(List<KnowledgeTrashEntry> entries);
}

final class ApplicationSupportKnowledgeLibraryCache
    implements
        KnowledgeLibraryCache,
        KnowledgeLibraryCacheFreshnessPort,
        KnowledgeLibraryWorkspaceProjectionCache {
  ApplicationSupportKnowledgeLibraryCache({
    KnowledgeLibraryDirectoryResolver? directoryResolver,
    String scopeId = 'local',
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory,
       _scopeId = scopeId.trim().isEmpty ? 'local' : scopeId.trim();

  static const _version = 3;
  static const _legacyVersion = 2;
  static const _oldestVersion = 1;
  static const _directoryName = 'knowledge_library';

  final KnowledgeLibraryDirectoryResolver _directoryResolver;
  final String _scopeId;
  String? _workspaceContentCursor;

  @override
  String? get workspaceContentCursor => _workspaceContentCursor;

  @override
  Future<List<V3FeedItem>?> load() async {
    final target = await _targetFile(_version);
    final partial = File('${target.path}.part');
    final legacy = await _targetFile(_legacyVersion);
    final legacyPartial = File('${legacy.path}.part');
    final oldest = await _targetFile(_oldestVersion);
    final oldestPartial = File('${oldest.path}.part');
    File? source;
    if (await target.exists()) {
      source = target;
    } else if (await partial.exists()) {
      source = partial;
    } else if (await legacy.exists()) {
      source = legacy;
    } else if (await legacyPartial.exists()) {
      source = legacyPartial;
    } else if (await oldest.exists()) {
      source = oldest;
    } else if (await oldestPartial.exists()) {
      source = oldestPartial;
    }
    if (source == null) return null;

    final decoded = jsonDecode(await source.readAsString());
    if (decoded is! Map) {
      throw const FormatException('KNOWLEDGE_LIBRARY_CACHE_INVALID_ROOT');
    }
    final root = Map<String, Object?>.from(decoded);
    final version = (root['version'] as num?)?.toInt();
    if ((version != _version &&
            version != _legacyVersion &&
            version != _oldestVersion) ||
        root['notes'] is! List) {
      throw const FormatException('KNOWLEDGE_LIBRARY_CACHE_INVALID_VERSION');
    }
    final notes = <V3FeedItem>[];
    for (final value in root['notes']! as List) {
      if (value is! Map) {
        throw const FormatException('KNOWLEDGE_LIBRARY_CACHE_INVALID_NOTE');
      }
      notes.add(_noteFromJson(Map<String, Object?>.from(value)));
    }
    _workspaceContentCursor = _validContentCursor(
      root['workspaceContentCursor'],
    );
    if (source.path.endsWith('.part')) {
      await source.rename(source.path.substring(0, source.path.length - 5));
    }
    return List<V3FeedItem>.unmodifiable(notes);
  }

  @override
  Future<DateTime?> lastSavedAt() async {
    final target = await _targetFile(_version);
    final partial = File('${target.path}.part');
    final source = await target.exists()
        ? target
        : await partial.exists()
        ? partial
        : null;
    if (source == null) return null;
    try {
      final decoded = jsonDecode(await source.readAsString());
      final root = decoded is Map
          ? Map<String, Object?>.from(decoded)
          : const <String, Object?>{};
      final raw = root['savedAt'];
      if (raw is! String || raw.length > 64) return null;
      return DateTime.tryParse(raw)?.toUtc();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(List<V3FeedItem> notes) {
    return _save(notes, workspaceContentCursor: _workspaceContentCursor);
  }

  @override
  Future<void> saveWorkspaceProjection(
    List<V3FeedItem> notes, {
    required String contentCursor,
  }) async {
    final cursor = _validContentCursor(contentCursor);
    if (cursor == null) {
      throw ArgumentError.value(
        contentCursor,
        'contentCursor',
        'must be a canonical content cursor',
      );
    }
    await _save(notes, workspaceContentCursor: cursor);
    _workspaceContentCursor = cursor;
  }

  Future<void> _save(
    List<V3FeedItem> notes, {
    required String? workspaceContentCursor,
  }) async {
    final target = await _targetFile(_version);
    await compute(_writeKnowledgeLibrarySnapshot, (
      notes: List<V3FeedItem>.unmodifiable(notes),
      targetPath: target.path,
      workspaceContentCursor: workspaceContentCursor,
    ), debugLabel: 'knowledge_cache_snapshot');
  }

  Future<File> _targetFile(int version) async {
    final support = await _directoryResolver();
    return File(
      '${support.path}/$_directoryName/${_fileNameForScope(_scopeId, version)}',
    );
  }
}

Future<void> _writeKnowledgeLibrarySnapshot(
  ({List<V3FeedItem> notes, String targetPath, String? workspaceContentCursor})
  snapshot,
) async {
  final target = File(snapshot.targetPath);
  await target.parent.create(recursive: true);
  final partial = File('${target.path}.part');
  if (await partial.exists()) await partial.delete();
  final payload = <String, Object?>{
    'version': ApplicationSupportKnowledgeLibraryCache._version,
    'savedAt': DateTime.now().toUtc().toIso8601String(),
    if (snapshot.workspaceContentCursor != null)
      'workspaceContentCursor': snapshot.workspaceContentCursor,
    'notes': snapshot.notes.map(_noteToJson).toList(growable: false),
  };
  await partial.writeAsString(jsonEncode(payload), flush: true);
  await partial.rename(target.path);
}

String? _validContentCursor(Object? value) {
  if (value is! String || value.isEmpty || value.length > 512) return null;
  if (!RegExp(r'^(?:0|[1-9][0-9]*)$').hasMatch(value)) return null;
  return value;
}

final class ApplicationSupportKnowledgeTrashRepository
    implements KnowledgeTrashRepository {
  ApplicationSupportKnowledgeTrashRepository({
    String scopeId = 'local',
    KnowledgeLibraryDirectoryResolver? directoryResolver,
  }) : _scopeId = scopeId.trim().isEmpty ? 'local' : scopeId.trim(),
       _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  static const _version = 1;
  static const _directoryName = 'knowledge_library';

  final String _scopeId;
  final KnowledgeLibraryDirectoryResolver _directoryResolver;

  @override
  Future<List<KnowledgeTrashEntry>> load() async {
    final target = await _targetFile();
    final partial = File('${target.path}.part');
    final source = await target.exists()
        ? target
        : await partial.exists()
        ? partial
        : null;
    if (source == null) return const <KnowledgeTrashEntry>[];
    try {
      final decoded = jsonDecode(await source.readAsString());
      if (decoded is! Map ||
          decoded['version'] != _version ||
          decoded['entries'] is! List) {
        return const <KnowledgeTrashEntry>[];
      }
      final entries = <KnowledgeTrashEntry>[];
      for (final raw in decoded['entries']! as List) {
        if (raw is! Map) continue;
        final entry = _trashEntryFromJson(Map<String, Object?>.from(raw));
        if (entry != null) entries.add(entry);
      }
      entries.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      if (source.path.endsWith('.part') && !await target.exists()) {
        await source.rename(target.path);
      }
      return List<KnowledgeTrashEntry>.unmodifiable(entries);
    } on Object {
      return const <KnowledgeTrashEntry>[];
    }
  }

  @override
  Future<void> save(List<KnowledgeTrashEntry> entries) async {
    final target = await _targetFile();
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();
    await partial.writeAsString(
      jsonEncode(<String, Object?>{
        'version': _version,
        'entries': entries.map(_trashEntryToJson).toList(growable: false),
      }),
      flush: true,
    );
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
  }

  Future<File> _targetFile() async {
    final support = await _directoryResolver();
    final suffix = _scopeId == 'local'
        ? 'local'
        : sha256.convert(utf8.encode(_scopeId)).toString().substring(0, 32);
    return File(
      '${support.path}/$_directoryName/trash.$suffix.v$_version.json',
    );
  }
}

String _fileNameForScope(String scopeId, int version) {
  if (scopeId == 'local') return 'notes.v$version.json';
  final digest = sha256.convert(utf8.encode(scopeId)).toString();
  return 'notes.${digest.substring(0, 32)}.v$version.json';
}

Map<String, Object?> _trashEntryToJson(KnowledgeTrashEntry entry) =>
    <String, Object?>{
      'note': _noteToJson(entry.note),
      'deletedAt': entry.deletedAt.toUtc().toIso8601String(),
      'memberships': [
        for (final membership in entry.memberships)
          <String, Object?>{
            'contentId': membership.contentId,
            'collection': membership.collection.name,
            'createdAt': membership.createdAt.toUtc().toIso8601String(),
          },
      ],
      'depositRecord': switch (entry.depositRecord) {
        final record? => <String, Object?>{
          'contentId': record.contentId,
          'folderId': record.folderId,
          'depositedAt': record.depositedAt.toUtc().toIso8601String(),
          'updatedAt': record.updatedAt.toUtc().toIso8601String(),
        },
        null => null,
      },
      'backlinks': [
        for (final backlink in entry.backlinks)
          <String, Object?>{
            'ownerNoteId': backlink.ownerNoteId,
            'index': backlink.index,
            'material': <String, Object?>{
              'id': backlink.material.id,
              'source': backlink.material.source.name,
              'title': backlink.material.title,
              'summary': backlink.material.summary,
            },
          },
      ],
    };

KnowledgeTrashEntry? _trashEntryFromJson(Map<String, Object?> json) {
  try {
    final rawNote = json['note'];
    if (rawNote is! Map) return null;
    final note = _noteFromJson(Map<String, Object?>.from(rawNote));
    final deletedAt = _requiredDate(json, 'deletedAt');
    final memberships = _mapList(json['memberships'], (value) {
      return V3LibraryMembership(
        contentId: _requiredString(value, 'contentId'),
        collection: _enumValue(
          V3LibraryCollection.values,
          value['collection'],
          V3LibraryCollection.deposits,
        ),
        createdAt: _requiredDate(value, 'createdAt'),
      );
    });
    final rawDeposit = json['depositRecord'];
    final depositRecord = rawDeposit is Map
        ? _depositRecordFromTrashJson(Map<String, Object?>.from(rawDeposit))
        : null;
    final backlinks = _mapList(json['backlinks'], (value) {
      final material = value['material'];
      if (material is! Map) throw const FormatException('INVALID_BACKLINK');
      final mapped = Map<String, Object?>.from(material);
      return KnowledgeTrashBacklink(
        ownerNoteId: _requiredString(value, 'ownerNoteId'),
        index: (value['index'] as num?)?.toInt() ?? 0,
        material: V3LinkedMaterialRef(
          id: _requiredString(mapped, 'id'),
          source: _enumValue(
            V3MaterialSource.values,
            mapped['source'],
            V3MaterialSource.note,
          ),
          title: _requiredString(mapped, 'title'),
          summary: _optionalString(mapped['summary']),
        ),
      );
    });
    if (note.isReadOnly ||
        memberships.any((value) => value.contentId != note.id) ||
        depositRecord?.contentId != null &&
            depositRecord!.contentId != note.id) {
      return null;
    }
    return KnowledgeTrashEntry(
      note: note,
      deletedAt: deletedAt,
      memberships: List<V3LibraryMembership>.unmodifiable(memberships),
      depositRecord: depositRecord,
      backlinks: List<KnowledgeTrashBacklink>.unmodifiable(backlinks),
    );
  } on Object {
    return null;
  }
}

V3DepositRecord _depositRecordFromTrashJson(Map<String, Object?> value) =>
    V3DepositRecord(
      contentId: _requiredString(value, 'contentId'),
      folderId: _optionalString(value['folderId']),
      depositedAt: _requiredDate(value, 'depositedAt'),
      updatedAt: _requiredDate(value, 'updatedAt'),
    );

Map<String, Object?> _noteToJson(V3FeedItem note) => <String, Object?>{
  'id': note.id,
  'title': note.title,
  'source': note.source.name,
  'createdAt': note.createdAt.toUtc().toIso8601String(),
  'updatedAt': note.updatedAt.toUtc().toIso8601String(),
  'rawBody': note.rawBody,
  'summaryBody': note.summaryBody,
  'recordingId': note.recordingId,
  'minutesStatus': note.minutesStatus,
  'summaryStatus': note.summaryStatus,
  'linkedMaterials': note.linkedMaterials
      .map(
        (material) => <String, Object?>{
          'id': material.id,
          'source': material.source.name,
          'title': material.title,
          'summary': material.summary,
        },
      )
      .toList(growable: false),
  'sproutStatus': _isTransientSproutStatus(note.sproutStatus)
      ? V3SproutTaskStatus.notStarted.name
      : note.sproutStatus.name,
  'sproutTopic': note.sproutTopic,
  'mediaAttachments': note.mediaAttachments
      .map(
        (attachment) => <String, Object?>{
          'privateUri': attachment.privateUri,
          'displayName': attachment.displayName,
          'mimeType': attachment.mimeType,
          'sizeBytes': attachment.sizeBytes,
          'kind': attachment.kind.name,
          'privatePath': attachment.privatePath,
        },
      )
      .toList(growable: false),
  'remoteMediaAttachments': note.remoteMediaAttachments
      .map(
        (attachment) => <String, Object?>{
          'resourceId': attachment.resourceId,
          'displayName': attachment.displayName,
          'mimeType': attachment.mimeType,
          'usage': attachment.usage,
          'anchor': attachment.anchor,
        },
      )
      .toList(growable: false),
  'ownership': note.ownership.name,
  'contentLineId': note.contentLineId,
  'contentLineName': note.contentLineName,
  'folderId': note.folderId,
  'folderName': note.folderName,
  'copiedFromContentId': note.copiedFromContentId,
  'publicUrl': normalizeV3PublicSourceUrl(note.publicUrl),
  'topics': note.topics,
  'localRevision': note.localRevision,
  'remoteRevision': note.remoteRevision,
  'remoteNoteId': note.remoteNoteId,
  'noteRevisionId': note.noteRevisionId,
  'rawPartRevisionId': note.rawPartRevisionId,
  'remoteSourceKind': note.remoteSourceKind,
  'outlinePartRevisionId': note.outlinePartRevisionId,
  'germinationPartRevisionId': note.germinationPartRevisionId,
  'etag': note.etag,
  'contentCursor': note.contentCursor,
  'publicationId': note.publicationId,
  'articleId': note.articleId,
  'articleRevisionId': note.articleRevisionId,
  'subscriptionArticleAssets': note.subscriptionArticleAssets
      .map(
        (asset) => <String, Object?>{
          'fileKey': asset.fileKey,
          'logicalPath': asset.logicalPath,
        },
      )
      .toList(growable: false),
  'author': note.author,
  'syncState': note.syncState.name,
  'pendingRawOnlyUpdate': note.pendingRawOnlyUpdate,
  'contentOrigin': note.contentOrigin.name,
  'activeDerivedTasksAuthoritative': note.activeDerivedTasksAuthoritative,
  if (note.activeDerivedTasksAuthoritative)
    'activeDerivedTasks': note.activeDerivedTasks
        .where((task) => !task.isTerminal)
        .map(
          (task) => <String, Object?>{
            'fileAgentRunId': task.fileAgentRunId,
            if (task.agentRunId != null) 'agentRunId': task.agentRunId,
            'stage': task.stage.wireValue,
            'status': task.status,
          },
        )
        .toList(growable: false),
  'sproutReport': switch (note.sproutReport) {
    V3SproutReport report => <String, Object?>{
      'id': report.id,
      'noteId': report.noteId,
      'title': report.title,
      'markdown': report.markdown,
      'generatedAt': report.generatedAt.toUtc().toIso8601String(),
    },
    null => null,
  },
};

V3FeedItem _noteFromJson(Map<String, Object?> json) {
  final reportJson = json['sproutReport'];
  final restoredSproutStatus = _enumValue(
    V3SproutTaskStatus.values,
    json['sproutStatus'],
    V3SproutTaskStatus.notStarted,
  );
  final activeDerivedTasksAuthoritative =
      json['activeDerivedTasksAuthoritative'] == true;
  final activeDerivedTasks = activeDerivedTasksAuthoritative
      ? _activeDerivedTasksFromJson(json['activeDerivedTasks'])
      : const <V3ActiveDerivedTask>[];
  return V3FeedItem(
    id: _requiredString(json, 'id'),
    title: _requiredString(json, 'title'),
    source: _enumValue(
      V3MaterialSource.values,
      json['source'],
      V3MaterialSource.note,
    ),
    createdAt: _requiredDate(json, 'createdAt'),
    updatedAt: _requiredDate(json, 'updatedAt'),
    rawBody: _requiredString(json, 'rawBody'),
    summaryBody: _optionalString(json['summaryBody']),
    summaryError: null,
    recordingId: _optionalString(json['recordingId']),
    minutesStatus: _optionalString(json['minutesStatus']),
    summaryStatus: _optionalString(json['summaryStatus']),
    linkedMaterials: _mapList(json['linkedMaterials'], (value) {
      return V3LinkedMaterialRef(
        id: _requiredString(value, 'id'),
        source: _enumValue(
          V3MaterialSource.values,
          value['source'],
          V3MaterialSource.note,
        ),
        title: _requiredString(value, 'title'),
        summary: _optionalString(value['summary']),
      );
    }),
    sproutStatus: _isTransientSproutStatus(restoredSproutStatus)
        ? V3SproutTaskStatus.notStarted
        : restoredSproutStatus,
    sproutError: null,
    sproutTopic: _optionalString(json['sproutTopic']),
    mediaAttachments: _mapList(json['mediaAttachments'], (value) {
      return V3MediaAttachment(
        privateUri: _requiredString(value, 'privateUri'),
        displayName: _requiredString(value, 'displayName'),
        mimeType: _requiredString(value, 'mimeType'),
        sizeBytes: (value['sizeBytes'] as num?)?.toInt() ?? 0,
        kind: _enumValue(
          V3MediaAttachmentKind.values,
          value['kind'],
          V3MediaAttachmentKind.image,
        ),
        privatePath: _optionalString(value['privatePath']) ?? '',
      );
    }),
    remoteMediaAttachments: _mapList(json['remoteMediaAttachments'], (value) {
      final resourceId = _requiredString(value, 'resourceId');
      final mimeType = _requiredString(value, 'mimeType').toLowerCase();
      final usage = _requiredString(value, 'usage');
      if (!mimeType.startsWith('image/') || usage != 'inline_image') {
        throw const FormatException('invalid remote media attachment');
      }
      return V3RemoteMediaAttachment(
        resourceId: resourceId,
        displayName: _requiredString(value, 'displayName'),
        mimeType: mimeType,
        usage: usage,
        anchor: _optionalString(value['anchor']),
      );
    }),
    ownership: _enumValue(
      V3NoteOwnership.values,
      json['ownership'],
      V3NoteOwnership.mine,
    ),
    contentLineId: _optionalString(json['contentLineId']),
    contentLineName: _optionalString(json['contentLineName']),
    folderId: _optionalString(json['folderId']),
    folderName: _optionalString(json['folderName']),
    copiedFromContentId: _optionalString(json['copiedFromContentId']),
    publicUrl: normalizeV3PublicSourceUrl(_optionalString(json['publicUrl'])),
    topics:
        (json['topics'] as List?)
            ?.whereType<String>()
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false) ??
        const <String>[],
    localRevision: (json['localRevision'] as num?)?.toInt() ?? 0,
    remoteRevision: (json['remoteRevision'] as num?)?.toInt(),
    remoteNoteId: _optionalString(json['remoteNoteId']),
    noteRevisionId: _optionalString(json['noteRevisionId']),
    rawPartRevisionId: _optionalString(json['rawPartRevisionId']),
    remoteSourceKind: _optionalString(json['remoteSourceKind']),
    outlinePartRevisionId: _optionalString(json['outlinePartRevisionId']),
    germinationPartRevisionId: _optionalString(
      json['germinationPartRevisionId'],
    ),
    etag: _optionalString(json['etag']),
    contentCursor: _optionalString(json['contentCursor']),
    publicationId: _optionalString(json['publicationId']),
    articleId: _optionalString(json['articleId']),
    articleRevisionId: _optionalString(json['articleRevisionId']),
    subscriptionArticleAssets: _mapList(
      json['subscriptionArticleAssets'],
      (value) => V3SubscriptionArticleAssetRef(
        fileKey: _requiredString(value, 'fileKey'),
        logicalPath: _requiredString(value, 'logicalPath'),
      ),
    ),
    author: _optionalString(json['author']),
    pendingRawOnlyUpdate: json['pendingRawOnlyUpdate'] == true,
    syncState: _enumValue(
      NoteSyncState.values,
      json['syncState'],
      NoteSyncState.pending,
    ),
    contentOrigin: _enumValue(
      V3ContentOrigin.values,
      json['contentOrigin'],
      V3ContentOrigin.standard,
    ),
    activeDerivedTasks: activeDerivedTasks,
    activeDerivedTasksAuthoritative: activeDerivedTasksAuthoritative,
    sproutReport: reportJson is Map
        ? _sproutReportFromJson(Map<String, Object?>.from(reportJson))
        : null,
  );
}

List<V3ActiveDerivedTask> _activeDerivedTasksFromJson(Object? value) {
  if (value is! List) throw const FormatException('INVALID_DERIVED_TASKS');
  final tasks = <V3ActiveDerivedTask>[];
  final seen = <String>{};
  for (final entry in value) {
    if (entry is! Map) throw const FormatException('INVALID_DERIVED_TASK');
    final json = Map<String, Object?>.from(entry);
    final fileAgentRunId = _requiredString(json, 'fileAgentRunId');
    final agentRunId = _optionalString(json['agentRunId']);
    final stage = V3DerivedTaskStageX.tryParse(json['stage']);
    final status = _optionalString(json['status']);
    if (!_isSafeTaskIdentifier(fileAgentRunId) ||
        (agentRunId != null && !_isSafeTaskIdentifier(agentRunId)) ||
        stage == null ||
        status == null ||
        !_publicDerivedTaskStatuses.contains(status) ||
        !seen.add(fileAgentRunId)) {
      throw const FormatException('INVALID_DERIVED_TASK');
    }
    if (!const <String>{
      'succeeded',
      'failed',
      'timeout',
      'cancelled',
      'conflict',
    }.contains(status)) {
      tasks.add(
        V3ActiveDerivedTask(
          fileAgentRunId: fileAgentRunId,
          agentRunId: agentRunId,
          stage: stage,
          status: status,
        ),
      );
    }
  }
  return List<V3ActiveDerivedTask>.unmodifiable(tasks);
}

bool _isSafeTaskIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(value);

const _publicDerivedTaskStatuses = <String>{
  'admitting',
  'retry_wait',
  'retry_admitting',
  'queued',
  'resolving',
  'planning',
  'running',
  'finalizing',
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'conflict',
};

V3SproutReport _sproutReportFromJson(Map<String, Object?> json) {
  return V3SproutReport(
    id: _requiredString(json, 'id'),
    noteId: _requiredString(json, 'noteId'),
    title: _requiredString(json, 'title'),
    markdown: _requiredString(json, 'markdown'),
    generatedAt: _requiredDate(json, 'generatedAt'),
  );
}

List<T> _mapList<T>(
  Object? value,
  T Function(Map<String, Object?> value) convert,
) {
  if (value == null) return <T>[];
  if (value is! List) throw const FormatException('INVALID_LIST');
  return value
      .map((entry) {
        if (entry is! Map) throw const FormatException('INVALID_LIST_ENTRY');
        return convert(Map<String, Object?>.from(entry));
      })
      .toList(growable: false);
}

T _enumValue<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is! String) return fallback;
  return values.where((value) => value.name == raw).firstOrNull ?? fallback;
}

bool _isTransientSproutStatus(V3SproutTaskStatus status) =>
    status == V3SproutTaskStatus.failed || status == V3SproutTaskStatus.running;

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('INVALID_$key');
  return value;
}

String? _optionalString(Object? value) => value is String ? value : null;

DateTime _requiredDate(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('INVALID_$key');
  return parsed.toLocal();
}
