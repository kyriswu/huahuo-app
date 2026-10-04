// ignore_for_file: prefer_initializing_formals

import 'package:huahuo_api/huahuo_api.dart';
import '../../ui_v3/data/note_file_agent_client.dart';
import '../domain/material_ingestion.dart';

enum MaterialRemoteTaskStatus { queued, analyzing, completed, failed }

final class MaterialTaskSnapshot {
  const MaterialTaskSnapshot({
    required this.taskId,
    required this.status,
    this.progress,
    this.note,
    this.promotedNoteId,
    this.errorCode,
  });

  final String taskId;
  final MaterialRemoteTaskStatus status;
  final int? progress;
  final GeneratedMemoryNote? note;
  final String? promotedNoteId;
  final String? errorCode;
}

final class MaterialLinkOutlineOwnership {
  const MaterialLinkOutlineOwnership({
    required this.ingestionId,
    required this.owner,
  });

  final String ingestionId;
  final MaterialLinkOutlineOwner owner;
}

abstract interface class MaterialIngestionApiPort {
  Future<ApiResult<MaterialTaskSnapshot>> createLinkImport({
    required Uri url,
    required String idempotencyKey,
  });

  Future<ApiResult<MaterialTaskSnapshot>> getLinkImport(String taskId);

  Future<ApiResult<MaterialLinkOutlineOwnership>> getLinkOutlineOwnership(
    String taskId,
  );

  Future<ApiResult<MaterialTaskSnapshot>> createVideoAnalysis({
    required String resourceId,
    required String title,
    required String idempotencyKey,
  });

  Future<ApiResult<MaterialTaskSnapshot>> getVideoAnalysis(String taskId);

  Future<ApiResult<PageResult<GeneratedMemoryNote>>> listMemoryNotes({
    String? cursor,
  });

  Future<ApiResult<GeneratedMemoryNote>> getMemoryNote(String noteId);
}

final class MaterialIngestionApi implements MaterialIngestionApiPort {
  const MaterialIngestionApi({
    required ApiClient apiClient,
    String? Function()? workspaceId,
  }) : _apiClient = apiClient,
       _workspaceId = workspaceId;

  final ApiClient _apiClient;
  final String? Function()? _workspaceId;

