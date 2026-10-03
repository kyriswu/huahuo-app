import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/di/chat_providers.dart';
import '../../../app/lifecycle/app_activity_coordinator.dart';
import '../../../core/api/upload_client.dart';
import '../../../core/native/voice_recorder_port.dart';
import '../../../core/storage/file_storage_port.dart';
import '../../recordings/data/local_recording_repository.dart';
import '../../recordings/data/recording_api.dart';
import '../../transcription/application/live_transcript_controller.dart';
import 'chat_controller.dart';
import 'chat_voice_uploader.dart';
import '../domain/chat_models.dart';

enum VoiceMessageControllerStatus {
  idle,
  checkingPermission,
  starting,
  recording,
  paused,
  stopping,
  registeringLocal,
  uploading,
  sending,
  asrPolling,
  sent,
  failed,
}

final class VoiceMessageState {
  const VoiceMessageState({
    required this.status,
    this.elapsedSeconds = 0,
    this.lastErrorCode,
    this.asrProgress,
    this.liveTranscriptText = '',
    this.isLiveTranscription = false,
    this.liveTranscriptStatus,
    this.liveTranscriptOwner,
    this.liveTranscriptAttemptId,
  });

  factory VoiceMessageState.initial() {
    return const VoiceMessageState(status: VoiceMessageControllerStatus.idle);
  }

  final VoiceMessageControllerStatus status;
  final int elapsedSeconds;
  final String? lastErrorCode;
  final int? asrProgress;
  final String liveTranscriptText;
  final bool isLiveTranscription;
  final LiveTranscriptStatus? liveTranscriptStatus;
  final String? liveTranscriptOwner;
  final int? liveTranscriptAttemptId;

  bool belongsToLiveTranscript(String owner, {int? attemptId}) {
    final normalizedOwner = owner.trim();
    return normalizedOwner.isNotEmpty &&
        liveTranscriptOwner == normalizedOwner &&
        (attemptId == null || liveTranscriptAttemptId == attemptId);
  }

  bool get isCaptureActive {
    return status == VoiceMessageControllerStatus.recording ||
        status == VoiceMessageControllerStatus.paused;
  }

  bool get isBusy {
    return status == VoiceMessageControllerStatus.checkingPermission ||
        status == VoiceMessageControllerStatus.starting ||
        status == VoiceMessageControllerStatus.stopping ||
        status == VoiceMessageControllerStatus.registeringLocal ||
        status == VoiceMessageControllerStatus.uploading ||
        status == VoiceMessageControllerStatus.sending ||
        status == VoiceMessageControllerStatus.asrPolling;
  }

  VoiceMessageState copyWith({
    VoiceMessageControllerStatus? status,
    int? elapsedSeconds,
    String? lastErrorCode,
    int? asrProgress,
    String? liveTranscriptText,
    bool? isLiveTranscription,
    LiveTranscriptStatus? liveTranscriptStatus,
    String? liveTranscriptOwner,
    int? liveTranscriptAttemptId,
    bool clearError = false,
    bool clearAsrProgress = false,
    bool clearLiveTranscript = false,
    bool clearLiveTranscriptStatus = false,
    bool clearLiveTranscriptIdentity = false,
  }) {
    return VoiceMessageState(
      status: status ?? this.status,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
      asrProgress: clearAsrProgress ? null : asrProgress ?? this.asrProgress,
      liveTranscriptText: clearLiveTranscript
          ? ''
          : liveTranscriptText ?? this.liveTranscriptText,
      isLiveTranscription: isLiveTranscription ?? this.isLiveTranscription,
      liveTranscriptStatus: clearLiveTranscriptStatus
          ? null
          : liveTranscriptStatus ?? this.liveTranscriptStatus,
      liveTranscriptOwner:
          liveTranscriptOwner ??
          (clearLiveTranscriptIdentity ? null : this.liveTranscriptOwner),
      liveTranscriptAttemptId:
          liveTranscriptAttemptId ??
          (clearLiveTranscriptIdentity ? null : this.liveTranscriptAttemptId),
    );
  }
}

final class VoiceMessageController extends ChangeNotifier {
  VoiceMessageController({
    required VoiceRecorderPort recorder,
    required ChatVoiceUploadPort uploader,
    required LocalRecordingRepository localRecordingRepository,
    required ChatController chatController,
    required RecordingApiPort recordingApi,
    LiveTranscriptController? liveTranscriptController,
    this.liveTranscriptStopGrace = const Duration(milliseconds: 1200),
  }) : _recorder = recorder,
       _uploader = uploader,
       _localRecordingRepository = localRecordingRepository,
       _chatController = chatController,
       _recordingApi = recordingApi,
       _liveTranscriptController = liveTranscriptController {
    _liveTranscriptController?.addListener(_onLiveTranscriptChanged);
  }

