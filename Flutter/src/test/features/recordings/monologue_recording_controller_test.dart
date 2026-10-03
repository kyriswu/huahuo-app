import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recordings/application/monologue_recording_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/transcription/data/tencent_live_asr_port.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MonologueRecordingController transcript-first journey', () {
    test('projects live transcript sentences into editable text', () async {
      final harness = _MonologueHarness();
      addTearDown(harness.dispose);

      expect(await harness.controller.start(), isTrue);
      expect(harness.recorder.requestedScene, VoiceRecordingScene.monologue);

      harness.asr.add(_sentence(0, '第一段想法'));
      harness.asr.add(_sentence(1, '第二段想法'));
      await pumpEventQueue(times: 3);

      expect(
        harness.controller.state.status,
        MonologueRecordingStatus.recording,
      );
      expect(harness.controller.state.transcriptText, '第一段想法\n第二段想法');
      expect(await harness.controller.cancel(), isTrue);
    });

    test('pause edit and resume appends the next live segment', () async {
      final harness = _MonologueHarness();
      addTearDown(harness.dispose);

      expect(await harness.controller.start(), isTrue);
      harness.asr.add(_sentence(0, '识别有误的文字'));
      await pumpEventQueue(times: 3);

      expect(await harness.controller.pause(), isTrue);
      expect(harness.controller.state.canEditTranscript, isTrue);
      expect(harness.controller.updateTranscript('用户修正后的文字'), isTrue);
      harness.recorder.operationLog.clear();
      expect(await harness.controller.resume(), isTrue);
      expect(harness.recorder.operationLog.take(2), <String>[
        'native_resume',
        'asr_connect',
      ]);

      harness.asr.add(_sentence(0, '继续说出的内容'));
      await pumpEventQueue(times: 3);

      expect(harness.controller.state.transcriptText, '用户修正后的文字\n继续说出的内容');
      expect(await harness.controller.pause(), isTrue);
      expect(harness.controller.updateTranscript('用户修正后的文字\n第二次修改'), isTrue);
      expect(await harness.controller.resume(), isTrue);
      harness.asr.add(_sentence(0, '第三段内容'));
      await pumpEventQueue(times: 3);

      expect(harness.controller.state.transcriptText, '用户修正后的文字\n第二次修改\n第三段内容');
      expect(harness.recorder.pauseCalls, 2);
      expect(harness.recorder.resumeCalls, 2);
      expect(await harness.controller.cancel(), isTrue);
    });

    test(
      'live resume failure rolls the same native session back before retry',
      () async {
        final harness = _MonologueHarness(
          asrConnectOutcomes: <bool>[true, false, true],
        );
        addTearDown(harness.dispose);

        expect(await harness.controller.start(), isTrue);
        harness.asr.add(_sentence(0, '失败前已经保留的文字'));
        await pumpEventQueue(times: 3);
        expect(await harness.controller.pause(), isTrue);
        expect(harness.controller.updateTranscript('用户编辑后保留的文字'), isTrue);

        expect(await harness.controller.resume(), isFalse);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.failed,
        );
        expect(
          harness.controller.state.failureStage,
          MonologueFailureStage.liveTranscription,
        );
        expect(
          harness.controller.state.nativeCaptureLatch,
          MonologueNativeCaptureLatch.paused,
        );
        expect(harness.controller.state.canResume, isTrue);
        expect(harness.controller.state.canFinish, isTrue);
        expect(harness.controller.state.transcriptText, '用户编辑后保留的文字');
        expect(harness.recorder.snapshot.state, VoiceRecorderState.paused);
        expect(harness.recorder.cancelCalls, 0);

        harness.recorder.operationLog.clear();
        expect(await harness.controller.retry(), isTrue);
        expect(harness.recorder.operationLog.take(2), <String>[
          'native_resume',
          'asr_connect',
        ]);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.recording,
        );
        expect(harness.asr.connectCalls, 3);
        expect(await harness.controller.cancel(), isTrue);
      },
    );

    test('native transition receipts must reach their target state', () async {
      final pauseMismatch = _MonologueHarness(
        recorder: _FakeRecorder(pauseTargetState: VoiceRecorderState.recording),
      );
      addTearDown(pauseMismatch.dispose);

      expect(await pauseMismatch.controller.start(), isTrue);
      expect(await pauseMismatch.controller.pause(), isFalse);
      expect(
        pauseMismatch.controller.state.status,
        MonologueRecordingStatus.recording,
      );
      expect(
        pauseMismatch.controller.state.nativeCaptureLatch,
        MonologueNativeCaptureLatch.recording,
      );
      expect(pauseMismatch.controller.state.canPause, isTrue);
      expect(
        pauseMismatch.liveTranscript.state.status,
        LiveTranscriptStatus.transcribing,
      );
      expect(pauseMismatch.asr.stopCalls, 0);
      expect(pauseMismatch.recorder.cancelCalls, 0);
      expect(await pauseMismatch.controller.cancel(), isTrue);

      final resumeMismatch = _MonologueHarness(
        recorder: _FakeRecorder(resumeTargetState: VoiceRecorderState.paused),
      );
      addTearDown(resumeMismatch.dispose);

      expect(await resumeMismatch.controller.start(), isTrue);
      expect(await resumeMismatch.controller.pause(), isTrue);
      expect(await resumeMismatch.controller.resume(), isFalse);
      expect(
        resumeMismatch.controller.state.failureStage,
        MonologueFailureStage.nativeCapture,
      );
      expect(
        resumeMismatch.controller.state.nativeCaptureLatch,
        MonologueNativeCaptureLatch.paused,
      );
      expect(resumeMismatch.controller.state.canResume, isTrue);
      expect(resumeMismatch.asr.connectCalls, 1);
      expect(resumeMismatch.recorder.cancelCalls, 0);
      expect(await resumeMismatch.controller.cancel(), isTrue);
    });

    test(
      'lost native session during pause releases live ASR before retry',
      () async {
        final harness = _MonologueHarness(
          recorder: _FakeRecorder(pauseTargetState: VoiceRecorderState.idle),
        );
        addTearDown(harness.dispose);

        expect(await harness.controller.start(), isTrue);
        expect(
          harness.liveTranscript.state.status,
          LiveTranscriptStatus.transcribing,
        );

        expect(await harness.controller.pause(), isFalse);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.failed,
        );
        expect(
          harness.controller.state.failureStage,
          MonologueFailureStage.nativeCapture,
        );
        expect(
          harness.controller.state.nativeCaptureLatch,
          MonologueNativeCaptureLatch.none,
        );
        expect(harness.controller.hasOwnedNativeCapture, isFalse);
        expect(harness.liveTranscript.state.status, LiveTranscriptStatus.idle);
        expect(harness.asr.stopCalls, 1);
        expect(harness.asr.releaseCalls, 1);

        expect(await harness.controller.retry(), isTrue);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.recording,
        );
        expect(harness.asr.connectCalls, 2);
        expect(await harness.controller.cancel(), isTrue);
      },
    );

    test(
      'native start receipt must reach recording before it is latched',
      () async {
        final harness = _MonologueHarness(
          recorder: _FakeRecorder(startTargetState: VoiceRecorderState.paused),
        );
        addTearDown(harness.dispose);

        expect(await harness.controller.start(), isFalse);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.failed,
        );
        expect(
          harness.controller.state.failureStage,
          MonologueFailureStage.nativeStart,
        );
        expect(
          harness.controller.state.nativeCaptureLatch,
          MonologueNativeCaptureLatch.none,
        );
        expect(harness.recorder.cancelCalls, 1);
        expect(harness.asr.connectCalls, 0);
      },
    );

    test(
      'leave waits for a pausing transaction and refuses unsafe exit',
      () async {
        final pauseGate = Completer<void>();
        final harness = _MonologueHarness(
          recorder: _FakeRecorder(
            pauseGate: pauseGate,
            pauseTargetState: VoiceRecorderState.recording,
          ),
        );
        addTearDown(harness.dispose);

        expect(await harness.controller.start(), isTrue);
        final pausing = harness.controller.pause();
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.pausing,
        );
        final leaving = harness.controller.endCaptureForLeave();
        var leaveSettled = false;
        unawaited(leaving.then((_) => leaveSettled = true));
        await pumpEventQueue(times: 2);
        expect(leaveSettled, isFalse);

        pauseGate.complete();
        expect(await pausing, isFalse);
        expect(await leaving, isFalse);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.recording,
        );
        expect(
          harness.controller.state.nativeCaptureLatch,
          MonologueNativeCaptureLatch.recording,
        );
        expect(harness.recorder.cancelCalls, 0);
        expect(await harness.controller.cancel(), isTrue);
      },
    );

    test(
      'live stop timeout leaves the same paused capture recoverable',
      () async {
        final harness = _MonologueHarness(
          hangAsrStop: true,
          liveTranscriptStopGrace: const Duration(milliseconds: 20),
        );
        addTearDown(harness.dispose);

        expect(await harness.controller.start(), isTrue);
        harness.asr.add(_sentence(0, '超时前已经识别的文字'));
        await pumpEventQueue(times: 3);

        expect(await harness.controller.pause(), isFalse);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.failed,
        );
        expect(
          harness.controller.state.failureStage,
          MonologueFailureStage.liveTranscription,
        );
        expect(
          harness.controller.state.lastErrorCode,
          'LIVE_TRANSCRIPT_STOP_TIMEOUT',
        );
        expect(
          harness.controller.state.nativeCaptureLatch,
          MonologueNativeCaptureLatch.paused,
        );
        expect(harness.controller.state.canFinish, isTrue);
        expect(harness.controller.state.canRetry, isTrue);
        expect(harness.controller.state.transcriptText, '超时前已经识别的文字');
        expect(harness.recorder.snapshot.state, VoiceRecorderState.paused);
        expect(harness.recorder.cancelCalls, 0);
        expect(harness.liveTranscript.state.status, LiveTranscriptStatus.idle);

        expect(await harness.controller.retry(), isTrue);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.recording,
        );
      },
    );

    test('stop stores history audio and directly syncs one note', () async {
      final harness = _MonologueHarness();
      addTearDown(harness.dispose);

      expect(await harness.controller.start(), isTrue);
      harness.asr.add(_sentence(0, '这是实时形成的独白原文'));
      await pumpEventQueue(times: 3);

      expect(await harness.controller.stop(), isTrue);

      final state = harness.controller.state;
      expect(state.status, MonologueRecordingStatus.completed);
      expect(state.localNoteId, isNotNull);
      expect(harness.repository.list().rows, hasLength(1));
      final recording = harness.repository.list().rows.single;
      expect(recording.source, RecordingLibrarySource.microphone);
      expect(recording.tagIds, contains(monologueRecordingHistoryTagId));
      expect(recording.displayName, startsWith('独白-'));

      expect(harness.notePort.requests, hasLength(1));
      expect(harness.notePort.requests.single.noteId, state.localNoteId);
      expect(harness.notePort.requests.single.draft.rawBody, '这是实时形成的独白原文');
      expect(harness.knowledge.notes, hasLength(1));
      expect(
        harness.knowledge.noteForId(state.localNoteId!)?.rawBody,
        '这是实时形成的独白原文',
      );

      expect(await harness.controller.start(), isTrue);
      expect(
        harness.controller.state.status,
        MonologueRecordingStatus.recording,
      );
      expect(harness.controller.state.transcriptText, isEmpty);
      expect(harness.controller.state.localNoteId, isNull);
      expect(harness.recorder.startCalls, 2);
      expect(harness.knowledge.noteForId(state.localNoteId!), isNotNull);
      expect(await harness.controller.cancel(), isTrue);
    });

    test('note sync retry reuses the latched local note id', () async {
      final notePort = _QueueNotePort(failuresBeforeSuccess: 1);
      final harness = _MonologueHarness(notePort: notePort);
      addTearDown(harness.dispose);

      expect(await harness.controller.start(), isTrue);
      harness.asr.add(_sentence(0, '网络恢复后仍应是同一篇笔记'));
      await pumpEventQueue(times: 3);

      expect(await harness.controller.stop(), isFalse);
      final failedNoteId = harness.controller.state.localNoteId;
      expect(failedNoteId, isNotNull);
      expect(harness.controller.state.status, MonologueRecordingStatus.failed);
      expect(
        harness.controller.state.failureStage,
        MonologueFailureStage.noteSave,
      );
      expect(harness.controller.state.lastErrorCode, 'TEST_NOTE_SYNC_FAILED');
      expect(harness.repository.list().rows, hasLength(1));
      expect(harness.knowledge.notes, hasLength(1));

      expect(await harness.controller.retry(), isTrue);

      expect(
        harness.controller.state.status,
        MonologueRecordingStatus.completed,
      );
      expect(harness.controller.state.localNoteId, failedNoteId);
      expect(harness.repository.list().rows, hasLength(1));
      expect(harness.knowledge.notes, hasLength(1));
      expect(notePort.requests, hasLength(2));
      expect(
        notePort.requests.map((request) => request.noteId).toSet(),
        <String>{failedNoteId!},
      );
    });

    test('latches one start while microphone permission is pending', () async {
      final permission = Completer<VoiceRecorderPermission>();
      final harness = _MonologueHarness(
        recorder: _FakeRecorder(permissionGate: permission),
      );
      addTearDown(harness.dispose);

      final firstStart = harness.controller.start();
      expect(await harness.controller.start(), isFalse);
      permission.complete(_grantedPermission);

      expect(await firstStart, isTrue);
      expect(harness.recorder.startCalls, 1);
      expect(await harness.controller.cancel(), isTrue);
    });

    test(
      'rejects foreign native scene and mismatched stopped session',
      () async {
        final foreignScene = _MonologueHarness(
          recorder: _FakeRecorder(startedScene: VoiceRecordingScene.internal),
        );
        addTearDown(foreignScene.dispose);

        expect(await foreignScene.controller.start(), isFalse);
        expect(
          foreignScene.controller.state.failureStage,
          MonologueFailureStage.nativeStart,
        );
        expect(foreignScene.recorder.cancelCalls, 0);
        expect(foreignScene.repository.list().rows, isEmpty);

        final mismatchedDraft = _MonologueHarness(
          recorder: _FakeRecorder(stoppedRecordingId: 'another-session'),
        );
        addTearDown(mismatchedDraft.dispose);

        expect(await mismatchedDraft.controller.start(), isTrue);
        mismatchedDraft.asr.add(_sentence(0, '不会保存到错误会话'));
        await pumpEventQueue(times: 3);
        expect(await mismatchedDraft.controller.stop(), isFalse);
        expect(
          mismatchedDraft.controller.state.failureStage,
          MonologueFailureStage.draftValidation,
        );
        expect(
          mismatchedDraft.controller.state.lastErrorCode,
          'MONOLOGUE_RECORDING_DRAFT_MISMATCH',
        );
        expect(mismatchedDraft.repository.list().rows, isEmpty);
        expect(mismatchedDraft.notePort.requests, isEmpty);
        expect(await mismatchedDraft.controller.retry(), isTrue);
        expect(
          mismatchedDraft.controller.state.status,
          MonologueRecordingStatus.recording,
        );
        expect(mismatchedDraft.recorder.startCalls, 2);
        expect(await mismatchedDraft.controller.cancel(), isTrue);
      },
    );

    test(
      'stop failure retains owned session and blocks leave until retry succeeds',
      () async {
        final harness = _MonologueHarness(
          recorder: _FakeRecorder(stopFailuresBeforeSuccess: 1),
        );
        addTearDown(harness.dispose);

        expect(await harness.controller.start(), isTrue);
        harness.asr.add(_sentence(0, '停止失败后仍保留这一段独白'));
        await pumpEventQueue(times: 3);

        expect(await harness.controller.endCaptureForLeave(), isFalse);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.failed,
        );
        expect(
          harness.controller.state.failureStage,
          MonologueFailureStage.nativeStop,
        );
        expect(harness.controller.hasOwnedNativeCapture, isTrue);
        expect(harness.recorder.stopCalls, 1);

        expect(await harness.controller.retry(), isTrue);
        expect(
          harness.controller.state.status,
          MonologueRecordingStatus.completed,
        );
        expect(harness.controller.hasOwnedNativeCapture, isFalse);
        expect(harness.recorder.stopCalls, 2);
      },
    );
  });
}