  @override
  Future<ApiResult<MaterialTaskSnapshot>> createLinkImport({
    required Uri url,
    required String idempotencyKey,
  }) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) {
      return _unavailable<MaterialTaskSnapshot>(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    if (!_isPublicLink(url)) {
      return _unavailable<MaterialTaskSnapshot>('LINK_IMPORT_URL_INVALID');
    }
    return _apiClient.request<MaterialTaskSnapshot>(
      ApiRequestOptions<MaterialTaskSnapshot>(
        endpointId: 'createWorkspaceNoteIngestion',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        body: <String, Object?>{'url': url.toString()},
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: parseLinkIngestionSnapshot,
      ),
    );
  }

  @override
  Future<ApiResult<MaterialTaskSnapshot>> getLinkImport(String taskId) async {
    final workspaceId = _activeWorkspaceId();
    final ingestionId = _safeId(taskId);
    if (workspaceId == null) {
      return _unavailable<MaterialTaskSnapshot>(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    if (ingestionId == null) {
      return _unavailable<MaterialTaskSnapshot>(
        'LINK_IMPORT_INGESTION_ID_INVALID',
      );
    }
    return _apiClient.request<MaterialTaskSnapshot>(
      ApiRequestOptions<MaterialTaskSnapshot>(
        endpointId: 'workspaceNoteIngestion',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'ingestionId': ingestionId,
        },
        parseData: parseLinkIngestionSnapshot,
      ),
    );
  }

  @override
  Future<ApiResult<MaterialLinkOutlineOwnership>> getLinkOutlineOwnership(
    String taskId,
  ) async {
    final workspaceId = _activeWorkspaceId();
    final ingestionId = _safeId(taskId);
    if (workspaceId == null) {
      return _unavailable<MaterialLinkOutlineOwnership>(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    if (ingestionId == null) {
      return _unavailable<MaterialLinkOutlineOwnership>(
        'LINK_IMPORT_INGESTION_ID_INVALID',
      );
    }
    return _apiClient.request<MaterialLinkOutlineOwnership>(
      ApiRequestOptions<MaterialLinkOutlineOwnership>(
        endpointId: 'workspaceNoteIngestionMediaPreview',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'ingestionId': ingestionId,
        },
        parseData: parseLinkOutlineOwnership,
      ),
    );
  }

  @override
  Future<ApiResult<MaterialTaskSnapshot>> createVideoAnalysis({
    required String resourceId,
    required String title,
    required String idempotencyKey,
  }) async => _unavailable<MaterialTaskSnapshot>('AGENT_PROFILE_UNAVAILABLE');

  @override
  Future<ApiResult<MaterialTaskSnapshot>> getVideoAnalysis(
    String taskId,
  ) async => _unavailable<MaterialTaskSnapshot>('AGENT_PROFILE_UNAVAILABLE');

  @override
  Future<ApiResult<PageResult<GeneratedMemoryNote>>> listMemoryNotes({
    String? cursor,
  }) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) {
      return _unavailable<PageResult<GeneratedMemoryNote>>(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    final page = await _apiClient.request<PageResult<NoteFileAgentNoteHead>>(
      ApiRequestOptions<PageResult<NoteFileAgentNoteHead>>(
        endpointId: 'workspaceNotes',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        query: <String, Object?>{if (cursor != null) 'cursor': cursor},
        parseData: (value) => parsePageResult<NoteFileAgentNoteHead>(
          value,
          NoteFileAgentNoteHead.fromValue,
        ),
      ),
    );
    if (!page.ok || page.data == null) {
      return _unavailable<PageResult<GeneratedMemoryNote>>(
        page.error?.code ?? 'WORKSPACE_NOTE_LIST_FAILED',
      );
    }
    final notes = <GeneratedMemoryNote>[];
    for (final head in page.data!.items) {
      if (head.sourceKind != 'recording') continue;
      final note = await _readMemoryNote(
        workspaceId: workspaceId,
        initialHead: head,
      );
      if (!note.ok || note.data == null) {
        return _unavailable<PageResult<GeneratedMemoryNote>>(
          note.error?.code ?? 'WORKSPACE_NOTE_READ_FAILED',
        );
      }
      notes.add(note.data!);
    }
    return ApiResult<PageResult<GeneratedMemoryNote>>.success(
      data: PageResult<GeneratedMemoryNote>(
        items: List<GeneratedMemoryNote>.unmodifiable(notes),
        nextCursor: page.data!.nextCursor,
      ),
      status: page.status ?? 200,
      idempotencyStore: page.idempotencyStore,
      traceId: page.traceId,
      responseHeaders: page.responseHeaders,
    );
  }

  @override
  Future<ApiResult<GeneratedMemoryNote>> getMemoryNote(String noteId) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) {
      return _unavailable<GeneratedMemoryNote>('WORKSPACE_CONTEXT_UNAVAILABLE');
    }
    return _readMemoryNote(workspaceId: workspaceId, noteId: noteId);
  }

  Future<ApiResult<GeneratedMemoryNote>> _readMemoryNote({
    required String workspaceId,
    String? noteId,
    NoteFileAgentNoteHead? initialHead,
  }) async {
    try {
      final hnotes = NoteFileAgentClient(
        apiClient: _apiClient,
        workspaceId: () => workspaceId,
      );
      final head =
          initialHead ??
          await _readWorkspaceNoteHead(
            workspaceId: workspaceId,
            noteId: noteId,
          );
      final raw = await hnotes.readPart(
        workspaceId: workspaceId,
        noteId: head.noteId,
        part: NoteFileAgentPart.raw,
      );
      final outline = await hnotes.readPart(
        workspaceId: workspaceId,
        noteId: head.noteId,
        part: NoteFileAgentPart.outline,
      );
      if (raw.partRevisionId != head.rawPartRevisionId ||
          outline.partRevisionId != head.outlinePartRevisionId ||
          raw.markdown.trim().isEmpty) {
        return _unavailable<GeneratedMemoryNote>('WORKSPACE_NOTE_PART_INVALID');
      }
      final detail = await _apiClient.request<_WorkspaceNoteMetadata>(
        ApiRequestOptions<_WorkspaceNoteMetadata>(
          endpointId: 'workspaceNoteDetail',
          pathParams: <String, Object>{
            'workspaceId': workspaceId,
            'noteId': head.noteId,
          },
          parseData: _WorkspaceNoteMetadata.fromValue,
        ),
      );
      final metadata = detail.data;
      if (!detail.ok || metadata == null || metadata.noteId != head.noteId) {
        return _unavailable<GeneratedMemoryNote>(
          detail.error?.code ?? 'WORKSPACE_NOTE_READ_FAILED',
        );
      }
      return ApiResult<GeneratedMemoryNote>.success(
        data: GeneratedMemoryNote(
          id: head.noteId,
          title: metadata.title,
          markdown: raw.markdown,
          summary: outline.markdown.trim().isEmpty ? null : outline.markdown,
          source: MaterialIngestionSource.meeting,
          createdAt: metadata.createdAt,
          updatedAt: metadata.updatedAt,
          folderId: metadata.folderId,
          tags: const <String>[],
          remoteNoteId: head.noteId,
          noteRevisionId: metadata.noteRevisionId,
          rawPartRevisionId: head.rawPartRevisionId,
          etag: metadata.etag,
          contentCursor: metadata.contentCursor,
        ),
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      );
    } on NoteFileAgentException catch (error) {
      return _unavailable<GeneratedMemoryNote>(error.code);
    }
  }

  Future<NoteFileAgentNoteHead> _readWorkspaceNoteHead({
    required String workspaceId,
    required String? noteId,
  }) async {
    final id = _safeId(noteId);
    if (id == null) {
      throw const NoteFileAgentException('NOTE_FILE_AGENT_REQUEST_INVALID');
    }
    final hnotes = NoteFileAgentClient(
      apiClient: _apiClient,
      workspaceId: () => workspaceId,
    );
    return hnotes.readNoteHead(workspaceId: workspaceId, noteId: id);
  }

  String? _activeWorkspaceId() {
    final value = _workspaceId?.call()?.trim();
    return value != null && _safeId(value) != null ? value : null;
  }
}