  final VoiceRecorderPort _recorder;
  final ChatVoiceUploadPort _uploader;
  final LocalRecordingRepository _localRecordingRepository;
  final ChatController _chatController;
  final RecordingApiPort _recordingApi;
  final LiveTranscriptController? _liveTranscriptController;
  final Duration liveTranscriptStopGrace;

  VoiceMessageState _state = VoiceMessageState.initial();
  VoiceRecordingDraft? _draft;
  ResourceIndex? _resource;
  String? _contentLineId;
  Timer? _snapshotTimer;
  int _snapshotGeneration = 0;
  bool _refreshing = false;
  bool _liveTranscriptCapture = false;
  bool _startingLiveTranscript = false;
  bool _ownsLiveTranscriptRecorder = false;
  Future<String?>? _liveRecorderCleanup;
  Future<void>? _liveFailureCleanup;
  String? _liveTranscriptOwner;
  int? _liveTranscriptAttemptId;
  bool _leaveEndRequested = false;
  Future<bool>? _leaveEndInFlight;
  bool _disposed = false;

  VoiceMessageState get state => _state;

  Future<bool> start({String? contentLineId}) {
    return _startRecording(
      scene: VoiceRecordingScene.feedAi,
      contentLineId: contentLineId,
    );
  }

  /// Starts Tencent's native microphone recognizer after a permission check.
  /// Its final output is an editable text draft, not a voice-message upload.
  Future<bool> startLiveTranscription({required String owner}) {
    final normalizedOwner = _normalizeLiveTranscriptOwner(owner);
    if (normalizedOwner == null) {
      _fail('CHAT_LIVE_TRANSCRIPT_OWNER_INVALID');
      return Future<bool>.value(false);
    }
    return _startRecording(
      scene: VoiceRecordingScene.monologue,
      liveTranscription: true,
      liveTranscriptOwner: normalizedOwner,
    );
  }

