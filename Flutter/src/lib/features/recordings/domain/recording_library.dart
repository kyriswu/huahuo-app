import '../../../core/api/api_envelope.dart';
import '../../../core/storage/private_recording_path_resolver.dart';

enum RecordingLibrarySource { localImport, microphone, device }

enum RecordingFileJobStatus { uploading, processing, ready, failed }

enum RecordingFileSource {
  recording,
  monologue,
  meeting,
  internalRecording,
  audioImport,
  recordingCard,
  localLibrary;

  String get routeValue => switch (this) {
    RecordingFileSource.recording => 'recording',
    RecordingFileSource.monologue => 'monologue',
    RecordingFileSource.meeting => 'meeting',
    RecordingFileSource.internalRecording => 'internal',
    RecordingFileSource.audioImport => 'audio-import',
    RecordingFileSource.recordingCard => 'recording-card',
    RecordingFileSource.localLibrary => 'local-library',
  };

  String get backendValue => switch (this) {
    RecordingFileSource.recording => 'local_upload',
    RecordingFileSource.monologue => 'monologue',
    RecordingFileSource.meeting => 'meeting',
    RecordingFileSource.internalRecording => 'internal_recording',
    RecordingFileSource.audioImport ||
    RecordingFileSource.localLibrary => 'local_upload',
    RecordingFileSource.recordingCard => 'recording_card',
  };

  String get label => switch (this) {
    RecordingFileSource.recording => '录音',
    RecordingFileSource.monologue => '独白',
    RecordingFileSource.meeting => '外录',
    RecordingFileSource.internalRecording => '内录',
    RecordingFileSource.audioImport => '音频文件',
    RecordingFileSource.recordingCard => '录音卡',
    RecordingFileSource.localLibrary => '本地录音',
  };

  static RecordingFileSource fromRoute(String? value) => switch (value
      ?.trim()) {
    'monologue' => RecordingFileSource.monologue,
    'meeting' => RecordingFileSource.meeting,
    'internal' ||
    'internal-recording' ||
    'internal_recording' => RecordingFileSource.internalRecording,
    'audio-import' ||
    'audio_import' ||
    'v3_material_upload' => RecordingFileSource.audioImport,
    'recording-card' || 'recording_card' => RecordingFileSource.recordingCard,
    'local-library' ||
    'local_library' ||
    'local_upload' => RecordingFileSource.localLibrary,
    _ => RecordingFileSource.recording,
  };
}

const String monologueRecordingHistoryTagId = 'monologue-history';
const String internalRecordingHistoryTagId = 'internal-history';
const String externalRecordingHistoryTagId = 'external-history';

enum RecordingLibraryFormat { mp3, opus, m4a, wav, unknown }

enum RecordingLibraryStatus {
  localOnly,
  uploading,
  failed,
  recycled,
  deviceOnly,
  downloading,
}

enum RecordingLocalFileState { ready, part, missing, none }

enum RecordingLibraryView { library, recycleBin }

final class RecordingLibraryQuery {
  const RecordingLibraryQuery({
    this.view = RecordingLibraryView.library,
    this.searchText,
  });

  final RecordingLibraryView view;
  final String? searchText;

  RecordingLibraryQuery copyWith({
    RecordingLibraryView? view,
    String? searchText,
  }) {
    return RecordingLibraryQuery(
      view: view ?? this.view,
      searchText: searchText ?? this.searchText,
    );
  }
}

final class RecordingLibrarySummary {
  const RecordingLibrarySummary({
    required this.totalCount,
    required this.favoriteCount,
    required this.playableCount,
    required this.recycledCount,
  });

  final int totalCount;
  final int favoriteCount;
  final int playableCount;
  final int recycledCount;
}