final class _WorkspaceNoteMetadata {
  const _WorkspaceNoteMetadata({
    required this.noteId,
    required this.title,
    required this.noteRevisionId,
    required this.createdAt,
    required this.updatedAt,
    this.folderId,
    this.etag,
    this.contentCursor,
  });

  factory _WorkspaceNoteMetadata.fromValue(Object? value) {
    final data = asObjectMap(value);
    final note = data == null ? null : asObjectMap(data['note']) ?? data;
    if (note == null) throw const FormatException('note missing');
    final noteId = _safeId(note['noteId']);
    final title = _safeText(note['title'], maxLength: 240);
    final revision = _safeId(note['noteRevisionId']);
    final createdAt = DateTime.tryParse('${note['createdAt'] ?? ''}');
    final updatedAt = DateTime.tryParse('${note['updatedAt'] ?? ''}');
    if (noteId == null ||
        title == null ||
        revision == null ||
        createdAt == null ||
        updatedAt == null) {
      throw const FormatException('note metadata missing');
    }
    return _WorkspaceNoteMetadata(
      noteId: noteId,
      title: title,
      noteRevisionId: revision,
      createdAt: createdAt,
      updatedAt: updatedAt,
      folderId: _safeId(note['folderId']),
      etag: _safeText(note['etag'], maxLength: 300),
      contentCursor: _safeText(note['contentCursor'], maxLength: 160),
    );
  }

  final String noteId;
  final String title;
  final String noteRevisionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? folderId;
  final String? etag;
  final String? contentCursor;
}

