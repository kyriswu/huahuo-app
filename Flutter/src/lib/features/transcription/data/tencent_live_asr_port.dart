import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../domain/live_transcript.dart';
import 'live_transcription_api.dart';

const tencentLiveAsrMethodChannelName = 'huahuoai/tencent_live_asr';
const tencentLiveAsrEventChannelName = 'huahuoai/tencent_live_asr/events';

final class LiveAsrOperationResult {
  const LiveAsrOperationResult._({
    required this.ok,
    required this.unavailable,
    this.errorCode,
  });

  const LiveAsrOperationResult.success() : this._(ok: true, unavailable: false);

  const LiveAsrOperationResult.failure(String errorCode)
    : this._(ok: false, unavailable: false, errorCode: errorCode);

  const LiveAsrOperationResult.sdkUnavailable()
    : this._(
        ok: false,
        unavailable: true,
        errorCode: 'TENCENT_LIVE_ASR_SDK_UNAVAILABLE',
      );

  final bool ok;
  final bool unavailable;
  final String? errorCode;
}

abstract interface class TencentLiveAsrPort {
  Stream<LiveTranscriptSentence> get events;

  Future<LiveAsrOperationResult> connect(LiveAsrSessionCredential credential);

  Future<LiveAsrOperationResult> stop();

  Future<LiveAsrOperationResult> release();
}

abstract interface class LiveSpeakerIdentitySource {
  Stream<LiveSpeakerIdentity> get speakerIdentities;
}

extension TencentLiveAsrIdentityEvents on TencentLiveAsrPort {
  Stream<LiveSpeakerIdentity> get identityEvents {
    final source = this;
    return source is LiveSpeakerIdentitySource
        ? (source as LiveSpeakerIdentitySource).speakerIdentities
        : const Stream<LiveSpeakerIdentity>.empty();
  }
}

/// Native transport seam. The default implementation binds Flutter's method
/// and event channels; tests supply an in-memory implementation.
abstract interface class TencentLiveAsrNativeBridge {
  Stream<Object?> get events;

  Future<void> start(Map<String, Object> arguments);

  Future<void> stop();

  Future<void> release();
}

final class MethodChannelTencentLiveAsrNativeBridge
    implements TencentLiveAsrNativeBridge {
  MethodChannelTencentLiveAsrNativeBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel =
           methodChannel ??
           const MethodChannel(tencentLiveAsrMethodChannelName),
       _eventChannel =
           eventChannel ?? const EventChannel(tencentLiveAsrEventChannelName);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  @override
  Stream<Object?> get events => _eventChannel.receiveBroadcastStream();

  @override
  Future<void> start(Map<String, Object> arguments) async {
    await _methodChannel.invokeMethod<void>('start', arguments);
  }

  @override
  Future<void> stop() async {
    await _methodChannel.invokeMethod<void>('stop');
  }

  @override
  Future<void> release() async {
    await _methodChannel.invokeMethod<void>('release');
  }
}