final class RecordingLibraryItem {
  const RecordingLibraryItem({
    required this.recordingId,
    required this.source,
    required this.displayName,
    required this.format,
    required this.localFileState,
    required this.status,
    required this.durationSeconds,
    required this.sizeBytes,
    required this.isFavorite,
    required this.tagIds,
    required this.createdAt,
    required this.updatedAt,
    this.originalFilename,
    this.deviceFilename,
    this.appPrivateUri,
    this.contentHash,
    this.remoteRecordingId,
    this.contentLineId,
    this.deletedAt,
  });

  final String recordingId;
  final RecordingLibrarySource source;
  final String displayName;
  final RecordingLibraryFormat format;
  final RecordingLocalFileState localFileState;
  final RecordingLibraryStatus status;
  final int durationSeconds;
  final int sizeBytes;
  final bool isFavorite;
  final List<String> tagIds;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? originalFilename;
  final String? deviceFilename;
  final String? appPrivateUri;
  final String? contentHash;
  final String? remoteRecordingId;
  final String? contentLineId;
  final DateTime? deletedAt;

  bool get hasServerChatContext =>
      remoteRecordingId != null &&
      contentLineId != null &&
      isSafeRecordingLibraryIdentifier(remoteRecordingId!) &&
      isSafeRecordingLibraryIdentifier(contentLineId!);