const _grantedPermission = VoiceRecorderPermission(
  state: VoiceRecorderPermissionState.granted,
  canAskAgain: false,
);

LiveTranscriptSentence _sentence(int id, String text) =>
    LiveTranscriptSentence(sentenceId: id, text: text, stable: true);

final class _MonologueHarness {
  _MonologueHarness({
    _FakeRecorder? recorder,
    _QueueNotePort? notePort,
    List<bool>? asrConnectOutcomes,
    bool hangAsrStop = false,
    Duration liveTranscriptStopGrace = const Duration(milliseconds: 1200),
  }) : recorder = recorder ?? _FakeRecorder(),
       notePort = notePort ?? _QueueNotePort(),
       database = AppDatabase() {
    repository = LocalRecordingRepository(
      database: database,
      fileStorage: const _FileStorage(),
    );
    knowledge = KnowledgeLibraryController(
      includeDemoFixtures: false,
      initialNotes: const [],
      notePort: this.notePort,
    );
    asr = _LiveAsr(
      recorder: this.recorder,
      connectOutcomes: asrConnectOutcomes,
      hangStop: hangAsrStop,
    );
    liveTranscript = LiveTranscriptController(
      credentialPort: const _LiveCredentialPort(),
      asrPort: asr,
      now: () => DateTime.utc(2026, 9, 4, 10),
    );
    controller = MonologueRecordingController(
      recorder: this.recorder,
      localRecordingRepository: repository,
      knowledgeLibrary: knowledge,
      liveTranscriptController: liveTranscript,
      correlationIdFactory: () => 'monologue-test-session',
      liveTranscriptStopGrace: liveTranscriptStopGrace,
    );
  }

