import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_recordings_port.dart';

typedef DesktopObjectUploadTransportFactory =
    ObjectUploadTransport Function(File source);

/// Uploads selected desktop audio through the same public Resource and
/// Recording APIs as mobile without allowing a local path past this boundary.
final class RemoteDesktopRecordingsPort implements DesktopRecordingsPort {
  RemoteDesktopRecordingsPort(
    ApiClient apiClient, {
    DesktopObjectUploadTransportFactory? objectUploadTransportFactory,
    DateTime Function()? now,
  }) : _apiClient = apiClient,
       _objectUploadTransportFactory = objectUploadTransportFactory,
       _now = now ?? DateTime.now;

  static const _maxRawMaterialBytes = 2 * 1024 * 1024 * 1024;

  final ApiClient _apiClient;
  final DesktopObjectUploadTransportFactory? _objectUploadTransportFactory;
  final DateTime Function() _now;

  @override
  Future<DesktopServiceResult<DesktopRecordingSubmission>> submitLocalAudio(
    DesktopLocalAudioRequest request, {
    DesktopRecordingUploadStageListener? onStage,
  }) async {
    final prepared = await _prepareRequest(request);
    if (prepared is DesktopServiceResult<DesktopRecordingSubmission>) {
      return prepared;
    }
    final source = prepared as _DesktopPreparedAudio;

    void emit(DesktopRecordingUploadStage stage) {
      try {
        onStage?.call(stage);
      } on Object {
        // Progress observers must not turn a verified upload into a failure.
      }
    }

    try {
      emit(DesktopRecordingUploadStage.hashing);
      final digest = await sha256.bind(source.file.openRead()).first;
      final hash = digest.toString();
      final actionKey = _actionKey(hash);
      final metadata = UploadMetadata(
        sourceScene: 'raw_material',
        fileName: source.fileName,
        mimeType: source.mimeType,
        sizeBytes: source.sizeBytes,
        durationSeconds: 0,
        appPrivateUri: _opaqueStreamReference(hash, source.fileName),
        sha256: hash,
        workspaceId: source.workspaceId,
      );
      final objectTransport =
          _objectUploadTransportFactory?.call(source.file) ??
          HttpObjectUploadTransport(openRead: (_) => source.file.openRead());
      final uploader = UploadClient(
        apiClient: _apiClient,
        objectTransport: objectTransport,
      );

      emit(DesktopRecordingUploadStage.requestingUpload);
      final token = await uploader.requestUploadToken(
        metadata: metadata,
        idempotencyKey: '$actionKey-token',
      );
      if (!token.ok || token.value == null) {
        return _uploadFailure(
          token.error,
          fallbackCode: 'DESKTOP_RECORDING_UPLOAD_TOKEN_FAILED',
          fallbackMessage: '无法获取音频上传凭证',
        );
      }

      emit(DesktopRecordingUploadStage.uploadingObject);
      final object = await uploader.uploadToObjectStore(
        token: token.value!,
        metadata: metadata,
      );
      if (!object.ok) {
        return _uploadFailure(
          object.error,
          fallbackCode: 'DESKTOP_RECORDING_OBJECT_UPLOAD_FAILED',
          fallbackMessage: '音频上传失败',
        );
      }

      emit(DesktopRecordingUploadStage.completingUpload);
      final completed = await uploader.completeUpload(
        uploadId: token.value!.uploadId,
        metadata: metadata,
        idempotencyKey: '$actionKey-complete',
      );
      if (!completed.ok || completed.value == null) {
        return _uploadFailure(
          completed.error,
          fallbackCode: 'DESKTOP_RECORDING_UPLOAD_COMPLETE_FAILED',
          fallbackMessage: '音频上传未完成',
        );
      }

      emit(DesktopRecordingUploadStage.creatingRecording);
      final recording = await _apiClient.request<DesktopRecordingSubmission>(
        ApiRequestOptions<DesktopRecordingSubmission>(
          endpointId: 'createRecording',
          body: <String, Object?>{
            'audioResourceId': completed.value!.resourceId,
            'title': source.title,
            'source': 'local_upload',
            'recordedAt': _now().toUtc().toIso8601String(),
          },
          idempotency: IdempotencyRequestContext(
            explicitKey: '$actionKey-recording',
          ),
          parseData: _parseSubmission,
        ),
      );
      if (!recording.ok || recording.data == null) {
        return _apiFailure(
          recording.error,
          fallbackCode: 'DESKTOP_RECORDING_CREATE_FAILED',
          fallbackMessage: '音频已上传，但无法提交转写',
        );
      }
      return DesktopServiceResult<DesktopRecordingSubmission>.success(
        recording.data!,
      );
    } on FileSystemException {
      return const DesktopServiceResult<DesktopRecordingSubmission>.failure(
        code: 'DESKTOP_RECORDING_FILE_READ_FAILED',
        message: '读取所选音频失败，请重新选择文件',
        retryable: true,
      );
    } on Object {
      return const DesktopServiceResult<DesktopRecordingSubmission>.failure(
        code: 'DESKTOP_RECORDING_UPLOAD_FAILED',
        message: '音频上传失败，请稍后重试',
        retryable: true,
      );
    }
  }

