import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/screen_capture_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/screen_capture');
  const eventChannel = EventChannel('test/screen_capture/events');
  const eventControl = MethodChannel('test/screen_capture/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(eventControl, null);
  });

  test(
    'event listeners release native subscriptions and can reconnect',
    () async {
      final lifecycle = <String>[];
      final captureCommands = <String>[];
      messenger.setMockMethodCallHandler(eventControl, (call) async {
        lifecycle.add(call.method);
        return null;
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        captureCommands.add(call.method);
        return null;
      });
      final port = MethodChannelScreenCapturePort(
        methodChannel: channel,
        eventChannel: eventChannel,
      );
      expect(port.events.isBroadcast, isTrue);
      final firstEvents = <ScreenCaptureSnapshot>[];
      final secondEvents = <ScreenCaptureSnapshot>[];
      final errors = <Object>[];
      final first = port.events.listen(firstEvents.add, onError: errors.add);
      final second = port.events.listen(secondEvents.add, onError: errors.add);
      addTearDown(first.cancel);
      addTearDown(second.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(lifecycle, ['listen']);

      Future<void> emit(Object? payload) async {
        await messenger.handlePlatformMessage(
          eventChannel.name,
          const StandardMethodCodec().encodeSuccessEnvelope(payload),
          (_) {},
        );
      }

      await emit(<String, Object?>{
        'state': 'importing',
        'elapsedSeconds': 0,
        'sessionId': 'capture-001',
      });
      expect(firstEvents.single.sessionId, 'capture-001');
      expect(secondEvents.single.state, ScreenCaptureState.importing);
      await first.cancel();
      expect(lifecycle, ['listen']);
      await second.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(lifecycle, ['listen', 'cancel']);

      final resumedEvents = <ScreenCaptureSnapshot>[];
      final resumed = port.events.listen(
        resumedEvents.add,
        onError: errors.add,
      );
      addTearDown(resumed.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(lifecycle, ['listen', 'cancel', 'listen']);
      await emit(<String, Object?>{'state': 'idle', 'elapsedSeconds': 0});
      expect(resumedEvents.single.state, ScreenCaptureState.idle);
      await emit(<String, Object?>{'state': 'invalid'});
      expect(errors.single, isA<FormatException>());
      await resumed.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(lifecycle, ['listen', 'cancel', 'listen', 'cancel']);
      expect(captureCommands, isEmpty);
    },
  );

  test('session recovery import and cleanup preserve owner identity', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.arguments, <String, Object?>{'sessionId': 'owned-import'});
      if (call.method == 'releaseSession') return true;
      return <String, Object?>{
        'state': 'importing',
        'sessionId': 'owned-import',
        'elapsedSeconds': 0,
      };
    });
    final port = MethodChannelScreenCapturePort(methodChannel: channel);
    expect(
      (await port.importVideo('owned-import')).value?.state,
      ScreenCaptureState.importing,
    );
    expect(
      (await port.recoverSession('owned-import')).value?.sessionId,
      'owned-import',
    );
    expect((await port.releaseSession('owned-import')).value, isTrue);
    expect(calls, ['importVideo', 'getSession', 'releaseSession']);
  });

  test('carries capture session identity and guards stop', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startCapture') {
        expect((call.arguments as Map)['sessionId'], 'internal-owned');
      } else {
        expect(call.method, 'stopCapture');
        expect((call.arguments as Map)['expectedSessionId'], 'internal-owned');
      }
      return <String, Object?>{
        'state': call.method == 'startCapture' ? 'starting' : 'stopping',
        'sessionId': 'internal-owned',
        'elapsedSeconds': 0,
      };
    });
    final port = MethodChannelScreenCapturePort(methodChannel: channel);
    expect(
      (await port.startCapture(sessionId: 'internal-owned')).value?.sessionId,
      'internal-owned',
    );
    expect(
      (await port.stopCapture(expectedSessionId: 'internal-owned')).ok,
      isTrue,
    );
  });

  test('maps native capability without inventing support', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getCapability');
      return <String, Object?>{
        'supported': true,
        'canCaptureSystemAudio': true,
        'requiresSystemPicker': true,
      };
    });
    final port = MethodChannelScreenCapturePort(methodChannel: channel);

    final result = await port.getCapability();

    expect(result.ok, isTrue);
    expect(result.value?.supported, isTrue);
    expect(result.value?.canCaptureSystemAudio, isTrue);
  });

  test('accepts only fully verified completed media payload', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'stopCapture');
      return _completedPayload();
    });
    final port = MethodChannelScreenCapturePort(methodChannel: channel);

    final result = await port.stopCapture();

    expect(result.ok, isTrue);
    expect(result.value?.state, ScreenCaptureState.completed);
    expect(result.value?.media?.mimeType, 'video/mp4');
    expect(result.value?.media?.sizeBytes, 1024);
  });

  test('accepts only a verified extracted M4A payload', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stopCapture') return _completedPayload();
      expect(call.method, 'extractAudio');
      expect(call.arguments, <String, Object?>{
        'appPrivateUri': 'app-private-media://screen-capture/capture-001.mp4',
      });
      return _audioPayload();
    });
    final port = MethodChannelScreenCapturePort(methodChannel: channel);
    final media = (await port.stopCapture()).value?.media;

    final result = await port.extractAudio(media!);

    expect(result.ok, isTrue);
    expect(result.value?.mimeType, 'audio/mp4');
    expect(result.value?.fileName, 'capture-001.m4a');
  });

  test('fails closed for traversal or malformed checksum', () async {
    final payload = _completedPayload();
    final media = Map<String, Object?>.from(payload['media']! as Map);
    media['appPrivateUri'] =
        'app-private-media://screen-capture/../capture.mp4';
    media['sha256'] = 'not-a-sha';
    payload['media'] = media;
    messenger.setMockMethodCallHandler(channel, (_) async => payload);
    final port = MethodChannelScreenCapturePort(methodChannel: channel);

    final result = await port.stopCapture();

    expect(result.ok, isFalse);
    expect(result.error?.code, 'SCREEN_CAPTURE_STATE_MALFORMED');
  });

  test('preserves a safe native platform error code', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'SCREEN_CAPTURE_PERMISSION_DENIED');
    });
    final port = MethodChannelScreenCapturePort(methodChannel: channel);

    final result = await port.startCapture();

    expect(result.ok, isFalse);
    expect(result.error?.code, 'SCREEN_CAPTURE_PERMISSION_DENIED');
  });
}

Map<String, Object?> _completedPayload() => <String, Object?>{
  'state': 'completed',
  'elapsedSeconds': 12,
  'media': <String, Object?>{
    'appPrivateUri': 'app-private-media://screen-capture/capture-001.mp4',
    'fileName': 'capture-001.mp4',
    'mimeType': 'video/mp4',
    'sizeBytes': 1024,
    'durationSeconds': 12,
    'sha256': List<String>.filled(64, 'a').join(),
    'recordedAt': '2026-07-14T02:00:00Z',
  },
};

Map<String, Object?> _audioPayload() => <String, Object?>{
  'appPrivateUri': 'app-private-media://screen-capture/capture-001.m4a',
  'fileName': 'capture-001.m4a',
  'mimeType': 'audio/mp4',
  'sizeBytes': 512,
  'durationSeconds': 12,
  'sha256': List<String>.filled(64, 'b').join(),
  'recordedAt': '2026-07-14T02:00:00Z',
};
