import 'dart:async';

import 'package:flutter/services.dart';

import '../api/api_envelope.dart';
import '../storage/private_recording_path_resolver.dart';

enum VoiceRecordingScene {
  workAi('work_ai'),
  feedAi('feed_ai'),
  monologue('monologue'),
  internal('internal'),
  meeting('meeting'),
  voiceprint('voiceprint');

  const VoiceRecordingScene(this.wireName);

  final String wireName;

  static VoiceRecordingScene? tryParse(Object? value) {
    for (final scene in VoiceRecordingScene.values) {
      if (scene.wireName == value) return scene;
    }
    return null;
  }
}

enum VoiceRecorderPermissionState {
  granted('granted'),
  denied('denied'),
  blocked('blocked'),
  notDetermined('not_determined'),
  unavailable('unavailable');

  const VoiceRecorderPermissionState(this.wireName);

  final String wireName;

  static VoiceRecorderPermissionState? tryParse(Object? value) {
    for (final state in VoiceRecorderPermissionState.values) {
      if (state.wireName == value) return state;
    }
    return null;
  }
}

enum VoiceRecorderState {
  idle('idle'),
  recording('recording'),
  paused('paused'),
  failed('failed');

  const VoiceRecorderState(this.wireName);

  final String wireName;

  static VoiceRecorderState? tryParse(Object? value) {
    for (final state in VoiceRecorderState.values) {
      if (state.wireName == value) return state;
    }
    return null;
  }
}

final class VoiceRecorderResult<T> {
  const VoiceRecorderResult._({required this.ok, this.value, this.error});

  factory VoiceRecorderResult.success(T value) {
    return VoiceRecorderResult<T>._(ok: true, value: value);
  }

  factory VoiceRecorderResult.failure(AppFailure error) {
    return VoiceRecorderResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

final class VoiceRecorderPermission {
  const VoiceRecorderPermission({
    required this.state,
    required this.canAskAgain,
  });

  final VoiceRecorderPermissionState state;
  final bool canAskAgain;

  bool get granted => state == VoiceRecorderPermissionState.granted;
}

final class VoiceRecordingSession {
  const VoiceRecordingSession({
    required this.recordingId,
    required this.scene,
    required this.state,
    required this.startedAt,
    this.elapsedSeconds = 0,
  });

  final String recordingId;
  final VoiceRecordingScene scene;
  final VoiceRecorderState state;
  final DateTime startedAt;
  final int elapsedSeconds;
}

final class VoiceRecordingDraft {
  const VoiceRecordingDraft({
    required this.recordingId,
    required this.appPrivateUri,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.sha256,
    this.scene,
    this.sampleRateHz,
    this.bitDepth,
    this.channelCount,
    this.recordedAt,
  });

  final String recordingId;
  final String appPrivateUri;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int durationSeconds;
  final String sha256;
  final VoiceRecordingScene? scene;
  final int? sampleRateHz;
  final int? bitDepth;
  final int? channelCount;
  final DateTime? recordedAt;
}

const voiceprintWavSampleRateHz = 16000;
const voiceprintWavBitDepth = 16;
const voiceprintWavChannelCount = 1;
const voiceprintWavMinimumSeconds = 10;
const voiceprintWavMaximumSeconds = voiceprintWavMinimumSeconds;
const voiceprintWavMaximumReportedSeconds = voiceprintWavMaximumSeconds + 1;
const voiceprintWavMaximumBytes = 2 * 1024 * 1024;
const voiceRecorderPcm16FrameBytes = 1280;
const voiceRecorderPcm16EarlyBufferOverflowCode =
    'LIVE_ASR_PCM_EARLY_BUFFER_OVERFLOW';
const voiceRecorderSessionMismatchCode = 'VOICE_RECORDER_SESSION_MISMATCH';

final class VoiceRecorderPcm16StreamFailure implements Exception {
  const VoiceRecorderPcm16StreamFailure({
    required this.code,
    required this.droppedFrames,
    required this.capacityFrames,
  });

  final String code;
  final int droppedFrames;
  final int capacityFrames;

  @override
  String toString() => code;
}

final class VoiceLevelSample {
  const VoiceLevelSample({
    required this.capturedAt,
    required this.average,
    required this.peak,
  });

  final DateTime capturedAt;
  final double average;
  final double peak;
}

final class VoiceRecorderSnapshot {
  const VoiceRecorderSnapshot({
    required this.state,
    this.microphonePermission,
    this.session,
    this.latestLevel,
    this.lastErrorCode,
  });

  const VoiceRecorderSnapshot.idle()
    : state = VoiceRecorderState.idle,
      microphonePermission = null,
      session = null,
      latestLevel = null,
      lastErrorCode = null;

  final VoiceRecorderState state;
  final VoiceRecorderPermission? microphonePermission;
  final VoiceRecordingSession? session;
  final VoiceLevelSample? latestLevel;
  final String? lastErrorCode;

  VoiceRecorderSnapshot copyWith({
    VoiceRecorderState? state,
    VoiceRecorderPermission? microphonePermission,
    VoiceRecordingSession? session,
    VoiceLevelSample? latestLevel,
    String? lastErrorCode,
    bool clearSession = false,
    bool clearLevel = false,
    bool clearErrorCode = false,
  }) {
    return VoiceRecorderSnapshot(
      state: state ?? this.state,
      microphonePermission: microphonePermission ?? this.microphonePermission,
      session: clearSession ? null : session ?? this.session,
      latestLevel: clearLevel ? null : latestLevel ?? this.latestLevel,
      lastErrorCode: clearErrorCode
          ? null
          : lastErrorCode ?? this.lastErrorCode,
    );
  }
}

abstract interface class VoiceRecorderPort {
  VoiceRecorderSnapshot get snapshot;

  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission();

  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission();

  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState();

  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  });

  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording();

  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording();

  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording();

  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording();
}

