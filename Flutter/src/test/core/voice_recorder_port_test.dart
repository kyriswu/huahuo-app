import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceRecorderPort contract', () {
    test(
      'unavailable driver fails closed for every recorder operation',
      () async {
        const port = UnavailableVoiceRecorderPort();

        final permission = await port.requestMicrophonePermission();
        final start = await port.startRecording(
          scene: VoiceRecordingScene.feedAi,
        );
        final pause = await port.pauseRecording();
        final resume = await port.resumeRecording();
        final stop = await port.stopRecording();
        final cancel = await port.cancelRecording();

        expect(permission.ok, isFalse);
        expect(start.ok, isFalse);
        expect(pause.ok, isFalse);
        expect(resume.ok, isFalse);
        expect(stop.ok, isFalse);
        expect(cancel.ok, isFalse);
        expect(start.error?.code, 'NATIVE_VOICE_RECORDER_DRIVER_UNAVAILABLE');
        expect(port.snapshot.state, VoiceRecorderState.failed);
      },
    );

    test('MethodChannel adapter parses a safe recorder lifecycle', () async {
      const channel = MethodChannel('huahuoai/voice_recorder_contract_success');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getMicrophonePermission':
          case 'requestMicrophonePermission':
            return const <String, Object?>{
              'state': 'granted',
              'canAskAgain': false,
            };
          case 'getRecordingState':
          case 'cancelRecording':
            return const <String, Object?>{'state': 'idle'};
          case 'startRecording':
            expect(call.arguments, <String, Object?>{
              'scene': 'feed_ai',
              'accountDirectory': 'u-0123456789abcdef0123456789abcdef',
            });
            return _sessionMap('recording');
          case 'pauseRecording':
            return _sessionMap('paused');
          case 'resumeRecording':
            return _sessionMap('recording');
          case 'stopRecording':
            return _draftMap();
        }
        return null;
      });
      final port = MethodChannelVoiceRecorderPort(
        channel: channel,
        nativeRecorderDirectoryScope: () =>
            'u-0123456789abcdef0123456789abcdef',
      );

      final permission = await port.requestMicrophonePermission();
      final started = await port.startRecording(
        scene: VoiceRecordingScene.feedAi,
      );
      final paused = await port.pauseRecording();
      final resumed = await port.resumeRecording();
      final stopped = await port.stopRecording();
      final cancelled = await port.cancelRecording();

      expect(permission.value?.granted, isTrue);
      expect(started.value?.recordingId, 'voice-1');
      expect(paused.value?.state, VoiceRecorderState.paused);
      expect(resumed.value?.state, VoiceRecorderState.recording);
      expect(stopped.value?.appPrivateUri, 'app-private://voice-1.m4a');
      expect(stopped.value?.fileName, 'voice-1.m4a');
      expect(stopped.value?.mimeType, 'audio/mp4');
      expect(port.snapshot.state, VoiceRecorderState.idle);
      expect(cancelled.value?.state, VoiceRecorderState.idle);
    });

    test(
      'owned MethodChannel controls forward the exact session identity',
      () async {
        const channel = MethodChannel('huahuoai/voice_recorder_contract_owned');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final invokedMethods = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          invokedMethods.add(call.method);
          expect(call.arguments, const <String, Object?>{
            'expectedScene': 'feed_ai',
            'expectedRecordingId': 'voice-1',
          });
          switch (call.method) {
            case 'pauseRecording':
              return _sessionMap('paused');
            case 'resumeRecording':
              return _sessionMap('recording');
            case 'stopRecording':
              return _draftMap();
            case 'cancelRecording':
              return const <String, Object?>{'state': 'idle'};
          }
          return null;
        });
        final VoiceRecorderPort port = MethodChannelVoiceRecorderPort(
          channel: channel,
        );

        final paused = await port.pauseOwnedRecording(
          expectedScene: VoiceRecordingScene.feedAi,
          expectedRecordingId: 'voice-1',
        );
        final resumed = await port.resumeOwnedRecording(
          expectedScene: VoiceRecordingScene.feedAi,
          expectedRecordingId: 'voice-1',
        );
        final stopped = await port.stopOwnedRecording(
          expectedScene: VoiceRecordingScene.feedAi,
          expectedRecordingId: 'voice-1',
        );
        final cancelled = await port.cancelOwnedRecording(
          expectedScene: VoiceRecordingScene.feedAi,
          expectedRecordingId: 'voice-1',
        );

        expect(paused.value?.state, VoiceRecorderState.paused);
        expect(resumed.value?.state, VoiceRecorderState.recording);
        expect(stopped.value?.recordingId, 'voice-1');
        expect(cancelled.value?.state, VoiceRecorderState.idle);
        expect(invokedMethods, <String>[
          'pauseRecording',
          'resumeRecording',
          'stopRecording',
          'cancelRecording',
        ]);
      },
    );

    test(
      'unsafe native output is an explicit malformed-payload failure',
      () async {
        const channel = MethodChannel('huahuoai/voice_recorder_contract_bad');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'stopRecording') {
            return <String, Object?>{
              ..._draftMap(),
              'appPrivateUri': 'file:///Users/run/voice.m4a',
            };
          }
          return const <String, Object?>{'state': 'idle'};
        });
        final port = MethodChannelVoiceRecorderPort(channel: channel);

        final stopped = await port.stopRecording();

        expect(stopped.ok, isFalse);
        expect(stopped.error?.code, 'NATIVE_VOICE_RECORDER_MALFORMED_PAYLOAD');
        expect(
          port.snapshot.lastErrorCode,
          'NATIVE_VOICE_RECORDER_MALFORMED_PAYLOAD',
        );
      },
    );

    test(
      'native PCM capture failure refreshes as a stable failed state',
      () async {
        const channel = MethodChannel(
          'huahuoai/voice_recorder_contract_pcm_failed',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getRecordingState') {
            return const <String, Object?>{
              'state': 'failed',
              'lastErrorCode': 'VOICE_RECORDER_PCM_CAPTURE_FAILED',
            };
          }
          return const <String, Object?>{'state': 'idle'};
        });
        final port = MethodChannelVoiceRecorderPort(channel: channel);

        final refreshed = await port.refreshState();

        expect(refreshed.ok, isTrue);
        expect(refreshed.value?.state, VoiceRecorderState.failed);
        expect(
          refreshed.value?.lastErrorCode,
          'VOICE_RECORDER_PCM_CAPTURE_FAILED',
        );
        expect(port.snapshot.state, VoiceRecorderState.failed);
      },
    );

    test('legacy and noncanonical library payloads are rejected', () async {
      const channel = MethodChannel('huahuoai/voice_recorder_contract_legacy');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      for (final payload in <Map<String, Object?>>[
        <String, Object?>{
          ..._draftMap(),
          'appPrivateUri': 'app-private://voice-drafts/voice-1/voice-1.m4a',
          'fileName': 'voice-1.m4a',
        },
        <String, Object?>{
          ..._draftMap(),
          'appPrivateUri': 'app-private://recordings/voice-1/voice-1.m4a',
          'fileName': 'voice-1.m4a',
        },
      ]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          return call.method == 'stopRecording'
              ? payload
              : const <String, Object?>{'state': 'idle'};
        });
        final port = MethodChannelVoiceRecorderPort(channel: channel);

        final stopped = await port.stopRecording();

        expect(stopped.ok, isFalse);
        expect(stopped.error?.code, 'NATIVE_VOICE_RECORDER_MALFORMED_PAYLOAD');
      }
    });

    test(
      'fake port exercises start pause resume stop and cancel state',
      () async {
        final port = _FakeVoiceRecorderPort();

        await port.requestMicrophonePermission();
        final started = await port.startRecording(
          scene: VoiceRecordingScene.workAi,
        );
        final paused = await port.pauseRecording();
        final resumed = await port.resumeRecording();
        final stopped = await port.stopRecording();
        await port.startRecording(scene: VoiceRecordingScene.feedAi);
        final cancelled = await port.cancelRecording();

        expect(started.value?.scene, VoiceRecordingScene.workAi);
        expect(paused.value?.state, VoiceRecorderState.paused);
        expect(resumed.value?.state, VoiceRecorderState.recording);
        expect(stopped.value?.recordingId, 'voice-fake-1');
        expect(cancelled.value?.state, VoiceRecorderState.idle);
        await expectLater(port.levelSamples, emitsDone);
      },
    );

    test('owned fallback rejects stale or foreign fake sessions', () async {
      final VoiceRecorderPort port = _FakeVoiceRecorderPort();
      await port.startRecording(scene: VoiceRecordingScene.workAi);

      final foreignPause = await port.pauseOwnedRecording(
        expectedScene: VoiceRecordingScene.internal,
        expectedRecordingId: 'voice-fake-1',
      );
      final staleStop = await port.stopOwnedRecording(
        expectedScene: VoiceRecordingScene.workAi,
        expectedRecordingId: 'voice-fake-stale',
      );
      final foreignCancel = await port.cancelOwnedRecording(
        expectedScene: VoiceRecordingScene.internal,
        expectedRecordingId: 'voice-fake-1',
      );

      expect(foreignPause.ok, isFalse);
      expect(foreignPause.error?.code, voiceRecorderSessionMismatchCode);
      expect(staleStop.ok, isFalse);
      expect(staleStop.error?.code, voiceRecorderSessionMismatchCode);
      expect(foreignCancel.ok, isFalse);
      expect(foreignCancel.error?.code, voiceRecorderSessionMismatchCode);
      expect(port.snapshot.state, VoiceRecorderState.recording);

      final paused = await port.pauseOwnedRecording(
        expectedScene: VoiceRecordingScene.workAi,
        expectedRecordingId: 'voice-fake-1',
      );
      final foreignResume = await port.resumeOwnedRecording(
        expectedScene: VoiceRecordingScene.feedAi,
        expectedRecordingId: 'voice-fake-1',
      );

      expect(paused.value?.state, VoiceRecorderState.paused);
      expect(foreignResume.ok, isFalse);
      expect(foreignResume.error?.code, voiceRecorderSessionMismatchCode);
      expect(port.snapshot.state, VoiceRecorderState.paused);
    });

    test('voice level payload accepts only safe normalized metering', () {
      final sample = parseVoiceLevelSample(const <String, Object?>{
        'capturedAt': '2026-07-10T08:00:00.000Z',
        'average': .25,
        'peak': .75,
      });

      expect(sample?.average, .25);
      expect(sample?.peak, .75);
      expect(
        parseVoiceLevelSample(const <String, Object?>{
          'capturedAt': '2026-07-10T08:00:00.000Z',
          'average': -1,
          'peak': 2,
        }),
        isNull,
      );
      expect(parseVoiceLevelSample(const <String, Object?>{}), isNull);
    });

    test('PCM16 source accepts only copied 1280-byte typed frames', () async {
      final source = Uint8List.fromList(
        List<int>.generate(
          voiceRecorderPcm16FrameBytes,
          (index) => index & 0xff,
        ),
      );
      final parsed = parseVoiceRecorderPcm16Frame(source);

      expect(parsed, isNotNull);
      expect(parsed, orderedEquals(source));
      expect(identical(parsed, source), isFalse);
      expect(
        parseVoiceRecorderPcm16Frame(
          Uint8List(voiceRecorderPcm16FrameBytes - 1),
        ),
        isNull,
      );
      expect(
        parseVoiceRecorderPcm16Frame(
          List<int>.filled(voiceRecorderPcm16FrameBytes, 0),
        ),
        isNull,
      );
      await expectLater(
        const UnavailableVoiceRecorderPort().pcm16Frames,
        emitsDone,
      );
    });

    test('PCM16 early-buffer overflow preserves safe native counts', () {
      final failure = parseVoiceRecorderPcm16StreamFailure(
        PlatformException(
          code: voiceRecorderPcm16EarlyBufferOverflowCode,
          details: const <String, Object?>{
            'droppedFrames': 1126,
            'capacityFrames': 1125,
          },
        ),
      );

      expect(failure?.code, voiceRecorderPcm16EarlyBufferOverflowCode);
      expect(failure?.droppedFrames, 1126);
      expect(failure?.capacityFrames, 1125);
      expect(
        parseVoiceRecorderPcm16StreamFailure(
          PlatformException(
            code: voiceRecorderPcm16EarlyBufferOverflowCode,
            details: const <String, Object?>{
              'droppedFrames': 1125,
              'capacityFrames': 1125,
            },
          ),
        ),
        isNull,
      );
      expect(
        parseVoiceRecorderPcm16StreamFailure(
          PlatformException(code: 'UNRELATED_PCM_FAILURE'),
        ),
        isNull,
      );
    });

    test('voiceprint accepts only bounded scene-matched PCM WAV metadata', () {
      final valid = parseVoiceRecordingDraft(_voiceprintDraftMap());

      expect(valid?.scene, VoiceRecordingScene.voiceprint);
      expect(valid?.appPrivateUri, 'app-private://voiceprint-1.wav');
      expect(valid?.mimeType, 'audio/wav');
      expect(valid?.sampleRateHz, voiceprintWavSampleRateHz);
      expect(valid?.bitDepth, voiceprintWavBitDepth);
      expect(valid?.channelCount, voiceprintWavChannelCount);
      final graceBoundary = parseVoiceRecordingDraft(<String, Object?>{
        ..._voiceprintDraftMap(),
        'durationSeconds': voiceprintWavMaximumReportedSeconds,
      });
      expect(
        graceBoundary?.durationSeconds,
        voiceprintWavMaximumReportedSeconds,
      );

      final monologue = parseVoiceRecordingDraft(
        _pcmDraftMap(scene: 'monologue'),
      );
      final meeting = parseVoiceRecordingDraft(_pcmDraftMap(scene: 'meeting'));
      expect(monologue?.mimeType, 'audio/wav');
      expect(monologue?.fileName, 'monologue-1.wav');
      expect(meeting?.appPrivateUri, 'app-private://meeting-1.wav');
      expect(
        meeting?.durationSeconds,
        greaterThan(voiceprintWavMaximumSeconds),
      );

      for (final invalid in <Map<String, Object?>>[
        <String, Object?>{..._voiceprintDraftMap()}..remove('scene'),
        <String, Object?>{..._voiceprintDraftMap(), 'scene': 'feed_ai'},
        <String, Object?>{
          ..._voiceprintDraftMap(),
          'appPrivateUri': 'app-private://voiceprint-1.m4a',
          'fileName': 'voiceprint-1.m4a',
          'mimeType': 'audio/mp4',
        },
        <String, Object?>{
          ..._voiceprintDraftMap(),
          'sizeBytes': voiceprintWavMaximumBytes + 1,
        },
        <String, Object?>{
          ..._voiceprintDraftMap(),
          'durationSeconds': voiceprintWavMaximumReportedSeconds + 1,
        },
        <String, Object?>{..._voiceprintDraftMap(), 'sampleRateHz': 44100},
        <String, Object?>{..._voiceprintDraftMap(), 'bitDepth': 24},
        <String, Object?>{..._voiceprintDraftMap(), 'channelCount': 2},
        <String, Object?>{
          ..._pcmDraftMap(scene: 'monologue'),
          'fileName': 'monologue-1.m4a',
          'appPrivateUri': 'app-private://monologue-1.m4a',
          'mimeType': 'audio/mp4',
        },
        <String, Object?>{
          ..._pcmDraftMap(scene: 'meeting'),
          'sampleRateHz': 44100,
        },
      ]) {
        expect(parseVoiceRecordingDraft(invalid), isNull);
      }
    });
  });
}

