import 'package:flutter/services.dart';

import 'package:huahuo_api/huahuo_api.dart';
import 'document_import_format.dart';

final class PickedAudioFile {
  const PickedAudioFile({
    required this.pickerRef,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    this.durationSeconds,
    this.contentHash,
    this.recordedAt,
    this.sourcePath,
    this.sourceIdentifier,
  });

  final String pickerRef;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final int? durationSeconds;
  final String? contentHash;
  final DateTime? recordedAt;
  final String? sourcePath;
  final String? sourceIdentifier;
}

final class PickedDocumentFile {
  const PickedDocumentFile({
    required this.pickerRef,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    this.sourcePath,
    this.sourceIdentifier,
    this.contentHash,
  });

  final String pickerRef;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final String? sourcePath;
  final String? sourceIdentifier;
  final String? contentHash;

  String get fileExtension {
    final dot = displayName.lastIndexOf('.');
    if (dot < 0 || dot == displayName.length - 1) return '';
    return displayName.substring(dot + 1).toLowerCase();
  }

  bool get isPlainText => fileExtension == 'txt' || fileExtension == 'md';

  bool get isAudio => const <String>{
    'mp3',
    'm4a',
    'mp4',
    'wav',
    'opus',
  }.contains(fileExtension);
}

enum NativeMediaKind { image, video }

enum NativeMediaSource { camera, gallery, files }

final class PickedMediaFile {
  const PickedMediaFile({
    required this.pickerRef,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.kind,
    required this.source,
    this.sourcePath,
    this.sourceIdentifier,
  });

  final String pickerRef;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final NativeMediaKind kind;
  final NativeMediaSource source;
  final String? sourcePath;
  final String? sourceIdentifier;

  String get fileExtension {
    final dot = displayName.lastIndexOf('.');
    if (dot < 0 || dot == displayName.length - 1) return '';
    return displayName.substring(dot + 1).toLowerCase();
  }
}

final class NativeFileResult<T> {
  const NativeFileResult._({
    required this.ok,
    this.value,
    this.error,
    this.cancelled = false,
  });

  factory NativeFileResult.success(T value) =>
      NativeFileResult<T>._(ok: true, value: value);

  factory NativeFileResult.failure(AppFailure error) =>
      NativeFileResult<T>._(ok: false, error: error);

  factory NativeFileResult.cancelled() =>
      NativeFileResult<T>._(ok: false, cancelled: true);

  final bool ok;
  final T? value;
  final AppFailure? error;
  final bool cancelled;
}

abstract interface class NativeFilePort {
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles();
}

/// Optional document-selection capability for the shared native file port.
///
/// It deliberately lives beside the existing audio-only interface so older
/// audio test doubles that `implements NativeFilePort` do not need a document
/// method they cannot support.
abstract interface class NativeDocumentFilePort {
  Future<NativeFileResult<List<PickedDocumentFile>>> pickDocumentFiles();
}

/// Optional image/video selection capability for the shared native file port.
abstract interface class NativeMediaFilePort {
  Future<NativeFileResult<List<PickedMediaFile>>> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  });
}

/// Optional system save/open capability for a prepared private audio export.
///
/// The opaque reference is resolved and validated by the platform bridge. UI
/// code never receives or supplies an absolute application-private path.
abstract interface class NativePreparedAudioExportPort {
  Future<NativeFileResult<bool>> savePreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  });

  Future<NativeFileResult<bool>> openPreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  });
}

/// Optional system photo-library write capability for trusted image bytes.
///
/// Flutter never gives the native bridge a source path or a remote URL. Callers
/// must first resolve and validate the image bytes through their own authorized
/// data flow.
abstract interface class NativeImageGallerySaverPort {
  Future<NativeFileResult<bool>> saveImageToGallery({
    required Uint8List bytes,
    required String displayName,
    required String mimeType,
  });
}

extension NativeFilePortDocumentSelection on NativeFilePort {
  Future<NativeFileResult<List<PickedDocumentFile>>> pickDocumentFiles() {
    final port = this;
    if (port is NativeDocumentFilePort) {
      return (port as NativeDocumentFilePort).pickDocumentFiles();
    }
    return Future<NativeFileResult<List<PickedDocumentFile>>>.value(
      NativeFileResult<List<PickedDocumentFile>>.failure(
        _nativeFailure(
          'NATIVE_DOCUMENT_PICKER_UNAVAILABLE',
          'Native document picker is unavailable',
        ),
      ),
    );
  }
}

