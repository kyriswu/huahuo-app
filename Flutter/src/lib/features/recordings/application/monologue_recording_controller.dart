import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/di/diagnostics_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../core/native/voice_recorder_port.dart';
import '../../../core/storage/file_storage_port.dart';
import '../../transcription/application/live_transcript_controller.dart';
import '../../transcription/domain/live_transcript.dart';
import '../../ui_v3/application/knowledge_library_controller.dart';
import '../../ui_v3/application/knowledge_note_port.dart';
import '../data/local_recording_repository.dart';
import '../domain/recording_library.dart';
import 'recording_waveform_controller.dart';

enum MonologueRecordingStatus {
  idle,
  checkingPermission,
  starting,
  recording,
  pausing,
  paused,
  resuming,
  stopping,
  registeringLocal,
  savingNote,
  completed,
  failed,
}

enum MonologueFailureStage {
  permission,
  nativeStart,
  liveTranscription,
  nativeCapture,
  nativeStop,
  draftValidation,
  localRegistration,
  noteSave,
}

enum MonologueNativeCaptureLatch { none, recording, paused, uncertain }

final class MonologueRecordingState {
  const MonologueRecordingState({
    required this.status,
    this.nativeCaptureLatch = MonologueNativeCaptureLatch.none,
    this.elapsedSeconds = 0,
    this.transcriptText = '',
    this.localItem,
    this.localNoteId,
    this.lastErrorCode,
    this.failureStage,
    this.correlationId,
    this.liveTranscriptErrorCode,
    this.liveTranscriptAttemptId,
  });

  factory MonologueRecordingState.initial() {
    return const MonologueRecordingState(status: MonologueRecordingStatus.idle);
  }

  final MonologueRecordingStatus status;
  final MonologueNativeCaptureLatch nativeCaptureLatch;
  final int elapsedSeconds;
  final String transcriptText;
  final RecordingLibraryItem? localItem;
  final String? localNoteId;
  final String? lastErrorCode;
  final MonologueFailureStage? failureStage;
  final String? correlationId;
  final String? liveTranscriptErrorCode;
  final int? liveTranscriptAttemptId;

  bool get hasNativeCapture =>
      nativeCaptureLatch != MonologueNativeCaptureLatch.none;

  bool get isNativeWriting =>
      nativeCaptureLatch == MonologueNativeCaptureLatch.recording &&
      (status == MonologueRecordingStatus.recording ||
          status == MonologueRecordingStatus.resuming);

  bool get hasRecoverableLiveFailure =>
      status == MonologueRecordingStatus.failed &&
      failureStage == MonologueFailureStage.liveTranscription &&
      nativeCaptureLatch == MonologueNativeCaptureLatch.paused;

  bool get isCaptureActive =>
      status == MonologueRecordingStatus.recording ||
      status == MonologueRecordingStatus.pausing ||
      status == MonologueRecordingStatus.paused ||
      status == MonologueRecordingStatus.resuming;

  bool get isBusy =>
      status == MonologueRecordingStatus.checkingPermission ||
      status == MonologueRecordingStatus.starting ||
      status == MonologueRecordingStatus.pausing ||
      status == MonologueRecordingStatus.resuming ||
      status == MonologueRecordingStatus.stopping ||
      status == MonologueRecordingStatus.registeringLocal ||
      status == MonologueRecordingStatus.savingNote;

  bool get canStart {
    if (isBusy || isCaptureActive || hasNativeCapture) return false;
    return switch (status) {
      MonologueRecordingStatus.idle ||
      MonologueRecordingStatus.completed => true,
      MonologueRecordingStatus.failed => switch (failureStage) {
        MonologueFailureStage.permission ||
        MonologueFailureStage.nativeStart ||
        MonologueFailureStage.nativeCapture ||
        MonologueFailureStage.nativeStop => true,
        MonologueFailureStage.draftValidation => localItem == null,
        MonologueFailureStage.liveTranscription ||
        MonologueFailureStage.localRegistration ||
        MonologueFailureStage.noteSave ||
        null => false,
      },
      _ => false,
    };
  }

  bool get canPause =>
      status == MonologueRecordingStatus.recording &&
      nativeCaptureLatch == MonologueNativeCaptureLatch.recording;

  bool get canResume =>
      nativeCaptureLatch == MonologueNativeCaptureLatch.paused &&
      (status == MonologueRecordingStatus.paused ||
          (status == MonologueRecordingStatus.failed &&
              (failureStage == MonologueFailureStage.liveTranscription ||
                  failureStage == MonologueFailureStage.nativeCapture)));

  bool get canFinish =>
      !isBusy &&
      hasNativeCapture &&
      (status == MonologueRecordingStatus.recording ||
          status == MonologueRecordingStatus.paused ||
          status == MonologueRecordingStatus.failed);

  bool get canEditTranscript =>
      (status == MonologueRecordingStatus.paused &&
          nativeCaptureLatch == MonologueNativeCaptureLatch.paused) ||
      (status == MonologueRecordingStatus.failed &&
          ((nativeCaptureLatch == MonologueNativeCaptureLatch.paused &&
                  (failureStage == MonologueFailureStage.liveTranscription ||
                      failureStage == MonologueFailureStage.nativeCapture)) ||
              (failureStage == MonologueFailureStage.draftValidation &&
                  localItem != null) ||
              failureStage == MonologueFailureStage.noteSave));

  bool get canRetry =>
      status == MonologueRecordingStatus.failed &&
      (canResume ||
          canStart ||
          hasNativeCapture ||
          failureStage == MonologueFailureStage.localRegistration ||
          failureStage == MonologueFailureStage.noteSave ||
          (failureStage == MonologueFailureStage.draftValidation &&
              localItem != null));

  MonologueRecordingState copyWith({
    MonologueRecordingStatus? status,
    MonologueNativeCaptureLatch? nativeCaptureLatch,
    int? elapsedSeconds,
    String? transcriptText,
    RecordingLibraryItem? localItem,
    String? localNoteId,
    String? lastErrorCode,
    MonologueFailureStage? failureStage,
    String? correlationId,
    String? liveTranscriptErrorCode,
    int? liveTranscriptAttemptId,
    bool clearLocalItem = false,
    bool clearLocalNoteId = false,
    bool clearError = false,
    bool clearFailureStage = false,
    bool clearLiveTranscriptError = false,
    bool clearLiveTranscriptAttempt = false,
  }) {
    return MonologueRecordingState(
      status: status ?? this.status,
      nativeCaptureLatch: nativeCaptureLatch ?? this.nativeCaptureLatch,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      transcriptText: transcriptText ?? this.transcriptText,
      localItem: clearLocalItem ? null : localItem ?? this.localItem,
      localNoteId: clearLocalNoteId ? null : localNoteId ?? this.localNoteId,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
      failureStage: clearFailureStage
          ? null
          : failureStage ?? this.failureStage,
      correlationId: correlationId ?? this.correlationId,
      liveTranscriptErrorCode: clearLiveTranscriptError
          ? null
          : liveTranscriptErrorCode ?? this.liveTranscriptErrorCode,
      liveTranscriptAttemptId: clearLiveTranscriptAttempt
          ? null
          : liveTranscriptAttemptId ?? this.liveTranscriptAttemptId,
    );
  }
}

final class MonologueRecordingController extends ChangeNotifier {
  MonologueRecordingController({
    required VoiceRecorderPort recorder,
    required LocalRecordingRepository localRecordingRepository,
    required KnowledgeLibraryController knowledgeLibrary,
    LiveTranscriptController? liveTranscriptController,
    DiagnosticLogger? diagnosticLogger,
    String Function()? correlationIdFactory,
    this.liveTranscriptStopGrace = const Duration(milliseconds: 1200),
  }) : _recorder = recorder,
       _localRecordingRepository = localRecordingRepository,
       _knowledgeLibrary = knowledgeLibrary,
       _liveTranscriptController = liveTranscriptController,
       _diagnosticLogger = diagnosticLogger,
       _correlationIdFactory = correlationIdFactory;

  final VoiceRecorderPort _recorder;
  final LocalRecordingRepository _localRecordingRepository;
  final KnowledgeLibraryController _knowledgeLibrary;
  final LiveTranscriptController? _liveTranscriptController;
  final DiagnosticLogger? _diagnosticLogger;
  final String Function()? _correlationIdFactory;
  final Duration liveTranscriptStopGrace;

