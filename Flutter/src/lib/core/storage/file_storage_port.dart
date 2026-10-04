import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:huahuo_api/huahuo_api.dart';
import '../native/native_file_port.dart';
import 'private_recording_path_resolver.dart';

final class PrivateAudioFile {
  const PrivateAudioFile({
    required this.fileId,
    required this.appPrivateUri,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    this.durationSeconds,
    this.contentHash,
    this.recordedAt,
  });

  final String fileId;
  final String appPrivateUri;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final int? durationSeconds;
  final String? contentHash;
  final DateTime? recordedAt;
}

final class PrivateAudioFileStat {
  const PrivateAudioFileStat({
    required this.exists,
    this.sizeBytes,
    this.durationSeconds,
  });

  final bool exists;
  final int? sizeBytes;
  final int? durationSeconds;
}

final class PreparedAudioExport {
  const PreparedAudioExport({
    required this.opaqueExportRef,
    required this.displayName,
    required this.sizeBytes,
    this.mimeType,
    this.contentHash,
  });

  final String opaqueExportRef;
  final String displayName;
  final int sizeBytes;
  final String? mimeType;
  final String? contentHash;
}

final class PrivateAudioMigration {
  const PrivateAudioMigration({
    required this.effectiveUri,
    required this.fileId,
    required this.sizeBytes,
    required this.migrated,
  });

  final String effectiveUri;
  final String fileId;
  final int sizeBytes;
  final bool migrated;
}

final class FileStorageResult<T> {
  const FileStorageResult._({required this.ok, this.value, this.error});

  factory FileStorageResult.success(T value) =>
      FileStorageResult<T>._(ok: true, value: value);

  factory FileStorageResult.failure(AppFailure error) =>
      FileStorageResult<T>._(ok: false, error: error);

  final bool ok;
  final T? value;
  final AppFailure? error;
}

abstract interface class FileStoragePort {
  Future<FileStorageResult<PrivateAudioFile>> copyPickedAudioToPrivateLibrary(
    PickedAudioFile picked,
  );

  Future<FileStorageResult<PrivateAudioFile>>
  copyPrivateMediaAudioToPrivateLibrary({
    required String sourceAppPrivateUri,
    required String displayName,
    required String mimeType,
    required int expectedSizeBytes,
    required int durationSeconds,
    required String expectedContentHash,
    required DateTime recordedAt,
  });

  Future<FileStorageResult<bool>> updatePrivateAudioMetadata({
    required String appPrivateUri,
    required String displayName,
  });

  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  );

  Future<FileStorageResult<String>> hashPrivateAudio(String appPrivateUri);

  Future<FileStorageResult<PreparedAudioExport>> prepareAudioExport({
    required String appPrivateUri,
    required String displayName,
  });

  Future<FileStorageResult<bool>> deletePrivateAudio(String appPrivateUri);

  Future<FileStorageResult<PrivateAudioMigration>> migrateLegacyPrivateAudio({
    required String appPrivateUri,
    required bool recordingCard,
  });
}

typedef PrivateRootDirectoryResolver = Future<Directory> Function();
typedef RecordingStorageClock = DateTime Function();
typedef PrivateAudioDurationProbe = Future<int?> Function(File file);
typedef PrivateAudioSourceResolver =
    Future<File?> Function(String appPrivateUri);

final class PathProviderFileStoragePort implements FileStoragePort {
  PathProviderFileStoragePort({
    PrivateRootDirectoryResolver? rootDirectory,
    PrivateRecordingPathResolver? pathResolver,
    this.privateAudioSourceResolver,
    this.durationProbe,
    RecordingStorageClock? now,
  }) : _pathResolver =
           pathResolver ??
           PrivateRecordingPathResolver(
             applicationSupportDirectory: rootDirectory,
             documentsDirectory: rootDirectory,
           ),
       _now = now ?? DateTime.now;

  final PrivateRecordingPathResolver _pathResolver;
  final PrivateAudioSourceResolver? privateAudioSourceResolver;
  final PrivateAudioDurationProbe? durationProbe;
  final RecordingStorageClock _now;

