import '../../../core/database/app_database.dart';

enum MaterialIngestionSource { link, internalRecording, meeting }

extension MaterialIngestionSourceX on MaterialIngestionSource {
  String get wireName => switch (this) {
    MaterialIngestionSource.link => 'link',
    MaterialIngestionSource.internalRecording => 'internal_recording',
    MaterialIngestionSource.meeting => 'meeting',
  };

  String get label => switch (this) {
    MaterialIngestionSource.link => '链接',
    MaterialIngestionSource.internalRecording => '内录',
    MaterialIngestionSource.meeting => '会议',
  };
}

enum MaterialIngestionStatus {
  draft,
  uploading,
  submitting,
  queued,
  analyzing,
  completed,
  failed,
  cancelled,
}

enum MaterialIngestionCheckpoint {
  created,
  uploadTokenReady,
  objectUploaded,
  resourceReady,
  taskSubmitted,
  noteDeposited,
}

enum MaterialLinkOutlineOwner { client, backendMedia }

final class CapturedMediaInput {
  const CapturedMediaInput({
    required this.appPrivateUri,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.sha256,
    required this.recordedAt,
  });

  final String appPrivateUri;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int durationSeconds;
  final String sha256;
  final DateTime recordedAt;
}

final class CapturedAudioInput {
  const CapturedAudioInput({
    required this.appPrivateUri,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.sha256,
    required this.recordedAt,
  });

  final String appPrivateUri;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int durationSeconds;
  final String sha256;
  final DateTime recordedAt;

  CapturedMediaInput toMediaInput() => CapturedMediaInput(
    appPrivateUri: appPrivateUri,
    fileName: fileName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    durationSeconds: durationSeconds,
    sha256: sha256,
    recordedAt: recordedAt,
  );
}

final class GeneratedMemoryNote {
  const GeneratedMemoryNote({
    required this.id,
    required this.title,
    required this.markdown,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.summary,
    this.contentLineId,
    this.contentLineName,
    this.folderId,
    this.folderName,
    this.tags = const <String>[],
    this.remoteNoteId,
    this.noteRevisionId,
    this.rawPartRevisionId,
    this.etag,
    this.contentCursor,
    this.publicUrl,
  });

  final String id;
  final String title;
  final String markdown;
  final MaterialIngestionSource source;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? summary;
  final String? contentLineId;
  final String? contentLineName;
  final String? folderId;
  final String? folderName;
  final List<String> tags;
  final String? remoteNoteId;
  final String? noteRevisionId;
  final String? rawPartRevisionId;
  final String? etag;
  final String? contentCursor;
  final String? publicUrl;
}

final class MaterialIngestionDraft {
  const MaterialIngestionDraft({
    required this.id,
    required this.source,
    required this.status,
    required this.checkpoint,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.submitKey,
    this.normalizedUrl,
    this.appPrivateUri,
    this.fileName,
    this.mimeType,
    this.sizeBytes,
    this.durationSeconds,
    this.sha256,
    this.recordedAt,
    this.uploadTokenKey,
    this.completeUploadKey,
    this.uploadId,
    this.resourceId,
    this.remoteTaskId,
    this.noteId,
    this.linkOutlineOwner,
    this.lastErrorCode,
  });

  final String id;
  final MaterialIngestionSource source;
  final MaterialIngestionStatus status;
  final MaterialIngestionCheckpoint checkpoint;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String submitKey;
  final String? normalizedUrl;
  final String? appPrivateUri;
  final String? fileName;
  final String? mimeType;
  final int? sizeBytes;
  final int? durationSeconds;
  final String? sha256;
  final DateTime? recordedAt;
  final String? uploadTokenKey;
  final String? completeUploadKey;
  final String? uploadId;
  final String? resourceId;
  final String? remoteTaskId;
  final String? noteId;
  final MaterialLinkOutlineOwner? linkOutlineOwner;
  final String? lastErrorCode;

  bool get isTerminal =>
      status == MaterialIngestionStatus.completed ||
      status == MaterialIngestionStatus.failed ||
      status == MaterialIngestionStatus.cancelled;
  bool get isRecoverable => !isTerminal;
  bool get isBusy => switch (status) {
    MaterialIngestionStatus.uploading ||
    MaterialIngestionStatus.submitting ||
    MaterialIngestionStatus.queued ||
    MaterialIngestionStatus.analyzing => true,
    _ => false,
  };

