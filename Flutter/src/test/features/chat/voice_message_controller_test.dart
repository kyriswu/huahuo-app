import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/features/chat/application/chat_controller.dart';
import 'package:huahuoai_app/features/chat/application/chat_voice_uploader.dart';
import 'package:huahuoai_app/features/chat/application/voice_message_controller.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_context.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/transcription/data/tencent_live_asr_port.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';

void main() {
  group('VoiceMessageController', () {
    test(
      'production provider survives live transcript state notifications',
      () async {
        final recorder = _FakeRecorder();
        final asr = _LiveAsrPort();
        final liveTranscript = LiveTranscriptController(
          credentialPort: const _LiveCredentialPort(),
          asrPort: asr,
        );
        final chat = ChatController(api: _ChatApi(), scene: ChatScene.feedAi);
        var stateDependentBuilds = 0;
        final stateDependentProbe = Provider<int>((ref) {
          ref.watch(liveTranscriptControllerProvider);
          return ++stateDependentBuilds;
        });
        final container = ProviderContainer(
          overrides: <Override>[
            authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
            voiceRecorderPortProvider.overrideWithValue(recorder),
            recordingUploadClientProvider.overrideWithValue(
              _unusedUploadClient(),
            ),
            localRecordingRepositoryProvider.overrideWithValue(
              LocalRecordingRepository(
                database: AppDatabase(),
                fileStorage: const _FileStorage(),
              ),
            ),
            feedAiChatControllerProvider.overrideWith((ref) => chat),
            recordingApiProvider.overrideWithValue(_RecordingApi()),
            liveTranscriptControllerProvider.overrideWith(
              (ref) => liveTranscript,
            ),
          ],
        );
        final subscription = container.listen<VoiceMessageController>(
          feedAiVoiceMessageControllerProvider,
          (previous, next) {},
          fireImmediately: true,
        );
        final probeSubscription = container.listen<int>(
          stateDependentProbe,
          (previous, next) {},
          fireImmediately: true,
        );
        addTearDown(container.dispose);
        addTearDown(subscription.close);
        addTearDown(probeSubscription.close);
        addTearDown(asr.close);

        final controller = subscription.read();
        expect(
          await controller.startLiveTranscription(owner: 'chat:test'),
          isTrue,
        );
        await pumpEventQueue(times: 2);

        expect(subscription.read(), same(controller));
        expect(
          container.read(feedAiVoiceMessageControllerProvider),
          same(controller),
        );
        expect(controller.state.status, VoiceMessageControllerStatus.recording);
        expect(liveTranscript.state.status, LiveTranscriptStatus.transcribing);
        final liveAttemptId = controller.state.liveTranscriptAttemptId;
        expect(controller.state.liveTranscriptOwner, 'chat:test');
        expect(liveAttemptId, isNotNull);
        expect(controller.state.belongsToLiveTranscript('chat:test'), isTrue);
        expect(
          controller.state.belongsToLiveTranscript('canvas:test'),
          isFalse,
        );
        expect(recorder.startCalls, 1);
        expect(recorder.startedScenes, <VoiceRecordingScene>[
          VoiceRecordingScene.monologue,
        ]);
        expect(recorder.cancelCalls, 0);
        expect(stateDependentBuilds, greaterThan(1));

        asr.add(
          LiveTranscriptSentence(
            sentenceId: 1,
            text: '生产依赖保持实时转写',
            stable: true,
          ),
        );
        await pumpEventQueue(times: 2);
        expect(controller.state.liveTranscriptText, '生产依赖保持实时转写');
        expect(await controller.stopAndTranscribe(owner: 'chat:test'), isTrue);
        expect(controller.state.liveTranscriptOwner, 'chat:test');
        expect(controller.state.liveTranscriptAttemptId, liveAttemptId);
        expect(controller.state.belongsToLiveTranscript('chat:test'), isTrue);
        expect(recorder.cancelCalls, 1);
      },
    );

    test('creates a content-line thread for the first voice message', () async {
      final api = _ChatApi();
      final recorder = _FakeRecorder();
      final controller = _controller(
        chat: ChatController(api: api, scene: ChatScene.feedAi),
        recorder: recorder,
      );
      addTearDown(controller.dispose);

      final started = await controller.start(contentLineId: 'line-1');

      expect(started, isTrue);
      expect(recorder.startCalls, 1);
      expect(await controller.stopAndSend(), isTrue);
      expect(api.createdContentLineIds, <String?>['line-1']);
      expect(api.sentVoiceContentLineIds, <String?>['line-1']);
    });

    test(
      'records, registers, uploads, sends, and refreshes server ASR',
      () async {
        final api = _ChatApi();
        final chat = ChatController(api: api, scene: ChatScene.feedAi);
        await chat.loadThreads();
        final recorder = _FakeRecorder();
        final uploader = _FakeUploader();
        final recordingApi = _RecordingApi();
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: const _FileStorage(),
        );
        final controller = VoiceMessageController(
          recorder: recorder,
          uploader: uploader,
          localRecordingRepository: repository,
          chatController: chat,
          recordingApi: recordingApi,
        );
        addTearDown(controller.dispose);
        addTearDown(chat.dispose);

        expect(await controller.start(), isTrue);
        expect(controller.state.status, VoiceMessageControllerStatus.recording);
        expect(await controller.pause(), isTrue);
        expect(controller.state.status, VoiceMessageControllerStatus.paused);
        expect(await controller.resume(), isTrue);

        expect(await controller.stopAndSend(), isTrue);

        expect(uploader.drafts.single.recordingId, 'voice-1');
        expect(api.sentVoiceResourceIds, <String>['resource-1']);
        expect(repository.list().rows, hasLength(1));
        expect(
          chat.state.messages.single.contentType,
          ChatMessageContentType.voice,
        );
        expect(chat.state.nextAction.type, ChatNextActionType.pollAsr);
        expect(controller.state.status, VoiceMessageControllerStatus.sent);

        expect(await controller.refreshAsr(), isTrue);
        expect(recordingApi.getAsrCalls, <String>['asr-1']);
        expect(chat.state.nextAction.type, ChatNextActionType.none);
      },
    );

    test(
      'keeps a live transcript as a text draft without uploading voice',
      () async {
        final api = _ChatApi();
        final chat = ChatController(api: api, scene: ChatScene.feedAi);
        final operationLog = <String>[];
        final recorder = _FakeRecorder(operationLog: operationLog);
        final uploader = _FakeUploader();
        final asr = _LiveAsrPort(operationLog: operationLog);
        final liveTranscript = LiveTranscriptController(
          credentialPort: const _LiveCredentialPort(),
          asrPort: asr,
        );
        final controller = VoiceMessageController(
          recorder: recorder,
          uploader: uploader,
          localRecordingRepository: LocalRecordingRepository(
            database: AppDatabase(),
            fileStorage: const _FileStorage(),
          ),
          chatController: chat,
          recordingApi: _RecordingApi(),
          liveTranscriptController: liveTranscript,
          liveTranscriptStopGrace: const Duration(seconds: 1),
        );
        addTearDown(controller.dispose);
        addTearDown(chat.dispose);
        addTearDown(liveTranscript.dispose);
        addTearDown(asr.close);

        expect(
          await controller.startLiveTranscription(owner: 'chat:test'),
          isTrue,
        );
        expect(recorder.startedScenes, <VoiceRecordingScene>[
          VoiceRecordingScene.monologue,
        ]);
        expect(
          controller.state.liveTranscriptStatus,
          LiveTranscriptStatus.transcribing,
        );
        expect(controller.state.elapsedSeconds, 0);
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(controller.state.elapsedSeconds, greaterThanOrEqualTo(1));
        final activeRefreshCalls = recorder.refreshCalls;
        expect(activeRefreshCalls, greaterThanOrEqualTo(1));
        asr.add(
          LiveTranscriptSentence(
            sentenceId: 1,
            text: '请帮我整理这段想法',
            stable: false,
          ),
        );
        await pumpEventQueue(times: 2);

        expect(controller.state.liveTranscriptText, '请帮我整理这段想法');
        expect(await controller.pause(), isFalse);
        expect(controller.state.status, VoiceMessageControllerStatus.recording);
        expect(liveTranscript.state.status, LiveTranscriptStatus.transcribing);
        expect(
          controller.state.liveTranscriptStatus,
          LiveTranscriptStatus.transcribing,
        );
        expect(controller.state.liveTranscriptText, '请帮我整理这段想法');
        expect(asr.stopCalls, 0);
        expect(asr.releaseCalls, 0);
        expect(await controller.resume(), isFalse);
        expect(controller.state.status, VoiceMessageControllerStatus.recording);
        expect(liveTranscript.state.status, LiveTranscriptStatus.transcribing);
        expect(await controller.stopAndTranscribe(owner: 'chat:test'), isTrue);
        expect(controller.state.status, VoiceMessageControllerStatus.idle);
        expect(controller.state.liveTranscriptText, '请帮我整理这段想法');
        final stoppedAt = controller.state.elapsedSeconds;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(controller.state.elapsedSeconds, stoppedAt);
        expect(recorder.startCalls, 1);
        expect(recorder.cancelCalls, 1);
        expect(recorder.refreshCalls, activeRefreshCalls);
        expect(uploader.drafts, isEmpty);
        expect(api.createdContentLineIds, isEmpty);
        expect(api.sentVoiceResourceIds, isEmpty);
        expect(asr.stopCalls, 1);
        expect(asr.releaseCalls, 1);
        expect(operationLog, <String>[
          'recorder.start',
          'asr.stop',
          'asr.release',
          'recorder.cancel',
        ]);
      },
    );

    test('stops a healthy silent live transcript without an error', () async {
      final api = _ChatApi();
      final chat = ChatController(api: api, scene: ChatScene.feedAi);
      final recorder = _FakeRecorder();
      final asr = _LiveAsrPort();
      final liveTranscript = LiveTranscriptController(
        credentialPort: const _LiveCredentialPort(),
        asrPort: asr,
      );
      final controller = VoiceMessageController(
        recorder: recorder,
        uploader: _FakeUploader(),
        localRecordingRepository: LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: const _FileStorage(),
        ),
        chatController: chat,
        recordingApi: _RecordingApi(),
        liveTranscriptController: liveTranscript,
        liveTranscriptStopGrace: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);
      addTearDown(chat.dispose);
      addTearDown(liveTranscript.dispose);
      addTearDown(asr.close);

      expect(
        await controller.startLiveTranscription(owner: 'chat:test'),
        isTrue,
      );
      expect(await controller.stopAndTranscribe(owner: 'chat:test'), isTrue);
      expect(controller.state.status, VoiceMessageControllerStatus.idle);
      expect(controller.state.liveTranscriptText, isEmpty);
      expect(controller.state.liveTranscriptOwner, isNull);
      expect(controller.state.liveTranscriptAttemptId, isNull);
      expect(controller.state.lastErrorCode, isNull);
      expect(recorder.startCalls, 1);
      expect(recorder.cancelCalls, 1);
      expect(asr.stopCalls, 1);
      expect(asr.releaseCalls, 1);
    });

    test(
      'route exit cancels a live capture once and releases its transcript',
      () async {
        final api = _ChatApi();
        final chat = ChatController(api: api, scene: ChatScene.feedAi);
        final recorder = _FakeRecorder();
        final asr = _LiveAsrPort();
        final liveTranscript = LiveTranscriptController(
          credentialPort: const _LiveCredentialPort(),
          asrPort: asr,
        );
        final controller = VoiceMessageController(
          recorder: recorder,
          uploader: _FakeUploader(),
          localRecordingRepository: LocalRecordingRepository(
            database: AppDatabase(),
            fileStorage: const _FileStorage(),
          ),
          chatController: chat,
          recordingApi: _RecordingApi(),
          liveTranscriptController: liveTranscript,
        );
        addTearDown(controller.dispose);
        addTearDown(chat.dispose);
        addTearDown(liveTranscript.dispose);
        addTearDown(asr.close);

        expect(
          await controller.startLiveTranscription(owner: 'chat:test'),
          isTrue,
        );
        final results = await Future.wait<bool>(<Future<bool>>[
          controller.endCaptureForLeave(owner: 'chat:test'),
          controller.endCaptureForLeave(owner: 'chat:test'),
        ]);

        expect(results, <bool>[true, true]);
        expect(controller.state.status, VoiceMessageControllerStatus.idle);
        expect(recorder.startCalls, 1);
        expect(recorder.cancelCalls, 1);
        expect(liveTranscript.state.status, LiveTranscriptStatus.idle);
        expect(asr.stopCalls, 1);
        expect(asr.releaseCalls, 1);
      },
    );

    test(
      'route exit cancels a live start that completes after navigation',
      () async {
        final startGate = Completer<void>();
        final api = _ChatApi();
        final chat = ChatController(api: api, scene: ChatScene.feedAi);
        final recorder = _FakeRecorder();
        final asr = _LiveAsrPort(connectGate: startGate);
        final liveTranscript = LiveTranscriptController(
          credentialPort: const _LiveCredentialPort(),
          asrPort: asr,
        );
        final controller = VoiceMessageController(
          recorder: recorder,
          uploader: _FakeUploader(),
          localRecordingRepository: LocalRecordingRepository(
            database: AppDatabase(),
            fileStorage: const _FileStorage(),
          ),
          chatController: chat,
          recordingApi: _RecordingApi(),
          liveTranscriptController: liveTranscript,
        );
        addTearDown(controller.dispose);
        addTearDown(chat.dispose);
        addTearDown(liveTranscript.dispose);
        addTearDown(asr.close);

        final starting = controller.startLiveTranscription(owner: 'chat:test');
        await Future<void>.delayed(Duration.zero);
        expect(recorder.startCalls, 1);
        expect(await controller.endCaptureForLeave(owner: 'chat:test'), isTrue);
        expect(
          await controller.startLiveTranscription(owner: 'chat:test'),
          isFalse,
        );

        startGate.complete();

        expect(await starting, isTrue);
        expect(controller.state.status, VoiceMessageControllerStatus.idle);
        expect(recorder.cancelCalls, 1);
        expect(liveTranscript.state.status, LiveTranscriptStatus.idle);
        expect(asr.stopCalls, 0);
        expect(asr.releaseCalls, 2);
      },
    );

    test(
      'waits for a shared live transcript stop before starting Chat capture',
      () async {
        final chat = ChatController(api: _ChatApi(), scene: ChatScene.feedAi);
        final stopGate = Completer<void>();
        final asr = _LiveAsrPort(stopGate: stopGate);
        final liveTranscript = LiveTranscriptController(
          credentialPort: const _LiveCredentialPort(),
          asrPort: asr,
        );
        final controller = VoiceMessageController(
          recorder: _FakeRecorder(),
          uploader: _FakeUploader(),
          localRecordingRepository: LocalRecordingRepository(
            database: AppDatabase(),
            fileStorage: const _FileStorage(),
          ),
          chatController: chat,
          recordingApi: _RecordingApi(),
          liveTranscriptController: liveTranscript,
        );
        addTearDown(controller.dispose);
        addTearDown(chat.dispose);
        addTearDown(liveTranscript.dispose);
        addTearDown(asr.close);

        expect(await liveTranscript.start(owner: 'existing:test'), isTrue);
        final attemptId = liveTranscript.state.attemptId;
        final stopping = liveTranscript.stop(
          owner: 'existing:test',
          attemptId: attemptId,
        );
        await Future<void>.delayed(Duration.zero);
        expect(liveTranscript.state.status, LiveTranscriptStatus.stopping);

        final starting = controller.startLiveTranscription(owner: 'chat:test');
        await Future<void>.delayed(Duration.zero);
        stopGate.complete();
        expect(await stopping, isTrue);
        expect(await starting, isTrue);
        expect(controller.state.status, VoiceMessageControllerStatus.recording);
      },
    );

    test(
      'cancels temporary capture when live ASR fails after startup',
      () async {
        final api = _ChatApi();
        final chat = ChatController(api: api, scene: ChatScene.feedAi);
        final cancelGate = Completer<void>();
        final recorder = _FakeRecorder(cancelGate: cancelGate);
        final asr = _LiveAsrPort();
        final liveTranscript = LiveTranscriptController(
          credentialPort: const _LiveCredentialPort(),
          asrPort: asr,
          maxReconnectAttempts: 0,
        );
        final controller = VoiceMessageController(
          recorder: recorder,
          uploader: _FakeUploader(),
          localRecordingRepository: LocalRecordingRepository(
            database: AppDatabase(),
            fileStorage: const _FileStorage(),
          ),
          chatController: chat,
          recordingApi: _RecordingApi(),
          liveTranscriptController: liveTranscript,
        );
        addTearDown(controller.dispose);
        addTearDown(chat.dispose);
        addTearDown(liveTranscript.dispose);
        addTearDown(asr.close);

        expect(
          await controller.startLiveTranscription(owner: 'chat:test'),
          isTrue,
        );
        asr.add(
          LiveTranscriptSentence(
            sentenceId: 1,
            text: '清理前已经识别的文字',
            stable: true,
          ),
        );
        await pumpEventQueue(times: 2);
        asr.addError('TENCENT_LIVE_ASR_NETWORK_FAILED');
        await pumpEventQueue(times: 8);

        expect(liveTranscript.state.status, LiveTranscriptStatus.idle);
        expect(controller.state.status, VoiceMessageControllerStatus.stopping);
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.state.liveTranscriptText, '清理前已经识别的文字');
        expect(recorder.cancelCalls, 1);
        expect(
          await controller.startLiveTranscription(owner: 'chat:test'),
          isFalse,
        );
        expect(recorder.startCalls, 1);

        cancelGate.complete();
        await pumpEventQueue(times: 4);

        expect(controller.state.status, VoiceMessageControllerStatus.failed);
        expect(
          controller.state.lastErrorCode,
          'TENCENT_LIVE_ASR_NETWORK_FAILED',
        );
        expect(controller.state.liveTranscriptText, '清理前已经识别的文字');
        expect(controller.state.isCaptureActive, isFalse);
        expect(recorder.cancelCalls, 1);
        expect(
          await controller.startLiveTranscription(owner: 'chat:test'),
          isTrue,
        );
        expect(recorder.startCalls, 2);
        expect(
          await controller.cancel(liveTranscriptOwner: 'chat:test'),
          isTrue,
        );
      },
    );

    test(
      'native interruption stops live capture and retains recognized text',
      () async {
        final chat = ChatController(api: _ChatApi(), scene: ChatScene.feedAi);
        final recorder = _FakeRecorder();
        final asr = _LiveAsrPort();
        final liveTranscript = LiveTranscriptController(
          credentialPort: const _LiveCredentialPort(),
          asrPort: asr,
        );
        final controller = VoiceMessageController(
          recorder: recorder,
          uploader: _FakeUploader(),
          localRecordingRepository: LocalRecordingRepository(
            database: AppDatabase(),
            fileStorage: const _FileStorage(),
          ),
          chatController: chat,
          recordingApi: _RecordingApi(),
          liveTranscriptController: liveTranscript,
        );
        addTearDown(controller.dispose);
        addTearDown(chat.dispose);
        addTearDown(liveTranscript.dispose);
        addTearDown(asr.close);

        expect(
          await controller.startLiveTranscription(owner: 'chat:test'),
          isTrue,
        );
        asr.add(
          LiveTranscriptSentence(sentenceId: 1, text: '中断前的内容', stable: true),
        );
        await pumpEventQueue(times: 2);
        recorder.setSnapshot(
          VoiceRecorderSnapshot(
            state: VoiceRecorderState.paused,
            session: recorder.snapshot.session,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await pumpEventQueue(times: 4);

        expect(recorder.refreshCalls, greaterThanOrEqualTo(1));
        expect(recorder.cancelCalls, 1);
        expect(asr.stopCalls, 1);
        expect(asr.releaseCalls, 1);
        expect(liveTranscript.state.status, LiveTranscriptStatus.idle);
        expect(controller.state.status, VoiceMessageControllerStatus.failed);
        expect(
          controller.state.lastErrorCode,
          'VOICE_RECORDER_AUDIO_INTERRUPTED',
        );
        expect(controller.state.liveTranscriptText, '中断前的内容');
      },
    );

    test(
      'detects a paused recorder while live ASR is still starting',
      () async {
        final connectGate = Completer<void>();
        final chat = ChatController(api: _ChatApi(), scene: ChatScene.feedAi);
        final recorder = _FakeRecorder();
        final asr = _LiveAsrPort(connectGate: connectGate);
        final liveTranscript = LiveTranscriptController(
          credentialPort: const _LiveCredentialPort(),
          asrPort: asr,
        );
        final controller = VoiceMessageController(
          recorder: recorder,
          uploader: _FakeUploader(),
          localRecordingRepository: LocalRecordingRepository(
            database: AppDatabase(),
            fileStorage: const _FileStorage(),
          ),
          chatController: chat,
          recordingApi: _RecordingApi(),
          liveTranscriptController: liveTranscript,
        );
        addTearDown(controller.dispose);
        addTearDown(chat.dispose);
        addTearDown(liveTranscript.dispose);
        addTearDown(asr.close);

        final starting = controller.startLiveTranscription(owner: 'chat:test');
        await Future<void>.delayed(Duration.zero);
        expect(recorder.startCalls, 1);
        recorder.setSnapshot(
          VoiceRecorderSnapshot(
            state: VoiceRecorderState.paused,
            session: recorder.snapshot.session,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await pumpEventQueue(times: 4);

        expect(recorder.refreshCalls, greaterThanOrEqualTo(1));
        expect(recorder.cancelCalls, 1);
        expect(controller.state.status, VoiceMessageControllerStatus.failed);
        expect(
          controller.state.lastErrorCode,
          'VOICE_RECORDER_AUDIO_INTERRUPTED',
        );

        connectGate.complete();
        expect(await starting, isFalse);
      },
    );

    test('cancels temporary capture when live ASR fails to connect', () async {
      final chat = ChatController(api: _ChatApi(), scene: ChatScene.feedAi);
      final recorder = _FakeRecorder();
      final asr = _LiveAsrPort(
        connectResult: const LiveAsrOperationResult.failure(
          'TENCENT_LIVE_ASR_AUDIO_SOURCE_START_FAILED',
        ),
      );
      final liveTranscript = LiveTranscriptController(
        credentialPort: const _LiveCredentialPort(),
        asrPort: asr,
      );
      final controller = VoiceMessageController(
        recorder: recorder,
        uploader: _FakeUploader(),
        localRecordingRepository: LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: const _FileStorage(),
        ),
        chatController: chat,
        recordingApi: _RecordingApi(),
        liveTranscriptController: liveTranscript,
      );
      addTearDown(controller.dispose);
      addTearDown(chat.dispose);
      addTearDown(liveTranscript.dispose);
      addTearDown(asr.close);

      expect(
        await controller.startLiveTranscription(owner: 'chat:test'),
        isFalse,
      );

      expect(recorder.startCalls, 1);
      expect(recorder.cancelCalls, 1);
      expect(controller.state.status, VoiceMessageControllerStatus.failed);
      expect(
        controller.state.lastErrorCode,
        'TENCENT_LIVE_ASR_AUDIO_SOURCE_START_FAILED',
      );
      expect(controller.state.isCaptureActive, isFalse);
    });

    test('leaves a local recording and exposes an upload failure', () async {
      final api = _ChatApi();
      final chat = ChatController(api: api, scene: ChatScene.feedAi);
      await chat.loadThreads();
      final repository = LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const _FileStorage(),
      );
      final controller = VoiceMessageController(
        recorder: _FakeRecorder(),
        uploader: _FakeUploader(failureCode: 'UPLOAD_OBJECT_FAILED'),
        localRecordingRepository: repository,
        chatController: chat,
        recordingApi: _RecordingApi(),
      );
      addTearDown(controller.dispose);
      addTearDown(chat.dispose);

      await controller.start();
      final sent = await controller.stopAndSend();

      expect(sent, isFalse);
      expect(controller.state.status, VoiceMessageControllerStatus.failed);
      expect(controller.state.lastErrorCode, 'UPLOAD_OBJECT_FAILED');
      expect(repository.list().rows, hasLength(1));
      expect(api.sentVoiceResourceIds, isEmpty);
    });
  });
}