  @override
  Future<FileStorageResult<PrivateAudioFile>> copyPickedAudioToPrivateLibrary(
    PickedAudioFile picked,
  ) async {
    final sourcePath = picked.sourcePath?.trim();
    if (sourcePath == null ||
        sourcePath.isEmpty ||
        sourcePath.endsWith('.part') ||
        _isUnsafePickedSourcePath(sourcePath)) {
      return FileStorageResult<PrivateAudioFile>.failure(
        _storageFailure(
          'RECORDING_SOURCE_PATH_UNSAFE',
          'Picked audio source path is unsafe',
        ),
      );
    }
    final extension = _safeAudioExtension(picked.displayName);
    if (extension == null) {
      return FileStorageResult<PrivateAudioFile>.failure(
        _storageFailure(
          'RECORDING_FILE_EXTENSION_UNSUPPORTED',
          'Picked audio file extension is unsupported',
        ),
      );
    }

    File? partFile;
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        return FileStorageResult<PrivateAudioFile>.failure(
          _storageFailure(
            'RECORDING_SOURCE_FILE_MISSING',
            'Picked audio source file does not exist',
          ),
        );
      }
      final fileId = _safeFileId(picked);
      final targetDirectory = await _pathResolver.localRecordingsDirectory();
      await targetDirectory.create(recursive: true);
      final fileName = '$fileId$extension';
      final targetFile = File(_join(targetDirectory.path, <String>[fileName]));
      partFile = File('${targetFile.path}.part');
      if (await partFile.exists()) {
        await partFile.delete();
      }
      await sourceFile.openRead().pipe(partFile.openWrite());
      final copiedSize = await partFile.length();
      if (copiedSize <= 0) {
        await partFile.delete();
        return FileStorageResult<PrivateAudioFile>.failure(
          _storageFailure('RECORDING_COPY_EMPTY', 'Copied audio file is empty'),
        );
      }
      final contentHash = (await sha256.bind(partFile.openRead()).first)
          .toString();
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await partFile.rename(targetFile.path);
      return FileStorageResult<PrivateAudioFile>.success(
        PrivateAudioFile(
          fileId: fileId,
          appPrivateUri: _pathResolver.localUri(fileName),
          displayName: picked.displayName,
          mimeType: picked.mimeType,
          sizeBytes: copiedSize,
          durationSeconds: picked.durationSeconds,
          contentHash: contentHash,
          recordedAt: picked.recordedAt,
        ),
      );
    } catch (error) {
      if (partFile != null && await partFile.exists()) {
        await partFile.delete();
      }
      return FileStorageResult<PrivateAudioFile>.failure(
        _storageFailure(
          'FILE_STORAGE_COPY_FAILED',
          'Private audio copy failed: $error',
        ),
      );
    }
  }

  @override
  Future<FileStorageResult<PrivateAudioFile>>
  copyPrivateMediaAudioToPrivateLibrary({
    required String sourceAppPrivateUri,
    required String displayName,
    required String mimeType,
    required int expectedSizeBytes,
    required int durationSeconds,
    required String expectedContentHash,
    required DateTime recordedAt,
  }) async {
    final extension = _safeAudioExtension(displayName);
    final contentHash = _safeSha256(expectedContentHash);
    final resolver = privateAudioSourceResolver;
    if (resolver == null ||
        extension == null ||
        expectedSizeBytes <= 0 ||
        durationSeconds < 0 ||
        contentHash == null) {
      return FileStorageResult<PrivateAudioFile>.failure(
        _storageFailure(
          'RECORDING_CAPTURE_ARCHIVE_INVALID',
          'Captured audio archive metadata is invalid',
        ),
      );
    }

    File? partFile;
    try {
      final sourceFile = await resolver(sourceAppPrivateUri);
      if (sourceFile == null ||
          await FileSystemEntity.type(sourceFile.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await sourceFile.length() != expectedSizeBytes) {
        return FileStorageResult<PrivateAudioFile>.failure(
          _storageFailure(
            'RECORDING_CAPTURE_ARCHIVE_SOURCE_INVALID',
            'Captured audio archive source is unavailable',
          ),
        );
      }
      final sourceHash = (await sha256.bind(sourceFile.openRead()).first)
          .toString();
      if (sourceHash != contentHash) {
        return FileStorageResult<PrivateAudioFile>.failure(
          _storageFailure(
            'RECORDING_CAPTURE_ARCHIVE_HASH_MISMATCH',
            'Captured audio archive source hash does not match',
          ),
        );
      }

      final fileName = 'internal-$contentHash$extension';
      final targetDirectory = await _pathResolver.localRecordingsDirectory();
      await targetDirectory.create(recursive: true);
      final targetFile = File(_join(targetDirectory.path, <String>[fileName]));
      if (await targetFile.exists()) {
        final existingHash = await sha256.bind(targetFile.openRead()).first;
        if (await targetFile.length() != expectedSizeBytes ||
            existingHash.toString() != contentHash) {
          return FileStorageResult<PrivateAudioFile>.failure(
            _storageFailure(
              'RECORDING_CAPTURE_ARCHIVE_CONFLICT',
              'Captured audio archive target conflicts with existing data',
            ),
          );
        }
        return FileStorageResult<PrivateAudioFile>.success(
          PrivateAudioFile(
            fileId: fileName,
            appPrivateUri: _pathResolver.localUri(fileName),
            displayName: displayName,
            mimeType: mimeType,
            sizeBytes: expectedSizeBytes,
            durationSeconds: durationSeconds,
            contentHash: contentHash,
            recordedAt: recordedAt,
          ),
        );
      }

      partFile = File('${targetFile.path}.part');
      if (await partFile.exists()) await partFile.delete();
      await sourceFile.openRead().pipe(partFile.openWrite());
      final copiedSize = await partFile.length();
      final copiedHash = (await sha256.bind(partFile.openRead()).first)
          .toString();
      if (copiedSize != expectedSizeBytes || copiedHash != contentHash) {
        await partFile.delete();
        return FileStorageResult<PrivateAudioFile>.failure(
          _storageFailure(
            'RECORDING_CAPTURE_ARCHIVE_COPY_MISMATCH',
            'Captured audio archive copy failed integrity verification',
          ),
        );
      }
      await partFile.rename(targetFile.path);
      return FileStorageResult<PrivateAudioFile>.success(
        PrivateAudioFile(
          fileId: fileName,
          appPrivateUri: _pathResolver.localUri(fileName),
          displayName: displayName,
          mimeType: mimeType,
          sizeBytes: copiedSize,
          durationSeconds: durationSeconds,
          contentHash: contentHash,
          recordedAt: recordedAt,
        ),
      );
    } catch (error) {
      if (partFile != null && await partFile.exists()) await partFile.delete();
      return FileStorageResult<PrivateAudioFile>.failure(
        _storageFailure(
          'RECORDING_CAPTURE_ARCHIVE_FAILED',
          'Captured audio archive failed: $error',
        ),
      );
    }
  }

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async {
    final resolved = await _resolvePrivateAudioFile(appPrivateUri);
    if (resolved == null) {
      return FileStorageResult<PrivateAudioFileStat>.failure(
        _storageFailure(
          'RECORDING_PRIVATE_URI_UNSAFE',
          'Private audio URI is unsafe',
        ),
      );
    }
    if (!await resolved.exists()) {
      return FileStorageResult<PrivateAudioFileStat>.success(
        const PrivateAudioFileStat(exists: false),
      );
    }
    int? durationSeconds;
    try {
      durationSeconds = await durationProbe?.call(resolved);
    } catch (_) {
      durationSeconds = null;
    }
    return FileStorageResult<PrivateAudioFileStat>.success(
      PrivateAudioFileStat(
        exists: true,
        sizeBytes: await resolved.length(),
        durationSeconds: durationSeconds != null && durationSeconds > 0
            ? durationSeconds
            : null,
      ),
    );
  }

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(
    String appPrivateUri,
  ) async {
    final resolved = await _resolvePrivateAudioFile(appPrivateUri);
    if (resolved == null) {
      return FileStorageResult<String>.failure(
        _storageFailure(
          'RECORDING_PRIVATE_URI_UNSAFE',
          'Private audio URI is unsafe',
        ),
      );
    }
    try {
      if (await FileSystemEntity.type(resolved.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return FileStorageResult<String>.failure(
          _storageFailure(
            'RECORDING_PRIVATE_FILE_MISSING',
            'Private audio file is missing',
          ),
        );
      }
      if (await resolved.length() <= 0) {
        return FileStorageResult<String>.failure(
          _storageFailure(
            'RECORDING_PRIVATE_FILE_EMPTY',
            'Private audio file is empty',
          ),
        );
      }
      return FileStorageResult<String>.success(
        (await sha256.bind(resolved.openRead()).first).toString(),
      );
    } catch (error) {
      return FileStorageResult<String>.failure(
        _storageFailure(
          'RECORDING_PRIVATE_HASH_FAILED',
          'Private audio hash calculation failed: $error',
        ),
      );
    }
  }

  @override
  Future<FileStorageResult<bool>> deletePrivateAudio(
    String appPrivateUri,
  ) async {
    final resolved = await _resolvePrivateAudioFile(appPrivateUri);
    if (resolved == null) {
      return FileStorageResult<bool>.failure(
        _storageFailure(
          'RECORDING_PRIVATE_URI_UNSAFE',
          'Private audio URI is unsafe',
        ),
      );
    }
    if (await resolved.exists()) {
      await resolved.delete();
    }
    final parent = resolved.parent;
    if (await parent.exists() && parent.listSync().isEmpty) {
      await parent.delete();
    }
    return FileStorageResult<bool>.success(true);
  }

  @override
  Future<FileStorageResult<PreparedAudioExport>> prepareAudioExport({
    required String appPrivateUri,
    required String displayName,
  }) async {
    final exportFileName = _safeExportFileName(displayName);
    if (exportFileName == null) {
      return FileStorageResult<PreparedAudioExport>.failure(
        _storageFailure(
          'RECORDING_EXPORT_NAME_UNSAFE',
          'Recording export display name is unsafe',
        ),
      );
    }
    final source = await _resolvePrivateAudioFile(appPrivateUri);
    if (source == null) {
      return FileStorageResult<PreparedAudioExport>.failure(
        _storageFailure(
          'RECORDING_PRIVATE_URI_UNSAFE',
          'Private audio URI is unsafe',
        ),
      );
    }
    File? partFile;
    try {
      if (!await source.exists()) {
        return FileStorageResult<PreparedAudioExport>.failure(
          _storageFailure(
            'RECORDING_PRIVATE_FILE_MISSING',
            'Private audio file is missing',
          ),
        );
      }
      final sourceSize = await source.length();
      if (sourceSize <= 0) {
        return FileStorageResult<PreparedAudioExport>.failure(
          _storageFailure(
            'RECORDING_EXPORT_EMPTY',
            'Private audio file is empty',
          ),
        );
      }
      final exportId =
          'export-${_stableStorageId('$appPrivateUri:$exportFileName:${_now().microsecondsSinceEpoch}')}';
      final temporaryRoot = await _pathResolver.temporaryTransfersDirectory();
      final exportDirectory = Directory(
        _join(temporaryRoot.path, <String>['export', 'cache', exportId]),
      );
      await exportDirectory.create(recursive: true);
      final exportFile = File(
        _join(exportDirectory.path, <String>[exportFileName]),
      );
      partFile = File('${exportFile.path}.part');
      if (await partFile.exists()) {
        await partFile.delete();
      }
      await source.openRead().pipe(partFile.openWrite());
      final exportedSize = await partFile.length();
      if (exportedSize <= 0) {
        await partFile.delete();
        return FileStorageResult<PreparedAudioExport>.failure(
          _storageFailure(
            'RECORDING_EXPORT_EMPTY',
            'Prepared export file is empty',
          ),
        );
      }
      if (exportedSize != sourceSize) {
        await partFile.delete();
        return FileStorageResult<PreparedAudioExport>.failure(
          _storageFailure(
            'RECORDING_EXPORT_SIZE_MISMATCH',
            'Prepared export byte count does not match the private audio',
          ),
        );
      }
      final contentHash = (await sha256.bind(partFile.openRead()).first)
          .toString();
      if (await exportFile.exists()) {
        await exportFile.delete();
      }
      await partFile.rename(exportFile.path);
      final transferScope = _pathResolver.temporaryTransferDirectoryScope;
      final opaquePath = transferScope == null
          ? 'cache/$exportId/$exportFileName'
          : 'users/$transferScope/cache/$exportId/$exportFileName';
      return FileStorageResult<PreparedAudioExport>.success(
        PreparedAudioExport(
          opaqueExportRef: 'app-private-export://recordings/$opaquePath',
          displayName: displayName.trim(),
          sizeBytes: exportedSize,
          contentHash: contentHash,
        ),
      );
    } catch (error) {
      if (partFile != null && await partFile.exists()) {
        await partFile.delete();
      }
      return FileStorageResult<PreparedAudioExport>.failure(
        _storageFailure(
          'FILE_STORAGE_EXPORT_PREPARE_FAILED',
          'Private audio export preparation failed: $error',
        ),
      );
    }
  }

  @override
  Future<FileStorageResult<bool>> updatePrivateAudioMetadata({
    required String appPrivateUri,
    required String displayName,
  }) async {
    if (displayName.trim().isEmpty || _unsafeStorageText(displayName)) {
      return FileStorageResult<bool>.failure(
        _storageFailure(
          'RECORDING_LOCAL_NAME_UNSAFE',
          'Recording display name is unsafe',
        ),
      );
    }
    final resolved = await _resolvePrivateAudioFile(appPrivateUri);
    if (resolved == null) {
      return FileStorageResult<bool>.failure(
        _storageFailure(
          'RECORDING_PRIVATE_URI_UNSAFE',
          'Private audio URI is unsafe',
        ),
      );
    }
    if (!await resolved.exists()) {
      return FileStorageResult<bool>.failure(
        _storageFailure(
          'RECORDING_PRIVATE_FILE_MISSING',
          'Private audio file is missing',
        ),
      );
    }
    return FileStorageResult<bool>.success(true);
  }

  Future<File?> _resolvePrivateAudioFile(String appPrivateUri) async {
    return _pathResolver.resolveFile(appPrivateUri);
  }

  @override
  Future<FileStorageResult<PrivateAudioMigration>> migrateLegacyPrivateAudio({
    required String appPrivateUri,
    required bool recordingCard,
  }) async {
    final reference = _pathResolver.parse(appPrivateUri);
    final expectedKind = recordingCard
        ? PrivateRecordingReferenceKind.recordingCard
        : PrivateRecordingReferenceKind.localRecording;
    final isLegacy =
        reference?.kind == PrivateRecordingReferenceKind.legacyFlutter;
    if (reference == null || (!isLegacy && reference.kind != expectedKind)) {
      return FileStorageResult<PrivateAudioMigration>.failure(
        _storageFailure(
          'RECORDING_LEGACY_URI_UNSAFE',
          'Legacy private recording URI is unsafe',
        ),
      );
    }
    final canonicalUri = isLegacy
        ? _pathResolver.canonicalUriForLegacy(
            reference,
            recordingCard: recordingCard,
          )
        : appPrivateUri;
    final target = await _pathResolver.resolveFile(canonicalUri);
    if (target == null) {
      return FileStorageResult<PrivateAudioMigration>.failure(
        _storageFailure(
          'RECORDING_MIGRATION_TARGET_UNSAFE',
          'Recording migration target is unsafe',
        ),
      );
    }
    final targetReference = _pathResolver.parse(canonicalUri);
    if (targetReference == null) {
      return FileStorageResult<PrivateAudioMigration>.failure(
        _storageFailure(
          'RECORDING_MIGRATION_TARGET_UNSAFE',
          'Recording migration target is unsafe',
        ),
      );
    }
    final source = await _pathResolver.resolveUnscopedFile(appPrivateUri);
    if (source == null || !await source.exists()) {
      if (await target.exists()) {
        final targetSize = await target.length();
        if (targetSize > 0) {
          return FileStorageResult<PrivateAudioMigration>.success(
            PrivateAudioMigration(
              effectiveUri: canonicalUri,
              fileId: targetReference.fileId,
              sizeBytes: targetSize,
              migrated: false,
            ),
          );
        }
      }
      return FileStorageResult<PrivateAudioMigration>.success(
        PrivateAudioMigration(
          effectiveUri: appPrivateUri,
          fileId: reference.fileId,
          sizeBytes: 0,
          migrated: false,
        ),
      );
    }
    final sourceSize = await source.length();
    if (source.path == target.path) {
      return FileStorageResult<PrivateAudioMigration>.success(
        PrivateAudioMigration(
          effectiveUri: canonicalUri,
          fileId: targetReference.fileId,
          sizeBytes: sourceSize,
          migrated: false,
        ),
      );
    }
    File? temporary;
    try {
      await target.parent.create(recursive: true);
      if (await target.exists()) {
        final targetSize = await target.length();
        if (targetSize == sourceSize && targetSize > 0) {
          if (!isLegacy) {
            await _deleteUnscopedSource(source);
          }
          return FileStorageResult<PrivateAudioMigration>.success(
            PrivateAudioMigration(
              effectiveUri: canonicalUri,
              fileId: targetReference.fileId,
              sizeBytes: targetSize,
              migrated: true,
            ),
          );
        }
        await target.delete();
      }
      temporary = File('${target.path}.tmp');
      if (await temporary.exists()) await temporary.delete();
      await source.openRead().pipe(temporary.openWrite());
      final copiedSize = await temporary.length();
      if (copiedSize <= 0 || copiedSize != sourceSize) {
        await temporary.delete();
        return FileStorageResult<PrivateAudioMigration>.success(
          PrivateAudioMigration(
            effectiveUri: appPrivateUri,
            fileId: reference.fileId,
            sizeBytes: sourceSize,
            migrated: false,
          ),
        );
      }
      await temporary.rename(target.path);
      if (!isLegacy) {
        await _deleteUnscopedSource(source);
      }
      return FileStorageResult<PrivateAudioMigration>.success(
        PrivateAudioMigration(
          effectiveUri: canonicalUri,
          fileId: targetReference.fileId,
          sizeBytes: copiedSize,
          migrated: true,
        ),
      );
    } catch (_) {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
      return FileStorageResult<PrivateAudioMigration>.success(
        PrivateAudioMigration(
          effectiveUri: appPrivateUri,
          fileId: reference.fileId,
          sizeBytes: sourceSize,
          migrated: false,
        ),
      );
    }
  }

  Future<void> _deleteUnscopedSource(File source) async {
    try {
      if (await source.exists()) {
        await source.delete();
      }
    } on FileSystemException {
      // The scoped copy is durable; stale native staging cleanup can retry.
    }
  }

  String _safeFileId(PickedAudioFile picked) {
    final seed =
        '${picked.pickerRef}:${picked.displayName}:${_now().microsecondsSinceEpoch}';
    return 'local-${_stableStorageId(seed)}';
  }
}

class UnavailableFileStoragePort implements FileStoragePort {
  const UnavailableFileStoragePort();

  @override
  Future<FileStorageResult<PrivateAudioFile>> copyPickedAudioToPrivateLibrary(
    PickedAudioFile picked,
  ) async {
    return FileStorageResult<PrivateAudioFile>.failure(_failure());
  }

  @override
  Future<FileStorageResult<PrivateAudioFile>>
  copyPrivateMediaAudioToPrivateLibrary({
    required String sourceAppPrivateUri,
    required String displayName,
    required String mimeType,
    required int expectedSizeBytes,
    required int durationSeconds,
    required String expectedContentHash,
    required DateTime recordedAt,
  }) async {
    return FileStorageResult<PrivateAudioFile>.failure(_failure());
  }

  @override
  Future<FileStorageResult<bool>> updatePrivateAudioMetadata({
    required String appPrivateUri,
    required String displayName,
  }) async {
    return FileStorageResult<bool>.failure(_failure());
  }

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<PrivateAudioFileStat>.failure(_failure());
  }

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<String>.failure(_failure());
  }

  @override
  Future<FileStorageResult<PreparedAudioExport>> prepareAudioExport({
    required String appPrivateUri,
    required String displayName,
  }) async {
    return FileStorageResult<PreparedAudioExport>.failure(_failure());
  }

  @override
  Future<FileStorageResult<bool>> deletePrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<bool>.failure(_failure());
  }

  @override
  Future<FileStorageResult<PrivateAudioMigration>> migrateLegacyPrivateAudio({
    required String appPrivateUri,
    required bool recordingCard,
  }) async {
    return FileStorageResult<PrivateAudioMigration>.failure(_failure());
  }
}