  MaterialIngestionDraft copyWith({
    MaterialIngestionStatus? status,
    MaterialIngestionCheckpoint? checkpoint,
    DateTime? updatedAt,
    String? uploadId,
    String? resourceId,
    String? remoteTaskId,
    String? noteId,
    MaterialLinkOutlineOwner? linkOutlineOwner,
    String? lastErrorCode,
    bool clearError = false,
  }) {
    return MaterialIngestionDraft(
      id: id,
      source: source,
      status: status ?? this.status,
      checkpoint: checkpoint ?? this.checkpoint,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      submitKey: submitKey,
      normalizedUrl: normalizedUrl,
      appPrivateUri: appPrivateUri,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      durationSeconds: durationSeconds,
      sha256: sha256,
      recordedAt: recordedAt,
      uploadTokenKey: uploadTokenKey,
      completeUploadKey: completeUploadKey,
      uploadId: uploadId ?? this.uploadId,
      resourceId: resourceId ?? this.resourceId,
      remoteTaskId: remoteTaskId ?? this.remoteTaskId,
      noteId: noteId ?? this.noteId,
      linkOutlineOwner: linkOutlineOwner ?? this.linkOutlineOwner,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
    );
  }

  LocalDatabaseRecord toRecord() => <String, Object?>{
    'draft_id': id,
    'source': source.wireName,
    'status': status.name,
    'checkpoint': checkpoint.name,
    'title': title,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'submit_idempotency_key': submitKey,
    if (normalizedUrl != null) 'normalized_url': normalizedUrl,
    if (appPrivateUri != null) 'app_private_uri': appPrivateUri,
    if (fileName != null) 'file_name': fileName,
    if (mimeType != null) 'mime_type': mimeType,
    if (sizeBytes != null) 'size_bytes': sizeBytes,
    if (durationSeconds != null) 'duration_seconds': durationSeconds,
    if (sha256 != null) 'content_hash': sha256,
    if (recordedAt != null)
      'recorded_at': recordedAt!.toUtc().toIso8601String(),
    if (uploadTokenKey != null) 'upload_idempotency_key': uploadTokenKey,
    if (completeUploadKey != null)
      'complete_idempotency_key': completeUploadKey,
    if (uploadId != null) 'resource_upload_id': uploadId,
    if (resourceId != null) 'resource_id': resourceId,
    if (remoteTaskId != null) 'remote_task_id': remoteTaskId,
    if (noteId != null) 'note_id': noteId,
    if (linkOutlineOwner != null) 'link_outline_owner': linkOutlineOwner!.name,
    if (lastErrorCode != null) 'last_error_code': lastErrorCode,
  };

  static MaterialIngestionDraft? fromRecord(LocalDatabaseRecord record) {
    final id = _text(record['draft_id']);
    final source = _source(record['source']);
    final status = _enumByName(
      MaterialIngestionStatus.values,
      record['status'],
    );
    final checkpoint = _enumByName(
      MaterialIngestionCheckpoint.values,
      record['checkpoint'],
    );
    final title = _text(record['title']);
    final createdAt = DateTime.tryParse('${record['created_at'] ?? ''}');
    final updatedAt = DateTime.tryParse('${record['updated_at'] ?? ''}');
    final submitKey = _text(record['submit_idempotency_key']);
    if (id == null ||
        source == null ||
        status == null ||
        checkpoint == null ||
        title == null ||
        createdAt == null ||
        updatedAt == null ||
        submitKey == null) {
      return null;
    }
    return MaterialIngestionDraft(
      id: id,
      source: source,
      status: status,
      checkpoint: checkpoint,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      submitKey: submitKey,
      normalizedUrl: _text(record['normalized_url']),
      appPrivateUri: _text(record['app_private_uri']),
      fileName: _text(record['file_name']),
      mimeType: _text(record['mime_type']),
      sizeBytes: record['size_bytes'] as int?,
      durationSeconds: record['duration_seconds'] as int?,
      sha256: _text(record['content_hash']),
      recordedAt: DateTime.tryParse('${record['recorded_at'] ?? ''}'),
      uploadTokenKey: _text(record['upload_idempotency_key']),
      completeUploadKey: _text(record['complete_idempotency_key']),
      uploadId: _text(record['resource_upload_id']),
      resourceId: _text(record['resource_id']),
      remoteTaskId: _text(record['remote_task_id']),
      noteId: _text(record['note_id']),
      linkOutlineOwner: _enumByName(
        MaterialLinkOutlineOwner.values,
        record['link_outline_owner'],
      ),
      lastErrorCode: _text(record['last_error_code']),
    );
  }
}

T? _enumByName<T extends Enum>(List<T> values, Object? raw) {
  final name = _text(raw);
  if (name == null) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

MaterialIngestionSource? _source(Object? raw) {
  final value = _text(raw);
  for (final source in MaterialIngestionSource.values) {
    if (source.wireName == value) return source;
  }
  return null;
}

String? _text(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  return value.isEmpty ? null : value;
}