Map<String, Object?> _sessionMap(String state) {
  return <String, Object?>{
    'state': state,
    'recordingId': 'voice-1',
    'scene': 'feed_ai',
    'startedAt': '2026-07-10T08:00:00.000Z',
    'elapsedSeconds': 3,
  };
}

Map<String, Object?> _draftMap() {
  return <String, Object?>{
    'recordingId': 'voice-1',
    'scene': 'feed_ai',
    'appPrivateUri': 'app-private://voice-1.m4a',
    'fileName': 'voice-1.m4a',
    'mimeType': 'audio/mp4',
    'sizeBytes': 4096,
    'durationSeconds': 3,
    'sha256': 'a' * 64,
    'recordedAt': '2026-07-10T08:00:00.000Z',
  };
}

Map<String, Object?> _voiceprintDraftMap() {
  return <String, Object?>{
    'recordingId': 'voiceprint-1',
    'scene': 'voiceprint',
    'appPrivateUri': 'app-private://voiceprint-1.wav',
    'fileName': 'voiceprint-1.wav',
    'mimeType': 'audio/wav',
    'sizeBytes': 640044,
    'durationSeconds': 20,
    'sampleRateHz': voiceprintWavSampleRateHz,
    'bitDepth': voiceprintWavBitDepth,
    'channelCount': voiceprintWavChannelCount,
    'sha256': 'c' * 64,
    'recordedAt': '2026-07-10T08:00:00.000Z',
  };
}