  @override
  Future<DesktopServiceResult<DesktopRecordingProgress>> loadProgress(
    String recordingId,
  ) async {
    final id = recordingId.trim();
    if (!_safeIdentifier.hasMatch(id)) {
      return const DesktopServiceResult<DesktopRecordingProgress>.failure(
        code: 'DESKTOP_RECORDING_ID_INVALID',
        message: '录音任务标识无效',
      );
    }
    final result = await _apiClient.request<DesktopRecordingProgress>(
      ApiRequestOptions<DesktopRecordingProgress>(
        endpointId: 'recordingDetail',
        pathParams: <String, Object>{'recordingId': id},
        parseData: (value) => _parseProgress(value, id),
      ),
    );
    return result.ok && result.data != null
        ? DesktopServiceResult<DesktopRecordingProgress>.success(result.data!)
        : _apiFailure(
            result.error,
            fallbackCode: 'DESKTOP_RECORDING_PROGRESS_FAILED',
            fallbackMessage: '无法读取转写进度',
          );
  }

  Future<Object> _prepareRequest(DesktopLocalAudioRequest request) async {
    final path = request.filePath.trim();
    final fileName = request.fileName.trim();
    final workspaceId = request.workspaceId.trim();
    final expectedMimeType = _audioMimeTypeForFileName(fileName);
    if (path.isEmpty ||
        !_safeFileName(fileName) ||
        !_safeIdentifier.hasMatch(workspaceId) ||
        expectedMimeType == null ||
        expectedMimeType != request.mimeType.trim().toLowerCase()) {
      return const DesktopServiceResult<DesktopRecordingSubmission>.failure(
        code: 'DESKTOP_RECORDING_FILE_INVALID',
        message: '请选择 WAV、MP3 或 M4A 音频文件',
      );
    }
    final source = File(path);
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return const DesktopServiceResult<DesktopRecordingSubmission>.failure(
        code: 'DESKTOP_RECORDING_FILE_INVALID',
        message: '所选音频不可读取',
      );
    }
    final sizeBytes = await source.length();
    if (sizeBytes <= 0 || sizeBytes > _maxRawMaterialBytes) {
      return const DesktopServiceResult<DesktopRecordingSubmission>.failure(
        code: 'DESKTOP_RECORDING_FILE_SIZE_INVALID',
        message: '所选音频大小不符合上传要求',
      );
    }
    final title = _safeTitle(request.title) ?? _displayTitle(fileName);
    return _DesktopPreparedAudio(
      file: source,
      fileName: fileName,
      mimeType: expectedMimeType,
      workspaceId: workspaceId,
      title: title,
      sizeBytes: sizeBytes,
    );
  }

  String _actionKey(String sha256) =>
      'desktop-recording-${sha256.substring(0, 20)}-${_now().toUtc().microsecondsSinceEpoch}';

  String _opaqueStreamReference(String sha256, String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    return 'app-private://desktop-recordings/${sha256.substring(0, 32)}.$extension';
  }
}

final class _DesktopPreparedAudio {
  const _DesktopPreparedAudio({
    required this.file,
    required this.fileName,
    required this.mimeType,
    required this.workspaceId,
    required this.title,
    required this.sizeBytes,
  });