  final _FakeRecorder recorder;
  final _QueueNotePort notePort;
  final AppDatabase database;
  late final LocalRecordingRepository repository;
  late final KnowledgeLibraryController knowledge;
  late final _LiveAsr asr;
  late final LiveTranscriptController liveTranscript;
  late final MonologueRecordingController controller;

  Future<void> dispose() async {
    controller.dispose();
    await pumpEventQueue(times: 2);
    liveTranscript.dispose();
    await asr.close();
    knowledge.dispose();
  }
}

final class _QueueNotePort implements KnowledgeNotePort {
  _QueueNotePort({this.failuresBeforeSuccess = 0});

  final int failuresBeforeSuccess;
  final List<KnowledgeNoteUpdateRequest> requests =
      <KnowledgeNoteUpdateRequest>[];

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    requests.add(request);
    if (requests.length <= failuresBeforeSuccess) {
      return const KnowledgeNotePortResult.failure('TEST_NOTE_SYNC_FAILED');
    }
    final local = request.localNote!;
    return KnowledgeNotePortResult.success(
      local.copyWith(
        remoteRevision: (local.remoteRevision ?? 0) + 1,
        remoteNoteId: 'remote-${local.id}',
        noteRevisionId: 'note-revision-${requests.length}',
        rawPartRevisionId: 'raw-revision-${requests.length}',
        etag: '"note-${requests.length}"',
        contentCursor: 'cursor-${requests.length}',
      ),
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
        sessionId: 'live-session-monologue',
        appId: 123456789,
        projectId: 0,
        tmpSecretId: 'tmp-secret-id',
        tmpSecretKey: 'tmp-secret-key',
        token: 'tmp-token',
        expiresAt: DateTime.utc(2026, 9, 4, 10, 15),
      ),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

final class _LiveAsr implements TencentLiveAsrPort {
  _LiveAsr({
    required this.recorder,
    List<bool>? connectOutcomes,
    this.hangStop = false,
  }) : _connectOutcomes = List<bool>.of(connectOutcomes ?? const <bool>[]);