extension NativeFilePortMediaSelection on NativeFilePort {
  Future<NativeFileResult<List<PickedMediaFile>>> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) {
    final port = this;
    if (port is NativeMediaFilePort) {
      return (port as NativeMediaFilePort).pickMediaFiles(
        kind: kind,
        source: source,
      );
    }
    return Future<NativeFileResult<List<PickedMediaFile>>>.value(
      NativeFileResult<List<PickedMediaFile>>.failure(
        _nativeFailure(
          'NATIVE_MEDIA_PICKER_UNAVAILABLE',
          'Native media picker is unavailable',
        ),
      ),
    );
  }
}

extension NativeFilePortPreparedAudioExport on NativeFilePort {
  Future<NativeFileResult<bool>> savePreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) {
    final port = this;
    if (port is NativePreparedAudioExportPort) {
      return (port as NativePreparedAudioExportPort).savePreparedAudioExport(
        opaqueExportRef: opaqueExportRef,
        displayName: displayName,
        mimeType: mimeType,
      );
    }
    return Future<NativeFileResult<bool>>.value(
      NativeFileResult<bool>.failure(
        _nativeFailure(
          'NATIVE_AUDIO_EXPORT_UNAVAILABLE',
          'Native audio save capability is unavailable',
        ),
      ),
    );
  }

  Future<NativeFileResult<bool>> openPreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) {
    final port = this;
    if (port is NativePreparedAudioExportPort) {
      return (port as NativePreparedAudioExportPort).openPreparedAudioExport(
        opaqueExportRef: opaqueExportRef,
        displayName: displayName,
        mimeType: mimeType,
      );
    }
    return Future<NativeFileResult<bool>>.value(
      NativeFileResult<bool>.failure(
        _nativeFailure(
          'NATIVE_AUDIO_OPEN_UNAVAILABLE',
          'Native audio open capability is unavailable',
        ),
      ),
    );
  }
}

extension NativeFilePortImageGallerySave on NativeFilePort {
  Future<NativeFileResult<bool>> saveImageToGallery({
    required Uint8List bytes,
    required String displayName,
    required String mimeType,
  }) {
    final port = this;
    if (port is NativeImageGallerySaverPort) {
      return (port as NativeImageGallerySaverPort).saveImageToGallery(
        bytes: bytes,
        displayName: displayName,
        mimeType: mimeType,
      );
    }
    return Future<NativeFileResult<bool>>.value(
      NativeFileResult<bool>.failure(
        _nativeFailure(
          'NATIVE_IMAGE_SAVE_UNAVAILABLE',
          'Native image save capability is unavailable',
        ),
      ),
    );
  }
}

abstract interface class NativeAudioPicker {
  Future<List<NativePickedAudioFile>?> pickAudioFiles();
}

abstract interface class NativeDocumentPicker {
  Future<List<NativePickedDocumentFile>?> pickDocumentFiles();
}

abstract interface class NativeMediaPicker {
  Future<List<NativePickedMediaFile>?> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  });
}

abstract interface class NativePreparedAudioExportDriver {
  Future<bool> savePreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  });

  Future<bool> openPreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  });
}

final class NativePickedAudioFile {
  const NativePickedAudioFile({
    required this.displayName,
    required this.sizeBytes,
    required this.sourcePath,
    this.mimeType,
    this.durationSeconds,
    this.sourceIdentifier,
  });

  final String displayName;
  final int sizeBytes;
  final String sourcePath;
  final String? mimeType;
  final int? durationSeconds;
  final String? sourceIdentifier;
}

final class NativePickedDocumentFile {
  const NativePickedDocumentFile({
    required this.displayName,
    required this.sizeBytes,
    required this.sourcePath,
    this.mimeType,
    this.sourceIdentifier,
    this.contentHash,
  });