  Future<bool> _startRecording({
    required VoiceRecordingScene scene,
    String? contentLineId,
    bool liveTranscription = false,
    String? liveTranscriptOwner,
  }) async {
    if (_disposed ||
        _leaveEndRequested ||
        _leaveEndInFlight != null ||
        _liveRecorderCleanup != null ||
        _liveFailureCleanup != null ||
        _state.isBusy ||
        _state.isCaptureActive) {
      return false;
    }
    _leaveEndRequested = false;
    if (contentLineId != null && !isSafeChatIdentifier(contentLineId)) {
      _fail('CHAT_CONTENT_LINE_ID_INVALID');
      return false;
    }
    if (liveTranscription && _liveTranscriptController == null) {
      _fail('CHAT_LIVE_TRANSCRIPT_UNAVAILABLE');
      return false;
    }
    if (liveTranscription && liveTranscriptOwner == null) {
      _fail('CHAT_LIVE_TRANSCRIPT_OWNER_INVALID');
      return false;
    }
    _contentLineId = null;
    _liveTranscriptCapture = false;
    if (liveTranscription) {
      _liveTranscriptOwner = liveTranscriptOwner;
      _liveTranscriptAttemptId = null;
    }
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.checkingPermission,
        elapsedSeconds: 0,
        clearError: true,
        clearAsrProgress: true,
        clearLiveTranscript: true,
        clearLiveTranscriptStatus: true,
        clearLiveTranscriptIdentity: true,
        isLiveTranscription: liveTranscription,
        liveTranscriptOwner: liveTranscription ? liveTranscriptOwner : null,
      ),
    );
    var permission = await _recorder.getMicrophonePermission();
    if (_disposed) return false;
    if (_consumeLeaveEndRequest()) return true;
    if (!permission.ok || permission.value == null) {
      _fail(permission.error?.code ?? 'VOICE_RECORDER_PERMISSION_UNAVAILABLE');
      return false;
    }
    if (!permission.value!.granted &&
        permission.value!.state == VoiceRecorderPermissionState.notDetermined) {
      permission = await _recorder.requestMicrophonePermission();
      if (_disposed) return false;
      if (_consumeLeaveEndRequest()) return true;
    }
    if (!permission.ok || permission.value == null) {
      _fail(permission.error?.code ?? 'VOICE_RECORDER_PERMISSION_UNAVAILABLE');
      return false;
    }
    if (!permission.value!.granted) {
      _fail(_permissionFailureCode(permission.value!));
      return false;
    }
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.starting,
        clearError: true,
      ),
    );
    if (liveTranscription) {
      return _startNativeLiveTranscription(
        contentLineId: contentLineId,
        owner: liveTranscriptOwner!,
      );
    }
    final started = await _recorder.startRecording(scene: scene);
    if (_disposed) {
      if (started.ok && started.value != null) {
        await _recorder.cancelRecording();
      }
      return false;
    }
    if (_leaveEndRequested) {
      if (started.ok && started.value != null) {
        await _recorder.cancelRecording();
      }
      _consumeLeaveEndRequest();
      return true;
    }
    if (!started.ok || started.value == null) {
      _fail(started.error?.code ?? 'VOICE_RECORDER_START_FAILED');
      return false;
    }
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.recording,
        elapsedSeconds: started.value!.elapsedSeconds,
        clearError: true,
      ),
    );
    _contentLineId = contentLineId;
    _startSnapshotTimer();
    return true;
  }

  Future<bool> _startNativeLiveTranscription({
    String? contentLineId,
    required String owner,
  }) async {
    if (!await _waitForLiveTranscriptStartReadiness()) {
      _fail('CHAT_LIVE_TRANSCRIPT_SESSION_BUSY');
      return false;
    }
    if (_disposed || _leaveEndRequested) return false;
    _startingLiveTranscript = true;
    final recorderStarted = await _recorder.startRecording(
      scene: VoiceRecordingScene.monologue,
    );
    if (recorderStarted.ok && recorderStarted.value != null) {
      _ownsLiveTranscriptRecorder = true;
    }
    if (_disposed) {
      _startingLiveTranscript = false;
      await _cancelLiveTranscriptRecorderSerially();
      return false;
    }
    if (_leaveEndRequested) {
      _startingLiveTranscript = false;
      await _cancelLiveTranscriptRecorderSerially();
      _consumeLeaveEndRequest();
      return true;
    }
    if (!recorderStarted.ok || recorderStarted.value == null) {
      _startingLiveTranscript = false;
      _fail(recorderStarted.error?.code ?? 'VOICE_RECORDER_START_FAILED');
      return false;
    }
    _liveTranscriptCapture = true;
    _startSnapshotTimer();
    final liveStarted = await _startLiveTranscript(owner);
    _startingLiveTranscript = false;
    if (_disposed) {
      await _stopLiveTranscript();
      await _cancelLiveTranscriptRecorderSerially();
      return false;
    }
    if (_leaveEndRequested) {
      await _stopLiveTranscript();
      await _cancelLiveTranscriptRecorderSerially();
      _consumeLeaveEndRequest();
      return true;
    }
    if (!_liveTranscriptCapture) {
      final cleanup = _liveFailureCleanup;
      if (cleanup != null) await cleanup;
      return false;
    }
    if (!liveStarted) {
      final errorCode =
          _liveTranscriptController?.state.lastErrorCode ??
          'CHAT_LIVE_TRANSCRIPT_START_FAILED';
      _liveTranscriptCapture = false;
      await _cancelLiveTranscriptRecorderSerially();
      _fail(errorCode);
      return false;
    }
    _contentLineId = contentLineId;
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.recording,
        elapsedSeconds: 0,
        liveTranscriptOwner: owner,
        liveTranscriptAttemptId: _liveTranscriptAttemptId,
        clearError: true,
      ),
    );
    return true;
  }

  Future<bool> _waitForLiveTranscriptStartReadiness() async {
    final liveTranscript = _liveTranscriptController;
    if (liveTranscript == null) return false;
    if (liveTranscript.state.status == LiveTranscriptStatus.stopping) {
      final ready = Completer<void>();
      void observe() {
        if (liveTranscript.state.status != LiveTranscriptStatus.stopping &&
            !ready.isCompleted) {
          ready.complete();
        }
      }

      liveTranscript.addListener(observe);
      observe();
      try {
        await ready.future.timeout(liveTranscriptStopGrace, onTimeout: () {});
      } finally {
        liveTranscript.removeListener(observe);
      }
    }
    return switch (liveTranscript.state.status) {
      LiveTranscriptStatus.idle || LiveTranscriptStatus.failed => true,
      _ => false,
    };
  }

  Future<bool> pause() async {
    if (_state.status != VoiceMessageControllerStatus.recording) return false;
    if (_liveTranscriptCapture) return false;
    final result = await _recorder.pauseRecording();
    if (!result.ok || result.value == null) {
      _fail(result.error?.code ?? 'VOICE_RECORDER_PAUSE_FAILED');
      return false;
    }
    _applyRecorderSnapshot(result.value!);
    return _state.status == VoiceMessageControllerStatus.paused;
  }

  Future<bool> resume() async {
    if (_state.status != VoiceMessageControllerStatus.paused) return false;
    if (_liveTranscriptCapture) return false;
    final result = await _recorder.resumeRecording();
    if (!result.ok || result.value == null) {
      _fail(result.error?.code ?? 'VOICE_RECORDER_RESUME_FAILED');
      return false;
    }
    _applyRecorderSnapshot(result.value!);
    return _state.status == VoiceMessageControllerStatus.recording;
  }

  Future<bool> cancel({String? liveTranscriptOwner}) async {
    _leaveEndRequested = false;
    _stopSnapshotTimer();
    final wasLiveTranscription =
        _state.isLiveTranscription ||
        _liveTranscriptCapture ||
        _startingLiveTranscript ||
        _ownsLiveTranscriptRecorder;
    if (wasLiveTranscription) {
      final owner = _normalizeLiveTranscriptOwner(liveTranscriptOwner ?? '');
      if (owner == null || owner != _liveTranscriptOwner) return false;
    }
    _liveTranscriptCapture = false;
    if (wasLiveTranscription) {
      _set(
        _state.copyWith(
          status: VoiceMessageControllerStatus.stopping,
          clearError: true,
        ),
      );
      await _awaitLiveTranscriptStop(_stopLiveTranscript());
      final recorderError = await _cancelLiveTranscriptRecorderSerially();
      if (_disposed) return false;
      if (recorderError != null) {
        _fail(recorderError);
        return false;
      }
      _draft = null;
      _resource = null;
      _contentLineId = null;
      _set(VoiceMessageState.initial());
      return true;
    }
    final result = await _recorder.cancelRecording();
    if (!result.ok) {
      _fail(result.error?.code ?? 'VOICE_RECORDER_CANCEL_FAILED');
      return false;
    }
    _draft = null;
    _resource = null;
    _contentLineId = null;
    _set(VoiceMessageState.initial());
    return true;
  }

  /// Ends temporary microphone work before the owning chat route disappears.
  ///
  /// A permission prompt or native start can finish after navigation. Keep the
  /// intent until that late continuation consumes it, rather than allowing an
  /// invisible recorder to become active under the next page.
  Future<bool> endCaptureForLeave({required String owner}) {
    final normalizedOwner = _normalizeLiveTranscriptOwner(owner);
    if (normalizedOwner == null) return Future<bool>.value(false);
    final inFlight = _leaveEndInFlight;
    if (inFlight != null) return inFlight;
    final ending = _endCaptureForLeave(normalizedOwner);
    _leaveEndInFlight = ending;
    return ending.whenComplete(() {
      if (identical(_leaveEndInFlight, ending)) {
        _leaveEndInFlight = null;
      }
    });
  }

  Future<bool> endActiveLiveCaptureForLifecycle() {
    final owner = _liveTranscriptOwner;
    if (owner == null) return Future<bool>.value(true);
    return endCaptureForLeave(owner: owner);
  }

  Future<bool> _endCaptureForLeave(String owner) async {
    if (_disposed) return false;
    final hasCaptureWork =
        _state.isCaptureActive ||
        _state.status == VoiceMessageControllerStatus.checkingPermission ||
        _state.status == VoiceMessageControllerStatus.starting ||
        _liveTranscriptCapture ||
        _startingLiveTranscript;
    if (!hasCaptureWork) return true;
    if ((_liveTranscriptCapture || _startingLiveTranscript) &&
        _liveTranscriptOwner != owner) {
      return true;
    }

    _leaveEndRequested = true;
    _stopSnapshotTimer();
    final shouldStopLive =
        _liveTranscriptCapture ||
        _startingLiveTranscript ||
        _ownsLiveTranscriptRecorder;
    if (shouldStopLive) {
      _set(
        _state.copyWith(
          status: VoiceMessageControllerStatus.stopping,
          clearError: true,
        ),
      );
      await _stopLiveTranscript();
      final recorderError = await _cancelLiveTranscriptRecorderSerially();
      if (_disposed) return true;
      if (_startingLiveTranscript) return true;
      if (recorderError != null) {
        _leaveEndRequested = false;
        _fail(recorderError);
        return false;
      }
      _consumeLeaveEndRequest();
      return true;
    }
    final cancelled = await _recorder.cancelRecording();
    if (_disposed) return cancelled.ok;
    if (!cancelled.ok) {
      _leaveEndRequested = false;
      _fail(cancelled.error?.code ?? 'VOICE_RECORDER_CANCEL_FAILED');
      return false;
    }
    if (!_state.isBusy) _consumeLeaveEndRequest();
    return true;
  }

  Future<bool> stopAndSend() async {
    if (_liveTranscriptCapture) {
      final owner = _liveTranscriptOwner;
      return owner != null && await stopAndTranscribe(owner: owner);
    }
    if (!_state.isCaptureActive) return false;
    _stopSnapshotTimer();
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.stopping,
        clearError: true,
      ),
    );
    final stopped = await _recorder.stopRecording();
    if (!stopped.ok || stopped.value == null) {
      _fail(stopped.error?.code ?? 'VOICE_RECORDER_STOP_FAILED');
      return false;
    }
    _draft = stopped.value!;
    _resource = null;
    return _registerUploadAndSend(
      stopped.value!,
      contentLineId: _contentLineId,
    );
  }

  Future<bool> stopAndTranscribe({required String owner}) async {
    final normalizedOwner = _normalizeLiveTranscriptOwner(owner);
    if (normalizedOwner == null || normalizedOwner != _liveTranscriptOwner) {
      return false;
    }
    if (!_liveTranscriptCapture || !_state.isCaptureActive) return false;
    final attemptId = _liveTranscriptAttemptId;
    _stopSnapshotTimer();
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.stopping,
        clearError: true,
      ),
    );
    final stoppingLiveTranscript = _stopLiveTranscript();
    await _awaitLiveTranscriptStop(stoppingLiveTranscript);
    _liveTranscriptCapture = false;
    final recorderError = await _cancelLiveTranscriptRecorderSerially();
    if (_disposed) return false;
    if (recorderError != null) {
      _fail(recorderError);
      return false;
    }
    final transcript = _liveTranscriptText();
    if (transcript.isEmpty) {
      final liveError = _liveTranscriptController?.state.lastErrorCode;
      if (liveError != null) {
        _fail(liveError);
        return false;
      }
      _draft = null;
      _resource = null;
      _contentLineId = null;
      _set(VoiceMessageState.initial());
      return true;
    }
    _draft = null;
    _resource = null;
    _contentLineId = null;
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.idle,
        liveTranscriptText: transcript,
        liveTranscriptOwner: normalizedOwner,
        liveTranscriptAttemptId: attemptId,
        clearError: true,
        clearAsrProgress: true,
      ),
    );
    _clearLiveTranscriptOwnership();
    return true;
  }

  Future<bool> retry({String? liveTranscriptOwner}) async {
    if (_state.isLiveTranscription) {
      final owner = _normalizeLiveTranscriptOwner(
        liveTranscriptOwner ?? _liveTranscriptOwner ?? '',
      );
      if (owner == null) return false;
      return startLiveTranscription(owner: owner);
    }
    final draft = _draft;
    if (draft == null || _state.isCaptureActive || _state.isBusy) {
      _fail('CHAT_VOICE_RETRY_UNAVAILABLE');
      return false;
    }
    final resource = _resource;
    if (resource != null) {
      return _sendResource(
        resource,
        draft.durationSeconds,
        contentLineId: _contentLineId,
      );
    }
    return _registerUploadAndSend(draft, contentLineId: _contentLineId);
  }

  Future<bool> refreshAsr() async {
    final action = _chatController.state.nextAction;
    final asrTaskId = action.asrTaskId;
    if (action.type != ChatNextActionType.pollAsr || asrTaskId == null) {
      _fail('CHAT_VOICE_ASR_REFRESH_UNAVAILABLE');
      return false;
    }
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.asrPolling,
        clearError: true,
      ),
    );
    final result = await _recordingApi.getAsrTask(asrTaskId);
    if (!result.ok || result.data == null) {
      _fail(result.error?.code ?? 'CHAT_VOICE_ASR_REFRESH_FAILED');
      return false;
    }
    final task = result.data!;
    if (task.isTerminal) {
      final threadId = _chatController.state.activeThreadId;
      if (threadId != null) {
        await _chatController.selectThread(threadId);
      }
      if (_chatController.state.lastErrorCode != null) {
        _fail(_chatController.state.lastErrorCode!);
        return false;
      }
    }
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.sent,
        asrProgress: task.progress,
        clearError: true,
      ),
    );
    return true;
  }

  Future<bool> retryAsr() async {
    final action = _chatController.state.nextAction;
    final asrTaskId = action.asrTaskId;
    if (action.type != ChatNextActionType.retryAsr || asrTaskId == null) {
      _fail('CHAT_VOICE_ASR_RETRY_UNAVAILABLE');
      return false;
    }
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.asrPolling,
        clearError: true,
      ),
    );
    final result = await _recordingApi.retryAsrTask(
      asrTaskId: asrTaskId,
      idempotencyKey: 'idem-workspace-voice-asr-retry-$asrTaskId',
    );
    if (!result.ok || result.data == null) {
      _fail(result.error?.code ?? 'CHAT_VOICE_ASR_RETRY_FAILED');
      return false;
    }
    final threadId = _chatController.state.activeThreadId;
    if (threadId != null) {
      await _chatController.selectThread(threadId);
    }
    if (_chatController.state.lastErrorCode != null) {
      _fail(_chatController.state.lastErrorCode!);
      return false;
    }
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.sent,
        asrProgress: result.data!.progress,
        clearError: true,
      ),
    );
    return true;
  }

  Future<bool> _registerUploadAndSend(
    VoiceRecordingDraft draft, {
    String? contentLineId,
  }) async {
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.registeringLocal,
        elapsedSeconds: draft.durationSeconds,
        clearError: true,
      ),
    );
    final registered = await _localRecordingRepository
        .registerNativeVoiceRecording(
          file: PrivateAudioFile(
            fileId: draft.recordingId,
            appPrivateUri: draft.appPrivateUri,
            displayName: 'Voice-${draft.recordingId}.m4a',
            mimeType: draft.mimeType,
            sizeBytes: draft.sizeBytes,
            durationSeconds: draft.durationSeconds,
            contentHash: draft.sha256,
            recordedAt: draft.recordedAt,
          ),
          recordedAt: draft.recordedAt,
        );
    if (!registered.ok) {
      _fail(registered.error?.code ?? 'CHAT_VOICE_LOCAL_REGISTER_FAILED');
      return false;
    }
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.uploading,
        clearError: true,
      ),
    );
    final uploaded = await _uploader.uploadVoice(draft);
    if (!uploaded.ok || uploaded.value == null) {
      _fail(uploaded.error?.code ?? 'CHAT_VOICE_UPLOAD_FAILED');
      return false;
    }
    _resource = uploaded.value!;
    return _sendResource(
      uploaded.value!,
      draft.durationSeconds,
      contentLineId: contentLineId,
    );
  }

  Future<bool> _sendResource(
    ResourceIndex resource,
    int durationSeconds, {
    String? contentLineId,
  }) async {
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.sending,
        clearError: true,
      ),
    );
    final sent = await _chatController.sendVoiceResource(
      resource: resource,
      durationSeconds: durationSeconds,
      contentLineId: contentLineId,
    );
    if (!sent) {
      _fail(_chatController.state.lastErrorCode ?? 'CHAT_VOICE_SEND_FAILED');
      return false;
    }
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.sent,
        clearError: true,
      ),
    );
    return true;
  }

  Future<bool> _startLiveTranscript(String owner) async {
    final liveTranscript = _liveTranscriptController;
    if (liveTranscript == null) return false;
    try {
      final starting = liveTranscript.start(owner: owner);
      final startedAttempt = liveTranscript.state;
      if (startedAttempt.belongsTo(owner)) {
        _liveTranscriptAttemptId = startedAttempt.attemptId;
      }
      final started = await starting;
      final currentAttempt = liveTranscript.state;
      if (currentAttempt.belongsTo(owner)) {
        _liveTranscriptAttemptId = currentAttempt.attemptId;
      }
      return started;
    } catch (_) {
      return false;
    }
  }

  Future<void> _stopLiveTranscript() async {
    final liveTranscript = _liveTranscriptController;
    if (liveTranscript == null) return;
    final owner = _liveTranscriptOwner;
    if (owner == null) return;
    final status = liveTranscript.state.status;
    if (status == LiveTranscriptStatus.idle) {
      _clearLiveTranscriptOwnership();
      return;
    }
    try {
      await liveTranscript.stop(
        owner: owner,
        attemptId: _liveTranscriptAttemptId,
      );
      if (liveTranscript.state.status == LiveTranscriptStatus.idle) {
        _clearLiveTranscriptOwnership();
      }
    } catch (_) {
      // Recorder cleanup must continue even if live ASR fails to stop.
    }
  }

  Future<String?> _cancelLiveTranscriptRecorder() async {
    if (!_ownsLiveTranscriptRecorder) return null;
    _ownsLiveTranscriptRecorder = false;
    try {
      final result = await _recorder.cancelRecording();
      if (result.ok) return null;
      return result.error?.code ?? 'VOICE_RECORDER_CANCEL_FAILED';
    } catch (_) {
      return 'VOICE_RECORDER_CANCEL_FAILED';
    }
  }

  Future<String?> _cancelLiveTranscriptRecorderSerially() {
    final activeCleanup = _liveRecorderCleanup;
    if (activeCleanup != null) return activeCleanup;
    late final Future<String?> trackedCleanup;
    trackedCleanup = _cancelLiveTranscriptRecorder().whenComplete(() {
      if (identical(_liveRecorderCleanup, trackedCleanup)) {
        _liveRecorderCleanup = null;
      }
    });
    _liveRecorderCleanup = trackedCleanup;
    return trackedCleanup;
  }

  Future<void> _awaitLiveTranscriptStop(Future<void> stopping) async {
    try {
      await stopping.timeout(liveTranscriptStopGrace, onTimeout: () {});
    } catch (_) {
      // A partial transcript remains a usable local draft.
    }
  }

  void _onLiveTranscriptChanged() {
    if (_disposed || !_liveTranscriptCapture) return;
    final liveTranscript = _liveTranscriptController;
    if (liveTranscript == null) return;
    final owner = _liveTranscriptOwner;
    if (owner == null ||
        (!liveTranscript.state.belongsTo(
              owner,
              candidateAttemptId: _liveTranscriptAttemptId,
            ) &&
            liveTranscript.state.status != LiveTranscriptStatus.idle)) {
      return;
    }
    final transcript = _liveTranscriptText();
    final status = liveTranscript.state.status;
    final failed = status == LiveTranscriptStatus.failed;
    final errorCode = failed
        ? liveTranscript.state.lastErrorCode ?? 'CHAT_LIVE_TRANSCRIPT_FAILED'
        : null;
    if (transcript == _state.liveTranscriptText &&
        status == _state.liveTranscriptStatus &&
        !failed) {
      return;
    }
    if (failed && !_startingLiveTranscript && _state.isCaptureActive) {
      _stopLiveCaptureAfterTranscriptFailure(errorCode!);
      return;
    }
    _set(
      _state.copyWith(
        liveTranscriptText: transcript,
        liveTranscriptStatus: status,
        liveTranscriptOwner: owner,
        liveTranscriptAttemptId: _liveTranscriptAttemptId,
        clearError: true,
      ),
    );
  }

  void _stopLiveCaptureAfterTranscriptFailure(String errorCode) {
    if (_disposed || _liveFailureCleanup != null) return;
    _stopSnapshotTimer();
    _liveTranscriptCapture = false;
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.stopping,
        liveTranscriptText: _liveTranscriptText(),
        liveTranscriptStatus: _liveTranscriptController?.state.status,
        clearError: true,
      ),
    );
    late final Future<void> cleanup;
    cleanup = _finishLiveCaptureFailure(errorCode).whenComplete(() {
      if (identical(_liveFailureCleanup, cleanup)) {
        _liveFailureCleanup = null;
      }
    });
    _liveFailureCleanup = cleanup;
    unawaited(cleanup);
  }

  Future<void> _finishLiveCaptureFailure(String errorCode) async {
    await _awaitLiveTranscriptStop(_stopLiveTranscript());
    final recorderError = await _cancelLiveTranscriptRecorderSerially();
    if (_disposed) return;
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.failed,
        lastErrorCode: recorderError ?? errorCode,
      ),
    );
  }

  String _liveTranscriptText() {
    final liveTranscript = _liveTranscriptController;
    if (liveTranscript == null) return '';
    return liveTranscript.state.sentences
        .map((sentence) => sentence.text.trim())
        .where((text) => text.isNotEmpty)
        .join();
  }

  void _startSnapshotTimer() {
    _stopSnapshotTimer();
    final generation = ++_snapshotGeneration;
    _snapshotTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || !_shouldRefreshRecorderSnapshot) return;
      unawaited(_refreshRecorderSnapshot(generation));
    });
  }

  bool get _shouldRefreshRecorderSnapshot =>
      _state.isCaptureActive ||
      (_startingLiveTranscript &&
          _liveTranscriptCapture &&
          _ownsLiveTranscriptRecorder);

  Future<void> _refreshRecorderSnapshot(int generation) async {
    if (_refreshing ||
        generation != _snapshotGeneration ||
        !_shouldRefreshRecorderSnapshot) {
      return;
    }
    _refreshing = true;
    final refreshed = await _recorder.refreshState();
    if (generation != _snapshotGeneration) return;
    _refreshing = false;
    if (_disposed || !_shouldRefreshRecorderSnapshot) return;
    if (refreshed.ok && refreshed.value != null) {
      _applyRecorderSnapshot(refreshed.value!);
    } else if (_liveTranscriptCapture) {
      _stopLiveCaptureAfterTranscriptFailure(
        refreshed.error?.code ?? 'VOICE_RECORDER_STATE_REFRESH_FAILED',
      );
    } else {
      _fail(refreshed.error?.code ?? 'VOICE_RECORDER_STATE_REFRESH_FAILED');
    }
  }

  void _stopSnapshotTimer() {
    _snapshotGeneration += 1;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _refreshing = false;
  }

  void _applyRecorderSnapshot(VoiceRecorderSnapshot snapshot) {
    if (_liveTranscriptCapture &&
        snapshot.state != VoiceRecorderState.recording) {
      final errorCode =
          snapshot.lastErrorCode ??
          switch (snapshot.state) {
            VoiceRecorderState.paused => 'VOICE_RECORDER_AUDIO_INTERRUPTED',
            VoiceRecorderState.failed => 'VOICE_RECORDER_PCM_CAPTURE_FAILED',
            VoiceRecorderState.idle => 'VOICE_RECORDER_CAPTURE_ENDED',
            VoiceRecorderState.recording =>
              'VOICE_RECORDER_STATE_REFRESH_FAILED',
          };
      _stopLiveCaptureAfterTranscriptFailure(errorCode);
      return;
    }
    final session = snapshot.session;
    final status = switch (snapshot.state) {
      VoiceRecorderState.recording => VoiceMessageControllerStatus.recording,
      VoiceRecorderState.paused => VoiceMessageControllerStatus.paused,
      VoiceRecorderState.idle => VoiceMessageControllerStatus.idle,
      VoiceRecorderState.failed => VoiceMessageControllerStatus.failed,
    };
    if (status == VoiceMessageControllerStatus.idle ||
        status == VoiceMessageControllerStatus.failed) {
      _stopSnapshotTimer();
      if (_liveTranscriptCapture) {
        _liveTranscriptCapture = false;
        unawaited(_stopLiveTranscript());
      }
    }
    _set(
      _state.copyWith(
        status: status,
        elapsedSeconds: session?.elapsedSeconds ?? _state.elapsedSeconds,
        lastErrorCode: snapshot.lastErrorCode,
        clearError: snapshot.lastErrorCode == null,
      ),
    );
  }

  String _permissionFailureCode(VoiceRecorderPermission permission) {
    return switch (permission.state) {
      VoiceRecorderPermissionState.blocked =>
        'VOICE_RECORDER_PERMISSION_BLOCKED',
      VoiceRecorderPermissionState.denied => 'VOICE_RECORDER_PERMISSION_DENIED',
      VoiceRecorderPermissionState.unavailable =>
        'VOICE_RECORDER_PERMISSION_UNAVAILABLE',
      VoiceRecorderPermissionState.notDetermined =>
        'VOICE_RECORDER_PERMISSION_NOT_GRANTED',
      VoiceRecorderPermissionState.granted =>
        'VOICE_RECORDER_PERMISSION_FAILED',
    };
  }

  void _fail(String errorCode) {
    _stopSnapshotTimer();
    _set(
      _state.copyWith(
        status: VoiceMessageControllerStatus.failed,
        lastErrorCode: errorCode,
        liveTranscriptOwner: _state.isLiveTranscription
            ? _liveTranscriptOwner
            : null,
        liveTranscriptAttemptId: _state.isLiveTranscription
            ? _liveTranscriptAttemptId
            : null,
      ),
    );
  }

  bool _consumeLeaveEndRequest() {
    if (!_leaveEndRequested) return false;
    _leaveEndRequested = false;
    _liveTranscriptCapture = false;
    _startingLiveTranscript = false;
    _draft = null;
    _resource = null;
    _contentLineId = null;
    _clearLiveTranscriptOwnership();
    _set(VoiceMessageState.initial());
    return true;
  }

  void _clearLiveTranscriptOwnership() {
    _liveTranscriptOwner = null;
    _liveTranscriptAttemptId = null;
  }

  String? _normalizeLiveTranscriptOwner(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 128) return null;
    return normalized;
  }

  void _set(VoiceMessageState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _leaveEndRequested = true;
    _stopSnapshotTimer();
    _liveTranscriptController?.removeListener(_onLiveTranscriptChanged);
    if (_liveTranscriptCapture ||
        _startingLiveTranscript ||
        _ownsLiveTranscriptRecorder) {
      _liveTranscriptCapture = false;
      _startingLiveTranscript = false;
      unawaited(() async {
        await _stopLiveTranscript();
        await _cancelLiveTranscriptRecorderSerially();
      }());
    } else if (_state.isCaptureActive) {
      unawaited(_recorder.cancelRecording());
    }
    super.dispose();
  }
}