abstract interface class VoiceRecorderOwnedSessionControl {
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  });

  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  });

  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  });

  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  });
}

abstract interface class VoiceRecorderLevelSource {
  Stream<VoiceLevelSample> get levelSamples;
}

abstract interface class VoiceRecorderPcm16Source {
  Stream<Uint8List> get pcm16Frames;
}

extension VoiceRecorderOwnedSessionOperations on VoiceRecorderPort {
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  }) {
    final recorder = this;
    if (recorder is VoiceRecorderOwnedSessionControl) {
      return (recorder as VoiceRecorderOwnedSessionControl).pauseOwnedRecording(
        expectedScene: expectedScene,
        expectedRecordingId: expectedRecordingId,
      );
    }
    if (!_matchesOwnedSession(
      recorder.snapshot,
      expectedScene: expectedScene,
      expectedRecordingId: expectedRecordingId,
    )) {
      return Future.value(_ownedSessionMismatch());
    }
    return recorder.pauseRecording();
  }

  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  }) {
    final recorder = this;
    if (recorder is VoiceRecorderOwnedSessionControl) {
      return (recorder as VoiceRecorderOwnedSessionControl)
          .resumeOwnedRecording(
            expectedScene: expectedScene,
            expectedRecordingId: expectedRecordingId,
          );
    }
    if (!_matchesOwnedSession(
      recorder.snapshot,
      expectedScene: expectedScene,
      expectedRecordingId: expectedRecordingId,
    )) {
      return Future.value(_ownedSessionMismatch());
    }
    return recorder.resumeRecording();
  }

  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  }) {
    final recorder = this;
    if (recorder is VoiceRecorderOwnedSessionControl) {
      return (recorder as VoiceRecorderOwnedSessionControl).stopOwnedRecording(
        expectedScene: expectedScene,
        expectedRecordingId: expectedRecordingId,
      );
    }
    if (!_matchesOwnedSession(
      recorder.snapshot,
      expectedScene: expectedScene,
      expectedRecordingId: expectedRecordingId,
    )) {
      return Future.value(_ownedSessionMismatch());
    }
    return recorder.stopRecording();
  }

  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  }) {
    final recorder = this;
    if (recorder is VoiceRecorderOwnedSessionControl) {
      return (recorder as VoiceRecorderOwnedSessionControl)
          .cancelOwnedRecording(
            expectedScene: expectedScene,
            expectedRecordingId: expectedRecordingId,
          );
    }
    if (!_matchesOwnedSession(
      recorder.snapshot,
      expectedScene: expectedScene,
      expectedRecordingId: expectedRecordingId,
    )) {
      return Future.value(_ownedSessionMismatch());
    }
    return recorder.cancelRecording();
  }
}

extension VoiceRecorderLevelSamples on VoiceRecorderPort {
  Stream<VoiceLevelSample> get levelSamples {
    final recorder = this;
    return recorder is VoiceRecorderLevelSource
        ? (recorder as VoiceRecorderLevelSource).levelSamples
        : const Stream.empty();
  }
}