  final String displayName;
  final int sizeBytes;
  final String sourcePath;
  final String? mimeType;
  final String? sourceIdentifier;
  final String? contentHash;
}

final class NativePickedMediaFile {
  const NativePickedMediaFile({
    required this.displayName,
    required this.sizeBytes,
    required this.sourcePath,
    required this.mimeType,
    required this.kind,
    required this.source,
    this.sourceIdentifier,
  });

  final String displayName;
  final int sizeBytes;
  final String sourcePath;
  final String mimeType;
  final NativeMediaKind kind;
  final NativeMediaSource source;
  final String? sourceIdentifier;
}

final class MethodChannelNativeFilePort
    implements
        NativeFilePort,
        NativeDocumentFilePort,
        NativeMediaFilePort,
        NativePreparedAudioExportPort,
        NativeImageGallerySaverPort {
  const MethodChannelNativeFilePort({
    NativeAudioPicker? picker,
    NativeDocumentPicker? documentPicker,
    NativeMediaPicker? mediaPicker,
    NativePreparedAudioExportDriver? preparedAudioExportDriver,
  }) : _picker = picker,
       _documentPicker = documentPicker,
       _mediaPicker = mediaPicker,
       _preparedAudioExportDriver = preparedAudioExportDriver;

  final NativeAudioPicker? _picker;
  final NativeDocumentPicker? _documentPicker;
  final NativeMediaPicker? _mediaPicker;
  final NativePreparedAudioExportDriver? _preparedAudioExportDriver;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async {
    try {
      final result = await (_picker ?? const _MethodChannelAudioPicker())
          .pickAudioFiles();
      if (result == null) {
        return NativeFileResult<List<PickedAudioFile>>.cancelled();
      }
      final picked = <PickedAudioFile>[];
      for (final file in result) {
        final sourcePath = file.sourcePath;
        if (sourcePath.trim().isEmpty) {
          return NativeFileResult<List<PickedAudioFile>>.failure(
            _nativeFailure(
              'RECORDING_PICKER_SOURCE_UNAVAILABLE',
              'Picked audio file did not include a readable source path',
            ),
          );
        }
        picked.add(
          PickedAudioFile(
            pickerRef:
                'picked-audio://${_stableOpaqueId('${file.sourceIdentifier ?? sourcePath}:${file.displayName}:${file.sizeBytes}')}',
            displayName: file.displayName,
            mimeType: file.mimeType ?? _mimeTypeFor(file.displayName),
            sizeBytes: file.sizeBytes,
            durationSeconds: file.durationSeconds,
            sourcePath: sourcePath,
            sourceIdentifier: file.sourceIdentifier,
          ),
        );
      }
      if (picked.isEmpty) {
        return NativeFileResult<List<PickedAudioFile>>.cancelled();
      }
      return NativeFileResult<List<PickedAudioFile>>.success(picked);
    } on PlatformException catch (error) {
      if (_isNativeAudioPickerCancellation(error.code)) {
        return NativeFileResult<List<PickedAudioFile>>.cancelled();
      }
      return NativeFileResult<List<PickedAudioFile>>.failure(
        _nativeFailure(
          error.code.trim().isEmpty ? 'NATIVE_FILE_PICKER_FAILED' : error.code,
          error.message ?? 'Native file picker failed',
        ),
      );
    } catch (error) {
      return NativeFileResult<List<PickedAudioFile>>.failure(
        _nativeFailure(
          'NATIVE_FILE_PICKER_FAILED',
          'Native file picker failed: $error',
        ),
      );
    }
  }

  @override
  Future<NativeFileResult<List<PickedDocumentFile>>> pickDocumentFiles() async {
    try {
      final result =
          await (_documentPicker ?? const _MethodChannelDocumentPicker())
              .pickDocumentFiles();
      if (result == null) {
        return NativeFileResult<List<PickedDocumentFile>>.cancelled();
      }
      if (result.isEmpty) {
        return NativeFileResult<List<PickedDocumentFile>>.cancelled();
      }

      final picked = <PickedDocumentFile>[];
      for (final file in result) {
        final sourcePath = file.sourcePath.trim();
        if (sourcePath.isEmpty) {
          return NativeFileResult<List<PickedDocumentFile>>.failure(
            _nativeFailure(
              'DOCUMENT_PICKER_SOURCE_UNAVAILABLE',
              'Picked document did not include a readable source path',
            ),
          );
        }
        final format = DocumentImportFormat.fromFileName(file.displayName);
        if (format == null) {
          return NativeFileResult<List<PickedDocumentFile>>.failure(
            _nativeFailure(
              'DOCUMENT_PICKER_UNSUPPORTED_FILE',
              'Picked document type is not supported',
            ),
          );
        }
        picked.add(
          PickedDocumentFile(
            pickerRef:
                'picked-document://${_stableOpaqueId('${file.sourceIdentifier ?? sourcePath}:${file.displayName}:${file.sizeBytes}')}',
            displayName: file.displayName,
            // Providers frequently return application/octet-stream or a broad
            // Office type. The extension is validated above and is the only
            // source of the Note-ingestion MIME contract.
            mimeType: format.mimeType,
            sizeBytes: file.sizeBytes,
            sourcePath: sourcePath,
            sourceIdentifier: file.sourceIdentifier,
            contentHash: file.contentHash,
          ),
        );
      }
      return NativeFileResult<List<PickedDocumentFile>>.success(picked);
    } on PlatformException catch (error) {
      if (_isNativeDocumentPickerCancellation(error.code)) {
        return NativeFileResult<List<PickedDocumentFile>>.cancelled();
      }
      return NativeFileResult<List<PickedDocumentFile>>.failure(
        _nativeFailure(
          error.code.trim().isEmpty
              ? 'NATIVE_DOCUMENT_PICKER_FAILED'
              : error.code,
          error.message ?? 'Native document picker failed',
        ),
      );
    } catch (error) {
      return NativeFileResult<List<PickedDocumentFile>>.failure(
        _nativeFailure(
          'NATIVE_DOCUMENT_PICKER_FAILED',
          'Native document picker failed: $error',
        ),
      );
    }
  }

  @override
  Future<NativeFileResult<List<PickedMediaFile>>> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) async {
    try {
      final files = await (_mediaPicker ?? const _MethodChannelMediaPicker())
          .pickMediaFiles(kind: kind, source: source);
      if (files == null) {
        return NativeFileResult<List<PickedMediaFile>>.cancelled();
      }
      if (files.isEmpty) {
        return NativeFileResult<List<PickedMediaFile>>.cancelled();
      }
      if (kind == NativeMediaKind.image &&
          source != NativeMediaSource.camera &&
          files.length > 9) {
        return NativeFileResult<List<PickedMediaFile>>.failure(
          _nativeFailure(
            'MEDIA_PICKER_TOO_MANY_FILES',
            'Gallery selection is limited to nine images',
          ),
        );
      }
      final picked = <PickedMediaFile>[];
      for (final file in files) {
        final sourcePath = file.sourcePath.trim();
        if (sourcePath.isEmpty ||
            file.sizeBytes <= 0 ||
            file.sizeBytes > _maximumMediaBytes(file.kind)) {
          return NativeFileResult<List<PickedMediaFile>>.failure(
            _nativeFailure(
              'MEDIA_PICKER_SOURCE_UNAVAILABLE',
              'Picked media is unavailable',
            ),
          );
        }
        if (file.kind != kind ||
            file.source != source ||
            !_isSupportedMediaName(file.displayName, kind)) {
          return NativeFileResult<List<PickedMediaFile>>.failure(
            _nativeFailure(
              'MEDIA_PICKER_UNSUPPORTED_FILE',
              'Picked media type is not supported',
            ),
          );
        }
        picked.add(
          PickedMediaFile(
            pickerRef:
                'picked-media://${_stableOpaqueId('${file.sourceIdentifier ?? sourcePath}:${file.displayName}:${file.sizeBytes}')}',
            displayName: file.displayName,
            mimeType: file.mimeType,
            sizeBytes: file.sizeBytes,
            kind: file.kind,
            source: file.source,
            sourcePath: sourcePath,
            sourceIdentifier: file.sourceIdentifier,
          ),
        );
      }
      return NativeFileResult<List<PickedMediaFile>>.success(picked);
    } on PlatformException catch (error) {
      if (_isNativeMediaPickerCancellation(error.code)) {
        return NativeFileResult<List<PickedMediaFile>>.cancelled();
      }
      return NativeFileResult<List<PickedMediaFile>>.failure(
        _nativeFailure(
          error.code.trim().isEmpty ? 'NATIVE_MEDIA_PICKER_FAILED' : error.code,
          error.message ?? 'Native media picker failed',
        ),
      );
    } catch (_) {
      return NativeFileResult<List<PickedMediaFile>>.failure(
        _nativeFailure(
          'NATIVE_MEDIA_PICKER_FAILED',
          'Native media picker failed',
        ),
      );
    }
  }

  @override
  Future<NativeFileResult<bool>> savePreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) {
    return _runPreparedAudioExport(
      opaqueExportRef: opaqueExportRef,
      displayName: displayName,
      mimeType: mimeType,
      openWithOtherApp: false,
    );
  }

  @override
  Future<NativeFileResult<bool>> openPreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) {
    return _runPreparedAudioExport(
      opaqueExportRef: opaqueExportRef,
      displayName: displayName,
      mimeType: mimeType,
      openWithOtherApp: true,
    );
  }

  @override
  Future<NativeFileResult<bool>> saveImageToGallery({
    required Uint8List bytes,
    required String displayName,
    required String mimeType,
  }) async {
    if (bytes.isEmpty ||
        bytes.lengthInBytes > _maxImageGallerySaveBytes ||
        !_isSafeImageGalleryDisplayName(displayName) ||
        !_isSupportedImageGalleryMimeType(mimeType)) {
      return NativeFileResult<bool>.failure(
        _nativeFailure(
          'NATIVE_IMAGE_SAVE_INVALID',
          'Image save metadata is invalid',
        ),
      );
    }
    try {
      final saved = await const _MethodChannelImageGallerySaver()
          .saveImageToGallery(
            bytes: bytes,
            displayName: displayName,
            mimeType: mimeType,
          );
      return NativeFileResult<bool>.success(saved);
    } on PlatformException catch (error) {
      return NativeFileResult<bool>.failure(
        _nativeFailure(
          error.code.trim().isEmpty ? 'NATIVE_IMAGE_SAVE_FAILED' : error.code,
          error.message ?? 'Native image save failed',
        ),
      );
    } catch (error) {
      return NativeFileResult<bool>.failure(
        _nativeFailure(
          'NATIVE_IMAGE_SAVE_FAILED',
          'Native image save failed: $error',
        ),
      );
    }
  }

  Future<NativeFileResult<bool>> _runPreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
    required bool openWithOtherApp,
  }) async {
    if (!_isSafePreparedAudioExportRef(opaqueExportRef) ||
        !_isSafeExportDisplayName(displayName) ||
        !_isSafeAudioMimeType(mimeType)) {
      return NativeFileResult<bool>.failure(
        _nativeFailure(
          'NATIVE_AUDIO_EXPORT_INVALID',
          'Prepared audio export metadata is invalid',
        ),
      );
    }
    final driver =
        _preparedAudioExportDriver ?? const _MethodChannelAudioExportDriver();
    try {
      final completed = openWithOtherApp
          ? await driver.openPreparedAudioExport(
              opaqueExportRef: opaqueExportRef,
              displayName: displayName,
              mimeType: mimeType,
            )
          : await driver.savePreparedAudioExport(
              opaqueExportRef: opaqueExportRef,
              displayName: displayName,
              mimeType: mimeType,
            );
      return NativeFileResult<bool>.success(completed);
    } on PlatformException catch (error) {
      if (!openWithOtherApp && _isNativeAudioExportCancellation(error.code)) {
        return NativeFileResult<bool>.cancelled();
      }
      return NativeFileResult<bool>.failure(
        _nativeFailure(
          error.code.trim().isEmpty ? 'NATIVE_AUDIO_EXPORT_FAILED' : error.code,
          error.message ?? 'Native prepared audio export failed',
        ),
      );
    } catch (error) {
      return NativeFileResult<bool>.failure(
        _nativeFailure(
          openWithOtherApp
              ? 'NATIVE_AUDIO_OPEN_FAILED'
              : 'NATIVE_AUDIO_SAVE_FAILED',
          'Native prepared audio export failed: $error',
        ),
      );
    }
  }
}

