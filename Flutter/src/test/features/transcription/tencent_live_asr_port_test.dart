import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/transcription/data/tencent_live_asr_port.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';

void main() {
  test(
    'starts the native SDK with an in-memory temporary credential',
    () async {
      final native = _FakeNativeBridge();
      final port = MethodChannelTencentLiveAsrPort(nativeBridge: native);

      final result = await port.connect(_credential());

      expect(result.ok, isTrue);
      expect(native.started, hasLength(1));
      expect(native.started.single['sessionId'], 'live-session-1');
      expect(native.started.single['appId'], 123456789);
      expect(native.started.single['tmpSecretId'], 'tmp-secret-id');
      expect(native.started.single['tmpSecretKey'], 'tmp-secret-key');
      expect(native.started.single['token'], 'tmp-token');
      await port.release();
      await native.close();
    },
  );

  test('waits for the native provider-ready boundary', () async {
    final ready = Completer<void>();
    final native = _FakeNativeBridge()..startGate = ready;
    final port = MethodChannelTencentLiveAsrPort(nativeBridge: native);

    var completed = false;
    final connecting = port.connect(_credential()).whenComplete(() {
      completed = true;
    });
    await pumpEventQueue(times: 2);

    expect(native.started, hasLength(1));
    expect(completed, isFalse);
    ready.complete();
    expect((await connecting).ok, isTrue);

    await port.release();
    await native.close();
  });

  test('late native readiness cannot reactivate a released session', () async {
    final ready = Completer<void>();
    final native = _FakeNativeBridge()..startGate = ready;
    final port = MethodChannelTencentLiveAsrPort(nativeBridge: native);

    final connecting = port.connect(_credential());
    await pumpEventQueue(times: 2);
    expect((await port.release()).ok, isTrue);
    ready.complete();

    final result = await connecting;
    expect(result.ok, isFalse);
    expect(result.errorCode, 'TENCENT_LIVE_ASR_SESSION_SUPERSEDED');
    expect(native.releaseCalls, 1);
    await native.close();
  });

  test('parses sanitized partial and stable native results', () async {
    final native = _FakeNativeBridge();
    final port = MethodChannelTencentLiveAsrPort(nativeBridge: native);
    final sentences = <LiveTranscriptSentence>[];
    final subscription = port.events.listen(sentences.add);

    expect((await port.connect(_credential())).ok, isTrue);
    native.emit(<String, Object?>{
      'type': 'diagnostic',
      'stage': 'audio_first_frame',
    });
    native.emit(<String, Object?>{
      'type': 'partial',
      'sequence': 0,
      'text': '实时转写',
      'startMs': 10,
      'endMs': 80,
    });
    native.emit(<String, Object?>{
      'type': 'segment',
      'sequence': 0,
      'text': '实时转写内容',
      'speakerId': 2,
      'startMs': 10,
      'endMs': 160,
    });
    await pumpEventQueue(times: 2);

    expect(sentences, hasLength(2));
    expect(sentences.first.stable, isFalse);
    expect(sentences.last.stable, isTrue);
    expect(sentences.last.text, '实时转写内容');
    expect(sentences.last.anonymousSpeakerId, 2);
    await subscription.cancel();
    await port.release();
    await native.close();
  });

  test(
    'reports malformed native events without leaking temporary credentials',
    () async {
      final native = _FakeNativeBridge();
      final port = MethodChannelTencentLiveAsrPort(nativeBridge: native);
      final errors = <Object>[];
      final subscription = port.events.listen((_) {}, onError: errors.add);

      expect((await port.connect(_credential())).ok, isTrue);
      native.emit(<String, Object?>{
        'type': 'partial',
        'sequence': -1,
        'text': 'x',
      });
      await pumpEventQueue(times: 2);

      expect(errors, <Object>['TENCENT_LIVE_ASR_EVENT_INVALID']);
      expect(errors.single.toString(), isNot(contains('tmp-secret-key')));
      await subscription.cancel();
      await port.release();
      await native.close();
    },
  );

  test(
    'reports unexpected active native completion as typed terminal',
    () async {
      final native = _FakeNativeBridge();
      final port = MethodChannelTencentLiveAsrPort(nativeBridge: native);
      final errors = <Object>[];
      final subscription = port.events.listen((_) {}, onError: errors.add);

      expect((await port.connect(_credential())).ok, isTrue);
      native.emit(<String, Object?>{'type': 'completed'});
      await pumpEventQueue(times: 2);

      expect(errors, <Object>['TENCENT_LIVE_ASR_PROVIDER_COMPLETED']);
      await subscription.cancel();
      await port.release();
      await native.close();
    },
  );

  test('maps an absent native SDK to an unavailable capability', () async {
    final native = _FakeNativeBridge()
      ..startError = PlatformException(
        code: 'TENCENT_LIVE_ASR_SDK_UNAVAILABLE',
      );
    final port = MethodChannelTencentLiveAsrPort(nativeBridge: native);

    final result = await port.connect(_credential());

    expect(result.ok, isFalse);
    expect(result.unavailable, isTrue);
    expect(result.errorCode, 'TENCENT_LIVE_ASR_SDK_UNAVAILABLE');
    await native.close();
  });

  test('delegates stop and release to the native SDK', () async {
    final native = _FakeNativeBridge();
    final port = MethodChannelTencentLiveAsrPort(nativeBridge: native);
    expect((await port.connect(_credential())).ok, isTrue);

    expect((await port.stop()).ok, isTrue);
    expect((await port.release()).ok, isTrue);

    expect(native.stopCalls, 1);
    expect(native.releaseCalls, 1);
    await native.close();
  });
}

LiveAsrSessionCredential _credential() => LiveAsrSessionCredential(
  sessionId: 'live-session-1',
  appId: 123456789,
  projectId: 0,
  tmpSecretId: 'tmp-secret-id',
  tmpSecretKey: 'tmp-secret-key',
  token: 'tmp-token',
  expiresAt: DateTime.utc(2030, 7, 29, 12, 15),
);

final class _FakeNativeBridge implements TencentLiveAsrNativeBridge {
  final StreamController<Object?> _events =
      StreamController<Object?>.broadcast();
  final List<Map<String, Object>> started = <Map<String, Object>>[];
  PlatformException? startError;
  Completer<void>? startGate;
  int stopCalls = 0;
  int releaseCalls = 0;

  @override
  Stream<Object?> get events => _events.stream;

  @override
  Future<void> start(Map<String, Object> arguments) async {
    final error = startError;
    if (error != null) throw error;
    started.add(arguments);
    await startGate?.future;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> release() async {
    releaseCalls += 1;
  }

  void emit(Object? event) => _events.add(event);

  Future<void> close() => _events.close();
}