ApiResult<T> _unavailable<T>(String code) => ApiResult<T>.failure(
  error: AppFailure(
    code: code,
    category: AppFailureCategory.api,
    message: 'Material integration operation is unavailable',
    userMessageKey: 'material.api.$code',
    recoveryActions: const <String>['none'],
  ),
  idempotencyStore: SubmissionKeyStore.empty,
);

MaterialTaskSnapshot? parseMaterialTaskSnapshot(
  Object? value, {
  required MaterialIngestionSource expectedSource,
  String? fallbackTaskId,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final task = asObjectMap(object['task']) ?? object;
  final taskId = _safeId(
    task['taskId'] ?? task['id'] ?? object['taskId'] ?? fallbackTaskId,
  );
  final status = _taskStatus(task['status'] ?? object['status']);
  if (taskId == null || status == null) return null;
  final rawProgress = task['progress'] ?? object['progress'];
  final progress = rawProgress is int && rawProgress >= 0 && rawProgress <= 100
      ? rawProgress
      : null;
  final rawNote = task['note'] ?? object['note'] ?? object['result'];
  final note = rawNote == null
      ? null
      : parseGeneratedMemoryNote(rawNote, expectedSource: expectedSource);
  if (status == MaterialRemoteTaskStatus.completed && note == null) return null;
  final errorCode = _safeCode(
    task['errorCode'] ??
        asObjectMap(task['error'])?['code'] ??
        object['errorCode'],
  );
  if (status == MaterialRemoteTaskStatus.failed && errorCode == null) {
    return null;
  }
  return MaterialTaskSnapshot(
    taskId: taskId,
    status: status,
    progress: progress,
    note: note,
    errorCode: errorCode,
  );
}

MaterialTaskSnapshot? parseLinkIngestionSnapshot(Object? value) {
  final object = asObjectMap(value);
  final ingestion = object == null
      ? null
      : asObjectMap(object['ingestion']) ?? object;
  if (ingestion == null) return null;
  final ingestionId = _safeId(ingestion['ingestionId']);
  final rawStatus = _safeText(
    ingestion['status'],
    maxLength: 40,
  )?.toLowerCase();
  if (ingestionId == null || rawStatus == null) return null;
  final promotedNoteId = _safeId(ingestion['promotedNoteId']);
  final safeError = asObjectMap(ingestion['safeError']);
  final failureCode = _safeCode(ingestion['failureCode'] ?? safeError?['code']);
  final status = switch (rawStatus) {
    'created' || 'queued' || 'pending' => MaterialRemoteTaskStatus.queued,
    'validating' ||
    'processing' ||
    'ready' ||
    'ready_to_promote' => MaterialRemoteTaskStatus.analyzing,
    'promoted' when promotedNoteId != null =>
      MaterialRemoteTaskStatus.completed,
    'failed' ||
    'quarantined' ||
    'expired' ||
    'cancelled' when failureCode != null => MaterialRemoteTaskStatus.failed,
    _ => null,
  };
  if (status == null) return null;
  return MaterialTaskSnapshot(
    taskId: ingestionId,
    status: status,
    promotedNoteId: promotedNoteId,
    errorCode: failureCode,
  );
}

MaterialLinkOutlineOwnership? parseLinkOutlineOwnership(Object? value) {
  final object = asObjectMap(value);
  final preview = object == null
      ? null
      : asObjectMap(object['mediaPreview']) ?? object;
  if (preview == null) return null;
  final ingestionId = _safeId(preview['ingestionId']);
  final status = _safeText(preview['status'], maxLength: 40)?.toLowerCase();
  final contentType = _safeText(
    preview['contentType'],
    maxLength: 64,
  )?.toLowerCase();
  if (ingestionId == null ||
      contentType == null ||
      status == null ||
      !const <String>{
        'ready',
        'unavailable',
        'refreshing',
        'failed',
      }.contains(status)) {
    return null;
  }

  // The backend leaves a no-video preview permanently unavailable. For a
  // has-video row, this GET returns ready or advances it to refreshing/failed.
  final backendOwnsOutline =
      contentType == 'video' ||
      contentType == 'audio' ||
      status != 'unavailable';
  return MaterialLinkOutlineOwnership(
    ingestionId: ingestionId,
    owner: backendOwnsOutline
        ? MaterialLinkOutlineOwner.backendMedia
        : MaterialLinkOutlineOwner.client,
  );
}

GeneratedMemoryNote? parseGeneratedMemoryNote(
  Object? value, {
  MaterialIngestionSource? expectedSource,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final id = _safeId(object['noteId'] ?? object['id']);
  final title = _safeText(object['title'], maxLength: 240);
  final markdown = _safeText(
    object['markdown'] ?? object['rawBody'] ?? object['content'],
    maxLength: 1000000,
  );
  final source = _source(object['source']) ?? expectedSource;
  final createdAt = DateTime.tryParse('${object['createdAt'] ?? ''}');
  final updatedAt = DateTime.tryParse(
    '${object['updatedAt'] ?? object['createdAt'] ?? ''}',
  );
  if (id == null ||
      title == null ||
      markdown == null ||
      source == null ||
      createdAt == null ||
      updatedAt == null) {
    return null;
  }
  final tags = _tags(object['tags']);
  if (tags == null) return null;
  return GeneratedMemoryNote(
    id: id,
    title: title,
    markdown: markdown,
    source: source,
    createdAt: createdAt,
    updatedAt: updatedAt,
    summary: _safeText(object['summary'], maxLength: 20000),
    contentLineId: _safeId(object['contentLineId']),
    contentLineName: _safeText(object['contentLineName'], maxLength: 120),
    folderId: _safeId(object['folderId']),
    folderName: _safeText(object['folderName'], maxLength: 120),
    tags: tags,
  );
}

MaterialRemoteTaskStatus? _taskStatus(Object? value) {
  final text = value is String ? value.trim().toLowerCase() : '';
  return switch (text) {
    'queued' || 'pending' || 'created' => MaterialRemoteTaskStatus.queued,
    'running' ||
    'processing' ||
    'analyzing' => MaterialRemoteTaskStatus.analyzing,
    'completed' ||
    'succeeded' ||
    'success' => MaterialRemoteTaskStatus.completed,
    'failed' ||
    'error' ||
    'timeout' ||
    'cancelled' => MaterialRemoteTaskStatus.failed,
    _ => null,
  };
}

MaterialIngestionSource? _source(Object? value) {
  final text = value is String ? value.trim().toLowerCase() : '';
  return switch (text) {
    'link' => MaterialIngestionSource.link,
    'internal_recording' ||
    'internal-recording' => MaterialIngestionSource.internalRecording,
    'meeting' => MaterialIngestionSource.meeting,
    _ => null,
  };
}

List<String>? _tags(Object? value) {
  if (value == null) return const <String>[];
  if (value is! List) return null;
  final result = <String>[];
  for (final item in value) {
    final tag = _safeText(item, maxLength: 40);
    if (tag == null) return null;
    if (!result.contains(tag)) result.add(tag);
    if (result.length > 40) return null;
  }
  return List<String>.unmodifiable(result);
}

String? _safeText(Object? value, {required int maxLength}) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.length > maxLength || text.contains('\u0000')) {
    return null;
  }
  return text;
}

bool _isPublicLink(Uri value) =>
    (value.scheme == 'http' || value.scheme == 'https') &&
    value.host.isNotEmpty &&
    value.userInfo.isEmpty &&
    (value.port == 0 || value.port == 80 || value.port == 443) &&
    !value.hasFragment;

String? _safeId(Object? value) {
  final text = _safeText(value, maxLength: 160);
  return text != null && RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(text)
      ? text
      : null;
}

String? _safeCode(Object? value) {
  final text = _safeText(value, maxLength: 80);
  return text != null && RegExp(r'^[A-Z0-9_]+$').hasMatch(text) ? text : null;
}