  RecordingLibraryItem copyWith({
    String? displayName,
    RecordingLocalFileState? localFileState,
    RecordingLibraryStatus? status,
    bool? isFavorite,
    List<String>? tagIds,
    DateTime? updatedAt,
    DateTime? deletedAt,
    String? deviceFilename,
    String? remoteRecordingId,
    String? contentLineId,
    String? appPrivateUri,
    int? durationSeconds,
    int? sizeBytes,
  }) {
    return RecordingLibraryItem(
      recordingId: recordingId,
      source: source,
      displayName: displayName ?? this.displayName,
      format: format,
      localFileState: localFileState ?? this.localFileState,
      status: status ?? this.status,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      isFavorite: isFavorite ?? this.isFavorite,
      tagIds: tagIds ?? this.tagIds,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      originalFilename: originalFilename,
      deviceFilename: deviceFilename ?? this.deviceFilename,
      appPrivateUri: appPrivateUri ?? this.appPrivateUri,
      contentHash: contentHash,
      remoteRecordingId: remoteRecordingId ?? this.remoteRecordingId,
      contentLineId: contentLineId ?? this.contentLineId,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  RecordingLibraryItem restored(DateTime restoredAt) {
    return RecordingLibraryItem(
      recordingId: recordingId,
      source: source,
      displayName: displayName,
      format: format,
      localFileState: localFileState,
      status: RecordingLibraryStatus.localOnly,
      durationSeconds: durationSeconds,
      sizeBytes: sizeBytes,
      isFavorite: isFavorite,
      tagIds: tagIds,
      createdAt: createdAt,
      updatedAt: restoredAt,
      originalFilename: originalFilename,
      deviceFilename: deviceFilename,
      appPrivateUri: appPrivateUri,
      contentHash: contentHash,
      remoteRecordingId: remoteRecordingId,
      contentLineId: contentLineId,
    );
  }

  Map<String, Object?> toRecord() {
    return <String, Object?>{
      'recording_id': recordingId,
      'source': source.name,
      'display_name': displayName,
      'format': format.name,
      'local_file_state': localFileState.name,
      'status': status.name,
      'duration_seconds': durationSeconds,
      'size_bytes': sizeBytes,
      'is_favorite': isFavorite,
      'tag_ids': tagIds,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      if (originalFilename != null) 'original_filename': originalFilename,
      if (deviceFilename != null) 'device_filename': deviceFilename,
      if (appPrivateUri != null) 'app_private_uri': appPrivateUri,
      if (contentHash != null) 'content_hash': contentHash,
      if (remoteRecordingId != null) 'remote_recording_id': remoteRecordingId,
      if (contentLineId != null) 'content_line_id': contentLineId,
      if (deletedAt != null) 'deleted_at': deletedAt!.toIso8601String(),
    };
  }

  static RecordingLibraryItem? fromRecord(Map<String, Object?> record) {
    final id = record['recording_id'] as String?;
    final name = record['display_name'] as String?;
    final createdAt = DateTime.tryParse('${record['created_at'] ?? ''}');
    final updatedAt = DateTime.tryParse('${record['updated_at'] ?? ''}');
    final remoteRecordingId = _safeOptionalIdentifier(
      record['remote_recording_id'],
    );
    final contentLineId = _safeOptionalIdentifier(record['content_line_id']);
    if (id == null || name == null || createdAt == null || updatedAt == null) {
      return null;
    }
    if ((record.containsKey('remote_recording_id') &&
            remoteRecordingId == null) ||
        (record.containsKey('content_line_id') && contentLineId == null)) {
      return null;
    }
    return RecordingLibraryItem(
      recordingId: id,
      source:
          _parseEnum(RecordingLibrarySource.values, record['source']) ??
          RecordingLibrarySource.localImport,
      displayName: name,
      format:
          _parseEnum(RecordingLibraryFormat.values, record['format']) ??
          RecordingLibraryFormat.unknown,
      localFileState:
          _parseEnum(
            RecordingLocalFileState.values,
            record['local_file_state'],
          ) ??
          RecordingLocalFileState.missing,
      status:
          _parseEnum(RecordingLibraryStatus.values, record['status']) ??
          RecordingLibraryStatus.failed,
      durationSeconds: record['duration_seconds'] is int
          ? record['duration_seconds']! as int
          : 0,
      sizeBytes: record['size_bytes'] is int ? record['size_bytes']! as int : 0,
      isFavorite: record['is_favorite'] == true,
      tagIds: record['tag_ids'] is Iterable
          ? (record['tag_ids']! as Iterable).whereType<String>().toList()
          : const <String>[],
      createdAt: createdAt,
      updatedAt: updatedAt,
      originalFilename: record['original_filename'] as String?,
      deviceFilename: record['device_filename'] as String?,
      appPrivateUri: record['app_private_uri'] as String?,
      contentHash: record['content_hash'] as String?,
      remoteRecordingId: remoteRecordingId,
      contentLineId: contentLineId,
      deletedAt: DateTime.tryParse('${record['deleted_at'] ?? ''}'),
    );
  }
}

bool isMonologueRecordingHistoryItem(RecordingLibraryItem item) {
  if (item.source != RecordingLibrarySource.microphone) return false;
  return item.tagIds.contains(monologueRecordingHistoryTagId) ||
      item.displayName.startsWith('独白-');
}

bool isInternalRecordingHistoryItem(RecordingLibraryItem item) {
  return item.source == RecordingLibrarySource.microphone &&
      (item.tagIds.contains(internalRecordingHistoryTagId) ||
          item.displayName.startsWith('内录-'));
}

bool isExternalRecordingHistoryItem(RecordingLibraryItem item) {
  return item.source == RecordingLibrarySource.microphone &&
      (item.tagIds.contains(externalRecordingHistoryTagId) ||
          item.displayName.startsWith('外录-') ||
          item.displayName.startsWith('会议-'));
}

bool isSafeRecordingLibraryIdentifier(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
}

String? _safeOptionalIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeRecordingLibraryIdentifier(text) ? text : null;
}

List<RecordingLibraryItem> filterRecordingLibrary(
  List<RecordingLibraryItem> items,
  RecordingLibraryQuery query,
) {
  final search = query.searchText?.trim().toLowerCase();
  final rows = items.where((item) {
    final inView = query.view == RecordingLibraryView.recycleBin
        ? item.status == RecordingLibraryStatus.recycled
        : item.status != RecordingLibraryStatus.recycled &&
              item.status != RecordingLibraryStatus.deviceOnly &&
              item.localFileState != RecordingLocalFileState.part;
    if (!inView) return false;
    if (search == null || search.isEmpty) return true;
    return <String?>[
      item.displayName,
      item.originalFilename,
      item.deviceFilename,
      ...item.tagIds,
    ].whereType<String>().any((value) => value.toLowerCase().contains(search));
  }).toList();
  rows.sort((left, right) => right.createdAt.compareTo(left.createdAt));
  return rows;
}

RecordingLibrarySummary summarizeRecordings(List<RecordingLibraryItem> items) {
  final rows = filterRecordingLibrary(items, const RecordingLibraryQuery());
  return RecordingLibrarySummary(
    totalCount: rows.length,
    favoriteCount: rows.where((item) => item.isFavorite).length,
    playableCount: rows
        .where((item) => item.localFileState == RecordingLocalFileState.ready)
        .length,
    recycledCount: items
        .where((item) => item.status == RecordingLibraryStatus.recycled)
        .length,
  );
}

Object renameRecording(
  RecordingLibraryItem item,
  String displayName,
  DateTime updatedAt,
) {
  final safe = safeDisplayName(displayName);
  if (safe == null) {
    return displayName.trim().isEmpty
        ? recordingLibraryError('RECORDING_NAME_EMPTY')
        : recordingLibraryError('RECORDING_LOCAL_NAME_UNSAFE');
  }
  return item.copyWith(displayName: safe, updatedAt: updatedAt);
}

Object updateRecordingTags(
  RecordingLibraryItem item,
  List<String> tagIds,
  DateTime updatedAt,
) {
  final safeTags = <String>[];
  for (final tagId in tagIds) {
    final safe = safeTagName(tagId);
    if (safe == null) return recordingLibraryError('RECORDING_TAG_INVALID');
    if (!safeTags.contains(safe)) safeTags.add(safe);
  }
  return item.copyWith(tagIds: safeTags, updatedAt: updatedAt);
}

AppFailure recordingLibraryError(String code) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.storage,
    message: 'Local recording library operation failed',
    userMessageKey: 'recording.local.error.$code',
    recoveryActions: const <String>['none'],
  );
}