bool _isNativeAudioPickerCancellation(String code) => const <String>{
  'NATIVE_FILE_PICKER_CANCELLED',
  'RECORDING_PICKER_CANCELLED',
}.contains(code.trim());

bool _isNativeDocumentPickerCancellation(String code) => const <String>{
  'NATIVE_DOCUMENT_PICKER_CANCELLED',
  'DOCUMENT_PICKER_CANCELLED',
}.contains(code.trim());

bool _isNativeAudioExportCancellation(String code) =>
    const <String>{'NATIVE_AUDIO_EXPORT_SAVE_CANCELLED'}.contains(code.trim());

bool _isNativeMediaPickerCancellation(String code) => const <String>{
  'NATIVE_MEDIA_PICKER_CANCELLED',
  'MEDIA_PICKER_CANCELLED',
}.contains(code.trim());

final class _MethodChannelAudioPicker implements NativeAudioPicker {
  const _MethodChannelAudioPicker();

  static const MethodChannel _channel = MethodChannel('huahuoai/native_file');

  @override
  Future<List<NativePickedAudioFile>?> pickAudioFiles() async {
    final rawFiles = await _channel.invokeMethod<List<dynamic>>(
      'pickAudioFiles',
    );
    if (rawFiles == null) return null;
    return rawFiles.map(_parsePickedAudioFile).toList(growable: false);
  }