/// Direct official Tencent mobile SDK adapter.
///
/// The native recorder owns microphone capture. Tencent consumes that shared
/// platform-local PCM stream; this adapter neither opens a Huahuo WebSocket nor
/// forwards PCM frames through Dart. Native `start` resolves only after the SDK
/// has confirmed its provider-ready callback.
final class MethodChannelTencentLiveAsrPort
    implements TencentLiveAsrPort, LiveSpeakerIdentitySource {
  MethodChannelTencentLiveAsrPort({TencentLiveAsrNativeBridge? nativeBridge})
    : _nativeBridge = nativeBridge ?? MethodChannelTencentLiveAsrNativeBridge();

  final TencentLiveAsrNativeBridge _nativeBridge;
  final StreamController<LiveTranscriptSentence> _sentenceEvents =
      StreamController<LiveTranscriptSentence>.broadcast(sync: true);
  StreamSubscription<Object?>? _nativeEvents;
  bool _active = false;
  int _generation = 0;

  @override
  Stream<LiveTranscriptSentence> get events => _sentenceEvents.stream;

  @override
  Stream<LiveSpeakerIdentity> get speakerIdentities =>
      const Stream<LiveSpeakerIdentity>.empty();

  @override
  Future<LiveAsrOperationResult> connect(
    LiveAsrSessionCredential credential,
  ) async {
    if (_active) {
      return const LiveAsrOperationResult.failure(
        'TENCENT_LIVE_ASR_SESSION_BUSY',
      );
    }
    _debugLiveNative(stage: 'connect_requested');
    if (credential.expiresWithin(const Duration(seconds: 5))) {
      return const LiveAsrOperationResult.failure('ASR_CREDENTIAL_EXPIRED');
    }
    _active = true;
    final generation = ++_generation;
    _nativeEvents = _nativeBridge.events.listen(
      (event) => _onNativeEvent(event, generation),
      onError: (Object _) => _emitNativeFailure(
        'TENCENT_LIVE_ASR_NATIVE_EVENT_FAILED',
        generation,
      ),
      cancelOnError: false,
    );
    try {
      await _nativeBridge.start(credential.toNativeStartArguments());
      if (!_active || generation != _generation) {
        return const LiveAsrOperationResult.failure(
          'TENCENT_LIVE_ASR_SESSION_SUPERSEDED',
        );
      }
      _debugLiveNative(stage: 'connect_started');
      return const LiveAsrOperationResult.success();
    } on MissingPluginException {
      _debugLiveNative(stage: 'sdk_unavailable');
      await _resetNativeSession(releaseNative: false);
      return const LiveAsrOperationResult.sdkUnavailable();
    } on PlatformException catch (error) {
      _debugLiveNative(stage: 'platform_failure', code: error.code);
      await _resetNativeSession(releaseNative: false);
      return _resultFromNativeCode(error.code);
    } catch (cause) {
      _debugLiveNative(
        stage: 'start_failure',
        causeType: cause.runtimeType.toString(),
      );
      await _resetNativeSession(releaseNative: false);
      return const LiveAsrOperationResult.failure(
        'TENCENT_LIVE_ASR_START_FAILED',
      );
    }
  }

  @override
  Future<LiveAsrOperationResult> stop() async {
    if (!_active) return const LiveAsrOperationResult.success();
    try {
      await _nativeBridge.stop();
      return const LiveAsrOperationResult.success();
    } on MissingPluginException {
      return const LiveAsrOperationResult.sdkUnavailable();
    } on PlatformException catch (error) {
      return _resultFromNativeCode(error.code);
    } catch (_) {
      return const LiveAsrOperationResult.failure(
        'TENCENT_LIVE_ASR_STOP_FAILED',
      );
    }
  }

  @override
  Future<LiveAsrOperationResult> release() async {
    if (!_active && _nativeEvents == null) {
      return const LiveAsrOperationResult.success();
    }
    try {
      await _nativeBridge.release();
      await _resetNativeSession(releaseNative: false);
      return const LiveAsrOperationResult.success();
    } on MissingPluginException {
      await _resetNativeSession(releaseNative: false);
      return const LiveAsrOperationResult.sdkUnavailable();
    } on PlatformException catch (error) {
      await _resetNativeSession(releaseNative: false);
      return _resultFromNativeCode(error.code);
    } catch (_) {
      await _resetNativeSession(releaseNative: false);
      return const LiveAsrOperationResult.failure(
        'TENCENT_LIVE_ASR_RELEASE_FAILED',
      );
    }
  }

  void _onNativeEvent(Object? raw, int generation) {
    if (!_active || generation != _generation) return;
    final event = _objectMap(raw);
    final type = event?['type'];
    if (type is! String) {
      _emitNativeFailure('TENCENT_LIVE_ASR_EVENT_INVALID', generation);
      return;
    }
    switch (type) {
      case 'partial':
        _debugLiveNative(stage: 'partial_received');
        _emitSentence(event!, stable: false, generation: generation);
        return;
      case 'segment':
        _debugLiveNative(stage: 'segment_received');
        _emitSentence(event!, stable: true, generation: generation);
        return;
      case 'completed':
        _debugLiveNative(stage: 'completed');
        _emitNativeFailure('TENCENT_LIVE_ASR_PROVIDER_COMPLETED', generation);
        return;
      case 'diagnostic':
        final stage = _safeNativeDiagnosticStage(event?['stage']);
        if (stage != null) {
          _debugLiveNative(stage: 'native_$stage');
        }
        return;
      case 'error':
        _debugLiveNative(
          stage: 'event_failure',
          code: _safeNativeCode(event?['code']),
        );
        _emitNativeFailure(_safeNativeCode(event?['code']), generation);
      default:
        _emitNativeFailure('TENCENT_LIVE_ASR_EVENT_INVALID', generation);
    }
  }

  void _emitSentence(
    Map<String, Object?> event, {
    required bool stable,
    required int generation,
  }) {
    final sequence = event['sequence'];
    final text = event['text'];
    final speakerId = event['speakerId'];
    final startMs = _optionalMilliseconds(event['startMs']);
    final endMs = _optionalMilliseconds(event['endMs']);
    if (sequence is! int ||
        sequence < 0 ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > 100000 ||
        (speakerId != null &&
            (speakerId is! int || speakerId < 0 || speakerId > 999)) ||
        (startMs != null && endMs != null && endMs < startMs)) {
      _emitNativeFailure('TENCENT_LIVE_ASR_EVENT_INVALID', generation);
      return;
    }
    try {
      _sentenceEvents.add(
        LiveTranscriptSentence(
          sentenceId: sequence,
          text: text,
          stable: stable,
          anonymousSpeakerId: speakerId as int?,
          startMs: startMs,
          endMs: endMs,
        ),
      );
    } on ArgumentError {
      _emitNativeFailure('TENCENT_LIVE_ASR_EVENT_INVALID', generation);
    }
  }

  void _emitNativeFailure(String code, int generation) {
    if (!_active || generation != _generation) return;
    _sentenceEvents.addError(_safeNativeCode(code));
  }

  Future<void> _resetNativeSession({required bool releaseNative}) async {
    _generation += 1;
    _active = false;
    final subscription = _nativeEvents;
    _nativeEvents = null;
    await subscription?.cancel();
    if (releaseNative) {
      try {
        await _nativeBridge.release();
      } catch (_) {
        // A failing cleanup must not replace the original start error.
      }
    }
  }
}

