import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/native/native_file_port.dart';
import '../domain/feed_item_models.dart';
import '../domain/profile_activity_models.dart';
import 'knowledge_library_controller.dart';
import 'profile_hub_controller.dart';

enum V3MediaImportStatus { idle, copying, completed, cancelled, failed }

final class V3MediaImportState {
  const V3MediaImportState({
    required this.status,
    this.importedNote,
    this.lastErrorCode,
  });

  const V3MediaImportState.initial()
    : status = V3MediaImportStatus.idle,
      importedNote = null,
      lastErrorCode = null;

  final V3MediaImportStatus status;
  final V3FeedItem? importedNote;
  final String? lastErrorCode;
}

final class V3MediaImportController extends ChangeNotifier {
  V3MediaImportController({
    required NativeFilePort nativeFilePort,
    required KnowledgeLibraryController knowledgeLibrary,
    required ProfileHubController profileHub,
    Future<Directory> Function()? applicationSupportDirectory,
  }) : _nativeFilePort = nativeFilePort,
       _knowledgeLibrary = knowledgeLibrary,
       _profileHub = profileHub,
       _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory;

  static const int _maxMediaBytes = 300 * 1024 * 1024;

  final NativeFilePort _nativeFilePort;
  final KnowledgeLibraryController _knowledgeLibrary;
  final ProfileHubController _profileHub;
  final Future<Directory> Function() _applicationSupportDirectory;
  V3MediaImportState _state = const V3MediaImportState.initial();
  bool _pickerInFlight = false;

  V3MediaImportState get state => _state;

  Future<V3FeedItem?> pickAndImport({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) async {
    if (_pickerInFlight || _state.status == V3MediaImportStatus.copying) {
      return null;
    }
    _pickerInFlight = true;
    late final NativeFileResult<List<PickedMediaFile>> picked;
    try {
      picked = await _nativeFilePort.pickMediaFiles(kind: kind, source: source);
    } on Object {
      _set(
        const V3MediaImportState(
          status: V3MediaImportStatus.failed,
          lastErrorCode: 'MEDIA_PICKER_FAILED',
        ),
      );
      return null;
    } finally {
      _pickerInFlight = false;
    }
    final files = picked.value;
    if (!picked.ok || files == null || files.isEmpty) {
      final code = picked.error?.code ?? 'MEDIA_PICKER_EMPTY';
      final cancelled = picked.cancelled || code == 'MEDIA_PICKER_CANCELLED';
      _set(
        V3MediaImportState(
          status: cancelled
              ? V3MediaImportStatus.cancelled
              : V3MediaImportStatus.failed,
          lastErrorCode: cancelled ? null : code,
        ),
      );
      return null;
    }
    final media = files.first;
    if (!_isSupportedMedia(media, kind, source)) {
      _set(
        const V3MediaImportState(
          status: V3MediaImportStatus.failed,
          lastErrorCode: 'MEDIA_PICKER_UNSUPPORTED_FILE',
        ),
      );
      return null;
    }
    _set(const V3MediaImportState(status: V3MediaImportStatus.copying));
    try {
      final attachment = await _copyToPrivateMedia(media);
      final importedAt = DateTime.now();
      final note = _knowledgeLibrary.importMedia(
        pickerRef: media.pickerRef,
        displayName: media.displayName,
        attachment: attachment,
        importedAt: importedAt,
      );
      _profileHub.recordActivity(
        V3ProfileActivity(
          id: 'media-import-${note.id}',
          occurredAt: importedAt,
          type: V3ProfileActivityType.upload,
          title: note.title,
          feedItemId: note.id,
          route: '/v3/feed/items/${Uri.encodeComponent(note.id)}',
        ),
      );
      _set(
        V3MediaImportState(
          status: V3MediaImportStatus.completed,
          importedNote: note,
        ),
      );
      return note;
    } on _MediaImportException catch (error) {
      _set(
        V3MediaImportState(
          status: V3MediaImportStatus.failed,
          lastErrorCode: error.code,
        ),
      );
      return null;
    } catch (_) {
      _set(
        const V3MediaImportState(
          status: V3MediaImportStatus.failed,
          lastErrorCode: 'MEDIA_IMPORT_FAILED',
        ),
      );
      return null;
    }
  }

  Future<V3MediaAttachment> _copyToPrivateMedia(PickedMediaFile media) async {
    final sourcePath = media.sourcePath?.trim();
    if (sourcePath == null ||
        sourcePath.isEmpty ||
        media.sizeBytes <= 0 ||
        media.sizeBytes > _maxMediaBytes) {
      throw const _MediaImportException('MEDIA_SOURCE_UNAVAILABLE');
    }
    final source = File(sourcePath);
    if (!await source.exists() || await source.length() != media.sizeBytes) {
      throw const _MediaImportException('MEDIA_SOURCE_UNAVAILABLE');
    }
    final extension = media.fileExtension;
    if (!_isAllowedExtension(extension, media.kind)) {
      throw const _MediaImportException('MEDIA_PICKER_UNSUPPORTED_FILE');
    }
    final root = await _applicationSupportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}HuahuoAI${Platform.pathSeparator}MediaImports',
    );
    await directory.create(recursive: true);
    final name = 'media-${_stableId(media.pickerRef)}.$extension';
    final target = File('${directory.path}${Platform.pathSeparator}$name');
    final temporary = File('${target.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    try {
      await source.openRead().pipe(temporary.openWrite());
      if (!await temporary.exists() ||
          await temporary.length() != media.sizeBytes) {
        throw const _MediaImportException('MEDIA_PRIVATE_COPY_FAILED');
      }
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      throw const _MediaImportException('MEDIA_PRIVATE_COPY_FAILED');
    }
    return V3MediaAttachment(
      privateUri: 'app-private-media://$name',
      displayName: media.displayName.trim().isEmpty
          ? name
          : media.displayName.trim(),
      mimeType: media.mimeType,
      sizeBytes: media.sizeBytes,
      kind: media.kind == NativeMediaKind.image
          ? V3MediaAttachmentKind.image
          : V3MediaAttachmentKind.video,
      privatePath: target.path,
    );
  }

  bool _isSupportedMedia(
    PickedMediaFile media,
    NativeMediaKind kind,
    NativeMediaSource source,
  ) =>
      media.kind == kind &&
      media.source == source &&
      media.sizeBytes > 0 &&
      media.sizeBytes <= _maxMediaBytes &&
      _isAllowedExtension(media.fileExtension, kind);

  void _set(V3MediaImportState value) {
    _state = value;
    notifyListeners();
  }
}

bool _isAllowedExtension(String extension, NativeMediaKind kind) =>
    switch (kind) {
      NativeMediaKind.image => const <String>{
        'jpg',
        'jpeg',
        'png',
        'heic',
        'webp',
      }.contains(extension),
      NativeMediaKind.video => const <String>{
        'mp4',
        'mov',
        'm4v',
        'avi',
      }.contains(extension),
    };

String _stableId(String value) {
  var hash = 0;
  for (final codeUnit in value.codeUnits) {
    hash = (hash * 31 + codeUnit) % 1000000007;
  }
  return hash.toRadixString(16);
}

final class _MediaImportException implements Exception {
  const _MediaImportException(this.code);

  final String code;
}