  MonologueRecordingState _state = MonologueRecordingState.initial();
  Timer? _snapshotTimer;
  late final RecordingWaveformController waveform = RecordingWaveformController(
    recorder: _recorder,
  );
  VoiceRecordingDraft? _pendingDraft;
  Future<void>? _liveFailureCleanup;
  bool _refreshing = false;
  bool _disposed = false;
  bool _leaveEndRequested = false;
  String? _nativeRecordingId;
  bool _ownsLiveTranscript = false;
  int _captureGeneration = 0;
  int _snapshotGeneration = 0;
  int _liveTranscriptGeneration = 0;
  int _liveSegmentSequence = 0;
  String? _liveTranscriptOwner;
  int? _liveTranscriptAttemptId;
  String _liveTranscriptAttemptTextPrefix = '';
  List<LiveTranscriptSentence> _retainedLiveTranscript =
      const <LiveTranscriptSentence>[];
  List<LiveTranscriptSentence> _liveTranscriptAttemptPrefix =
      const <LiveTranscriptSentence>[];

  MonologueRecordingState get state => _state;

  bool get hasOwnedNativeCapture => _ownedRecordingId != null;

  LiveTranscriptState visibleLiveTranscriptState(LiveTranscriptState shared) {
    final owner = _liveTranscriptOwner;
    if (owner != null &&
        shared.belongsTo(owner, candidateAttemptId: _liveTranscriptAttemptId)) {
      return LiveTranscriptState(
        status: shared.status,
        sentences: _sentencesForCurrentAttempt(shared.sentences),
        owner: shared.owner,
        attemptId: shared.attemptId,
        lastErrorCode: shared.lastErrorCode,
      );
    }
    return LiveTranscriptState.idle(sentences: _retainedLiveTranscript);
  }

  bool updateTranscript(String value) {
    if (_disposed || !_state.canEditTranscript || value.length > 500000) {
      return false;
    }
    if (_state.transcriptText == value) return true;
    _liveTranscriptAttemptTextPrefix = value;
    _set(_state.copyWith(transcriptText: value));
    return true;
  }

  Future<void> retryLiveTranscriptPreview() async {
    await retry();
  }