  final _FakeRecorder recorder;
  final List<bool> _connectOutcomes;
  final bool hangStop;
  final Completer<LiveAsrOperationResult> _stopGate =
      Completer<LiveAsrOperationResult>();
  final StreamController<LiveTranscriptSentence> _events =
      StreamController<LiveTranscriptSentence>.broadcast();
  int connectCalls = 0;
  int stopCalls = 0;
  int releaseCalls = 0;

  @override
  Stream<LiveTranscriptSentence> get events => _events.stream;

  void add(LiveTranscriptSentence sentence) => _events.add(sentence);

  @override
  Future<LiveAsrOperationResult> connect(
    LiveAsrSessionCredential credential,
  ) async {
    connectCalls += 1;
    recorder.operationLog.add('asr_connect');
    if (recorder.snapshot.state != VoiceRecorderState.recording) {
      return const LiveAsrOperationResult.failure(
        'TEST_ASR_REQUIRES_RUNNING_PCM',
      );
    }
    if (_connectOutcomes.isNotEmpty && !_connectOutcomes.removeAt(0)) {
      return const LiveAsrOperationResult.failure('TEST_ASR_CONNECT_FAILED');
    }
    return const LiveAsrOperationResult.success();
  }

  @override
  Future<LiveAsrOperationResult> release() async {
    releaseCalls += 1;
    return const LiveAsrOperationResult.success();
  }