  NativePickedAudioFile _parsePickedAudioFile(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      throw const FormatException('Invalid native picked audio payload');
    }
    final displayName = raw['displayName'];
    final sizeBytes = raw['sizeBytes'];
    final sourcePath = raw['sourcePath'];
    if (displayName is! String || sizeBytes is! int || sourcePath is! String) {
      throw const FormatException('Incomplete native picked audio payload');
    }
    return NativePickedAudioFile(
      displayName: displayName,
      sizeBytes: sizeBytes,
      sourcePath: sourcePath,
      mimeType: _optionalString(raw['mimeType']),
      durationSeconds: _optionalPositiveInt(raw['durationSeconds']),
      sourceIdentifier: _optionalString(raw['sourceIdentifier']),
    );
  }
}

String? _optionalSha256(Object? value) {
  final normalized = _optionalString(value)?.toLowerCase();
  if (normalized == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

final class _MethodChannelDocumentPicker implements NativeDocumentPicker {
  const _MethodChannelDocumentPicker();

  static const MethodChannel _channel = MethodChannel('huahuoai/native_file');

  @override
  Future<List<NativePickedDocumentFile>?> pickDocumentFiles() async {
    final rawFiles = await _channel.invokeMethod<List<dynamic>>(
      'pickDocumentFiles',
    );
    if (rawFiles == null) return null;
    return rawFiles.map(_parsePickedDocumentFile).toList(growable: false);
  }

  NativePickedDocumentFile _parsePickedDocumentFile(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      throw const FormatException('Invalid native picked document payload');
    }
    final displayName = raw['displayName'];
    final sizeBytes = raw['sizeBytes'];
    final sourcePath = raw['sourcePath'];
    if (displayName is! String || sizeBytes is! int || sourcePath is! String) {
      throw const FormatException('Incomplete native picked document payload');
    }
    return NativePickedDocumentFile(
      displayName: displayName,
      sizeBytes: sizeBytes,
      sourcePath: sourcePath,
      mimeType: _optionalString(raw['mimeType']),
      sourceIdentifier: _optionalString(raw['sourceIdentifier']),
      contentHash: _optionalSha256(raw['contentHash']),
    );
  }
}

final class _MethodChannelMediaPicker implements NativeMediaPicker {
  const _MethodChannelMediaPicker();

  static const MethodChannel _channel = MethodChannel('huahuoai/native_file');

  @override
  Future<List<NativePickedMediaFile>?> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) async {
    final rawFiles = await _channel.invokeMethod<List<dynamic>>(
      'pickMediaFiles',
      <String, String>{'kind': kind.name, 'source': source.name},
    );
    if (rawFiles == null) return null;
    return rawFiles
        .map((raw) => _parsePickedMediaFile(raw, kind: kind, source: source))
        .toList(growable: false);
  }

  NativePickedMediaFile _parsePickedMediaFile(
    Object? raw, {
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) {
    if (raw is! Map<Object?, Object?>) {
      throw const FormatException('Invalid native picked media payload');
    }
    final displayName = raw['displayName'];
    final sizeBytes = raw['sizeBytes'];
    final sourcePath = raw['sourcePath'];
    final mimeType = raw['mimeType'];
    if (displayName is! String ||
        sizeBytes is! int ||
        sourcePath is! String ||
        mimeType is! String) {
      throw const FormatException('Incomplete native picked media payload');
    }
    return NativePickedMediaFile(
      displayName: displayName,
      sizeBytes: sizeBytes,
      sourcePath: sourcePath,
      mimeType: mimeType,
      kind: kind,
      source: source,
      sourceIdentifier: _optionalString(raw['sourceIdentifier']),
    );
  }
}

final class _MethodChannelAudioExportDriver
    implements NativePreparedAudioExportDriver {
  const _MethodChannelAudioExportDriver();

  static const MethodChannel _channel = MethodChannel('huahuoai/native_file');

  @override
  Future<bool> savePreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    return await _channel
            .invokeMethod<bool>('savePreparedAudioExport', <String, String>{
              'opaqueExportRef': opaqueExportRef,
              'displayName': displayName,
              'mimeType': mimeType,
            }) ??
        false;
  }

  @override
  Future<bool> openPreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    return await _channel
            .invokeMethod<bool>('openPreparedAudioExport', <String, String>{
              'opaqueExportRef': opaqueExportRef,
              'displayName': displayName,
              'mimeType': mimeType,
            }) ??
        false;
  }
}