  Future<bool> start() async {
    if (_disposed || !_state.canStart) return false;
    final generation = ++_captureGeneration;
    _leaveEndRequested = false;
    _nativeRecordingId = null;
    _pendingDraft = null;
    _liveSegmentSequence = 0;
    _liveTranscriptAttemptTextPrefix = '';
    _retainedLiveTranscript = const <LiveTranscriptSentence>[];
    final correlationId = _newCorrelationId();
    _set(
      MonologueRecordingState(
        status: MonologueRecordingStatus.checkingPermission,
        correlationId: correlationId,
      ),
    );

    _logStage(MonologueFailureStage.permission, 'started');
    var permission = await _recorder.getMicrophonePermission();
    if (!_isCurrentCapture(generation)) return false;
    if (_consumeLeaveBeforeNativeStart()) return true;
    if (!permission.ok || permission.value == null) {
      _fail(
        permission.error?.code ?? 'VOICE_RECORDER_PERMISSION_UNAVAILABLE',
        MonologueFailureStage.permission,
      );
      return false;
    }
    if (!permission.value!.granted && permission.value!.canAskAgain) {
      permission = await _recorder.requestMicrophonePermission();
      if (!_isCurrentCapture(generation)) return false;
      if (_consumeLeaveBeforeNativeStart()) return true;
    }
    if (!permission.ok || permission.value == null) {
      _fail(
        permission.error?.code ?? 'VOICE_RECORDER_PERMISSION_UNAVAILABLE',
        MonologueFailureStage.permission,
      );
      return false;
    }
    if (!permission.value!.granted) {
      _fail(
        _permissionFailureCode(permission.value!),
        MonologueFailureStage.permission,
      );
      return false;
    }
    if (_consumeLeaveBeforeNativeStart()) return true;

    _logStage(MonologueFailureStage.permission, 'succeeded');
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.starting,
        clearError: true,
        clearFailureStage: true,
        clearLiveTranscriptError: true,
        clearLiveTranscriptAttempt: true,
      ),
    );
    _logStage(MonologueFailureStage.nativeStart, 'started');
    final started = await _recorder.startRecording(
      scene: VoiceRecordingScene.monologue,
    );
    if (!_isCurrentCapture(generation)) {
      final staleSession = started.value;
      if (started.ok && staleSession != null) {
        await _cancelStartedMonologueSession(staleSession);
      }
      return false;
    }
    final session = started.value;
    if (!started.ok ||
        session == null ||
        session.scene != VoiceRecordingScene.monologue ||
        session.state != VoiceRecorderState.recording ||
        session.recordingId.trim().isEmpty) {
      if (started.ok && session != null) {
        final cancelled = await _cancelStartedMonologueSession(session);
        if (!cancelled) return false;
      }
      _fail(
        started.error?.code ?? 'MONOLOGUE_RECORDING_SESSION_INVALID',
        MonologueFailureStage.nativeStart,
      );
      return false;
    }
    _nativeRecordingId = session.recordingId;
    _set(
      _state.copyWith(
        nativeCaptureLatch: MonologueNativeCaptureLatch.recording,
      ),
    );
    if (_leaveEndRequested) {
      _leaveEndRequested = false;
      final cancelled = await _cancelNativeCapture();
      if (_isCurrentCapture(generation)) {
        if (cancelled) {
          _set(MonologueRecordingState.initial());
        } else {
          _fail(
            'VOICE_RECORDER_CANCEL_FAILED',
            MonologueFailureStage.nativeCapture,
            stopLiveTranscript: false,
          );
        }
      }
      return cancelled;
    }
    _logStage(MonologueFailureStage.nativeStart, 'succeeded');
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.starting,
        elapsedSeconds: session.elapsedSeconds,
        clearError: true,
        clearFailureStage: true,
      ),
    );

    _logStage(MonologueFailureStage.liveTranscription, 'started');
    final liveStarted = await _startLiveTranscript(generation, textPrefix: '');
    if (!_isCurrentCapture(generation)) {
      await _stopLiveTranscript();
      await _cancelNativeCapture();
      return false;
    }
    if (!liveStarted || !_ownedLiveTranscriptIsTranscribing()) {
      final errorCode =
          _state.liveTranscriptErrorCode ?? 'LIVE_TRANSCRIPT_START_FAILED';
      final expectedRecordingId = _ownedRecordingId;
      if (expectedRecordingId == null) {
        _fail(
          'MONOLOGUE_RECORDING_SESSION_LOST',
          MonologueFailureStage.nativeCapture,
          stopLiveTranscript: false,
        );
        return false;
      }
      final pausedLatch = await _pauseOwnedNativeSession(
        generation,
        expectedRecordingId,
      );
      if (!_isCurrentCapture(generation)) return false;
      if (pausedLatch == MonologueNativeCaptureLatch.paused) {
        _fail(
          errorCode,
          MonologueFailureStage.liveTranscription,
          stopLiveTranscript: false,
        );
        if (_leaveEndRequested) {
          _leaveEndRequested = false;
          unawaited(stop());
          return true;
        }
      } else {
        _fail(
          'VOICE_RECORDER_PAUSE_FAILED',
          MonologueFailureStage.nativeCapture,
          stopLiveTranscript: false,
        );
      }
      return false;
    }
    if (_leaveEndRequested) {
      _leaveEndRequested = false;
      await _stopLiveTranscript();
      final cancelled = await _cancelNativeCapture();
      if (_isCurrentCapture(generation)) {
        if (cancelled) {
          _set(MonologueRecordingState.initial());
        } else {
          _fail(
            'VOICE_RECORDER_CANCEL_FAILED',
            MonologueFailureStage.nativeCapture,
            stopLiveTranscript: false,
          );
        }
      }
      return cancelled;
    }

    _logStage(MonologueFailureStage.liveTranscription, 'succeeded');
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.recording,
        clearError: true,
        clearFailureStage: true,
        clearLiveTranscriptError: true,
      ),
    );
    _startLevelSubscription();
    _startSnapshotTimer(generation);
    return true;
  }

  Future<bool> pause() async {
    if (_disposed || !_state.canPause) return false;
    final generation = _captureGeneration;
    final expectedRecordingId = _ownedRecordingId;
    if (expectedRecordingId == null) {
      _fail(
        'MONOLOGUE_RECORDING_SESSION_LOST',
        MonologueFailureStage.nativeCapture,
      );
      return false;
    }
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.pausing,
        clearError: true,
        clearFailureStage: true,
      ),
    );
    _stopSnapshotTimer();
    await _stopLevelSubscription();
    final result = await _recorder.pauseOwnedRecording(
      expectedScene: VoiceRecordingScene.monologue,
      expectedRecordingId: expectedRecordingId,
    );
    if (!_isCurrentCapture(generation)) return false;
    final nativeLatch =
        result.ok &&
            result.value != null &&
            _isOwnedSnapshot(
              result.value!,
              expectedState: VoiceRecorderState.paused,
            )
        ? MonologueNativeCaptureLatch.paused
        : await _reconcileNativeCapture(generation, expectedRecordingId);
    if (!_isCurrentCapture(generation)) return false;
    if (nativeLatch != MonologueNativeCaptureLatch.paused) {
      if (nativeLatch == MonologueNativeCaptureLatch.recording) {
        _logStage(
          MonologueFailureStage.nativeCapture,
          'failed',
          errorCode: result.error?.code ?? 'VOICE_RECORDER_PAUSE_FAILED',
        );
        _set(
          _state.copyWith(
            status: MonologueRecordingStatus.recording,
            nativeCaptureLatch: nativeLatch,
            clearError: true,
            clearFailureStage: true,
          ),
        );
        _startLevelSubscription();
        _startSnapshotTimer(generation);
        return false;
      }
      await _stopLiveTranscript();
      if (!_isCurrentCapture(generation)) return false;
      _fail(
        result.error?.code ?? 'MONOLOGUE_RECORDING_SESSION_LOST',
        MonologueFailureStage.nativeCapture,
        stopLiveTranscript: false,
      );
      return false;
    }
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.pausing,
        nativeCaptureLatch: MonologueNativeCaptureLatch.paused,
        elapsedSeconds:
            result.value?.session?.elapsedSeconds ?? _state.elapsedSeconds,
      ),
    );

    final liveStopped = await _stopLiveTranscript();
    if (!_isCurrentCapture(generation)) return false;
    final liveError = _state.liveTranscriptErrorCode;
    if (!liveStopped || liveError != null) {
      _fail(
        liveError ?? 'LIVE_TRANSCRIPT_STOP_FAILED',
        MonologueFailureStage.liveTranscription,
        stopLiveTranscript: false,
      );
      return false;
    }

    _liveTranscriptAttemptTextPrefix = _state.transcriptText;
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.paused,
        clearError: true,
        clearFailureStage: true,
        clearLiveTranscriptError: true,
        clearLiveTranscriptAttempt: true,
      ),
    );
    if (_leaveEndRequested) {
      _leaveEndRequested = false;
      unawaited(stop());
    }
    return true;
  }

  Future<bool> resume() async {
    if (_disposed || !_state.canResume) return false;
    final generation = _captureGeneration;
    final expectedRecordingId = _ownedRecordingId;
    if (expectedRecordingId == null) {
      _fail(
        'MONOLOGUE_RECORDING_SESSION_LOST',
        MonologueFailureStage.nativeCapture,
      );
      return false;
    }
    final prefix = _state.transcriptText;
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.resuming,
        clearError: true,
        clearFailureStage: true,
        clearLiveTranscriptError: true,
        clearLiveTranscriptAttempt: true,
      ),
    );

    final resumed = await _recorder.resumeOwnedRecording(
      expectedScene: VoiceRecordingScene.monologue,
      expectedRecordingId: expectedRecordingId,
    );
    if (!_isCurrentCapture(generation)) {
      if (resumed.ok &&
          resumed.value != null &&
          _matchesOwnedSnapshot(resumed.value!, expectedRecordingId) &&
          resumed.value!.state == VoiceRecorderState.recording) {
        await _recorder.pauseOwnedRecording(
          expectedScene: VoiceRecordingScene.monologue,
          expectedRecordingId: expectedRecordingId,
        );
      }
      return false;
    }
    final resumedLatch =
        resumed.ok &&
            resumed.value != null &&
            _isOwnedSnapshot(
              resumed.value!,
              expectedState: VoiceRecorderState.recording,
            )
        ? MonologueNativeCaptureLatch.recording
        : await _reconcileNativeCapture(generation, expectedRecordingId);
    if (!_isCurrentCapture(generation)) return false;
    if (resumedLatch != MonologueNativeCaptureLatch.recording) {
      _fail(
        resumed.error?.code ?? 'VOICE_RECORDER_RESUME_FAILED',
        MonologueFailureStage.nativeCapture,
        stopLiveTranscript: false,
      );
      return false;
    }

    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.resuming,
        nativeCaptureLatch: MonologueNativeCaptureLatch.recording,
        elapsedSeconds:
            resumed.value?.session?.elapsedSeconds ?? _state.elapsedSeconds,
      ),
    );
    _startLevelSubscription();
    _startSnapshotTimer(generation);
    if (_leaveEndRequested) {
      _leaveEndRequested = false;
      _stopSnapshotTimer();
      await _stopLevelSubscription();
      final rolledBack = await _pauseOwnedNativeSession(
        generation,
        expectedRecordingId,
      );
      if (!_isCurrentCapture(generation)) return false;
      if (rolledBack == MonologueNativeCaptureLatch.paused) {
        _set(_state.copyWith(status: MonologueRecordingStatus.paused));
        unawaited(stop());
        return true;
      }
      _fail(
        'VOICE_RECORDER_PAUSE_FAILED',
        MonologueFailureStage.nativeCapture,
        stopLiveTranscript: false,
      );
      return false;
    }

    _logStage(MonologueFailureStage.liveTranscription, 'started');
    final liveStarted = await _startLiveTranscript(
      generation,
      textPrefix: prefix,
    );
    if (!_isCurrentCapture(generation)) return false;
    if (!liveStarted || !_ownedLiveTranscriptIsTranscribing()) {
      final liveError =
          _state.liveTranscriptErrorCode ?? 'LIVE_TRANSCRIPT_START_FAILED';
      await _stopLiveTranscript();
      _stopSnapshotTimer();
      await _stopLevelSubscription();
      final rolledBack = await _pauseOwnedNativeSession(
        generation,
        expectedRecordingId,
      );
      if (!_isCurrentCapture(generation)) return false;
      if (rolledBack == MonologueNativeCaptureLatch.paused) {
        _fail(
          liveError,
          MonologueFailureStage.liveTranscription,
          stopLiveTranscript: false,
        );
        if (_leaveEndRequested) {
          _leaveEndRequested = false;
          unawaited(stop());
          return true;
        }
      } else {
        _fail(
          'VOICE_RECORDER_PAUSE_FAILED',
          MonologueFailureStage.nativeCapture,
          stopLiveTranscript: false,
        );
      }
      return false;
    }
    if (_leaveEndRequested) {
      _leaveEndRequested = false;
      await _stopLiveTranscript();
      _stopSnapshotTimer();
      await _stopLevelSubscription();
      final rolledBack = await _pauseOwnedNativeSession(
        generation,
        expectedRecordingId,
      );
      if (!_isCurrentCapture(generation)) return false;
      if (rolledBack == MonologueNativeCaptureLatch.paused) {
        _set(_state.copyWith(status: MonologueRecordingStatus.paused));
        unawaited(stop());
        return true;
      }
      _fail(
        'VOICE_RECORDER_PAUSE_FAILED',
        MonologueFailureStage.nativeCapture,
        stopLiveTranscript: false,
      );
      return false;
    }

    _logStage(MonologueFailureStage.liveTranscription, 'succeeded');
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.recording,
        nativeCaptureLatch: MonologueNativeCaptureLatch.recording,
        clearError: true,
        clearFailureStage: true,
        clearLiveTranscriptError: true,
      ),
    );
    _startLevelSubscription();
    _startSnapshotTimer(generation);
    return true;
  }

  Future<bool> stop() async {
    if (_disposed) return false;
    if (_state.canPause) {
      final paused = await pause();
      if (!paused) return false;
    }
    if (!_state.canFinish) return false;
    final generation = _captureGeneration;
    final expectedRecordingId = _ownedRecordingId;
    if (expectedRecordingId == null) {
      _fail(
        'MONOLOGUE_RECORDING_SESSION_LOST',
        MonologueFailureStage.nativeStop,
        stopLiveTranscript: false,
      );
      return false;
    }
    _leaveEndRequested = false;
    _stopSnapshotTimer();
    await _stopLevelSubscription();
    if (_liveTranscriptOwner != null) {
      await _stopLiveTranscript();
    }
    if (!_isCurrentCapture(generation)) return false;

    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.stopping,
        clearError: true,
        clearFailureStage: true,
      ),
    );
    _logStage(MonologueFailureStage.nativeStop, 'started');
    final stopped = await _recorder.stopOwnedRecording(
      expectedScene: VoiceRecordingScene.monologue,
      expectedRecordingId: expectedRecordingId,
    );
    if (!_isCurrentCapture(generation)) return false;
    if (!stopped.ok || stopped.value == null) {
      final errorCode = stopped.error?.code ?? 'VOICE_RECORDER_STOP_FAILED';
      final stillOwned = await _reconcileOwnershipAfterStopFailure(
        generation,
        expectedRecordingId,
      );
      if (!_isCurrentCapture(generation)) return false;
      _fail(
        errorCode,
        !stillOwned && _isDraftValidationFailure(errorCode)
            ? MonologueFailureStage.draftValidation
            : MonologueFailureStage.nativeStop,
        stopLiveTranscript: false,
      );
      return false;
    }
    final draft = stopped.value!;
    _nativeRecordingId = null;
    _set(_state.copyWith(nativeCaptureLatch: MonologueNativeCaptureLatch.none));
    if (draft.scene != VoiceRecordingScene.monologue ||
        draft.recordingId != expectedRecordingId) {
      _fail(
        'MONOLOGUE_RECORDING_DRAFT_MISMATCH',
        MonologueFailureStage.draftValidation,
        stopLiveTranscript: false,
      );
      return false;
    }

    _logStage(MonologueFailureStage.nativeStop, 'succeeded');
    _logStage(MonologueFailureStage.draftValidation, 'succeeded');
    _pendingDraft = draft;
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.registeringLocal,
        nativeCaptureLatch: MonologueNativeCaptureLatch.none,
        elapsedSeconds: draft.durationSeconds,
        clearError: true,
        clearFailureStage: true,
      ),
    );
    return _registerLocalAndSaveNote(generation);
  }

  Future<bool> complete() {
    if (_state.isCaptureActive) return stop();
    if (_pendingDraft != null || _state.localItem != null) {
      return _registerLocalAndSaveNote(_captureGeneration);
    }
    return Future<bool>.value(false);
  }

  Future<bool> retry() async {
    if (_disposed || !_state.canRetry) return false;
    switch (_state.failureStage) {
      case MonologueFailureStage.permission:
      case MonologueFailureStage.nativeStart:
        return start();
      case MonologueFailureStage.liveTranscription:
        return _state.canResume ? resume() : start();
      case MonologueFailureStage.nativeCapture:
        return _recoverNativeCaptureFailure();
      case MonologueFailureStage.draftValidation:
        if (_state.localItem != null &&
            _state.transcriptText.trim().isNotEmpty) {
          return _saveNote(_captureGeneration);
        }
        return hasOwnedNativeCapture ? stop() : start();
      case MonologueFailureStage.localRegistration:
        return _pendingDraft == null
            ? false
            : _registerLocalAndSaveNote(_captureGeneration);
      case MonologueFailureStage.noteSave:
        return _state.localItem == null ? false : _saveNote(_captureGeneration);
      case MonologueFailureStage.nativeStop:
        return hasOwnedNativeCapture ? stop() : start();
      case null:
        return false;
    }
  }

  Future<bool> _recoverNativeCaptureFailure() async {
    final expectedRecordingId = _nativeRecordingId?.trim();
    if (expectedRecordingId == null || expectedRecordingId.isEmpty) {
      return start();
    }
    var latch = _state.nativeCaptureLatch;
    if (latch == MonologueNativeCaptureLatch.uncertain) {
      latch = await _reconcileNativeCapture(
        _captureGeneration,
        expectedRecordingId,
      );
    }
    if (_disposed) return false;
    switch (latch) {
      case MonologueNativeCaptureLatch.paused:
        _set(
          _state.copyWith(
            status: MonologueRecordingStatus.failed,
            nativeCaptureLatch: latch,
          ),
        );
        return resume();
      case MonologueNativeCaptureLatch.recording:
        _set(
          _state.copyWith(
            status: MonologueRecordingStatus.recording,
            nativeCaptureLatch: latch,
            clearError: true,
            clearFailureStage: true,
          ),
        );
        _startLevelSubscription();
        _startSnapshotTimer(_captureGeneration);
        return pause();
      case MonologueNativeCaptureLatch.none:
        return start();
      case MonologueNativeCaptureLatch.uncertain:
        return false;
    }
  }

  @Deprecated('Use retry; monologue audio is no longer uploaded for ASR.')
  Future<bool> retryUpload() => retry();

  Future<bool> cancel() async {
    if (_disposed ||
        (!hasOwnedNativeCapture &&
            _state.status != MonologueRecordingStatus.checkingPermission &&
            _state.status != MonologueRecordingStatus.starting)) {
      return false;
    }
    ++_captureGeneration;
    _leaveEndRequested = false;
    _stopSnapshotTimer();
    await _stopLevelSubscription();
    await _stopLiveTranscript();
    final cancelled = await _cancelNativeCapture();
    if (_disposed) return false;
    if (!cancelled) {
      _fail(
        'VOICE_RECORDER_CANCEL_FAILED',
        MonologueFailureStage.nativeCapture,
        stopLiveTranscript: false,
      );
      return false;
    }
    _pendingDraft = null;
    _liveTranscriptAttemptTextPrefix = '';
    _retainedLiveTranscript = const <LiveTranscriptSentence>[];
    _liveTranscriptAttemptPrefix = const <LiveTranscriptSentence>[];
    _set(MonologueRecordingState.initial());
    return true;
  }

  Future<bool> endCaptureForLeave() {
    if (_disposed) return Future<bool>.value(false);
    switch (_state.status) {
      case MonologueRecordingStatus.checkingPermission:
        _leaveEndRequested = true;
        return Future<bool>.value(true);
      case MonologueRecordingStatus.starting:
        _leaveEndRequested = true;
        return _endCaptureAfterTransition(_captureGeneration);
      case MonologueRecordingStatus.pausing:
      case MonologueRecordingStatus.resuming:
        return _endCaptureAfterTransition(_captureGeneration);
      case MonologueRecordingStatus.recording:
      case MonologueRecordingStatus.paused:
        return stop();
      case MonologueRecordingStatus.stopping:
      case MonologueRecordingStatus.registeringLocal:
      case MonologueRecordingStatus.savingNote:
        return Future<bool>.value(true);
      case MonologueRecordingStatus.failed:
        if (hasOwnedNativeCapture) return stop();
        return Future<bool>.value(false);
      case MonologueRecordingStatus.idle:
      case MonologueRecordingStatus.completed:
        return Future<bool>.value(false);
    }
  }

  Future<bool> _endCaptureAfterTransition(int generation) {
    final settled = Completer<bool>();
    var ending = false;
    late final VoidCallback evaluate;

    void complete(bool value) {
      if (settled.isCompleted) return;
      removeListener(evaluate);
      settled.complete(value);
    }

    evaluate = () {
      if (settled.isCompleted || ending) return;
      if (_disposed || generation != _captureGeneration) {
        complete(false);
        return;
      }
      switch (_state.status) {
        case MonologueRecordingStatus.checkingPermission:
        case MonologueRecordingStatus.starting:
        case MonologueRecordingStatus.pausing:
        case MonologueRecordingStatus.resuming:
          return;
        case MonologueRecordingStatus.recording:
        case MonologueRecordingStatus.paused:
        case MonologueRecordingStatus.failed:
          if (!hasOwnedNativeCapture) {
            complete(true);
            return;
          }
          ending = true;
          removeListener(evaluate);
          unawaited(() async {
            final stopped = await stop();
            complete(stopped || !hasOwnedNativeCapture);
          }());
          return;
        case MonologueRecordingStatus.stopping:
        case MonologueRecordingStatus.registeringLocal:
        case MonologueRecordingStatus.savingNote:
        case MonologueRecordingStatus.completed:
        case MonologueRecordingStatus.idle:
          complete(true);
          return;
      }
    };

    addListener(evaluate);
    scheduleMicrotask(evaluate);
    return settled.future;
  }

  Future<bool> _registerLocalAndSaveNote(int generation) async {
    if (!_isCurrentCapture(generation)) return false;
    var localItem = _state.localItem;
    if (localItem == null) {
      final draft = _pendingDraft;
      if (draft == null) {
        _fail(
          'MONOLOGUE_LOCAL_DRAFT_UNAVAILABLE',
          MonologueFailureStage.localRegistration,
          stopLiveTranscript: false,
        );
        return false;
      }
      _set(
        _state.copyWith(
          status: MonologueRecordingStatus.registeringLocal,
          clearError: true,
          clearFailureStage: true,
        ),
      );
      _logStage(MonologueFailureStage.localRegistration, 'started');
      final registered = await _localRecordingRepository
          .registerNativeVoiceRecording(
            file: PrivateAudioFile(
              fileId: draft.recordingId,
              appPrivateUri: draft.appPrivateUri,
              displayName: '独白-${draft.fileName}',
              mimeType: draft.mimeType,
              sizeBytes: draft.sizeBytes,
              durationSeconds: draft.durationSeconds,
              contentHash: draft.sha256,
              recordedAt: draft.recordedAt,
            ),
            recordedAt: draft.recordedAt,
            tagIds: const <String>[monologueRecordingHistoryTagId],
          );
      if (!_isCurrentCapture(generation)) return false;
      if (!registered.ok || registered.value == null) {
        _fail(
          registered.error?.code ?? 'MONOLOGUE_LOCAL_REGISTER_FAILED',
          MonologueFailureStage.localRegistration,
          stopLiveTranscript: false,
        );
        return false;
      }
      localItem = registered.value!;
      _pendingDraft = null;
      _logStage(MonologueFailureStage.localRegistration, 'succeeded');
      _set(
        _state.copyWith(
          status: MonologueRecordingStatus.registeringLocal,
          localItem: localItem,
          clearError: true,
          clearFailureStage: true,
        ),
      );
    }

    if (_state.transcriptText.trim().isEmpty) {
      _fail(
        'MONOLOGUE_TRANSCRIPT_EMPTY',
        MonologueFailureStage.draftValidation,
        stopLiveTranscript: false,
      );
      return false;
    }
    return _saveNote(generation);
  }

  Future<bool> _saveNote(int generation) async {
    if (!_isCurrentCapture(generation) || _state.localItem == null) {
      return false;
    }
    final transcript = _state.transcriptText.trim();
    if (transcript.isEmpty) {
      _fail(
        'MONOLOGUE_TRANSCRIPT_EMPTY',
        MonologueFailureStage.draftValidation,
        stopLiveTranscript: false,
      );
      return false;
    }

    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.savingNote,
        clearError: true,
        clearFailureStage: true,
      ),
    );
    _logStage(MonologueFailureStage.noteSave, 'started');
    try {
      var noteId = _state.localNoteId;
      if (noteId == null) {
        final note = _knowledgeLibrary.createManualNote(
          title: '',
          rawBody: transcript,
          createdAt: _state.localItem!.createdAt,
        );
        noteId = note.id;
        _set(_state.copyWith(localNoteId: noteId));
      } else {
        final existing = _knowledgeLibrary.noteForId(noteId);
        if (existing == null) {
          _fail(
            'MONOLOGUE_NOTE_DRAFT_MISSING',
            MonologueFailureStage.noteSave,
            stopLiveTranscript: false,
          );
          return false;
        }
        final updated = _knowledgeLibrary.updateManualNote(
          id: noteId,
          title: existing.title,
          rawBody: transcript,
        );
        if (updated == null) {
          _fail(
            'MONOLOGUE_NOTE_UPDATE_FAILED',
            MonologueFailureStage.noteSave,
            stopLiveTranscript: false,
          );
          return false;
        }
      }

      if (!await _knowledgeLibrary.flushPersistenceResult()) {
        _fail(
          'MONOLOGUE_NOTE_LOCAL_PERSIST_FAILED',
          MonologueFailureStage.noteSave,
          stopLiveTranscript: false,
        );
        return false;
      }
      if (!_isCurrentCapture(generation)) return false;

      final synced = await _knowledgeLibrary.syncNote(noteId);
      if (!_isCurrentCapture(generation)) return false;
      if (synced.outcome != KnowledgeNoteSyncOutcome.synced) {
        _fail(
          synced.errorCode ?? 'MONOLOGUE_NOTE_SYNC_FAILED',
          MonologueFailureStage.noteSave,
          stopLiveTranscript: false,
        );
        return false;
      }
      if (!await _knowledgeLibrary.flushPersistenceResult()) {
        _fail(
          'MONOLOGUE_NOTE_LOCAL_PERSIST_FAILED',
          MonologueFailureStage.noteSave,
          stopLiveTranscript: false,
        );
        return false;
      }
      if (!_isCurrentCapture(generation)) return false;

      _logStage(MonologueFailureStage.noteSave, 'succeeded');
      _set(
        _state.copyWith(
          status: MonologueRecordingStatus.completed,
          localNoteId: noteId,
          clearError: true,
          clearFailureStage: true,
          clearLiveTranscriptError: true,
          clearLiveTranscriptAttempt: true,
        ),
      );
      return true;
    } catch (_) {
      if (_isCurrentCapture(generation)) {
        _fail(
          'MONOLOGUE_NOTE_SYNC_FAILED',
          MonologueFailureStage.noteSave,
          stopLiveTranscript: false,
        );
      }
      return false;
    }
  }

  bool _consumeLeaveBeforeNativeStart() {
    if (!_leaveEndRequested) return false;
    _leaveEndRequested = false;
    _set(MonologueRecordingState.initial());
    return true;
  }

  void _startSnapshotTimer(int generation) {
    _stopSnapshotTimer();
    final snapshotGeneration = ++_snapshotGeneration;
    _snapshotTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_refreshing ||
          !_isCurrentCapture(generation) ||
          snapshotGeneration != _snapshotGeneration ||
          !_state.isNativeWriting) {
        return;
      }
      _refreshing = true;
      final refreshed = await _recorder.refreshState();
      _refreshing = false;
      if (!_isCurrentCapture(generation) ||
          snapshotGeneration != _snapshotGeneration ||
          !_state.isNativeWriting) {
        return;
      }
      if (!refreshed.ok || refreshed.value == null) {
        unawaited(
          _markNativeCaptureUncertain(
            refreshed.error?.code ?? 'VOICE_RECORDER_STATE_REFRESH_FAILED',
          ),
        );
        return;
      }
      final snapshot = refreshed.value!;
      if ((snapshot.state == VoiceRecorderState.recording ||
              snapshot.state == VoiceRecorderState.paused) &&
          !_isOwnedSnapshot(snapshot)) {
        _nativeRecordingId = null;
        _set(
          _state.copyWith(nativeCaptureLatch: MonologueNativeCaptureLatch.none),
        );
        unawaited(
          _markNativeCaptureUncertain('MONOLOGUE_RECORDING_SESSION_LOST'),
        );
        return;
      }
      switch (snapshot.state) {
        case VoiceRecorderState.recording:
          _set(
            _state.copyWith(
              nativeCaptureLatch: MonologueNativeCaptureLatch.recording,
              elapsedSeconds:
                  snapshot.session?.elapsedSeconds ?? _state.elapsedSeconds,
            ),
          );
        case VoiceRecorderState.paused:
          unawaited(_settleSystemPause(snapshot, generation));
        case VoiceRecorderState.idle:
        case VoiceRecorderState.failed:
          _nativeRecordingId = null;
          _set(
            _state.copyWith(
              nativeCaptureLatch: MonologueNativeCaptureLatch.none,
            ),
          );
          unawaited(
            _markNativeCaptureUncertain(
              snapshot.lastErrorCode ?? 'VOICE_RECORDER_CAPTURE_ENDED',
            ),
          );
      }
    });
  }

  Future<void> _settleSystemPause(
    VoiceRecorderSnapshot snapshot,
    int generation,
  ) async {
    if (!_state.isNativeWriting) return;
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.pausing,
        nativeCaptureLatch: MonologueNativeCaptureLatch.paused,
        elapsedSeconds:
            snapshot.session?.elapsedSeconds ?? _state.elapsedSeconds,
      ),
    );
    _stopSnapshotTimer();
    await _stopLevelSubscription();
    final stopped = await _stopLiveTranscript();
    if (!_isCurrentCapture(generation)) return;
    if (!stopped) {
      _fail(
        'LIVE_TRANSCRIPT_STOP_FAILED',
        MonologueFailureStage.liveTranscription,
        stopLiveTranscript: false,
      );
      return;
    }
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.paused,
        nativeCaptureLatch: MonologueNativeCaptureLatch.paused,
        clearLiveTranscriptAttempt: true,
      ),
    );
  }

  Future<void> _markNativeCaptureUncertain(String errorCode) async {
    if (_state.status == MonologueRecordingStatus.failed) {
      return;
    }
    _stopSnapshotTimer();
    await _stopLevelSubscription();
    await _stopLiveTranscript();
    if (_disposed) return;
    final latch = hasOwnedNativeCapture
        ? MonologueNativeCaptureLatch.uncertain
        : MonologueNativeCaptureLatch.none;
    _fail(
      errorCode,
      MonologueFailureStage.nativeCapture,
      stopLiveTranscript: false,
    );
    _set(_state.copyWith(nativeCaptureLatch: latch));
  }

  void _stopSnapshotTimer() {
    _snapshotGeneration += 1;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _refreshing = false;
  }

  void _startLevelSubscription() => waveform.start();

  Future<void> _stopLevelSubscription() => waveform.stop();

  Future<bool> _startLiveTranscript(
    int captureGeneration, {
    required String textPrefix,
  }) async {
    final liveTranscript = _liveTranscriptController;
    if (kDebugMode) {
      debugPrint(
        '[Monologue] stage=live_start_requested '
        'available=${liveTranscript != null}',
      );
    }
    if (liveTranscript == null) {
      _recordLiveTranscriptFailure('LIVE_TRANSCRIPT_UNAVAILABLE');
      return false;
    }
    if (!await _waitForLiveTranscriptReadiness(liveTranscript) ||
        !_isCurrentCapture(captureGeneration)) {
      _recordLiveTranscriptFailure('LIVE_TRANSCRIPT_SESSION_BUSY');
      return false;
    }
    final correlationId = _state.correlationId;
    if (correlationId == null) {
      _recordLiveTranscriptFailure('LIVE_TRANSCRIPT_START_FAILED');
      return false;
    }

    final owner = 'monologue:$correlationId:${++_liveSegmentSequence}';
    _liveTranscriptAttemptTextPrefix = textPrefix;
    _liveTranscriptAttemptPrefix = _retainedLiveTranscript;
    final generation = ++_liveTranscriptGeneration;
    try {
      final starting = liveTranscript.start(owner: owner);
      final startedAttempt = liveTranscript.state;
      if (startedAttempt.belongsTo(owner)) {
        _liveTranscriptOwner = owner;
        _liveTranscriptAttemptId = startedAttempt.attemptId;
        _set(
          _state.copyWith(liveTranscriptAttemptId: _liveTranscriptAttemptId),
        );
      }
      final started = await starting;
      final currentAttempt = liveTranscript.state;
      if (currentAttempt.belongsTo(owner)) {
        _liveTranscriptOwner = owner;
        _liveTranscriptAttemptId = currentAttempt.attemptId;
      }
      if (_disposed ||
          generation != _liveTranscriptGeneration ||
          !_isCurrentCapture(captureGeneration)) {
        if (started) {
          await _releaseLiveTranscript(
            liveTranscript,
            owner: owner,
            attemptId: _liveTranscriptAttemptId,
          );
        }
        return false;
      }
      if (!started ||
          currentAttempt.status != LiveTranscriptStatus.transcribing ||
          !currentAttempt.belongsTo(
            owner,
            candidateAttemptId: _liveTranscriptAttemptId,
          )) {
        _recordLiveTranscriptFailure(
          _liveTranscriptStartFailureCode(liveTranscript),
        );
        if (liveTranscript.state.belongsTo(
          owner,
          candidateAttemptId: _liveTranscriptAttemptId,
        )) {
          await _releaseLiveTranscript(
            liveTranscript,
            owner: owner,
            attemptId: _liveTranscriptAttemptId,
          );
        }
        _clearLiveTranscriptOwnership();
        return false;
      }

      _claimLiveTranscript(liveTranscript, owner: owner);
      _adoptLiveTranscriptAttempt(currentAttempt.sentences);
      _clearLiveTranscriptFailure();
      if (kDebugMode) {
        debugPrint(
          '[Monologue] stage=live_start_completed started=true '
          'owned=$_ownsLiveTranscript '
          'status=${liveTranscript.state.status.name}',
        );
      }
      return true;
    } catch (cause) {
      if (!_disposed && generation == _liveTranscriptGeneration) {
        _recordLiveTranscriptFailure('LIVE_TRANSCRIPT_START_FAILED');
      }
      if (kDebugMode) {
        debugPrint(
          '[Monologue] stage=live_start_failed cause=${cause.runtimeType}',
        );
      }
      return false;
    }
  }

  Future<bool> _waitForLiveTranscriptReadiness(
    LiveTranscriptController liveTranscript,
  ) async {
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

  String _liveTranscriptStartFailureCode(
    LiveTranscriptController liveTranscript,
  ) {
    final reported = liveTranscript.state.lastErrorCode;
    if (reported != null &&
        RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(reported)) {
      return reported;
    }
    return switch (liveTranscript.state.status) {
      LiveTranscriptStatus.starting ||
      LiveTranscriptStatus.transcribing ||
      LiveTranscriptStatus.stopping => 'LIVE_TRANSCRIPT_SESSION_BUSY',
      LiveTranscriptStatus.idle ||
      LiveTranscriptStatus.failed => 'LIVE_TRANSCRIPT_START_FAILED',
    };
  }

  void _recordLiveTranscriptFailure(String errorCode) {
    if (_disposed) return;
    final safeErrorCode = _safeErrorCode(errorCode);
    if (_state.liveTranscriptErrorCode == safeErrorCode) return;
    _set(
      _state.copyWith(
        liveTranscriptErrorCode: safeErrorCode,
        liveTranscriptAttemptId: _liveTranscriptAttemptId,
      ),
    );
    _logLiveTranscriptStage('failed', errorCode: safeErrorCode);
  }

  void _clearLiveTranscriptFailure() {
    if (_disposed || _state.liveTranscriptErrorCode == null) return;
    _set(_state.copyWith(clearLiveTranscriptError: true));
    _logLiveTranscriptStage('succeeded');
  }

  void _logLiveTranscriptStage(String outcome, {String? errorCode}) {
    final logger = _diagnosticLogger;
    final correlationId = _state.correlationId;
    if (logger == null || correlationId == null) return;
    logger.log(
      DiagnosticLogInput(
        category: DiagnosticCategory.recording,
        severity: outcome == 'failed'
            ? DiagnosticSeverity.error
            : DiagnosticSeverity.info,
        safeSummary: 'monologue_live_transcript_$outcome',
        correlationId: correlationId,
        metadata: <String, Object?>{
          'stage': 'liveTranscription',
          'outcome': outcome,
          if (errorCode != null) 'errorCode': errorCode,
        },
      ),
    );
  }

  Future<bool> _stopLiveTranscript() async {
    _liveTranscriptGeneration += 1;
    final liveTranscript = _liveTranscriptController;
    final owner = _liveTranscriptOwner;
    if (liveTranscript == null || owner == null) return true;
    final attemptId = _liveTranscriptAttemptId;
    var stopped = true;
    var timedOut = false;
    try {
      stopped =
          await _releaseLiveTranscript(
            liveTranscript,
            owner: owner,
            attemptId: attemptId,
          ).timeout(
            liveTranscriptStopGrace,
            onTimeout: () {
              timedOut = true;
              if (attemptId != null) {
                liveTranscript.abandonOwnedStoppingAttempt(
                  owner: owner,
                  attemptId: attemptId,
                );
              }
              return false;
            },
          );
      if (liveTranscript.state.status == LiveTranscriptStatus.idle ||
          liveTranscript.state.belongsTo(
            owner,
            candidateAttemptId: attemptId,
          )) {
        _adoptLiveTranscriptAttempt(liveTranscript.state.sentences);
      }
    } catch (_) {
      stopped = false;
    } finally {
      if (_liveTranscriptOwner == owner &&
          _liveTranscriptAttemptId == attemptId) {
        _clearLiveTranscriptOwnership();
      }
    }
    if (timedOut) {
      _recordLiveTranscriptFailure('LIVE_TRANSCRIPT_STOP_TIMEOUT');
    }
    return stopped;
  }

  void _claimLiveTranscript(
    LiveTranscriptController liveTranscript, {
    required String owner,
  }) {
    if (_ownsLiveTranscript) return;
    if (!liveTranscript.state.belongsTo(
      owner,
      candidateAttemptId: _liveTranscriptAttemptId,
    )) {
      return;
    }
    _ownsLiveTranscript = true;
    liveTranscript.addListener(_onOwnedLiveTranscriptChanged);
  }

  void _clearLiveTranscriptOwnership() {
    if (_ownsLiveTranscript) {
      _liveTranscriptController?.removeListener(_onOwnedLiveTranscriptChanged);
    }
    _ownsLiveTranscript = false;
    _liveTranscriptOwner = null;
    _liveTranscriptAttemptId = null;
  }

  bool _ownedLiveTranscriptIsTranscribing() {
    final liveTranscript = _liveTranscriptController;
    final owner = _liveTranscriptOwner;
    final attemptId = _liveTranscriptAttemptId;
    if (liveTranscript == null || owner == null || attemptId == null) {
      return false;
    }
    final shared = liveTranscript.state;
    return shared.status == LiveTranscriptStatus.transcribing &&
        shared.belongsTo(owner, candidateAttemptId: attemptId);
  }

  void _onOwnedLiveTranscriptChanged() {
    if (!_ownsLiveTranscript || _disposed) return;
    final liveTranscript = _liveTranscriptController;
    final owner = _liveTranscriptOwner;
    if (liveTranscript == null || owner == null) return;
    final shared = liveTranscript.state;
    if (shared.belongsTo(owner, candidateAttemptId: _liveTranscriptAttemptId)) {
      _adoptLiveTranscriptAttempt(shared.sentences);
      if (shared.status == LiveTranscriptStatus.failed) {
        final errorCode = _liveTranscriptStartFailureCode(liveTranscript);
        _recordLiveTranscriptFailure(errorCode);
        if (_state.status == MonologueRecordingStatus.recording &&
            _liveFailureCleanup == null) {
          late final Future<void> cleanup;
          cleanup = _pauseAfterLiveFailure(errorCode).whenComplete(() {
            if (identical(_liveFailureCleanup, cleanup)) {
              _liveFailureCleanup = null;
            }
          });
          _liveFailureCleanup = cleanup;
          unawaited(cleanup);
        }
      }
      return;
    }
    if (shared.status == LiveTranscriptStatus.idle) {
      _clearLiveTranscriptOwnership();
    }
  }

  Future<void> _pauseAfterLiveFailure(String errorCode) async {
    if (_disposed || _state.status != MonologueRecordingStatus.recording) {
      return;
    }
    final generation = _captureGeneration;
    final expectedRecordingId = _ownedRecordingId;
    if (expectedRecordingId == null) {
      _fail(
        'MONOLOGUE_RECORDING_SESSION_LOST',
        MonologueFailureStage.nativeCapture,
        stopLiveTranscript: false,
      );
      return;
    }
    _set(_state.copyWith(status: MonologueRecordingStatus.pausing));
    _stopSnapshotTimer();
    await _stopLevelSubscription();
    final pausedLatch = await _pauseOwnedNativeSession(
      generation,
      expectedRecordingId,
    );
    if (!_isCurrentCapture(generation)) return;
    if (pausedLatch != MonologueNativeCaptureLatch.paused) {
      await _stopLiveTranscript();
      _fail(
        'VOICE_RECORDER_PAUSE_FAILED',
        MonologueFailureStage.nativeCapture,
        stopLiveTranscript: false,
      );
      return;
    }
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.pausing,
        nativeCaptureLatch: MonologueNativeCaptureLatch.paused,
      ),
    );
    await _stopLiveTranscript();
    if (!_isCurrentCapture(generation)) return;
    _fail(
      errorCode,
      MonologueFailureStage.liveTranscription,
      stopLiveTranscript: false,
    );
  }

  void _adoptLiveTranscriptAttempt(
    List<LiveTranscriptSentence> attemptSentences,
  ) {
    _retainedLiveTranscript = _sentencesForCurrentAttempt(attemptSentences);
    final attemptText = _plainLiveTranscript(attemptSentences);
    final transcript = _appendTranscript(
      _liveTranscriptAttemptTextPrefix,
      attemptText,
    );
    if (!_disposed && transcript != _state.transcriptText) {
      _set(_state.copyWith(transcriptText: transcript));
    }
  }

  List<LiveTranscriptSentence> _sentencesForCurrentAttempt(
    List<LiveTranscriptSentence> attemptSentences,
  ) {
    final prefix = _liveTranscriptAttemptPrefix;
    if (prefix.isEmpty) {
      return List<LiveTranscriptSentence>.unmodifiable(attemptSentences);
    }
    if (attemptSentences.isEmpty) return prefix;
    final sentenceOffset =
        prefix.fold<int>(
          -1,
          (value, item) => item.sentenceId > value ? item.sentenceId : value,
        ) +
        1;
    final speakerOffset =
        prefix.fold<int>(-1, (value, item) {
          final speaker = item.anonymousSpeakerId;
          return speaker != null && speaker > value ? speaker : value;
        }) +
        1;
    return List<LiveTranscriptSentence>.unmodifiable(<LiveTranscriptSentence>[
      ...prefix,
      ...attemptSentences.map(
        (sentence) => LiveTranscriptSentence(
          sentenceId: sentenceOffset + sentence.sentenceId,
          text: sentence.text,
          stable: sentence.stable,
          anonymousSpeakerId: sentence.anonymousSpeakerId == null
              ? null
              : speakerOffset + sentence.anonymousSpeakerId!,
          startMs: sentence.startMs,
          endMs: sentence.endMs,
          speakerIdentityState: sentence.speakerIdentityState,
          speakerProfileId: sentence.speakerProfileId,
          speakerDisplayName: sentence.speakerDisplayName,
          speakerIdentityScore: sentence.speakerIdentityScore,
        ),
      ),
    ]);
  }

  Future<bool> _releaseLiveTranscript(
    LiveTranscriptController liveTranscript, {
    required String owner,
    required int? attemptId,
  }) async {
    final status = liveTranscript.state.status;
    if (status == LiveTranscriptStatus.idle) return true;
    if (!liveTranscript.state.belongsTo(owner, candidateAttemptId: attemptId)) {
      return false;
    }
    return liveTranscript.stop(owner: owner, attemptId: attemptId);
  }

  Future<MonologueNativeCaptureLatch> _pauseOwnedNativeSession(
    int generation,
    String expectedRecordingId,
  ) async {
    VoiceRecorderResult<VoiceRecorderSnapshot> paused;
    try {
      paused = await _recorder.pauseOwnedRecording(
        expectedScene: VoiceRecordingScene.monologue,
        expectedRecordingId: expectedRecordingId,
      );
    } catch (_) {
      return _reconcileNativeCapture(generation, expectedRecordingId);
    }
    if (!_isCurrentCapture(generation)) {
      return _state.nativeCaptureLatch;
    }
    final snapshot = paused.value;
    if (paused.ok &&
        snapshot != null &&
        _matchesOwnedSnapshot(snapshot, expectedRecordingId) &&
        snapshot.state == VoiceRecorderState.paused) {
      _set(
        _state.copyWith(
          nativeCaptureLatch: MonologueNativeCaptureLatch.paused,
          elapsedSeconds:
              snapshot.session?.elapsedSeconds ?? _state.elapsedSeconds,
        ),
      );
      return MonologueNativeCaptureLatch.paused;
    }
    return _reconcileNativeCapture(generation, expectedRecordingId);
  }

  Future<bool> _cancelNativeCapture() async {
    if (!hasOwnedNativeCapture) return true;
    final expectedRecordingId = _ownedRecordingId;
    if (expectedRecordingId == null) {
      _nativeRecordingId = null;
      _set(
        _state.copyWith(nativeCaptureLatch: MonologueNativeCaptureLatch.none),
      );
      return true;
    }
    try {
      final cancelled = await _recorder.cancelOwnedRecording(
        expectedScene: VoiceRecordingScene.monologue,
        expectedRecordingId: expectedRecordingId,
      );
      if (cancelled.ok) {
        _nativeRecordingId = null;
        _set(
          _state.copyWith(nativeCaptureLatch: MonologueNativeCaptureLatch.none),
        );
      } else {
        _set(
          _state.copyWith(
            nativeCaptureLatch: MonologueNativeCaptureLatch.uncertain,
          ),
        );
      }
      return cancelled.ok;
    } catch (_) {
      _set(
        _state.copyWith(
          nativeCaptureLatch: MonologueNativeCaptureLatch.uncertain,
        ),
      );
      return false;
    }
  }

  Future<bool> _cancelStartedMonologueSession(
    VoiceRecordingSession session,
  ) async {
    final recordingId = session.recordingId.trim();
    if (session.scene != VoiceRecordingScene.monologue || recordingId.isEmpty) {
      return true;
    }
    try {
      final cancelled = await _recorder.cancelOwnedRecording(
        expectedScene: VoiceRecordingScene.monologue,
        expectedRecordingId: recordingId,
      );
      if (cancelled.ok) return true;
    } catch (_) {
      // Never fall back to an unscoped command for an uncertain session.
    }
    if (!_disposed && !_state.hasNativeCapture) {
      _nativeRecordingId = recordingId;
      _set(
        _state.copyWith(
          nativeCaptureLatch: MonologueNativeCaptureLatch.uncertain,
        ),
      );
      _fail(
        'VOICE_RECORDER_CANCEL_FAILED',
        MonologueFailureStage.nativeCapture,
        stopLiveTranscript: false,
      );
    }
    return false;
  }

  Future<bool> _reconcileOwnershipAfterStopFailure(
    int generation,
    String expectedRecordingId,
  ) async {
    final latch = await _reconcileNativeCapture(
      generation,
      expectedRecordingId,
    );
    return latch != MonologueNativeCaptureLatch.none;
  }

  Future<MonologueNativeCaptureLatch> _reconcileNativeCapture(
    int generation,
    String expectedRecordingId,
  ) async {
    VoiceRecorderResult<VoiceRecorderSnapshot> refreshed;
    try {
      refreshed = await _recorder.refreshState();
    } catch (_) {
      if (_isCurrentCapture(generation)) {
        _set(
          _state.copyWith(
            nativeCaptureLatch: MonologueNativeCaptureLatch.uncertain,
          ),
        );
      }
      return MonologueNativeCaptureLatch.uncertain;
    }
    if (!_isCurrentCapture(generation)) return _state.nativeCaptureLatch;
    final snapshot = refreshed.value;
    if (!refreshed.ok || snapshot == null) {
      _set(
        _state.copyWith(
          nativeCaptureLatch: MonologueNativeCaptureLatch.uncertain,
        ),
      );
      return MonologueNativeCaptureLatch.uncertain;
    }
    if (_matchesOwnedSnapshot(snapshot, expectedRecordingId) &&
        (snapshot.state == VoiceRecorderState.recording ||
            snapshot.state == VoiceRecorderState.paused)) {
      _nativeRecordingId = expectedRecordingId;
      final latch = snapshot.state == VoiceRecorderState.recording
          ? MonologueNativeCaptureLatch.recording
          : MonologueNativeCaptureLatch.paused;
      _set(
        _state.copyWith(
          nativeCaptureLatch: latch,
          elapsedSeconds:
              snapshot.session?.elapsedSeconds ?? _state.elapsedSeconds,
        ),
      );
      return latch;
    }
    _nativeRecordingId = null;
    _set(_state.copyWith(nativeCaptureLatch: MonologueNativeCaptureLatch.none));
    return MonologueNativeCaptureLatch.none;
  }

  String? get _ownedRecordingId {
    if (!_state.hasNativeCapture) return null;
    final recordingId = _nativeRecordingId?.trim();
    return recordingId == null || recordingId.isEmpty ? null : recordingId;
  }

  bool _isCurrentCapture(int generation) =>
      !_disposed && generation == _captureGeneration;

  bool _isOwnedSnapshot(
    VoiceRecorderSnapshot snapshot, {
    VoiceRecorderState? expectedState,
  }) {
    final recordingId = _ownedRecordingId;
    return recordingId != null &&
        _matchesOwnedSnapshot(snapshot, recordingId) &&
        (expectedState == null || snapshot.state == expectedState);
  }

  bool _matchesOwnedSnapshot(
    VoiceRecorderSnapshot snapshot,
    String expectedRecordingId,
  ) {
    final session = snapshot.session;
    return session != null &&
        session.scene == VoiceRecordingScene.monologue &&
        session.recordingId == expectedRecordingId;
  }

  bool _isDraftValidationFailure(String errorCode) {
    return errorCode == 'NATIVE_VOICE_RECORDER_MALFORMED_PAYLOAD' ||
        errorCode == 'VOICE_RECORDER_EMPTY_FILE' ||
        errorCode == 'VOICE_RECORDER_FILE_UNAVAILABLE' ||
        errorCode == 'VOICE_RECORDER_INVALID_CHECKSUM';
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

  void _fail(
    String errorCode,
    MonologueFailureStage stage, {
    bool stopLiveTranscript = true,
  }) {
    final safeErrorCode = _safeErrorCode(errorCode);
    _stopSnapshotTimer();
    unawaited(_stopLevelSubscription());
    if (stopLiveTranscript) unawaited(_stopLiveTranscript());
    _logStage(stage, 'failed', errorCode: safeErrorCode);
    _set(
      _state.copyWith(
        status: MonologueRecordingStatus.failed,
        lastErrorCode: safeErrorCode,
        failureStage: stage,
        liveTranscriptErrorCode:
            stage == MonologueFailureStage.liveTranscription
            ? safeErrorCode
            : null,
        clearLiveTranscriptError:
            stage != MonologueFailureStage.liveTranscription,
        clearLiveTranscriptAttempt:
            stage != MonologueFailureStage.liveTranscription,
      ),
    );
  }

  String _newCorrelationId() {
    final explicit = _correlationIdFactory?.call();
    if (explicit != null && explicit.isNotEmpty) {
      return _safeCorrelationId(explicit);
    }
    final logger = _diagnosticLogger;
    if (logger != null) {
      return _safeCorrelationId(logger.createCorrelationId('monologue'));
    }
    return _safeCorrelationId(
      'monologue-${DateTime.now().toUtc().microsecondsSinceEpoch}',
    );
  }

  String _safeCorrelationId(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9_:-]'), '');
    if (safe.isEmpty) return 'monologue';
    return safe.length <= 80 ? safe : safe.substring(0, 80);
  }

  String _safeErrorCode(String value) {
    return RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(value)
        ? value
        : 'MONOLOGUE_OPERATION_FAILED';
  }

  void _logStage(
    MonologueFailureStage stage,
    String outcome, {
    String? errorCode,
  }) {
    final logger = _diagnosticLogger;
    final correlationId = _state.correlationId;
    if (logger == null || correlationId == null) return;
    logger.log(
      DiagnosticLogInput(
        category: stage == MonologueFailureStage.permission
            ? DiagnosticCategory.permission
            : stage == MonologueFailureStage.noteSave
            ? DiagnosticCategory.assets
            : DiagnosticCategory.recording,
        severity: outcome == 'failed'
            ? DiagnosticSeverity.error
            : DiagnosticSeverity.info,
        safeSummary: 'monologue_${stage.name}_$outcome',
        correlationId: correlationId,
        metadata: <String, Object?>{
          'stage': stage.name,
          'outcome': outcome,
          if (errorCode != null) 'errorCode': errorCode,
        },
      ),
    );
  }

  void _set(MonologueRecordingState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _captureGeneration += 1;
    _stopSnapshotTimer();
    waveform.dispose();
    unawaited(_stopLiveTranscript());
    if (hasOwnedNativeCapture) unawaited(_cancelNativeCapture());
    super.dispose();
  }
}

String _plainLiveTranscript(List<LiveTranscriptSentence> sentences) {
  return sentences
      .map((sentence) => sentence.text.trim())
      .where((text) => text.isNotEmpty)
      .join('\n');
}

String _appendTranscript(String prefix, String suffix) {
  final left = prefix.trimRight();
  final right = suffix.trimLeft();
  if (left.isEmpty) return right;
  if (right.isEmpty) return left;
  return '$left\n$right';
}

final monologueRecordingControllerProvider =
    ChangeNotifierProvider.autoDispose<MonologueRecordingController>((ref) {
      ref.keepAlive();
      return MonologueRecordingController(
        recorder: ref.watch(voiceRecorderPortProvider),
        localRecordingRepository: ref.watch(localRecordingRepositoryProvider),
        knowledgeLibrary: ref.read(knowledgeLibraryControllerProvider),
        diagnosticLogger: ref.watch(diagnosticLoggerProvider),
        liveTranscriptController: ref.read(liveTranscriptControllerProvider),
      );
    });