VoiceMessageController _controller({
  required ChatController chat,
  required _FakeRecorder recorder,
}) {
  return VoiceMessageController(
    recorder: recorder,
    uploader: _FakeUploader(),
    localRecordingRepository: LocalRecordingRepository(
      database: AppDatabase(),
      fileStorage: const _FileStorage(),
    ),
    chatController: chat,
    recordingApi: _RecordingApi(),
  );
}

final class _ChatApi implements ChatRepository {
  final sentVoiceResourceIds = <String>[];
  final createdContentLineIds = <String?>[];
  final sentVoiceContentLineIds = <String?>[];

  @override
  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    createdContentLineIds.add(contentLineId);
    return _success(
      const ChatThread(threadId: 'feed-1', scene: ChatScene.feedAi),
      idempotencyStore,
    );
  }

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async {
    return _success(
      ChatThreadDetail(
        thread: ChatThread(threadId: threadId, scene: ChatScene.feedAi),
        messages: const <ChatMessage>[],
      ),
      SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async {
    return _success(
      const ChatThreadPage(
        items: <ChatThread>[
          ChatThread(threadId: 'feed-1', scene: ChatScene.feedAi),
        ],
      ),
      SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<ChatTextMutation>> sendTextMessage({
    required String threadId,
    required ChatScene scene,
    required String content,
    String? contentLineId,
    ChatContextEnvelope? context,
    String? agentProfileId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<ChatVoiceMutation>> sendVoiceMessage({
    required String threadId,
    required ChatScene scene,
    required String audioResourceId,
    required int durationSeconds,
    String? contentLineId,
    ChatContextEnvelope? context,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    sentVoiceResourceIds.add(audioResourceId);
    sentVoiceContentLineIds.add(contentLineId);
    return _success(
      const ChatVoiceMutation(
        message: ChatMessage(
          messageId: 'voice-message-1',
          threadId: 'feed-1',
          scene: ChatScene.feedAi,
          role: ChatMessageRole.user,
          contentType: ChatMessageContentType.voice,
          status: 'sent',
        ),
        nextAction: ChatNextAction(
          type: ChatNextActionType.pollAsr,
          asrTaskId: 'asr-1',
        ),
      ),
      idempotencyStore,
    );
  }
}

final class _FakeRecorder implements VoiceRecorderPort {
  _FakeRecorder({this.operationLog, this.cancelGate});

  final List<String>? operationLog;
  final Completer<void>? cancelGate;
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();
  int startCalls = 0;
  int cancelCalls = 0;
  int refreshCalls = 0;
  final startedScenes = <VoiceRecordingScene>[];

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    cancelCalls += 1;
    operationLog?.add('recorder.cancel');
    await cancelGate?.future;
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(_snapshot);
  }

  void setSnapshot(VoiceRecorderSnapshot snapshot) {
    _snapshot = snapshot;
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async {
    return VoiceRecorderResult.success(
      const VoiceRecorderPermission(
        state: VoiceRecorderPermissionState.granted,
        canAskAgain: false,
      ),
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async {
    _snapshot = _snapshot.copyWith(
      state: VoiceRecorderState.paused,
      session: _session(VoiceRecorderState.paused),
    );
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async {
    refreshCalls += 1;
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() => getMicrophonePermission();

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async {
    _snapshot = _snapshot.copyWith(
      state: VoiceRecorderState.recording,
      session: _session(VoiceRecorderState.recording),
    );
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    startCalls += 1;
    operationLog?.add('recorder.start');
    startedScenes.add(scene);
    final session = _session(VoiceRecorderState.recording, scene: scene);
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: session,
    );
    return VoiceRecorderResult.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() async {
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(
      VoiceRecordingDraft(
        recordingId: 'voice-1',
        appPrivateUri: 'app-private://recordings/voice-1/source.m4a',
        fileName: 'source.m4a',
        mimeType: 'audio/mp4',
        sizeBytes: 333,
        durationSeconds: 3,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        recordedAt: DateTime.utc(2026, 7, 10, 8),
      ),
    );
  }

  VoiceRecordingSession _session(
    VoiceRecorderState state, {
    VoiceRecordingScene scene = VoiceRecordingScene.feedAi,
  }) {
    return VoiceRecordingSession(
      recordingId: 'voice-1',
      scene: scene,
      state: state,
      startedAt: DateTime.utc(2026, 7, 10, 8),
      elapsedSeconds: 3,
    );
  }
}

final class _LiveCredentialPort implements LiveTranscriptionCredentialPort {
  const _LiveCredentialPort();

  @override
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  }) async {
    return ApiResult<LiveAsrSessionCredential>.success(
      data: LiveAsrSessionCredential(
        sessionId: 'live-chat-session',
        appId: 123456789,
        projectId: 0,
        tmpSecretId: 'tmp-secret-id',
        tmpSecretKey: 'tmp-secret-key',
        token: 'tmp-token',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
      ),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

final class _LiveAsrPort implements TencentLiveAsrPort {
  _LiveAsrPort({
    this.operationLog,
    this.connectGate,
    this.stopGate,
    this.connectResult = const LiveAsrOperationResult.success(),
  });

  final List<String>? operationLog;
  final Completer<void>? connectGate;
  final Completer<void>? stopGate;
  final LiveAsrOperationResult connectResult;
  final StreamController<LiveTranscriptSentence> _events =
      StreamController<LiveTranscriptSentence>.broadcast(sync: true);
  int stopCalls = 0;
  int releaseCalls = 0;

  @override
  Stream<LiveTranscriptSentence> get events => _events.stream;

  void add(LiveTranscriptSentence sentence) => _events.add(sentence);

  void addError(Object error) => _events.addError(error);

  @override
  Future<LiveAsrOperationResult> connect(
    LiveAsrSessionCredential credential,
  ) async {
    await connectGate?.future;
    return connectResult;
  }

  @override
  Future<LiveAsrOperationResult> stop() async {
    stopCalls += 1;
    operationLog?.add('asr.stop');
    await stopGate?.future;
    return const LiveAsrOperationResult.success();
  }

  @override
  Future<LiveAsrOperationResult> release() async {
    releaseCalls += 1;
    operationLog?.add('asr.release');
    return const LiveAsrOperationResult.success();
  }

  Future<void> close() => _events.close();
}

final class _FakeUploader implements ChatVoiceUploadPort {
  _FakeUploader({this.failureCode});

  final String? failureCode;
  final drafts = <VoiceRecordingDraft>[];

  @override
  Future<ChatVoiceUploadResult<ResourceIndex>> uploadVoice(
    VoiceRecordingDraft draft,
  ) async {
    drafts.add(draft);
    final failureCode = this.failureCode;
    if (failureCode != null) {
      return ChatVoiceUploadResult.failure(
        AppFailure(
          code: failureCode,
          category: AppFailureCategory.api,
          message: 'upload failed',
          userMessageKey: 'test.upload.failed',
        ),
      );
    }
    return ChatVoiceUploadResult.success(
      const ResourceIndex(
        resourceId: 'resource-1',
        uploadId: 'upload-1',
        sourceScene: 'workspace_voice',
        mimeType: 'audio/mp4',
        sizeBytes: 333,
        durationSeconds: 3,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    );
  }
}

final class _FileStorage extends UnavailableFileStoragePort {
  const _FileStorage();

  @override
  Future<FileStorageResult<PrivateAudioFile>> copyPickedAudioToPrivateLibrary(
    PickedAudioFile picked,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<FileStorageResult<bool>> deletePrivateAudio(String appPrivateUri) {
    throw UnimplementedError();
  }

  @override
  Future<FileStorageResult<PreparedAudioExport>> prepareAudioExport({
    required String appPrivateUri,
    required String displayName,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult.success(
      const PrivateAudioFileStat(exists: true, sizeBytes: 333),
    );
  }

  @override
  Future<FileStorageResult<bool>> updatePrivateAudioMetadata({
    required String appPrivateUri,
    required String displayName,
  }) {
    throw UnimplementedError();
  }
}

final class _RecordingApi implements RecordingApiPort {
  final getAsrCalls = <String>[];

  @override
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId) async {
    getAsrCalls.add(asrTaskId);
    return _success(
      const AsrTaskSnapshot(
        asrTaskId: 'asr-1',
        status: RecordingRemoteStatus.completed,
        progress: 100,
      ),
      SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(String recordingId) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }
}

ApiResult<T> _success<T>(T data, SubmissionKeyStore idempotencyStore) {
  return ApiResult<T>.success(
    data: data,
    status: 200,
    idempotencyStore: idempotencyStore,
  );
}

UploadClient _unusedUploadClient() {
  return UploadClient(
    apiClient: ApiClient(
      config: ApiClientConfig(
        baseUrl: Uri.parse('https://api.example.test'),
        clientVersion: 'test',
        deviceId: 'device-test',
        platform: 'test',
        locale: 'zh-CN',
      ),
      transport: const _UnusedApiTransport(),
    ),
    objectTransport: const _UnusedObjectTransport(),
  );
}

final class _UnusedApiTransport implements ApiTransport {
  const _UnusedApiTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    throw StateError('unexpected API request');
  }
}

final class _UnusedObjectTransport implements ObjectUploadTransport {
  const _UnusedObjectTransport();

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) {
    throw StateError('unexpected object upload');
  }
}