bool isSafeAppPrivateUri(String value) {
  return isSafeAppPrivateRecordingUri(value);
}

String? safeDisplayName(String? value) {
  final text = value?.trim();
  if (text == null ||
      text.isEmpty ||
      text.length > 80 ||
      unsafeLocalLibraryText(text)) {
    return null;
  }
  return text;
}

String? safeTagName(String value) {
  final text = value.trim();
  if (text.isEmpty || text.length > 24 || unsafeLocalLibraryText(text)) {
    return null;
  }
  return text;
}

String? safeContentHash(String? value) {
  final normalized = value?.trim().toLowerCase();
  return normalized != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)
      ? normalized
      : null;
}

RecordingLibraryFormat formatFromMetadata(String mimeType, String name) {
  final text = '$mimeType $name'.toLowerCase();
  if (text.contains('mpeg') || text.contains('.mp3')) {
    return RecordingLibraryFormat.mp3;
  }
  if (text.contains('opus') || text.contains('.opus')) {
    return RecordingLibraryFormat.opus;
  }
  if (text.contains('m4a') || text.contains('mp4') || text.contains('.m4a')) {
    return RecordingLibraryFormat.m4a;
  }
  if (text.contains('wav') || text.contains('.wav')) {
    return RecordingLibraryFormat.wav;
  }
  return RecordingLibraryFormat.unknown;
}

RecordingLibraryFormat resolveRecordingLibraryExportFormat(
  RecordingLibraryItem item,
) {
  if (item.format != RecordingLibraryFormat.unknown) return item.format;
  for (final candidate in <String?>[
    item.originalFilename,
    item.deviceFilename,
    ..._privateUriFileNameCandidates(item.appPrivateUri),
  ]) {
    final format = recordingLibraryFormatFromFileName(candidate);
    if (format != RecordingLibraryFormat.unknown) return format;
  }
  return RecordingLibraryFormat.unknown;
}

