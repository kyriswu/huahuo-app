import 'dart:async';

import 'package:flutter/services.dart';

import '../api/api_envelope.dart';
import '../../features/ingestion/domain/material_ingestion.dart';

enum ScreenCaptureState {
  unsupported,
  idle,
  starting,
  recording,
  stopping,
  importing,
  completed,
  failed,
}

final class ScreenCaptureCapability {
  const ScreenCaptureCapability({
    required this.supported,
    required this.canCaptureSystemAudio,
    required this.requiresSystemPicker,
    this.reasonCode,
  });

  final bool supported;
  final bool canCaptureSystemAudio;
  final bool requiresSystemPicker;
  final String? reasonCode;
}

final class ScreenCaptureSnapshot {
  const ScreenCaptureSnapshot({
    required this.state,
    required this.elapsedSeconds,
    this.startedAt,
    this.media,
    this.lastErrorCode,
    this.sessionId,
  });

  const ScreenCaptureSnapshot.idle()
    : state = ScreenCaptureState.idle,
      elapsedSeconds = 0,
      startedAt = null,
      media = null,
      sessionId = null,
      lastErrorCode = null;

  final ScreenCaptureState state;
  final int elapsedSeconds;
  final DateTime? startedAt;
  final CapturedMediaInput? media;
  final String? lastErrorCode;
  final String? sessionId;

  bool get isActive =>
      state == ScreenCaptureState.importing ||
      state == ScreenCaptureState.starting ||
      state == ScreenCaptureState.recording ||
      state == ScreenCaptureState.stopping;
}

final class ScreenCaptureResult<T> {
  const ScreenCaptureResult._({required this.ok, this.value, this.error});

  factory ScreenCaptureResult.success(T value) =>
      ScreenCaptureResult<T>._(ok: true, value: value, error: null);

  factory ScreenCaptureResult.failure(AppFailure error) =>
      ScreenCaptureResult<T>._(ok: false, value: null, error: error);

  final bool ok;
  final T? value;
  final AppFailure? error;
}

abstract interface class ScreenCapturePort {
  Stream<ScreenCaptureSnapshot> get events;

  Future<ScreenCaptureResult<ScreenCaptureCapability>> getCapability();

  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> refreshState();

  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> recoverSession(
    String sessionId,
  );

  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> importVideo(
    String sessionId,
  );

  Future<ScreenCaptureResult<bool>> releaseSession(String sessionId);

  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> startCapture({
    String? sessionId,
    int maxDurationSeconds = 1800,
    int maxSizeBytes = 500 * 1024 * 1024,
    int targetWidth = 720,
    int targetHeight = 1280,
  });

  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> stopCapture({
    String? expectedSessionId,
  });

  Future<ScreenCaptureResult<CapturedAudioInput>> extractAudio(
    CapturedMediaInput media,
  );
}

