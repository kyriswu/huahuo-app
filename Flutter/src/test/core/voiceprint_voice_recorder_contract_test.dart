import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'voiceprint scene is serialized through the native recorder contract',
    () async {
      const channel = MethodChannel('huahuoai/voiceprint_scene_contract');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startRecording') {
          expect(call.arguments, const <String, Object?>{
            'scene': 'voiceprint',
          });
          return <String, Object?>{
            'recordingId': 'voice-print-1',
            'scene': 'voiceprint',
            'state': 'recording',
            'startedAt': DateTime.utc(2026, 7, 15, 8).toIso8601String(),
            'elapsedSeconds': 0,
          };
        }
        if (call.method == 'stopRecording') {
          return <String, Object?>{
            'recordingId': 'voice-print-1',
            'scene': 'voiceprint',
            'appPrivateUri': 'app-private://voice-print-1.wav',
            'fileName': 'voice-print-1.wav',
            'mimeType': 'audio/wav',
            'sizeBytes': 320044,
            'durationSeconds': 10,
            'sampleRateHz': voiceprintWavSampleRateHz,
            'bitDepth': voiceprintWavBitDepth,
            'channelCount': voiceprintWavChannelCount,
            'sha256': 'a' * 64,
            'recordedAt': DateTime.utc(2026, 7, 15, 8).toIso8601String(),
          };
        }
        return null;
      });

      final port = MethodChannelVoiceRecorderPort(channel: channel);
      final result = await port.startRecording(
        scene: VoiceRecordingScene.voiceprint,
      );
      final stopped = await port.stopRecording();

      expect(result.ok, isTrue);
      expect(result.value?.scene, VoiceRecordingScene.voiceprint);
      expect(stopped.ok, isTrue);
      expect(stopped.value?.scene, VoiceRecordingScene.voiceprint);
      expect(stopped.value?.fileName, 'voice-print-1.wav');
      expect(stopped.value?.mimeType, 'audio/wav');
    },
  );
}