final class _MethodChannelImageGallerySaver {
  const _MethodChannelImageGallerySaver();

  static const MethodChannel _channel = MethodChannel('huahuoai/native_file');

  Future<bool> saveImageToGallery({
    required Uint8List bytes,
    required String displayName,
    required String mimeType,
  }) async {
    return await _channel.invokeMethod<bool>(
          'saveImageToGallery',
          <String, Object>{
            'bytes': bytes,
            'displayName': displayName,
            'mimeType': mimeType,
          },
        ) ??
        false;
  }
}

final class UnavailableNativeFilePort
    implements
        NativeFilePort,
        NativeDocumentFilePort,
        NativeMediaFilePort,
        NativeImageGallerySaverPort {
  const UnavailableNativeFilePort();

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async {
    return NativeFileResult<List<PickedAudioFile>>.failure(
      const AppFailure(
        code: 'NATIVE_FILE_DRIVER_UNAVAILABLE',
        category: AppFailureCategory.storage,
        message: 'Native file picker is unavailable',
        userMessageKey: 'recording.import.nativeUnavailable',
        recoveryActions: <String>['none'],
      ),
    );
  }

  @override
  Future<NativeFileResult<List<PickedDocumentFile>>> pickDocumentFiles() async {
    return NativeFileResult<List<PickedDocumentFile>>.failure(
      const AppFailure(
        code: 'NATIVE_DOCUMENT_PICKER_UNAVAILABLE',
        category: AppFailureCategory.storage,
        message: 'Native document picker is unavailable',
        userMessageKey: 'document.import.nativeUnavailable',
        recoveryActions: <String>['none'],
      ),
    );
  }

  @override
  Future<NativeFileResult<List<PickedMediaFile>>> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) async {
    return NativeFileResult<List<PickedMediaFile>>.failure(
      _nativeFailure(
        'NATIVE_MEDIA_PICKER_UNAVAILABLE',
        'Native media picker is unavailable',
      ),
    );
  }

  @override
  Future<NativeFileResult<bool>> saveImageToGallery({
    required Uint8List bytes,
    required String displayName,
    required String mimeType,
  }) async => NativeFileResult<bool>.failure(
    _nativeFailure(
      'NATIVE_IMAGE_SAVE_UNAVAILABLE',
      'Native image save capability is unavailable',
    ),
  );
}

