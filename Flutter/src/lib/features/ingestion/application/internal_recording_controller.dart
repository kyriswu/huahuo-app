import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../core/native/screen_capture_port.dart';
import '../../../core/storage/upload_draft_store.dart';
import '../../recordings/application/recording_upload_controller.dart';
import '../../recordings/data/local_recording_repository.dart';
import '../../recordings/domain/recording_library.dart';
import '../data/internal_recording_session_store.dart';
import '../domain/material_ingestion.dart';

enum InternalRecordingStatus {
  loading,
  idle,
  unsupported,
  starting,
  awaitingConsent,
  recording,
  stopping,
  importingMedia,
  extractingAudio,
  registeringLocal,
  handingOff,
  completed,
  cancelled,
  failed,
}

enum InternalRecordingFailureStage {
  capability,
  permission,
  nativeStart,
  nativeCapture,
  nativeStop,
  extraction,
  localRegistration,
  handoff,
  persistence,
  cleanup,
}

enum InternalRecordingEntryOutcome { ready, restored, unavailable, superseded }

@immutable
final class InternalRecordingState {
  const InternalRecordingState({
    required this.status,
    this.elapsedSeconds = 0,
    this.sessionId,
    this.startedAt,
    this.capability,
    this.localItem,
    this.transcriptionJobId,
    this.remoteRecordingId,
    this.lastErrorCode,
    this.failureStage,
    this.hasRetainedMedia = false,
  });

  factory InternalRecordingState.initial({
    InternalRecordingStatus status = InternalRecordingStatus.loading,
  }) => InternalRecordingState(status: status);

  final InternalRecordingStatus status;
  final int elapsedSeconds;
  final String? sessionId;
  final DateTime? startedAt;
  final ScreenCaptureCapability? capability;
  final RecordingLibraryItem? localItem;
  final String? transcriptionJobId;
  final String? remoteRecordingId;
  final String? lastErrorCode;
  final InternalRecordingFailureStage? failureStage;
  final bool hasRetainedMedia;

  bool get hasNativeSession => switch (status) {
    InternalRecordingStatus.starting ||
    InternalRecordingStatus.awaitingConsent ||
    InternalRecordingStatus.recording ||
    InternalRecordingStatus.stopping => true,
    _ => false,
  };

  bool get isCaptureActive => hasNativeSession;
  bool get isRecording => status == InternalRecordingStatus.recording;
  bool get isProcessing => switch (status) {
    InternalRecordingStatus.importingMedia ||
    InternalRecordingStatus.extractingAudio ||
    InternalRecordingStatus.registeringLocal ||
    InternalRecordingStatus.handingOff => true,
    _ => false,
  };
  bool get isBusy =>
      status == InternalRecordingStatus.loading ||
      status == InternalRecordingStatus.starting ||
      status == InternalRecordingStatus.stopping ||
      isProcessing;
  bool get projectsActiveMessage =>
      hasNativeSession ||
      isProcessing ||
      (status == InternalRecordingStatus.failed && hasRetainedMedia);

  InternalRecordingState copyWith({
    InternalRecordingStatus? status,
    int? elapsedSeconds,
    DateTime? startedAt,
    ScreenCaptureCapability? capability,
    RecordingLibraryItem? localItem,
    String? transcriptionJobId,
    String? remoteRecordingId,
    String? lastErrorCode,
    InternalRecordingFailureStage? failureStage,
    bool? hasRetainedMedia,
    bool clearError = false,
  }) => InternalRecordingState(
    status: status ?? this.status,
    sessionId: sessionId,
    elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
    startedAt: startedAt ?? this.startedAt,
    capability: capability ?? this.capability,
    localItem: localItem ?? this.localItem,
    transcriptionJobId: transcriptionJobId ?? this.transcriptionJobId,
    remoteRecordingId: remoteRecordingId ?? this.remoteRecordingId,
    lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
    failureStage: clearError ? null : failureStage ?? this.failureStage,
    hasRetainedMedia: hasRetainedMedia ?? this.hasRetainedMedia,
  );
}