VoiceMessageController createFeedAiVoiceMessageController(
  Ref ref, {
  ChatConversationPurpose conversationPurpose = ChatConversationPurpose.general,
}) {
  ref.watch(authenticatedUserDataScopeProvider);
  // State emissions occur during capture; only notifier replacement may rebuild.
  final chatController = ref.watch(
    conversationPurpose == ChatConversationPurpose.deepPositioning
        ? deepPositioningChatControllerProvider.notifier
        : feedAiChatControllerProvider.notifier,
  );
  final liveTranscriptController = ref.watch(
    liveTranscriptControllerProvider.notifier,
  );
  final controller = VoiceMessageController(
    recorder: ref.watch(voiceRecorderPortProvider),
    uploader: ChatVoiceUploader(
      uploadClient: ref.watch(recordingUploadClientProvider),
    ),
    localRecordingRepository: ref.watch(localRecordingRepositoryProvider),
    chatController: chatController,
    recordingApi: ref.watch(recordingApiProvider),
    liveTranscriptController: liveTranscriptController,
  );
  final activity = ref.read(appActivityCoordinatorProvider);
  void endLiveCaptureOnBackground() {
    if (activity.state.visibility == AppVisibility.background) {
      unawaited(controller.endActiveLiveCaptureForLifecycle());
    }
  }

  activity.addListener(endLiveCaptureOnBackground);
  ref.onDispose(() => activity.removeListener(endLiveCaptureOnBackground));
  return controller;
}

final feedAiVoiceMessageControllerProvider =
    ChangeNotifierProvider.autoDispose<VoiceMessageController>(
      (ref) => createFeedAiVoiceMessageController(ref),
      dependencies: <ProviderOrFamily>[
        feedAiChatControllerProvider,
        deepPositioningChatControllerProvider,
      ],
    );