RecordingLibraryFormat recordingLibraryFormatFromFileName(String? fileName) {
  final lower = fileName?.trim().toLowerCase();
  if (lower == null || lower.isEmpty) return RecordingLibraryFormat.unknown;
  if (lower.endsWith('.mp3')) return RecordingLibraryFormat.mp3;
  if (lower.endsWith('.opus')) return RecordingLibraryFormat.opus;
  if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) {
    return RecordingLibraryFormat.m4a;
  }
  if (lower.endsWith('.wav')) return RecordingLibraryFormat.wav;
  return RecordingLibraryFormat.unknown;
}

String? recordingLibraryExtensionForFormat(RecordingLibraryFormat format) {
  return switch (format) {
    RecordingLibraryFormat.mp3 => '.mp3',
    RecordingLibraryFormat.opus => '.opus',
    RecordingLibraryFormat.m4a => '.m4a',
    RecordingLibraryFormat.wav => '.wav',
    RecordingLibraryFormat.unknown => null,
  };
}

String? recordingLibraryMimeTypeForFormat(RecordingLibraryFormat format) {
  return switch (format) {
    RecordingLibraryFormat.mp3 => 'audio/mpeg',
    RecordingLibraryFormat.opus => 'audio/opus',
    RecordingLibraryFormat.m4a => 'audio/mp4',
    RecordingLibraryFormat.wav => 'audio/wav',
    RecordingLibraryFormat.unknown => null,
  };
}

String? recordingLibraryExportDisplayName(
  String displayName,
  RecordingLibraryFormat format,
) {
  final safe = safeDisplayName(displayName);
  final extension = recordingLibraryExtensionForFormat(format);
  if (safe == null || extension == null) return null;
  var basename = safe;
  while (true) {
    final audioExtension = _audioExtensionForName(basename);
    if (audioExtension == null) break;
    basename = basename.substring(0, basename.length - audioExtension.length);
  }
  basename = basename.trim().replaceFirst(RegExp(r'[.\s]+$'), '');
  if (basename.isEmpty) basename = 'recording';
  basename = _truncateCodeUnits(basename, 80 - extension.length);
  final result = '$basename$extension';
  return safeDisplayName(result);
}

Iterable<String?> _privateUriFileNameCandidates(String? appPrivateUri) sync* {
  if (appPrivateUri == null || !isSafeAppPrivateUri(appPrivateUri)) return;
  final uri = Uri.tryParse(appPrivateUri);
  if (uri == null) return;
  for (final segment in uri.pathSegments.reversed) {
    yield segment;
  }
  yield uri.host;
}

String? _audioExtensionForName(String name) {
  final lower = name.toLowerCase();
  for (final extension in const <String>[
    '.opus',
    '.mp3',
    '.m4a',
    '.mp4',
    '.wav',
  ]) {
    if (lower.endsWith(extension)) return extension;
  }
  return null;
}

String _truncateCodeUnits(String value, int maximumLength) {
  if (value.length <= maximumLength) return value;
  final buffer = StringBuffer();
  var length = 0;
  for (final rune in value.runes) {
    final text = String.fromCharCode(rune);
    if (length + text.length > maximumLength) break;
    buffer.write(text);
    length += text.length;
  }
  return buffer.toString().trim();
}

String stableRecordingHash(String value) {
  var hash = 0;
  for (final codeUnit in value.codeUnits) {
    hash = (hash * 31 + codeUnit) % 1000000007;
  }
  return hash.toString();
}

bool unsafeLocalLibraryText(String value) {
  return _unsafePatterns.any((pattern) => pattern.hasMatch(value));
}

T? _parseEnum<T extends Enum>(List<T> values, Object? value) {
  for (final item in values) {
    if (item.name == value) return item;
  }
  return null;
}

final _unsafePatterns = <RegExp>[
  RegExp(r'^file://', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(r'[\\/]Users[\\/]', caseSensitive: false),
  RegExp('workspace', caseSensitive: false),
  RegExp('provider', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('runtime', caseSensitive: false),
  RegExp('token', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
];