AppFailure _nativeFailure(String code, String message) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.storage,
    message: message,
    userMessageKey: 'recording.import.native.$code',
    recoveryActions: const <String>['retry'],
  );
}

const _maxImageGallerySaveBytes = 50 * 1024 * 1024;
const _imageGalleryMimes = <String>{'image/jpeg', 'image/png', 'image/webp'};

bool _isSupportedImageGalleryMimeType(String value) =>
    _imageGalleryMimes.contains(value.trim().toLowerCase());

bool _isSafeImageGalleryDisplayName(String value) {
  final name = value.trim();
  if (name.isEmpty ||
      name.length > 128 ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('..') ||
      name.codeUnits.any((code) => code < 32)) {
    return false;
  }
  final extension = name.split('.').last.toLowerCase();
  return const <String>{'jpg', 'jpeg', 'png', 'webp'}.contains(extension);
}

String _mimeTypeFor(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) return 'audio/mp4';
  if (lower.endsWith('.wav')) return 'audio/wav';
  if (lower.endsWith('.opus')) return 'audio/opus';
  return 'audio/*';
}

bool _isSafePreparedAudioExportRef(String value) {
  final text = value.trim();
  final lower = text.toLowerCase();
  if (text.contains('..') || lower.contains('%2e')) return false;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'app-private-export' ||
      uri.host != 'recordings' ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty ||
      uri.port != 0 ||
      (uri.pathSegments.length != 3 && uri.pathSegments.length != 5)) {
    return false;
  }
  final scoped = uri.pathSegments.length == 5;
  if (scoped &&
      (uri.pathSegments[0] != 'users' ||
          !_isSafeExportAccountScope(uri.pathSegments[1]) ||
          uri.pathSegments[2] != 'cache')) {
    return false;
  }
  if (!scoped && uri.pathSegments.first != 'cache') return false;
  final exportId = uri.pathSegments[scoped ? 3 : 1];
  final fileName = uri.pathSegments[scoped ? 4 : 2];
  return exportId.startsWith('export-') &&
      _isSafeExportComponent(exportId) &&
      _isSafeExportDisplayName(fileName);
}