final class InternalRecordingController extends ChangeNotifier
    with WidgetsBindingObserver {
  InternalRecordingController({
    required this._capture,
    required this._sessionStore,
    required this._localRecordingRepository,
    required this._uploadController,
    DiagnosticLogger? diagnosticLogger,
    this.onDistillationJobReady,
    DateTime Function()? now,
  }) : _logger = diagnosticLogger,
       _now = now ?? DateTime.now {
    WidgetsBinding.instance.addObserver(this);
    _uploadController.addListener(_uploadChanged);
    scheduleMicrotask(() {
      if (!_disposed) unawaited(initialize());
    });
  }

  final ScreenCapturePort _capture;
  final Future<bool> Function(String jobId, String title)?
  onDistillationJobReady;
  final InternalRecordingSessionStore _sessionStore;
  final LocalRecordingRepository _localRecordingRepository;
  final RecordingUploadController _uploadController;
  final DiagnosticLogger? _logger;
  final DateTime Function() _now;
  InternalRecordingState _state = InternalRecordingState.initial();
  InternalRecordingCheckpoint? _checkpoint;
  CapturedAudioInput? _audio;
  Future<InternalRecordingEntryOutcome>? _initialization;
  Future<bool>? _processing;
  StreamSubscription<ScreenCaptureSnapshot>? _events;
  Timer? _timer;
  bool _commandInFlight = false;
  bool _refreshInFlight = false;
  bool _disposed = false;
  int _revision = 0;
  String? _acceptedMedia;
  bool _checkpointUnreadable = false;
  bool _foreground = true;
  int _nativeSnapshotVersion = 0;
  Future<void> _checkpointWrites = Future<void>.value();

  InternalRecordingState get state => _state;
  bool get canResetCheckpoint => _checkpointUnreadable && !_state.isBusy;
  bool get hasDurableJob {
    final jobId = _state.transcriptionJobId;
    return jobId != null && _uploadController.draftForJob(jobId) != null;
  }

  bool beginFreshJourney() {
    if (_disposed ||
        _commandInFlight ||
        _processing != null ||
        _state.isProcessing ||
        _state.hasNativeSession ||
        _state.hasRetainedMedia ||
        (_checkpoint != null && !_checkpoint!.handedOff)) {
      return false;
    }
    _revision++;
    _checkpoint = null;
    _audio = null;
    _acceptedMedia = null;
    _set(
      InternalRecordingState(
        status: _state.capability?.supported == false
            ? InternalRecordingStatus.unsupported
            : InternalRecordingStatus.idle,
        capability: _state.capability,
      ),
    );
    return true;
  }

  Future<InternalRecordingEntryOutcome> initialize({
    bool restorePending = true,
    String? recoveryDraftId,
  }) async {
    if (_disposed) {
      return InternalRecordingEntryOutcome.unavailable;
    }
    final outcome = await (_initialization ??= _initialize());
    if (_disposed) {
      return InternalRecordingEntryOutcome.superseded;
    }
    if (recoveryDraftId != null && recoveryDraftId != _checkpoint?.sessionId) {
      return InternalRecordingEntryOutcome.unavailable;
    }
    return outcome;
  }

  Future<InternalRecordingEntryOutcome> _initialize() async {
    final revision = _revision;
    try {
      await _events?.cancel();
      _events = null;
      _checkpointUnreadable = true;
      _checkpoint = _sessionStore.read();
      _checkpointUnreadable = false;
      final capability = await _capture.getCapability();
      if (!_owns(revision)) {
        return InternalRecordingEntryOutcome.superseded;
      }
      final checkpoint = _checkpoint;
      _set(
        InternalRecordingState(
          status: InternalRecordingStatus.loading,
          capability: capability.value,
          sessionId: checkpoint?.sessionId,
          startedAt: checkpoint?.startedAt,
          hasRetainedMedia: checkpoint?.media != null,
        ),
      );
      final refreshed = checkpoint == null
          ? await _capture.refreshState()
          : await _capture.recoverSession(checkpoint.sessionId);
      if (!_owns(revision)) {
        return InternalRecordingEntryOutcome.superseded;
      }
      _events = _capture.events.listen(
        _applySnapshot,
        onError: (Object error) {
          if (!_disposed && _state.hasNativeSession) {
            _set(_state.copyWith(lastErrorCode: 'SCREEN_CAPTURE_EVENT_FAILED'));
            unawaited(refreshSession());
          }
        },
      );
      if (checkpoint?.discardRequested == true) {
        await discardAndReset();
        return InternalRecordingEntryOutcome.restored;
      }
      if (checkpoint?.handedOff == true) {
        if (!await _enqueueDistillation(checkpoint!)) {
          return InternalRecordingEntryOutcome.restored;
        }
        await _completeHandoff(revision);
        return InternalRecordingEntryOutcome.restored;
      }
      if (checkpoint?.media != null) {
        _acceptedMedia = checkpoint!.media!.appPrivateUri;
        unawaited(_processMedia(checkpoint.media!));
        return InternalRecordingEntryOutcome.restored;
      }
      if (checkpoint != null) {
        final snapshot = refreshed.value;
        if (snapshot != null &&
            snapshot.sessionId == checkpoint.sessionId &&
            (snapshot.isActive ||
                snapshot.state == ScreenCaptureState.completed ||
                snapshot.state == ScreenCaptureState.failed)) {
          _applySnapshot(snapshot);
        } else {
          _fail(
            'SCREEN_CAPTURE_SESSION_INTERRUPTED',
            InternalRecordingFailureStage.nativeCapture,
          );
        }
        return InternalRecordingEntryOutcome.restored;
      }
      if (!capability.ok || capability.value == null) {
        _fail(
          capability.error?.code ?? 'SCREEN_CAPTURE_DRIVER_UNAVAILABLE',
          InternalRecordingFailureStage.capability,
        );
      } else if (!capability.value!.supported ||
          !capability.value!.canCaptureSystemAudio) {
        _set(
          _state.copyWith(
            status: InternalRecordingStatus.unsupported,
            lastErrorCode:
                capability.value!.reasonCode ?? 'SCREEN_CAPTURE_UNSUPPORTED',
          ),
        );
      } else {
        _set(_state.copyWith(status: InternalRecordingStatus.idle));
      }
      return InternalRecordingEntryOutcome.ready;
    } catch (_) {
      if (_owns(revision)) {
        _fail(
          'INTERNAL_RECORDING_CHECKPOINT_READ_FAILED',
          InternalRecordingFailureStage.persistence,
        );
      }
      return InternalRecordingEntryOutcome.unavailable;
    }
  }

  Future<bool> start({bool distillToDigitalTwin = false}) async {
    await initialize();
    if (_checkpointUnreadable) return false;
    if (_state.status == InternalRecordingStatus.completed &&
        !beginFreshJourney()) {
      return false;
    }
    if (!_localRecordingRepository.hasActiveAccount) {
      _fail(
        'RECORDING_LOGIN_REQUIRED',
        InternalRecordingFailureStage.permission,
      );
      return false;
    }
    if (_disposed ||
        _commandInFlight ||
        _processing != null ||
        _state.hasNativeSession ||
        _state.hasRetainedMedia) {
      return false;
    }
    _commandInFlight = true;
    final revision = ++_revision;
    try {
      final capability = await _capture.getCapability();
      if (!_owns(revision)) {
        return false;
      }
      if (!capability.ok ||
          capability.value?.supported != true ||
          capability.value?.canCaptureSystemAudio != true) {
        _set(
          _state.copyWith(
            status: capability.ok
                ? InternalRecordingStatus.unsupported
                : InternalRecordingStatus.failed,
            capability: capability.value,
            lastErrorCode:
                capability.error?.code ??
                capability.value?.reasonCode ??
                'SCREEN_CAPTURE_UNSUPPORTED',
            failureStage: InternalRecordingFailureStage.capability,
          ),
        );
        return false;
      }
      final current = await _capture.refreshState();
      if (!_owns(revision)) {
        return false;
      }
      if (current.value?.isActive == true &&
          current.value!.sessionId == _checkpoint?.sessionId) {
        _set(
          _state.copyWith(
            status: InternalRecordingStatus.loading,
            clearError: true,
          ),
        );
        _applySnapshot(current.value!);
        return true;
      }
      if (!current.ok || current.value == null || current.value!.isActive) {
        _fail(
          current.value?.isActive == true
              ? 'SCREEN_CAPTURE_ALREADY_ACTIVE'
              : current.error?.code ?? 'SCREEN_CAPTURE_STATE_UNAVAILABLE',
          InternalRecordingFailureStage.nativeStart,
        );
        return false;
      }
      final sessionId = _newSessionId();
      _checkpoint = InternalRecordingCheckpoint(
        sessionId: sessionId,
        startedAt: _now(),
        distillToDigitalTwin: distillToDigitalTwin,
      );
      _audio = null;
      _acceptedMedia = null;
      _set(
        InternalRecordingState(
          status: InternalRecordingStatus.starting,
          sessionId: sessionId,
          capability: capability.value,
          startedAt: _checkpoint!.startedAt,
        ),
      );
      if (!await _saveCheckpoint(revision)) return false;
      if (!_owns(revision)) {
        return false;
      }
      _set(_state.copyWith(status: InternalRecordingStatus.awaitingConsent));
      _observe();
      final result = await _capture.startCapture(sessionId: sessionId);
      if (!_owns(revision)) {
        unawaited(_capture.stopCapture(expectedSessionId: sessionId));
        return false;
      }
      if (!result.ok || result.value == null) {
        _captureFailed(result.error?.code ?? 'SCREEN_CAPTURE_START_FAILED');
        return false;
      }
      _applySnapshot(result.value!);
      return _state.hasNativeSession ||
          _state.isProcessing ||
          _state.status == InternalRecordingStatus.completed;
    } catch (_) {
      if (_owns(revision)) {
        _fail(
          'SCREEN_CAPTURE_START_FAILED',
          InternalRecordingFailureStage.nativeStart,
        );
      }
      return false;
    } finally {
      _commandInFlight = false;
    }
  }

  Future<bool> stop() async {
    if (_disposed ||
        _commandInFlight ||
        !_state.hasNativeSession ||
        _checkpoint == null) {
      return false;
    }
    _commandInFlight = true;
    final revision = _revision;
    final previous = _state.status;
    _nativeSnapshotVersion++;
    final sessionId = _checkpoint!.sessionId;
    _set(
      _state.copyWith(
        status: InternalRecordingStatus.stopping,
        clearError: true,
      ),
    );
    try {
      _checkpoint = _checkpoint!.copyWith(
        stage: InternalRecordingCheckpointStage.stopping,
      );
      if (!await _saveCheckpoint(revision)) {
        if (_owns(revision)) {
          _set(_state.copyWith(status: previous));
          _observe();
        }
        return false;
      }
      final result = await _capture.stopCapture(expectedSessionId: sessionId);
      if (!_owns(revision)) {
        return false;
      }
      if (_acceptedMedia != null) {
        return true;
      }
      if (!_state.hasNativeSession) {
        return _state.status == InternalRecordingStatus.cancelled;
      }
      if (!result.ok || result.value == null) {
        _set(
          _state.copyWith(
            status: previous,
            lastErrorCode: result.error?.code ?? 'SCREEN_CAPTURE_STOP_FAILED',
            failureStage: InternalRecordingFailureStage.nativeStop,
          ),
        );
        _observe();
        return false;
      }
      _applySnapshot(result.value!);
      return true;
    } catch (_) {
      if (_owns(revision) &&
          _acceptedMedia == null &&
          _state.hasNativeSession) {
        _set(
          _state.copyWith(
            status: previous,
            lastErrorCode: 'SCREEN_CAPTURE_STOP_FAILED',
            failureStage: InternalRecordingFailureStage.nativeStop,
          ),
        );
        _observe();
      }
      return false;
    } finally {
      _commandInFlight = false;
    }
  }

  Future<bool> cancel() => stop();

  Future<bool> importVideo({bool distillToDigitalTwin = false}) async {
    await initialize();
    if (_disposed ||
        _state.isProcessing ||
        _checkpointUnreadable ||
        _commandInFlight ||
        _processing != null ||
        _state.hasNativeSession ||
        _state.hasRetainedMedia) {
      return false;
    }
    if (!_localRecordingRepository.hasActiveAccount) {
      _fail(
        'RECORDING_LOGIN_REQUIRED',
        InternalRecordingFailureStage.permission,
      );
      return false;
    }
    _commandInFlight = true;
    final revision = ++_revision;
    final sessionId = _newSessionId();
    _checkpoint = InternalRecordingCheckpoint(
      sessionId: sessionId,
      startedAt: _now(),
      distillToDigitalTwin: distillToDigitalTwin,
      stage: InternalRecordingCheckpointStage.importingMedia,
    );
    _audio = null;
    _acceptedMedia = null;
    _set(
      InternalRecordingState(
        status: InternalRecordingStatus.importingMedia,
        capability: _state.capability,
        sessionId: sessionId,
        startedAt: _checkpoint!.startedAt,
      ),
    );
    try {
      if (!await _saveCheckpoint(revision)) return false;
      final result = await _capture.importVideo(sessionId);
      if (!_owns(revision)) return false;
      if (!result.ok || result.value == null) {
        _fail(
          result.error?.code ?? 'SCREEN_CAPTURE_IMPORT_FAILED',
          InternalRecordingFailureStage.extraction,
        );
        return false;
      }
      _applySnapshot(result.value!);
      return result.value!.state == ScreenCaptureState.completed;
    } catch (_) {
      if (_owns(revision)) {
        _fail(
          'SCREEN_CAPTURE_IMPORT_FAILED',
          InternalRecordingFailureStage.extraction,
        );
      }
      return false;
    } finally {
      _commandInFlight = false;
    }
  }

  Future<bool> _enqueueDistillation(
    InternalRecordingCheckpoint checkpoint,
  ) async {
    if (!checkpoint.distillToDigitalTwin) return true;
    try {
      if (checkpoint.jobId != null &&
          await onDistillationJobReady?.call(checkpoint.jobId!, '内录转写材料') ==
              true)
        return true;
    } catch (_) {}
    if (!_disposed)
      _fail(
        'DIGITAL_TWIN_QUEUE_SAVE_FAILED',
        InternalRecordingFailureStage.persistence,
      );
    return false;
  }

  Future<bool> retry() async {
    if (_disposed || _commandInFlight || _processing != null) {
      return false;
    }
    if (_checkpoint?.discardRequested == true) return discardAndReset();
    if (_checkpoint?.handedOff == true) {
      _commandInFlight = true;
      final revision = _revision;
      try {
        if (!await _enqueueDistillation(_checkpoint!)) return false;
        return await _completeHandoff(revision);
      } finally {
        _commandInFlight = false;
      }
    }
    if (_state.hasNativeSession) {
      await refreshSession();
      return _state.hasNativeSession ? stop() : true;
    }
    final media = _checkpoint?.media;
    if (media != null) {
      return _processMedia(media);
    }
    if (_state.failureStage == InternalRecordingFailureStage.persistence) {
      _initialization = null;
      await initialize();
      return _state.status != InternalRecordingStatus.failed;
    }
    return start(
      distillToDigitalTwin: _checkpoint?.distillToDigitalTwin ?? false,
    );
  }

  Future<bool> discardAndReset() async {
    if (_disposed ||
        _commandInFlight ||
        _processing != null ||
        _state.hasNativeSession) {
      return false;
    }
    _commandInFlight = true;
    final revision = _revision;
    try {
      if (_checkpointUnreadable) {
        final current = await _capture.refreshState();
        if (!current.ok || current.value?.isActive == true) {
          _fail(
            'SCREEN_CAPTURE_RESET_REQUIRES_STOP',
            InternalRecordingFailureStage.persistence,
          );
          return false;
        }
        await _sessionStore.quarantine();
        _checkpointUnreadable = false;
      } else {
        if (_checkpoint != null) {
          _checkpoint = _checkpoint!.copyWith(discardRequested: true);
          if (!await _saveCheckpoint(revision)) return false;
        }
        if (!await _releaseMedia(revision)) return false;
        await _sessionStore.clear();
      }
      if (_disposed) {
        return false;
      }
      _checkpoint = null;
      _audio = null;
      _acceptedMedia = null;
      _revision++;
      _set(
        InternalRecordingState(
          status: InternalRecordingStatus.idle,
          capability: _state.capability,
        ),
      );
      return true;
    } catch (_) {
      _fail(
        'INTERNAL_RECORDING_CHECKPOINT_WRITE_FAILED',
        InternalRecordingFailureStage.persistence,
      );
      return false;
    } finally {
      _commandInFlight = false;
    }
  }

  Future<void> refreshSession() async {
    if (_disposed ||
        !_foreground ||
        _refreshInFlight ||
        _commandInFlight ||
        _processing != null ||
        _checkpoint == null ||
        _checkpoint!.handedOff) {
      return;
    }
    _refreshInFlight = true;
    final revision = _revision;
    final snapshotVersion = _nativeSnapshotVersion;
    try {
      final result = await _capture.recoverSession(_checkpoint!.sessionId);
      if (!_owns(revision) || snapshotVersion != _nativeSnapshotVersion) {
        return;
      }
      if (result.ok && result.value != null) {
        if (_state.hasNativeSession &&
            result.value!.sessionId != _checkpoint!.sessionId) {
          _fail(
            'SCREEN_CAPTURE_SESSION_INTERRUPTED',
            InternalRecordingFailureStage.nativeCapture,
          );
          return;
        }
        _applySnapshot(result.value!);
      } else if (_state.hasNativeSession) {
        _set(
          _state.copyWith(
            lastErrorCode:
                result.error?.code ?? 'SCREEN_CAPTURE_STATE_UNAVAILABLE',
          ),
        );
      }
    } catch (_) {
      if (_owns(revision) && _state.hasNativeSession) {
        _set(
          _state.copyWith(lastErrorCode: 'SCREEN_CAPTURE_STATE_UNAVAILABLE'),
        );
      }
    } finally {
      _refreshInFlight = false;
    }
  }

  void _applySnapshot(ScreenCaptureSnapshot snapshot) {
    if (_disposed ||
        _checkpoint == null ||
        _checkpoint!.handedOff ||
        snapshot.sessionId != _checkpoint!.sessionId ||
        _processing != null) {
      return;
    }
    if (_acceptedMedia != null) {
      return;
    }
    if (snapshot.state == ScreenCaptureState.starting &&
        (_state.status == InternalRecordingStatus.recording ||
            _state.status == InternalRecordingStatus.stopping)) {
      return;
    }
    _nativeSnapshotVersion++;
    switch (snapshot.state) {
      case ScreenCaptureState.importing:
        _set(_state.copyWith(status: InternalRecordingStatus.importingMedia));
        _observe();
      case ScreenCaptureState.starting:
      case ScreenCaptureState.recording:
      case ScreenCaptureState.stopping:
        if (_state.status == InternalRecordingStatus.cancelled ||
            _state.status == InternalRecordingStatus.failed) {
          return;
        }
        final next = switch (snapshot.state) {
          ScreenCaptureState.starting =>
            InternalRecordingStatus.awaitingConsent,
          ScreenCaptureState.recording => InternalRecordingStatus.recording,
          _ => InternalRecordingStatus.stopping,
        };
        final stage = switch (next) {
          InternalRecordingStatus.recording =>
            InternalRecordingCheckpointStage.recording,
          InternalRecordingStatus.stopping =>
            InternalRecordingCheckpointStage.stopping,
          _ => InternalRecordingCheckpointStage.awaitingConsent,
        };
        if (_state.status != InternalRecordingStatus.stopping &&
            _checkpoint!.stage != stage) {
          _checkpoint = _checkpoint!.copyWith(stage: stage);
          unawaited(_saveCheckpoint(_revision));
        }
        _set(
          _state.copyWith(
            status: _state.status == InternalRecordingStatus.stopping
                ? _state.status
                : next,
            elapsedSeconds: max(_state.elapsedSeconds, snapshot.elapsedSeconds),
            startedAt: snapshot.startedAt,
            clearError: true,
          ),
        );
        _observe();
      case ScreenCaptureState.completed:
        final media = snapshot.media;
        if (media == null) {
          _fail(
            'SCREEN_CAPTURE_MEDIA_INVALID',
            InternalRecordingFailureStage.extraction,
          );
          return;
        }
        _acceptedMedia = media.appPrivateUri;
        _checkpoint = _checkpoint!.copyWith(media: media);
        unawaited(_processMedia(media));
      case ScreenCaptureState.failed:
        if (snapshot.media != null) {
          _acceptedMedia = snapshot.media!.appPrivateUri;
          _checkpoint = _checkpoint!.copyWith(media: snapshot.media);
          unawaited(_processMedia(snapshot.media!));
          return;
        }
        _captureFailed(snapshot.lastErrorCode ?? 'SCREEN_CAPTURE_FAILED');
      case ScreenCaptureState.idle:
      case ScreenCaptureState.unsupported:
        if (_state.hasNativeSession) {
          _fail(
            'SCREEN_CAPTURE_SESSION_INTERRUPTED',
            InternalRecordingFailureStage.nativeCapture,
          );
        }
    }
  }

  Future<bool> _processMedia(CapturedMediaInput media) {
    final existing = _processing;
    if (existing != null) {
      return existing;
    }
    final completer = Completer<bool>();
    _processing = completer.future;
    _timer?.cancel();
    _timer = null;
    final revision = _revision;
    () async {
      try {
        completer.complete(await _runPipeline(media, revision));
      } catch (_) {
        if (_owns(revision)) {
          _fail('INTERNAL_RECORDING_PROCESSING_FAILED', switch (_state.status) {
            InternalRecordingStatus.handingOff =>
              InternalRecordingFailureStage.handoff,
            InternalRecordingStatus.registeringLocal =>
              InternalRecordingFailureStage.localRegistration,
            _ => InternalRecordingFailureStage.extraction,
          });
        }
        completer.complete(false);
      } finally {
        _processing = null;
      }
    }();
    return completer.future;
  }

  Future<bool> _runPipeline(CapturedMediaInput media, int revision) async {
    if (!_owns(revision) || _checkpoint == null) {
      return false;
    }
    _checkpoint = _checkpoint!.copyWith(
      media: media,
      stage: InternalRecordingCheckpointStage.extractingAudio,
    );
    _set(
      _state.copyWith(
        status: InternalRecordingStatus.extractingAudio,
        elapsedSeconds: media.durationSeconds,
        hasRetainedMedia: true,
        clearError: true,
      ),
    );
    if (!await _saveCheckpoint(revision)) {
      return false;
    }
    var item = _state.localItem;
    final localId = _checkpoint!.localRecordingId;
    item ??= localId == null
        ? null
        : _localRecordingRepository.findById(localId);
    if (item == null) {
      if (_audio == null) {
        final extracted = await _capture.extractAudio(media);
        if (!_owns(revision)) {
          return false;
        }
        if (!extracted.ok || extracted.value == null) {
          _fail(
            extracted.error?.code ?? 'SCREEN_CAPTURE_AUDIO_EXPORT_FAILED',
            InternalRecordingFailureStage.extraction,
          );
          return false;
        }
        _audio = extracted.value!;
      }
      final audio = _audio!;
      if (audio.mimeType != 'audio/mp4' || audio.durationSeconds < 3) {
        _fail(
          'SCREEN_CAPTURE_AUDIO_TOO_SHORT',
          InternalRecordingFailureStage.extraction,
        );
        return false;
      }
      _set(_state.copyWith(status: InternalRecordingStatus.registeringLocal));
      _checkpoint = _checkpoint!.copyWith(
        stage: InternalRecordingCheckpointStage.registeringLocal,
      );
      if (!await _saveCheckpoint(revision)) return false;
      final registered = await _localRecordingRepository
          .archivePrivateMediaAudio(
            sourceAppPrivateUri: audio.appPrivateUri,
            displayName: _fileName(_checkpoint!.startedAt),
            mimeType: audio.mimeType,
            sizeBytes: audio.sizeBytes,
            durationSeconds: audio.durationSeconds,
            contentHash: audio.sha256,
            recordedAt: _checkpoint!.startedAt,
          );
      if (!_owns(revision)) {
        return false;
      }
      if (!registered.ok || registered.value == null) {
        _fail(
          registered.error?.code ?? 'INTERNAL_RECORDING_LOCAL_REGISTER_FAILED',
          InternalRecordingFailureStage.localRegistration,
        );
        return false;
      }
      item = registered.value!;
    }
    final jobId = recordingFileJobId(item);
    _checkpoint = _checkpoint!.copyWith(
      localRecordingId: item.recordingId,
      jobId: jobId,
      stage: InternalRecordingCheckpointStage.handingOff,
    );
    _set(
      _state.copyWith(
        status: InternalRecordingStatus.handingOff,
        localItem: item,
        transcriptionJobId: jobId,
      ),
    );
    if (!await _saveCheckpoint(revision)) {
      return false;
    }
    if (!await _enqueueDistillation(_checkpoint!)) return false;
    if (!_owns(revision)) return false;
    final existingDraft = _uploadController.draftForJob(jobId);
    if (existingDraft != null &&
        existingDraft.recordingId != null &&
        const <UploadDraftStage>{
          UploadDraftStage.asrQueued,
          UploadDraftStage.uploaded,
          UploadDraftStage.asrCompleted,
          UploadDraftStage.asrFailed,
        }.contains(existingDraft.stage)) {
      _checkpoint = _checkpoint!.copyWith(handedOff: true);
    } else if (existingDraft != null) {
      final accepted = await _uploadController.retryJob(jobId);
      if (!_owns(revision)) {
        return false;
      }
      if (!accepted) {
        _fail(
          _uploadController.state.lastErrorCode ??
              'INTERNAL_RECORDING_HANDOFF_FAILED',
          InternalRecordingFailureStage.handoff,
        );
        return false;
      }
    } else {
      final created = await _uploadController.uploadLocalRecording(
        item: item,
        sourceScene: 'raw_material',
        fileSource: RecordingFileSource.internalRecording,
        title: item.displayName,
      );
      if (!_owns(revision)) {
        return false;
      }
      if (created == null) {
        _fail(
          _uploadController.state.lastErrorCode ??
              'INTERNAL_RECORDING_HANDOFF_FAILED',
          InternalRecordingFailureStage.handoff,
        );
        return false;
      }
    }
    _checkpoint = _checkpoint!.copyWith(handedOff: true);
    if (!await _saveCheckpoint(revision)) {
      return false;
    }
    return _completeHandoff(revision);
  }

  Future<bool> _completeHandoff(int revision) async {
    if (!_owns(revision) || _checkpoint?.handedOff != true) return false;
    if (!await _releaseMedia(revision)) return false;
    _checkpoint = _checkpoint!.copyWith(
      stage: InternalRecordingCheckpointStage.completed,
    );
    if (!await _saveCheckpoint(revision)) return false;
    _set(
      _state.copyWith(
        status: InternalRecordingStatus.completed,
        hasRetainedMedia: false,
        transcriptionJobId: _checkpoint!.jobId,
        localItem: _checkpoint!.localRecordingId == null
            ? null
            : _localRecordingRepository.findById(
                _checkpoint!.localRecordingId!,
              ),
        remoteRecordingId: _checkpoint!.jobId == null
            ? null
            : _uploadController.draftForJob(_checkpoint!.jobId!)?.recordingId,
        clearError: true,
      ),
    );
    return true;
  }

  Future<bool> _saveCheckpoint(int revision) async {
    final checkpoint = _checkpoint;
    if (checkpoint == null || !_owns(revision)) return false;
    final write = _checkpointWrites.then((_) async {
      if (_owns(revision)) await _sessionStore.save(checkpoint);
    });
    _checkpointWrites = write.catchError((Object _) {});
    try {
      await write;
      return _owns(revision);
    } catch (_) {
      if (_owns(revision)) {
        if (_state.isRecording ||
            _state.status == InternalRecordingStatus.stopping) {
          _set(
            _state.copyWith(
              lastErrorCode: 'INTERNAL_RECORDING_CHECKPOINT_WRITE_FAILED',
              failureStage: InternalRecordingFailureStage.persistence,
            ),
          );
          _observe();
        } else {
          _fail(
            'INTERNAL_RECORDING_CHECKPOINT_WRITE_FAILED',
            InternalRecordingFailureStage.persistence,
          );
        }
      }
      return false;
    }
  }

  Future<bool> _releaseMedia(int revision) async {
    final checkpoint = _checkpoint;
    if (checkpoint == null) return true;
    try {
      final result = await _capture.releaseSession(checkpoint.sessionId);
      if (!_owns(revision)) return false;
      if (!result.ok || result.value != true) {
        _fail(
          result.error?.code ?? 'SCREEN_CAPTURE_CLEANUP_FAILED',
          InternalRecordingFailureStage.cleanup,
        );
        return false;
      }
      _audio = null;
      return true;
    } catch (_) {
      if (_owns(revision)) {
        _fail(
          'SCREEN_CAPTURE_CLEANUP_FAILED',
          InternalRecordingFailureStage.cleanup,
        );
      }
      return false;
    }
  }

  void _captureFailed(String code) {
    if (_acceptedMedia != null ||
        (_state.isProcessing &&
            _state.status != InternalRecordingStatus.importingMedia) ||
        _state.status == InternalRecordingStatus.completed) {
      return;
    }
    if (code == 'SCREEN_CAPTURE_CONSENT_CANCELLED') {
      _timer?.cancel();
      _timer = null;
      _checkpoint = _checkpoint?.copyWith(
        stage: InternalRecordingCheckpointStage.cancelled,
      );
      unawaited(_saveCheckpoint(_revision));
      _set(
        _state.copyWith(
          status: InternalRecordingStatus.cancelled,
          clearError: true,
        ),
      );
      return;
    }
    _fail(
      code,
      code.contains('PERMISSION')
          ? InternalRecordingFailureStage.permission
          : InternalRecordingFailureStage.nativeCapture,
    );
  }

  void _observe() {
    if (!_foreground || _disposed) return;
    _timer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(refreshSession()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _timer?.cancel();
      _timer = null;
    } else if (_state.hasNativeSession) {
      _observe();
      unawaited(refreshSession());
    }
  }

  void _uploadChanged() {
    if (!_disposed && _state.transcriptionJobId != null) notifyListeners();
  }

  bool _owns(int revision) => !_disposed && revision == _revision;

  void _fail(String code, InternalRecordingFailureStage stage) {
    _timer?.cancel();
    _timer = null;
    _set(
      _state.copyWith(
        status: InternalRecordingStatus.failed,
        lastErrorCode: RegExp(r'^[A-Z0-9_]{1,100}$').hasMatch(code)
            ? code
            : 'SCREEN_CAPTURE_FAILED',
        failureStage: stage,
      ),
    );
  }

  void _set(InternalRecordingState state) {
    if (_disposed) {
      return;
    }
    if (_state.status != state.status ||
        _state.lastErrorCode != state.lastErrorCode) {
      try {
        _logger?.log(
          DiagnosticLogInput(
            category: DiagnosticCategory.recording,
            severity: state.status == InternalRecordingStatus.failed
                ? DiagnosticSeverity.warning
                : DiagnosticSeverity.info,
            safeSummary: 'Internal screen recording state changed',
            correlationId: state.sessionId,
            metadata: <String, Object?>{
              'stage': state.status.name,
              'session_id': state.sessionId,
              'draft_id': state.transcriptionJobId,
              'recording_id': state.remoteRecordingId,
              if (state.lastErrorCode != null)
                'error_code': state.lastErrorCode,
            },
          ),
        );
      } catch (_) {}
    }
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _timer?.cancel();
    unawaited(_events?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    _uploadController.removeListener(_uploadChanged);
    final sessionId = _checkpoint?.sessionId;
    if (_state.hasNativeSession && sessionId != null) {
      unawaited(_capture.stopCapture(expectedSessionId: sessionId));
    }
    super.dispose();
  }
}

String _fileName(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '内录-${local.year}${two(local.month)}${two(local.day)}-'
      '${two(local.hour)}${two(local.minute)}${two(local.second)}.m4a';
}

String _newSessionId() {
  final random = Random.secure();
  return 'internal-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}