Map<String, Object?> _pcmDraftMap({required String scene}) {
  return <String, Object?>{
    'recordingId': '$scene-1',
    'scene': scene,
    'appPrivateUri': 'app-private://$scene-1.wav',
    'fileName': '$scene-1.wav',
    'mimeType': 'audio/wav',
    'sizeBytes': 1280044,
    'durationSeconds': 40,
    'sampleRateHz': voiceprintWavSampleRateHz,
    'bitDepth': voiceprintWavBitDepth,
    'channelCount': voiceprintWavChannelCount,
    'sha256': 'd' * 64,
    'recordedAt': '2026-07-10T08:00:00.000Z',
  };
}

final class _FakeVoiceRecorderPort implements VoiceRecorderPort {
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();
  var _counter = 0;

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult<VoiceRecorderSnapshot>.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async {
    return VoiceRecorderResult<VoiceRecorderPermission>.success(
      const VoiceRecorderPermission(
        state: VoiceRecorderPermissionState.granted,
        canAskAgain: false,
      ),
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async {
    final session = _snapshot.session;
    if (session == null || _snapshot.state != VoiceRecorderState.recording) {
      return _failure('VOICE_RECORDER_NOT_RECORDING');
    }
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.paused,
      session: VoiceRecordingSession(
        recordingId: session.recordingId,
        scene: session.scene,
        state: VoiceRecorderState.paused,
        startedAt: session.startedAt,
      ),
    );
    return VoiceRecorderResult<VoiceRecorderSnapshot>.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async {
    return VoiceRecorderResult<VoiceRecorderSnapshot>.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() async {
    return getMicrophonePermission();
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async {
    final session = _snapshot.session;
    if (session == null || _snapshot.state != VoiceRecorderState.paused) {
      return _failure('VOICE_RECORDER_NOT_PAUSED');
    }
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: VoiceRecordingSession(
        recordingId: session.recordingId,
        scene: session.scene,
        state: VoiceRecorderState.recording,
        startedAt: session.startedAt,
      ),
    );
    return VoiceRecorderResult<VoiceRecorderSnapshot>.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    _counter += 1;
    final session = VoiceRecordingSession(
      recordingId: 'voice-fake-$_counter',
      scene: scene,
      state: VoiceRecorderState.recording,
      startedAt: DateTime.utc(2026, 7, 10, 8),
    );
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: session,
    );
    return VoiceRecorderResult<VoiceRecordingSession>.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() async {
    final session = _snapshot.session;
    if (session == null) {
      return VoiceRecorderResult<VoiceRecordingDraft>.failure(
        const AppFailure(
          code: 'VOICE_RECORDER_NOT_ACTIVE',
          category: AppFailureCategory.storage,
          message: 'not active',
          userMessageKey: 'voice.test.notActive',
        ),
      );
    }
    final draft = VoiceRecordingDraft(
      recordingId: session.recordingId,
      appPrivateUri: 'app-private://${session.recordingId}.m4a',
      fileName: '${session.recordingId}.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: 4096,
      durationSeconds: 3,
      sha256: 'b' * 64,
    );
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult<VoiceRecordingDraft>.success(draft);
  }

  VoiceRecorderResult<VoiceRecorderSnapshot> _failure(String code) {
    return VoiceRecorderResult<VoiceRecorderSnapshot>.failure(
      AppFailure(
        code: code,
        category: AppFailureCategory.storage,
        message: 'failed',
        userMessageKey: 'voice.test.$code',
      ),
    );
  }
}