AppFailure _failure() {
  return const AppFailure(
    code: 'FILE_STORAGE_DRIVER_UNAVAILABLE',
    category: AppFailureCategory.storage,
    message: 'Private file storage is unavailable',
    userMessageKey: 'recording.import.storageUnavailable',
    recoveryActions: <String>['none'],
  );
}

AppFailure _storageFailure(String code, String message) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.storage,
    message: message,
    userMessageKey: 'recording.storage.$code',
    recoveryActions: const <String>['retry'],
  );
}

String? _safeAudioExtension(String displayName) {
  final lower = displayName.trim().toLowerCase();
  for (final extension in const <String>[
    '.mp3',
    '.m4a',
    '.mp4',
    '.wav',
    '.opus',
  ]) {
    if (lower.endsWith(extension)) return extension;
  }
  return null;
}

String? _safeSha256(String value) {
  final normalized = value.trim().toLowerCase();
  return RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized) ? normalized : null;
}

String? _safeExportFileName(String displayName) {
  final trimmed = displayName.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 80 ||
      trimmed.endsWith('.part') ||
      _unsafeStorageText(trimmed)) {
    return null;
  }
  final extension = _safeAudioExtension(trimmed);
  if (extension == null) return null;
  final basename = trimmed.substring(0, trimmed.length - extension.length);
  final safeBase = basename
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^[._-]+|[._-]+$'), '');
  return '${safeBase.isEmpty ? 'recording' : safeBase}$extension';
}

bool _isUnsafePickedSourcePath(String value) {
  final normalized = value.trim();
  return normalized.startsWith('file://') ||
      normalized.contains('\u0000') ||
      normalized.contains('\r') ||
      normalized.contains('\n');
}

bool _unsafeStorageText(String value) {
  return _unsafeStoragePatterns.any((pattern) => pattern.hasMatch(value));
}

String _stableStorageId(String value) {
  var hash = 0;
  for (final codeUnit in value.codeUnits) {
    hash = (hash * 31 + codeUnit) % 1000000007;
  }
  return hash.toRadixString(16);
}

String _join(String base, List<String> parts) {
  return <String>[base, ...parts].join(Platform.pathSeparator);
}

final _unsafeStoragePatterns = <RegExp>[
  RegExp(r'^file://', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(r'[\\/]Users[\\/]', caseSensitive: false),
  RegExp(r'\.\.[\\/]'),
  RegExp(r'[\\/]\.\.'),
  RegExp('workspace', caseSensitive: false),
  RegExp('provider', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('runtime', caseSensitive: false),
  RegExp('token', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
];