void _debugLiveNative({
  required String stage,
  String? code,
  String? causeType,
}) {
  if (!kDebugMode) return;
  debugPrint(
    '[TencentLiveAsr] stage=$stage'
    '${code == null ? '' : ' code=$code'}'
    '${causeType == null ? '' : ' cause=$causeType'}',
  );
}

LiveAsrOperationResult _resultFromNativeCode(String? value) {
  final code = _safeNativeCode(value);
  if (code == 'TENCENT_LIVE_ASR_SDK_UNAVAILABLE') {
    return const LiveAsrOperationResult.sdkUnavailable();
  }
  return LiveAsrOperationResult.failure(code);
}

String _safeNativeCode(Object? value) {
  final code = value is String ? value.trim() : '';
  return RegExp(r'^TENCENT_LIVE_ASR_[A-Z0-9_]{3,80}$').hasMatch(code)
      ? code
      : 'TENCENT_LIVE_ASR_NATIVE_FAILED';
}

String? _safeNativeDiagnosticStage(Object? value) {
  final stage = value is String ? value.trim() : '';
  return RegExp(r'^[a-z][a-z0-9_]{2,63}$').hasMatch(stage) ? stage : null;
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is! Map<Object?, Object?>) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

int? _optionalMilliseconds(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 0) return null;
  return value;
}