bool _isSafeExportAccountScope(String value) =>
    RegExp(r'^u-[a-f0-9]{32}$').hasMatch(value);

bool _isSafeExportDisplayName(String value) {
  final text = value.trim();
  return text.isNotEmpty &&
      text.length <= 160 &&
      text != '.' &&
      text != '..' &&
      !text.contains('/') &&
      !text.contains('\\') &&
      !text.contains('\u0000') &&
      !text.contains('\n') &&
      !text.contains('\r');
}

bool _isSafeExportComponent(String value) {
  return RegExp(r'^[A-Za-z0-9._-]{1,160}$').hasMatch(value);
}

bool _isSafeAudioMimeType(String value) {
  final text = value.trim().toLowerCase();
  return text.startsWith('audio/') &&
      RegExp(r'^[a-z0-9.+*\-/]{7,80}$').hasMatch(text);
}

const int _maxImageMediaBytes = 50 * 1024 * 1024;
const int _maxVideoMediaBytes = 4 * 1024 * 1024 * 1024;

int _maximumMediaBytes(NativeMediaKind kind) => switch (kind) {
  NativeMediaKind.image => _maxImageMediaBytes,
  NativeMediaKind.video => _maxVideoMediaBytes,
};

bool _isSupportedMediaName(String name, NativeMediaKind kind) {
  final lower = name.toLowerCase();
  return switch (kind) {
    NativeMediaKind.image =>
      lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.heic') ||
          lower.endsWith('.webp'),
    NativeMediaKind.video =>
      lower.endsWith('.mp4') ||
          lower.endsWith('.mov') ||
          lower.endsWith('.webm'),
  };
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _optionalPositiveInt(Object? value) {
  if (value is int && value > 0) return value;
  if (value is num && value.isFinite && value > 0) return value.ceil();
  return null;
}

String _stableOpaqueId(String value) {
  var hash = 0;
  for (final codeUnit in value.codeUnits) {
    hash = (hash * 31 + codeUnit) % 1000000007;
  }
  return hash.toRadixString(16);
}