final class MethodChannelScreenCapturePort implements ScreenCapturePort {
  MethodChannelScreenCapturePort({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel('huahuoai/screen_capture'),
       _eventChannel =
           eventChannel ?? const EventChannel('huahuoai/screen_capture/events');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  Stream<ScreenCaptureSnapshot>? _events;

  @override
  Stream<ScreenCaptureSnapshot> get events =>
      _events ??= _eventChannel.receiveBroadcastStream().map((event) {
        final snapshot = _parseSnapshot(event);
        if (snapshot == null) {
          throw const FormatException('SCREEN_CAPTURE_STATE_MALFORMED');
        }
        return snapshot;
      });

  @override
  Future<ScreenCaptureResult<ScreenCaptureCapability>> getCapability() async {
    try {
      final raw = await _methodChannel.invokeMethod<Object?>('getCapability');
      final value = _parseCapability(raw);
      if (value == null) {
        return ScreenCaptureResult.failure(
          _failure('SCREEN_CAPTURE_CAPABILITY_MALFORMED'),
        );
      }
      return ScreenCaptureResult.success(value);
    } on PlatformException catch (error) {
      return ScreenCaptureResult.failure(_platformFailure(error));
    } catch (error) {
      return ScreenCaptureResult.failure(
        _failure('SCREEN_CAPTURE_DRIVER_UNAVAILABLE', cause: error),
      );
    }
  }

  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> refreshState() =>
      _invokeSnapshot('getState');

  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> recoverSession(
    String sessionId,
  ) => _invokeSnapshot('getSession', <String, Object>{'sessionId': sessionId});

  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> importVideo(
    String sessionId,
  ) => _invokeSnapshot('importVideo', <String, Object>{'sessionId': sessionId});

  @override
  Future<ScreenCaptureResult<bool>> releaseSession(String sessionId) async {
    try {
      final released = await _methodChannel.invokeMethod<bool>(
        'releaseSession',
        <String, Object>{'sessionId': sessionId},
      );
      return released == true
          ? ScreenCaptureResult.success(true)
          : ScreenCaptureResult.failure(
              _failure('SCREEN_CAPTURE_CLEANUP_FAILED'),
            );
    } on PlatformException catch (error) {
      return ScreenCaptureResult.failure(_platformFailure(error));
    } catch (error) {
      return ScreenCaptureResult.failure(
        _failure('SCREEN_CAPTURE_CLEANUP_FAILED', cause: error),
      );
    }
  }

  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> startCapture({
    String? sessionId,
    int maxDurationSeconds = 1800,
    int maxSizeBytes = 500 * 1024 * 1024,
    int targetWidth = 720,
    int targetHeight = 1280,
  }) {
    return _invokeSnapshot('startCapture', <String, Object>{
      if (sessionId != null) 'sessionId': sessionId,
      'maxDurationSeconds': maxDurationSeconds,
      'maxSizeBytes': maxSizeBytes,
      'targetWidth': targetWidth,
      'targetHeight': targetHeight,
    });
  }

  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> stopCapture({
    String? expectedSessionId,
  }) => _invokeSnapshot(
    'stopCapture',
    expectedSessionId == null
        ? null
        : <String, Object>{'expectedSessionId': expectedSessionId},
  );

  @override
  Future<ScreenCaptureResult<CapturedAudioInput>> extractAudio(
    CapturedMediaInput media,
  ) async {
    if (_parseMedia(<String, Object?>{
          'appPrivateUri': media.appPrivateUri,
          'fileName': media.fileName,
          'mimeType': media.mimeType,
          'sizeBytes': media.sizeBytes,
          'durationSeconds': media.durationSeconds,
          'sha256': media.sha256,
          'recordedAt': media.recordedAt.toUtc().toIso8601String(),
        }) ==
        null) {
      return ScreenCaptureResult.failure(
        _failure('SCREEN_CAPTURE_MEDIA_INVALID'),
      );
    }
    try {
      final raw = await _methodChannel.invokeMethod<Object?>(
        'extractAudio',
        <String, Object?>{'appPrivateUri': media.appPrivateUri},
      );
      final audio = _parseAudio(raw);
      if (audio == null) {
        return ScreenCaptureResult.failure(
          _failure('SCREEN_CAPTURE_AUDIO_RESULT_MALFORMED'),
        );
      }
      return ScreenCaptureResult.success(audio);
    } on PlatformException catch (error) {
      return ScreenCaptureResult.failure(_platformFailure(error));
    } catch (error) {
      return ScreenCaptureResult.failure(
        _failure('SCREEN_CAPTURE_AUDIO_DRIVER_UNAVAILABLE', cause: error),
      );
    }
  }

  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> _invokeSnapshot(
    String method, [
    Object? arguments,
  ]) async {
    try {
      final raw = await _methodChannel.invokeMethod<Object?>(method, arguments);
      final value = _parseSnapshot(raw);
      if (value == null) {
        return ScreenCaptureResult.failure(
          _failure('SCREEN_CAPTURE_STATE_MALFORMED'),
        );
      }
      return ScreenCaptureResult.success(value);
    } on PlatformException catch (error) {
      return ScreenCaptureResult.failure(_platformFailure(error));
    } catch (error) {
      return ScreenCaptureResult.failure(
        _failure('SCREEN_CAPTURE_DRIVER_UNAVAILABLE', cause: error),
      );
    }
  }
}

ScreenCaptureCapability? _parseCapability(Object? raw) {
  if (raw is! Map) return null;
  final supported = raw['supported'];
  final systemAudio = raw['canCaptureSystemAudio'];
  final systemPicker = raw['requiresSystemPicker'];
  final reason = _safeCode(raw['reasonCode']);
  if (supported is! bool || systemAudio is! bool || systemPicker is! bool) {
    return null;
  }
  if (!supported && reason == null) return null;
  return ScreenCaptureCapability(
    supported: supported,
    canCaptureSystemAudio: systemAudio,
    requiresSystemPicker: systemPicker,
    reasonCode: reason,
  );
}

ScreenCaptureSnapshot? _parseSnapshot(Object? raw) {
  if (raw is! Map) return null;
  final state = _state(raw['state']);
  if (state == null) return null;
  final sessionId = raw['sessionId'];
  if (sessionId != null &&
      (sessionId is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(sessionId))) {
    return null;
  }
  final elapsed = raw['elapsedSeconds'];
  if (elapsed is! int || elapsed < 0 || elapsed > 1800) return null;
  final startedAt = raw['startedAt'] == null
      ? null
      : DateTime.tryParse('${raw['startedAt']}')?.toUtc();
  final errorCode = _safeCode(raw['errorCode']);
  CapturedMediaInput? media;
  final mediaRaw = raw['media'];
  if (mediaRaw != null) {
    media = _parseMedia(mediaRaw);
    if (media == null) return null;
  }
  if (state == ScreenCaptureState.completed && media == null) return null;
  if (state == ScreenCaptureState.failed && errorCode == null) return null;
  if (state == ScreenCaptureState.recording && startedAt == null) return null;
  return ScreenCaptureSnapshot(
    sessionId: sessionId as String?,
    state: state,
    elapsedSeconds: elapsed,
    startedAt: startedAt,
    media: media,
    lastErrorCode: errorCode,
  );
}

CapturedMediaInput? _parseMedia(Object? raw) {
  if (raw is! Map) return null;
  final uri = raw['appPrivateUri'];
  final fileName = raw['fileName'];
  final mimeType = raw['mimeType'];
  final size = raw['sizeBytes'];
  final duration = raw['durationSeconds'];
  final sha256 = raw['sha256'];
  final recordedAt = DateTime.tryParse('${raw['recordedAt'] ?? ''}')?.toUtc();
  if (uri is! String ||
      !RegExp(
        r'^app-private-media://screen-capture/[A-Za-z0-9][A-Za-z0-9._-]*\.mp4$',
      ).hasMatch(uri) ||
      fileName is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.mp4$').hasMatch(fileName) ||
      mimeType != 'video/mp4' ||
      size is! int ||
      size <= 0 ||
      size > 500 * 1024 * 1024 ||
      duration is! int ||
      duration <= 0 ||
      duration > 1800 ||
      sha256 is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
      recordedAt == null) {
    return null;
  }
  return CapturedMediaInput(
    appPrivateUri: uri,
    fileName: fileName,
    mimeType: mimeType,
    sizeBytes: size,
    durationSeconds: duration,
    sha256: sha256,
    recordedAt: recordedAt,
  );
}

CapturedAudioInput? _parseAudio(Object? raw) {
  if (raw is! Map) return null;
  final uri = raw['appPrivateUri'];
  final fileName = raw['fileName'];
  final mimeType = raw['mimeType'];
  final size = raw['sizeBytes'];
  final duration = raw['durationSeconds'];
  final hash = raw['sha256'];
  final recordedAt = DateTime.tryParse('${raw['recordedAt'] ?? ''}')?.toUtc();
  if (uri is! String ||
      !RegExp(
        r'^app-private-media://screen-capture/[A-Za-z0-9][A-Za-z0-9._-]*\.m4a$',
      ).hasMatch(uri) ||
      fileName is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.m4a$').hasMatch(fileName) ||
      mimeType != 'audio/mp4' ||
      size is! int ||
      size <= 0 ||
      size > 500 * 1024 * 1024 ||
      duration is! int ||
      duration <= 0 ||
      duration > 1800 ||
      hash is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
      recordedAt == null) {
    return null;
  }
  return CapturedAudioInput(
    appPrivateUri: uri,
    fileName: fileName,
    mimeType: mimeType,
    sizeBytes: size,
    durationSeconds: duration,
    sha256: hash,
    recordedAt: recordedAt,
  );
}

ScreenCaptureState? _state(Object? raw) => switch (raw) {
  'unsupported' => ScreenCaptureState.unsupported,
  'idle' => ScreenCaptureState.idle,
  'starting' => ScreenCaptureState.starting,
  'recording' => ScreenCaptureState.recording,
  'stopping' => ScreenCaptureState.stopping,
  'importing' => ScreenCaptureState.importing,
  'completed' => ScreenCaptureState.completed,
  'failed' => ScreenCaptureState.failed,
  _ => null,
};

String? _safeCode(Object? raw) {
  if (raw is! String || raw.isEmpty || raw.length > 80) return null;
  return RegExp(r'^[A-Z0-9_]+$').hasMatch(raw) ? raw : null;
}

AppFailure _platformFailure(PlatformException error) => _failure(
  _safeCode(error.code) ?? 'SCREEN_CAPTURE_PLATFORM_FAILED',
  cause: error,
);

AppFailure _failure(String code, {Object? cause}) => AppFailure(
  code: code,
  category: code.contains('PERMISSION')
      ? AppFailureCategory.permission
      : code.contains('STORAGE')
      ? AppFailureCategory.storage
      : AppFailureCategory.compatibility,
  message: 'Screen capture operation failed',
  userMessageKey: 'screenCapture.error.$code',
  isRetryable: !code.contains('UNSUPPORTED'),
  recoveryActions: !code.contains('UNSUPPORTED')
      ? const <String>['retry']
      : const <String>['none'],
  cause: cause,
);