  final File file;
  final String fileName;
  final String mimeType;
  final String workspaceId;
  final String title;
  final int sizeBytes;
}

DesktopRecordingSubmission? _parseSubmission(Object? value) {
  final response = asObjectMap(value);
  final recording = asObjectMap(response?['recording']) ?? response;
  final asrTask = asObjectMap(response?['asrTask']);
  final recordingId = _safeId(recording?['recordingId'] ?? recording?['id']);
  if (recordingId == null) return null;
  return DesktopRecordingSubmission(
    recordingId: recordingId,
    title: _safeTitle(recording?['title']) ?? '本地音频',
    status: _statusOf(
      asrTask?['status'] ??
          recording?['status'] ??
          recording?['transcriptStatus'],
    ),
    asrTaskId: _safeId(asrTask?['asrTaskId'] ?? asrTask?['taskId']),
  );
}

DesktopRecordingProgress? _parseProgress(Object? value, String expectedId) {
  final response = asObjectMap(value);
  final recording = asObjectMap(response?['recording']) ?? response;
  final asrTask = asObjectMap(response?['asrTask']);
  final asrResult = asObjectMap(asrTask?['result']);
  final recordingId = _safeId(recording?['recordingId'] ?? recording?['id']);
  if (recordingId != expectedId) return null;
  return DesktopRecordingProgress(
    recordingId: recordingId!,
    status: _statusOf(
      asrTask?['status'] ??
          recording?['status'] ??
          recording?['transcriptStatus'],
    ),
    progress: _progressOf(
      asrTask?['progress'] ?? asrResult?['progress'] ?? response?['progress'],
    ),
    message: _safeMessage(
      asrTask?['message'] ?? asrResult?['message'] ?? response?['message'],
    ),
  );
}

DesktopServiceResult<DesktopRecordingSubmission> _uploadFailure(
  AppFailure? failure, {
  required String fallbackCode,
  required String fallbackMessage,
}) => DesktopServiceResult<DesktopRecordingSubmission>.failure(
  code: failure?.code ?? fallbackCode,
  message: _safeMessage(failure?.message) ?? fallbackMessage,
  retryable: failure?.isRetryable ?? true,
);

DesktopServiceResult<T> _apiFailure<T>(
  AppFailure? failure, {
  required String fallbackCode,
  required String fallbackMessage,
}) => DesktopServiceResult<T>.failure(
  code: failure?.code ?? fallbackCode,
  message: _safeMessage(failure?.message) ?? fallbackMessage,
  retryable: failure?.isRetryable ?? true,
);

String? _audioMimeTypeForFileName(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) return 'audio/mp4';
  if (lower.endsWith('.wav')) return 'audio/wav';
  return null;
}

String _displayTitle(String fileName) {
  final separator = fileName.lastIndexOf('.');
  final stem = separator > 0 ? fileName.substring(0, separator) : fileName;
  return _safeTitle(stem) ?? '本地音频';
}

String _statusOf(Object? value) {
  final status = value is String ? value.trim().toLowerCase() : '';
  return RegExp(r'^[a-z][a-z_]{1,63}$').hasMatch(status) ? status : 'queued';
}

int? _progressOf(Object? value) {
  final parsed = switch (value) {
    int() => value,
    double() => value.round(),
    String() => int.tryParse(value.trim()),
    _ => null,
  };
  return parsed == null || parsed < 0 || parsed > 100 ? null : parsed;
}

String? _safeId(Object? value) =>
    value is String && _safeIdentifier.hasMatch(value) ? value : null;

String? _safeTitle(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.runes.length > 240 || text.runes.any(_isControl)) {
    return null;
  }
  return text;
}

String? _safeMessage(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.runes.length > 280 || text.runes.any(_isControl)) {
    return null;
  }
  return text;
}

bool _safeFileName(String value) {
  final text = value.trim();
  return text.isNotEmpty &&
      text.runes.length <= 120 &&
      !text.contains('/') &&
      !text.contains('\\') &&
      !text.endsWith('.part') &&
      !text.runes.any(_isControl);
}

bool _isControl(int rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f);

final _safeIdentifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