extension VoiceRecorderPcm16Frames on VoiceRecorderPort {
  Stream<Uint8List> get pcm16Frames {
    final recorder = this;
    return recorder is VoiceRecorderPcm16Source
        ? (recorder as VoiceRecorderPcm16Source).pcm16Frames
        : const Stream<Uint8List>.empty();
  }
}

final class MethodChannelVoiceRecorderPort
    implements
        VoiceRecorderPort,
        VoiceRecorderOwnedSessionControl,
        VoiceRecorderLevelSource,
        VoiceRecorderPcm16Source {
  MethodChannelVoiceRecorderPort({
    MethodChannel channel = const MethodChannel(_channelName),
    EventChannel levelChannel = const EventChannel(_levelChannelName),
    EventChannel pcm16Channel = const EventChannel(_pcm16ChannelName),
    String? Function()? nativeRecorderDirectoryScope,
  }) : _channel = channel,
       _levelChannel = levelChannel,
       _pcm16Channel = pcm16Channel,
       _nativeRecorderDirectoryScope = nativeRecorderDirectoryScope;

  static const _channelName = 'huahuoai/voice_recorder';
  static const _levelChannelName = 'huahuoai/voice_recorder_levels';
  static const _pcm16ChannelName = 'huahuoai/voice_recorder_pcm16';

  final MethodChannel _channel;
  final EventChannel _levelChannel;
  final EventChannel _pcm16Channel;
  final String? Function()? _nativeRecorderDirectoryScope;
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();
  Stream<VoiceLevelSample>? _levelSamples;
  Stream<Uint8List>? _pcm16Frames;

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Stream<VoiceLevelSample> get levelSamples =>
      _levelSamples ??= _levelChannel.receiveBroadcastStream().transform(
        StreamTransformer<Object?, VoiceLevelSample>.fromHandlers(
          handleData: (raw, sink) {
            final sample = parseVoiceLevelSample(raw);
            if (sample == null) return;
            _snapshot = _snapshot.copyWith(latestLevel: sample);
            sink.add(sample);
          },
          handleError: (error, stackTrace, sink) {
            // Metering is optional feedback and must not terminate capture.
          },
        ),
      );

  @override
  Stream<Uint8List> get pcm16Frames =>
      _pcm16Frames ??= _pcm16Channel.receiveBroadcastStream().transform(
        StreamTransformer<Object?, Uint8List>.fromHandlers(
          handleData: (raw, sink) {
            final frame = parseVoiceRecorderPcm16Frame(raw);
            if (frame == null) {
              sink.addError(StateError('VOICE_RECORDER_PCM16_FRAME_INVALID'));
              return;
            }
            sink.add(frame);
          },
          handleError: (error, stackTrace, sink) {
            final failure = parseVoiceRecorderPcm16StreamFailure(error);
            sink.addError(failure ?? error, stackTrace);
          },
        ),
      );

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() {
    return _invoke<VoiceRecorderPermission>(
      'getMicrophonePermission',
      parse: parseVoiceRecorderPermission,
      onSuccess: (permission) {
        _snapshot = _snapshot.copyWith(microphonePermission: permission);
      },
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() {
    return _invoke<VoiceRecorderPermission>(
      'requestMicrophonePermission',
      parse: parseVoiceRecorderPermission,
      onSuccess: (permission) {
        _snapshot = _snapshot.copyWith(microphonePermission: permission);
      },
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() {
    return _invoke<VoiceRecorderSnapshot>(
      'getRecordingState',
      parse: parseVoiceRecorderSnapshot,
      onSuccess: _setSnapshot,
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) {
    final directoryScope = _safeNativeDirectoryScope(
      _nativeRecorderDirectoryScope?.call(),
    );
    return _invoke<VoiceRecordingSession>(
      'startRecording',
      arguments: <String, Object?>{
        'scene': scene.wireName,
        if (directoryScope != null) 'accountDirectory': directoryScope,
      },
      parse: parseVoiceRecordingSession,
      onSuccess: (session) {
        _setSnapshot(
          VoiceRecorderSnapshot(
            state: session.state,
            microphonePermission: _snapshot.microphonePermission,
            session: session,
          ),
        );
      },
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() {
    return _invoke<VoiceRecorderSnapshot>(
      'pauseRecording',
      parse: parseVoiceRecorderSnapshot,
      onSuccess: _setSnapshot,
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() {
    return _invoke<VoiceRecorderSnapshot>(
      'resumeRecording',
      parse: parseVoiceRecorderSnapshot,
      onSuccess: _setSnapshot,
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() {
    final expectedScene = _snapshot.session?.scene;
    return _invoke<VoiceRecordingDraft>(
      'stopRecording',
      parse: (value) {
        final draft = parseVoiceRecordingDraft(value);
        if (draft == null ||
            (expectedScene != null && draft.scene != expectedScene)) {
          return null;
        }
        return draft;
      },
      onSuccess: (draft) {
        _setSnapshot(
          VoiceRecorderSnapshot(
            state: VoiceRecorderState.idle,
            microphonePermission: _snapshot.microphonePermission,
          ),
        );
      },
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() {
    return _invoke<VoiceRecorderSnapshot>(
      'cancelRecording',
      parse: parseVoiceRecorderSnapshot,
      onSuccess: _setSnapshot,
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  }) {
    return _invoke<VoiceRecorderSnapshot>(
      'pauseRecording',
      arguments: _ownedSessionArguments(
        expectedScene: expectedScene,
        expectedRecordingId: expectedRecordingId,
      ),
      parse: (value) => _parseOwnedSnapshot(
        value,
        expectedScene: expectedScene,
        expectedRecordingId: expectedRecordingId,
      ),
      onSuccess: _setSnapshot,
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  }) {
    return _invoke<VoiceRecorderSnapshot>(
      'resumeRecording',
      arguments: _ownedSessionArguments(
        expectedScene: expectedScene,
        expectedRecordingId: expectedRecordingId,
      ),
      parse: (value) => _parseOwnedSnapshot(
        value,
        expectedScene: expectedScene,
        expectedRecordingId: expectedRecordingId,
      ),
      onSuccess: _setSnapshot,
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  }) {
    return _invoke<VoiceRecordingDraft>(
      'stopRecording',
      arguments: _ownedSessionArguments(
        expectedScene: expectedScene,
        expectedRecordingId: expectedRecordingId,
      ),
      parse: (value) {
        final draft = parseVoiceRecordingDraft(value);
        return draft?.scene == expectedScene &&
                draft?.recordingId == expectedRecordingId
            ? draft
            : null;
      },
      onSuccess: (draft) {
        _setSnapshot(
          VoiceRecorderSnapshot(
            state: VoiceRecorderState.idle,
            microphonePermission: _snapshot.microphonePermission,
          ),
        );
      },
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelOwnedRecording({
    required VoiceRecordingScene expectedScene,
    required String expectedRecordingId,
  }) {
    return _invoke<VoiceRecorderSnapshot>(
      'cancelRecording',
      arguments: _ownedSessionArguments(
        expectedScene: expectedScene,
        expectedRecordingId: expectedRecordingId,
      ),
      parse: (value) {
        final snapshot = parseVoiceRecorderSnapshot(value);
        return snapshot?.state == VoiceRecorderState.idle &&
                snapshot?.session == null
            ? snapshot
            : null;
      },
      onSuccess: _setSnapshot,
    );
  }

  Future<VoiceRecorderResult<T>> _invoke<T>(
    String method, {
    Object? arguments,
    required T? Function(Object? value) parse,
    void Function(T value)? onSuccess,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(method, arguments);
      final parsed = parse(raw);
      if (parsed == null) {
        return _failure<T>('NATIVE_VOICE_RECORDER_MALFORMED_PAYLOAD');
      }
      onSuccess?.call(parsed);
      return VoiceRecorderResult<T>.success(parsed);
    } on MissingPluginException catch (error) {
      return _failure<T>(
        'NATIVE_VOICE_RECORDER_DRIVER_UNAVAILABLE',
        cause: error,
      );
    } on PlatformException catch (error) {
      final code =
          _safeFailureCode(error.code) ?? 'VOICE_RECORDER_METHOD_FAILED';
      return _failure<T>(code, cause: error);
    } catch (error) {
      return _failure<T>('VOICE_RECORDER_METHOD_FAILED', cause: error);
    }
  }

  VoiceRecorderResult<T> _failure<T>(String code, {Object? cause}) {
    _snapshot = _snapshot.copyWith(
      state: VoiceRecorderState.failed,
      lastErrorCode: code,
      clearLevel: true,
    );
    return VoiceRecorderResult<T>.failure(
      voiceRecorderFailure(code, cause: cause),
    );
  }

  void _setSnapshot(VoiceRecorderSnapshot value) {
    final captureActive =
        value.state == VoiceRecorderState.recording ||
        value.state == VoiceRecorderState.paused;
    final latestLevel = captureActive
        ? value.latestLevel ?? _snapshot.latestLevel
        : null;
    _snapshot = value.copyWith(
      latestLevel: latestLevel,
      clearLevel: latestLevel == null,
    );
  }
}

String? _safeNativeDirectoryScope(String? value) {
  final candidate = value?.trim();
  if (candidate == null || candidate.isEmpty) return null;
  return RegExp(r'^u-[a-f0-9]{32}$').hasMatch(candidate) ? candidate : null;
}

Map<String, Object?> _ownedSessionArguments({
  required VoiceRecordingScene expectedScene,
  required String expectedRecordingId,
}) {
  return <String, Object?>{
    'expectedScene': expectedScene.wireName,
    'expectedRecordingId': expectedRecordingId,
  };
}

VoiceRecorderSnapshot? _parseOwnedSnapshot(
  Object? value, {
  required VoiceRecordingScene expectedScene,
  required String expectedRecordingId,
}) {
  final snapshot = parseVoiceRecorderSnapshot(value);
  return snapshot != null &&
          _matchesOwnedSession(
            snapshot,
            expectedScene: expectedScene,
            expectedRecordingId: expectedRecordingId,
          )
      ? snapshot
      : null;
}

bool _matchesOwnedSession(
  VoiceRecorderSnapshot snapshot, {
  required VoiceRecordingScene expectedScene,
  required String expectedRecordingId,
}) {
  final session = snapshot.session;
  return session != null &&
      session.scene == expectedScene &&
      session.recordingId == expectedRecordingId;
}

VoiceRecorderResult<T> _ownedSessionMismatch<T>() {
  return VoiceRecorderResult<T>.failure(
    voiceRecorderFailure(voiceRecorderSessionMismatchCode),
  );
}

final class UnavailableVoiceRecorderPort
    implements VoiceRecorderPort, VoiceRecorderLevelSource {
  const UnavailableVoiceRecorderPort();

  @override
  VoiceRecorderSnapshot get snapshot => const VoiceRecorderSnapshot(
    state: VoiceRecorderState.failed,
    lastErrorCode: 'NATIVE_VOICE_RECORDER_DRIVER_UNAVAILABLE',
  );

  @override
  Stream<VoiceLevelSample> get levelSamples => const Stream.empty();

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async =>
      _unavailable();

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async => _unavailable();

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async =>
      _unavailable();

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async =>
      _unavailable();

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() async => _unavailable();

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async =>
      _unavailable();

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async => _unavailable();

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() async =>
      _unavailable();
}

VoiceRecorderPermission? parseVoiceRecorderPermission(Object? value) {
  final object = _asStringMap(value);
  if (object == null) return null;
  final state = VoiceRecorderPermissionState.tryParse(
    object['state'] ?? object['status'],
  );
  final canAskAgain = object['canAskAgain'];
  if (state == null || canAskAgain is! bool) return null;
  return VoiceRecorderPermission(state: state, canAskAgain: canAskAgain);
}

VoiceRecordingSession? parseVoiceRecordingSession(Object? value) {
  final object = _asStringMap(value);
  if (object == null) return null;
  final recordingId = _safeIdentifier(object['recordingId']);
  final scene = VoiceRecordingScene.tryParse(object['scene']);
  final state = VoiceRecorderState.tryParse(object['state']);
  final startedAt = _safeDate(object['startedAt']);
  if (recordingId == null ||
      scene == null ||
      state == null ||
      (state != VoiceRecorderState.recording &&
          state != VoiceRecorderState.paused) ||
      startedAt == null) {
    return null;
  }
  return VoiceRecordingSession(
    recordingId: recordingId,
    scene: scene,
    state: state,
    startedAt: startedAt,
    elapsedSeconds: _nonNegativeInt(object['elapsedSeconds']) ?? 0,
  );
}

VoiceRecorderSnapshot? parseVoiceRecorderSnapshot(Object? value) {
  final object = _asStringMap(value);
  if (object == null) return null;
  final state = VoiceRecorderState.tryParse(object['state']);
  if (state == null) return null;
  final rawPermission = object['microphonePermission'];
  final microphonePermission = rawPermission == null
      ? null
      : parseVoiceRecorderPermission(rawPermission);
  if (rawPermission != null && microphonePermission == null) return null;
  final session =
      state == VoiceRecorderState.recording ||
          state == VoiceRecorderState.paused
      ? parseVoiceRecordingSession(object)
      : null;
  if ((state == VoiceRecorderState.recording ||
          state == VoiceRecorderState.paused) &&
      session == null) {
    return null;
  }
  return VoiceRecorderSnapshot(
    state: state,
    microphonePermission: microphonePermission,
    session: session,
    lastErrorCode: _safeFailureCode(object['lastErrorCode']),
  );
}

VoiceRecordingDraft? parseVoiceRecordingDraft(Object? value) {
  final object = _asStringMap(value);
  if (object == null) return null;
  final recordingId = _safeIdentifier(object['recordingId']);
  final scene = VoiceRecordingScene.tryParse(object['scene']);
  if (scene == null) return null;
  final appPrivateUri = _safeAppPrivateVoiceUri(
    object['appPrivateUri'],
    scene: scene,
  );
  final fileName = _safeFileName(object['fileName'], scene: scene);
  final mimeType = _safeVoiceMimeType(object['mimeType'], scene: scene);
  final sizeBytes = _positiveInt(object['sizeBytes']);
  final durationSeconds = _positiveInt(object['durationSeconds']);
  final sha256 = _safeSha256(object['sha256']);
  final sampleRateHz = _positiveInt(object['sampleRateHz']);
  final bitDepth = _positiveInt(object['bitDepth']);
  final channelCount = _positiveInt(object['channelCount']);
  if (recordingId == null ||
      !_isSafePrivateLibraryId(recordingId) ||
      appPrivateUri == null ||
      fileName == null ||
      mimeType == null ||
      sizeBytes == null ||
      durationSeconds == null ||
      sha256 == null ||
      !_matchesLibraryRecordingUri(appPrivateUri, recordingId, fileName)) {
    return null;
  }
  if (_usesPcmWav(scene)) {
    if ((scene == VoiceRecordingScene.voiceprint &&
            (sizeBytes > voiceprintWavMaximumBytes ||
                durationSeconds > voiceprintWavMaximumReportedSeconds)) ||
        sampleRateHz != voiceprintWavSampleRateHz ||
        bitDepth != voiceprintWavBitDepth ||
        channelCount != voiceprintWavChannelCount) {
      return null;
    }
  } else if (sampleRateHz != null || bitDepth != null || channelCount != null) {
    return null;
  }
  return VoiceRecordingDraft(
    recordingId: recordingId,
    appPrivateUri: appPrivateUri,
    fileName: fileName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    durationSeconds: durationSeconds,
    sha256: sha256,
    scene: scene,
    sampleRateHz: sampleRateHz,
    bitDepth: bitDepth,
    channelCount: channelCount,
    recordedAt: _safeDate(object['recordedAt']),
  );
}

VoiceLevelSample? parseVoiceLevelSample(Object? value) {
  final object = _asStringMap(value);
  if (object == null) return null;
  final capturedAt = _safeDate(object['capturedAt']);
  final average = _normalizedLevel(object['average']);
  final peak = _normalizedLevel(object['peak']);
  if (capturedAt == null || average == null || peak == null) return null;
  return VoiceLevelSample(
    capturedAt: capturedAt,
    average: average,
    peak: peak < average ? average : peak,
  );
}

Uint8List? parseVoiceRecorderPcm16Frame(Object? value) {
  if (value is! Uint8List || value.length != voiceRecorderPcm16FrameBytes) {
    return null;
  }
  return Uint8List.fromList(value);
}

VoiceRecorderPcm16StreamFailure? parseVoiceRecorderPcm16StreamFailure(
  Object? value,
) {
  if (value is! PlatformException ||
      value.code != voiceRecorderPcm16EarlyBufferOverflowCode) {
    return null;
  }
  final details = _asStringMap(value.details);
  final droppedFrames = _positiveInt(details?['droppedFrames']);
  final capacityFrames = _positiveInt(details?['capacityFrames']);
  if (droppedFrames == null ||
      capacityFrames == null ||
      droppedFrames <= capacityFrames) {
    return null;
  }
  return VoiceRecorderPcm16StreamFailure(
    code: value.code,
    droppedFrames: droppedFrames,
    capacityFrames: capacityFrames,
  );
}

AppFailure voiceRecorderFailure(String code, {Object? cause}) {
  final isPermission =
      code.contains('PERMISSION') || code.contains('MICROPHONE');
  final retryable =
      !code.contains('UNAVAILABLE') &&
      !code.contains('DENIED') &&
      !code.contains('BLOCKED') &&
      !code.contains('BUSY') &&
      !code.contains('NOT_ACTIVE') &&
      !code.contains('SESSION_MISMATCH') &&
      !code.contains('PAUSE_UNSUPPORTED');
  return AppFailure(
    code: code,
    category: isPermission
        ? AppFailureCategory.permission
        : AppFailureCategory.storage,
    message: 'Voice recorder operation failed',
    userMessageKey: 'voiceRecorder.error.$code',
    isRetryable: retryable,
    recoveryActions: retryable
        ? const <String>['retry']
        : const <String>['none'],
    cause: cause,
  );
}

Map<String, Object?>? _asStringMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

String? _safeIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(text)) {
    return null;
  }
  return text;
}

String? _safeFailureCode(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(text)
      ? text
      : null;
}

String? _safeFileName(Object? value, {required VoiceRecordingScene scene}) {
  final text = value is String ? value.trim() : null;
  final extension = _usesPcmWav(scene) ? 'wav' : 'm4a';
  return text != null &&
          text.length <= 160 &&
          RegExp(
            '^[A-Za-z0-9._-]+\\.$extension\$',
            caseSensitive: false,
          ).hasMatch(text) &&
          !text.contains('..')
      ? text
      : null;
}

String? _safeVoiceMimeType(
  Object? value, {
  required VoiceRecordingScene scene,
}) {
  if (_usesPcmWav(scene)) {
    return value == 'audio/wav' || value == 'audio/x-wav' ? 'audio/wav' : null;
  }
  switch (value) {
    case 'audio/mp4':
    case 'audio/m4a':
    case 'audio/x-m4a':
      return 'audio/mp4';
    default:
      return null;
  }
}

String? _safeSha256(Object? value) {
  final text = value is String ? value.trim().toLowerCase() : null;
  return text != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(text) ? text : null;
}

String? _safeAppPrivateVoiceUri(
  Object? value, {
  required VoiceRecordingScene scene,
}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.length > 300) return null;
  final reference = PrivateRecordingPathResolver().parse(text);
  final extension = _usesPcmWav(scene) ? '.wav' : '.m4a';
  if (reference == null ||
      reference.kind != PrivateRecordingReferenceKind.localRecording ||
      !reference.fileName.toLowerCase().endsWith(extension)) {
    return null;
  }
  return text;
}

bool _usesPcmWav(VoiceRecordingScene scene) =>
    scene == VoiceRecordingScene.voiceprint ||
    scene == VoiceRecordingScene.monologue ||
    scene == VoiceRecordingScene.meeting;

bool _matchesLibraryRecordingUri(
  String appPrivateUri,
  String recordingId,
  String fileName,
) {
  final reference = PrivateRecordingPathResolver().parse(appPrivateUri);
  return reference != null &&
      reference.kind == PrivateRecordingReferenceKind.localRecording &&
      reference.fileName == fileName &&
      fileName.startsWith(recordingId);
}

bool _isSafePrivateLibraryId(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value);
}

int? _positiveInt(Object? value) {
  if (value is! num ||
      !value.isFinite ||
      value <= 0 ||
      value != value.roundToDouble()) {
    return null;
  }
  final result = value.toInt();
  return result <= 2 * 1024 * 1024 * 1024 ? result : null;
}

int? _nonNegativeInt(Object? value) {
  if (value is! num ||
      !value.isFinite ||
      value < 0 ||
      value != value.roundToDouble()) {
    return null;
  }
  final result = value.toInt();
  return result <= 24 * 60 * 60 ? result : null;
}

double? _normalizedLevel(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final level = value.toDouble();
  return level >= 0 && level <= 1 ? level : null;
}

DateTime? _safeDate(Object? value) {
  final text = value is String ? value.trim() : null;
  return text == null ? null : DateTime.tryParse(text)?.toUtc();
}

VoiceRecorderResult<T> _unavailable<T>() {
  return VoiceRecorderResult<T>.failure(
    voiceRecorderFailure('NATIVE_VOICE_RECORDER_DRIVER_UNAVAILABLE'),
  );
}