  @override
  Future<LiveAsrOperationResult> stop() async {
    stopCalls += 1;
    if (hangStop) return _stopGate.future;
    return const LiveAsrOperationResult.success();
  }

  Future<void> close() => _events.close();
}

final class _FakeRecorder
    implements VoiceRecorderPort, VoiceRecorderLevelSource {
  _FakeRecorder({
    this.permissionGate,
    this.startedScene,
    this.startTargetState = VoiceRecorderState.recording,
    this.stoppedRecordingId = 'voice-1',
    this.stopFailuresBeforeSuccess = 0,
    this.pauseGate,
    this.pauseTargetState = VoiceRecorderState.paused,
    this.resumeTargetState = VoiceRecorderState.recording,
  });

  final Completer<VoiceRecorderPermission>? permissionGate;
  final VoiceRecordingScene? startedScene;
  final VoiceRecorderState startTargetState;
  final String stoppedRecordingId;
  final int stopFailuresBeforeSuccess;
  final Completer<void>? pauseGate;
  final VoiceRecorderState pauseTargetState;
  final VoiceRecorderState resumeTargetState;
  final StreamController<VoiceLevelSample> _levels =
      StreamController<VoiceLevelSample>.broadcast();

  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();
  VoiceRecordingScene? requestedScene;
  int startCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  final List<String> operationLog = <String>[];

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Stream<VoiceLevelSample> get levelSamples => _levels.stream;

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async {
    return VoiceRecorderResult.success(
      permissionGate == null
          ? _grantedPermission
          : await permissionGate!.future,
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() async =>
      VoiceRecorderResult.success(_grantedPermission);

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    startCalls += 1;
    requestedScene = scene;
    final session = _session(
      state: startTargetState,
      scene: startedScene ?? scene,
    );
    _snapshot = VoiceRecorderSnapshot(
      state: startTargetState,
      session: session,
    );
    return VoiceRecorderResult.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async {
    pauseCalls += 1;
    operationLog.add('native_pause');
    await pauseGate?.future;
    _snapshot = VoiceRecorderSnapshot(
      state: pauseTargetState,
      session: _session(
        state: pauseTargetState,
        scene: requestedScene ?? VoiceRecordingScene.monologue,
      ),
    );
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async {
    resumeCalls += 1;
    operationLog.add('native_resume');
    _snapshot = VoiceRecorderSnapshot(
      state: resumeTargetState,
      session: _session(
        state: resumeTargetState,
        scene: requestedScene ?? VoiceRecordingScene.monologue,
      ),
    );
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() async {
    stopCalls += 1;
    if (stopCalls <= stopFailuresBeforeSuccess) {
      return VoiceRecorderResult.failure(
        const AppFailure(
          code: 'VOICE_RECORDER_STOP_FAILED',
          category: AppFailureCategory.storage,
          message: 'stop failed',
          userMessageKey: 'voice.test.stopFailed',
        ),
      );
    }
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(
      VoiceRecordingDraft(
        recordingId: stoppedRecordingId,
        appPrivateUri: 'app-private://source.wav',
        fileName: 'source.wav',
        mimeType: 'audio/wav',
        sizeBytes: 333,
        durationSeconds: 3,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        scene: VoiceRecordingScene.monologue,
        sampleRateHz: 16000,
        bitDepth: 16,
        channelCount: 1,
        recordedAt: DateTime.utc(2026, 9, 4, 10),
      ),
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    cancelCalls += 1;
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(_snapshot);
  }

  VoiceRecordingSession _session({
    required VoiceRecorderState state,
    required VoiceRecordingScene scene,
  }) {
    return VoiceRecordingSession(
      recordingId: 'voice-1',
      scene: scene,
      state: state,
      startedAt: DateTime.utc(2026, 9, 4, 10),
      elapsedSeconds: 3,
    );
  }
}

final class _FileStorage extends UnavailableFileStoragePort {
  const _FileStorage();

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async => FileStorageResult.success(
    const PrivateAudioFileStat(exists: true, sizeBytes: 333),
  );
}
