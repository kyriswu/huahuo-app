import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/di/diagnostics_providers.dart';
import '../../../app/di/database_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../core/native/voice_recorder_port.dart';
import '../../../core/storage/file_storage_port.dart';
import '../data/meeting_capture_session_store.dart';
import '../../recording_card/application/recording_card_controller.dart';
import '../../recordings/application/recording_library_controller.dart';
import '../../recordings/application/recording_upload_controller.dart';
import '../../recordings/data/local_recording_repository.dart';
import '../../recordings/domain/recording_library.dart';
import '../../recordings/application/recording_waveform_controller.dart';

enum MeetingCaptureStatus {
  idle,
  loadingSources,
  checkingPermission,
  starting,
  recording,
  paused,
  stopping,
  registeringLocal,
  downloadingDevice,
  uploading,
  completed,
  failed,
}

enum MeetingCaptureEntryOutcome { ready, restored, unavailable, superseded }

enum MeetingCaptureSource { liveMicrophone, localLibrary, recordingCard }

enum MeetingFailureStage {
  permission,
  nativeStart,
  nativeCapture,
  nativeStop,
  draftValidation,
  localRegistration,
  localSelection,
  deviceDownload,
  upload,
}

final class MeetingCaptureState {
  const MeetingCaptureState({
    required this.status,
    this.source,
    this.elapsedSeconds = 0,
    this.startedAt,
    this.nativeRecordingId,
    this.localItem,
    this.selectedDeviceFile,
    this.remoteRecordingId,
    this.transcriptionJobId,
    this.lastErrorCode,
    this.failureStage,
    this.correlationId,
    this.awaitingMaterialQueue = false,
  });

  factory MeetingCaptureState.initial() =>
      const MeetingCaptureState(status: MeetingCaptureStatus.idle);

  final MeetingCaptureStatus status;
  final MeetingCaptureSource? source;
  final int elapsedSeconds;
  final DateTime? startedAt;
  final String? nativeRecordingId;
  final RecordingLibraryItem? localItem;
  final RecordingCardScannedFile? selectedDeviceFile;
  final String? remoteRecordingId;
  final String? transcriptionJobId;
  final String? lastErrorCode;
  final MeetingFailureStage? failureStage;
  final String? correlationId;
  final bool awaitingMaterialQueue;

  bool get isCaptureActive =>
      status == MeetingCaptureStatus.recording ||
      status == MeetingCaptureStatus.paused;

  bool get projectsActiveMessage =>
      source == MeetingCaptureSource.liveMicrophone &&
      switch (status) {
        MeetingCaptureStatus.checkingPermission ||
        MeetingCaptureStatus.starting ||
        MeetingCaptureStatus.recording ||
        MeetingCaptureStatus.paused ||
        MeetingCaptureStatus.stopping ||
        MeetingCaptureStatus.registeringLocal ||
        MeetingCaptureStatus.uploading ||
        MeetingCaptureStatus.failed => true,
        _ => false,
      };

  bool get isBusy => switch (status) {
    MeetingCaptureStatus.loadingSources ||
    MeetingCaptureStatus.checkingPermission ||
    MeetingCaptureStatus.starting ||
    MeetingCaptureStatus.stopping ||
    MeetingCaptureStatus.registeringLocal ||
    MeetingCaptureStatus.downloadingDevice ||
    MeetingCaptureStatus.uploading => true,
    _ => false,
  };

  bool get canRetry =>
      status == MeetingCaptureStatus.failed &&
      (localItem != null ||
          selectedDeviceFile != null ||
          failureStage == MeetingFailureStage.localRegistration);

  MeetingCaptureState copyWith({
    MeetingCaptureStatus? status,
    MeetingCaptureSource? source,
    int? elapsedSeconds,
    DateTime? startedAt,
    String? nativeRecordingId,
    RecordingLibraryItem? localItem,
    RecordingCardScannedFile? selectedDeviceFile,
    String? remoteRecordingId,
    String? transcriptionJobId,
    String? lastErrorCode,
    MeetingFailureStage? failureStage,
    String? correlationId,
    bool? awaitingMaterialQueue,
    bool clearLocalItem = false,
    bool clearSelectedDeviceFile = false,
    bool clearRemoteRecordingId = false,
    bool clearTranscriptionJobId = false,
    bool clearError = false,
    bool clearFailureStage = false,
  }) {
    return MeetingCaptureState(
      status: status ?? this.status,
      source: source ?? this.source,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      startedAt: startedAt ?? this.startedAt,
      nativeRecordingId: nativeRecordingId ?? this.nativeRecordingId,
      localItem: clearLocalItem ? null : localItem ?? this.localItem,
      selectedDeviceFile: clearSelectedDeviceFile
          ? null
          : selectedDeviceFile ?? this.selectedDeviceFile,
      remoteRecordingId: clearRemoteRecordingId
          ? null
          : remoteRecordingId ?? this.remoteRecordingId,
      transcriptionJobId: clearTranscriptionJobId
          ? null
          : transcriptionJobId ?? this.transcriptionJobId,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
      failureStage: clearFailureStage
          ? null
          : failureStage ?? this.failureStage,
      correlationId: correlationId ?? this.correlationId,
      awaitingMaterialQueue:
          awaitingMaterialQueue ?? this.awaitingMaterialQueue,
    );
  }
}

final class MeetingUploadResult {
  const MeetingUploadResult._({
    required this.ok,
    this.recordingId,
    this.errorCode,
  });

  factory MeetingUploadResult.success(String recordingId) =>
      MeetingUploadResult._(ok: true, recordingId: recordingId);

  factory MeetingUploadResult.failure(String errorCode) =>
      MeetingUploadResult._(ok: false, errorCode: errorCode);

  final bool ok;
  final String? recordingId;
  final String? errorCode;
}

abstract interface class MeetingRecordingUploadPort {
  Future<MeetingUploadResult> upload(RecordingLibraryItem item);
}

abstract interface class MeetingSourceAwareUploadPort {
  Future<MeetingUploadResult> uploadForSource(
    RecordingLibraryItem item,
    RecordingFileSource source,
  );
}

final class RecordingUploadMeetingPort
    implements MeetingRecordingUploadPort, MeetingSourceAwareUploadPort {
  const RecordingUploadMeetingPort(this._controller);

  final RecordingUploadController _controller;

  @override
  Future<MeetingUploadResult> upload(RecordingLibraryItem item) async {
    return uploadForSource(item, RecordingFileSource.meeting);
  }

  @override
  Future<MeetingUploadResult> uploadForSource(
    RecordingLibraryItem item,
    RecordingFileSource source,
  ) async {
    final jobId = recordingFileJobId(item);
    final created = await _controller.uploadLocalRecording(
      item: item,
      sourceScene: 'raw_material',
      fileSource: source,
      title: item.displayName,
    );
    if (created == null) {
      final uploadState = _controller.state;
      return MeetingUploadResult.failure(
        uploadState.failureCodeForJob(jobId) ?? 'MEETING_UPLOAD_FAILED',
      );
    }
    return MeetingUploadResult.success(created.recording.recordingId);
  }
}

abstract interface class MeetingRecordingLibraryPort {
  List<RecordingLibraryItem> get items;
  Future<void> load();
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
}

final class ControllerMeetingRecordingLibraryPort
    implements MeetingRecordingLibraryPort {
  const ControllerMeetingRecordingLibraryPort(this._controller);

  final RecordingLibraryController _controller;

  @override
  List<RecordingLibraryItem> get items => _controller.state.items;

  @override
  Future<void> load() {
    _controller.setView(RecordingLibraryView.library);
    _controller.setSearchText('');
    return _controller.load();
  }

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);
}

abstract interface class MeetingRecordingCardPort {
  bool get isConnected;
  List<RecordingCardScannedFile> get files;
  String? get lastErrorCode;
  Future<void> scanFiles();
  Future<RecordingCardResult<RecordingCardDownloadedFile>> downloadFile(
    RecordingCardScannedFile file,
  );
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
}

final class ControllerMeetingRecordingCardPort
    implements MeetingRecordingCardPort {
  const ControllerMeetingRecordingCardPort(this._controller);

  final RecordingCardController _controller;

  @override
  bool get isConnected =>
      _controller.state.snapshot.deviceState.isOperationallyConnected;

  @override
  List<RecordingCardScannedFile> get files => _controller.state.snapshot.files;

  @override
  String? get lastErrorCode => _controller.state.lastErrorCode;

  @override
  Future<void> scanFiles() => _controller.scanFiles();

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>> downloadFile(
    RecordingCardScannedFile file,
  ) => _controller.downloadFileResult(file);

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);
}

final class MeetingCaptureController extends ChangeNotifier
    with WidgetsBindingObserver {
  MeetingCaptureController({
    required VoiceRecorderPort recorder,
    required LocalRecordingRepository localRecordingRepository,
    required MeetingRecordingLibraryPort recordingLibrary,
    required MeetingRecordingCardPort recordingCard,
    required MeetingRecordingUploadPort uploader,
    DiagnosticLogger? diagnosticLogger,
    String Function()? correlationIdFactory,
    this.sessionStore,
    this.onDistillationJobReady,
  }) : _recorder = recorder,
       _localRecordingRepository = localRecordingRepository,
       _recordingLibrary = recordingLibrary,
       _recordingCard = recordingCard,
       _uploader = uploader,
       _diagnosticLogger = diagnosticLogger,
       _correlationIdFactory = correlationIdFactory {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _foreground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _recordingLibrary.addListener(_sourceChanged);
    _recordingCard.addListener(_sourceChanged);
  }

  final VoiceRecorderPort _recorder;
  final MeetingCaptureSessionStore? sessionStore;
  final Future<bool> Function(String jobId, String title)?
  onDistillationJobReady;
  MeetingCaptureCheckpoint? _checkpoint;
  final LocalRecordingRepository _localRecordingRepository;
  final MeetingRecordingLibraryPort _recordingLibrary;
  final MeetingRecordingCardPort _recordingCard;
  final MeetingRecordingUploadPort _uploader;
  final DiagnosticLogger? _diagnosticLogger;
  final String Function()? _correlationIdFactory;

  MeetingCaptureState _state = MeetingCaptureState.initial();
  Timer? _snapshotTimer;
  late final RecordingWaveformController waveform = RecordingWaveformController(
    recorder: _recorder,
  );
  Future<void>? _snapshotRead;
  Completer<void>? _nativeControlGate;
  Completer<void>? _nativeTerminalGate;
  Completer<void>? _foregroundWaiter;
  bool _initialized = false;
  Future<void>? _sourceInitialization;
  bool _disposed = false;
  bool _foreground = false;
  bool _nativeSessionOwned = false;
  bool _leaveEndRequested = false;
  int _journeyRevision = 0;
  int _captureRevision = 0;
  int _observationRevision = 0;

  MeetingCaptureState get state => _state;

  bool get hasPendingRecovery {
    if (_checkpoint != null) return true;
    try {
      return sessionStore?.read() != null;
    } catch (_) {
      return true;
    }
  }

  bool beginFreshJourney() {
    final canReset = switch (_state.status) {
      MeetingCaptureStatus.idle ||
      MeetingCaptureStatus.loadingSources ||
      MeetingCaptureStatus.completed ||
      MeetingCaptureStatus.failed => true,
      _ => false,
    };
    if (_disposed || !canReset || hasPendingRecovery) return false;
    _journeyRevision += 1;
    _leaveEndRequested = false;
    _set(MeetingCaptureState.initial());
    return true;
  }

  bool get recordingCardConnected => _recordingCard.isConnected;

  List<RecordingLibraryItem> get localRecordings => List.unmodifiable(
    _recordingLibrary.items.where(_isPlayableLocalRecording),
  );

  List<RecordingCardScannedFile> get recordingCardFiles =>
      List.unmodifiable(_recordingCard.files);

  Future<MeetingCaptureEntryOutcome> initialize({
    bool restorePending = true,
    String? recoveryDraftId,
  }) async {
    if (_state.isBusy && _state.status != MeetingCaptureStatus.loadingSources) {
      return MeetingCaptureEntryOutcome.restored;
    }
    if (_state.isCaptureActive) {
      return recoveryDraftId == null
          ? MeetingCaptureEntryOutcome.restored
          : MeetingCaptureEntryOutcome.unavailable;
    }
    final journeyRevision = ++_journeyRevision;
    await _ensureSourcesInitialized();
    if (!_ownsJourney(journeyRevision)) {
      return MeetingCaptureEntryOutcome.superseded;
    }
    if (recoveryDraftId != null) {
      return MeetingCaptureEntryOutcome.unavailable;
    }
    if (restorePending) {
      try {
        _checkpoint ??= sessionStore?.read();
        if (_checkpoint case final saved?) {
          _set(_state.copyWith(correlationId: saved.correlationId));
          final item = saved.localRecordingId == null
              ? null
              : _localRecordingRepository.findById(saved.localRecordingId!);
          if (item != null) {
            await _uploadLocalItem(
              item,
              source: MeetingCaptureSource.liveMicrophone,
              journeyRevision: journeyRevision,
            );
          } else if (saved.draft != null) {
            await _registerCapturedDraft(saved.draft!, journeyRevision);
          } else {
            _fail(
              'MEETING_CAPTURE_INTERRUPTED',
              MeetingFailureStage.nativeCapture,
            );
          }
          return MeetingCaptureEntryOutcome.restored;
        }
      } catch (_) {
        _fail(
          'MEETING_CHECKPOINT_RECOVERY_FAILED',
          MeetingFailureStage.localRegistration,
        );
        return MeetingCaptureEntryOutcome.unavailable;
      }
    }
    if (_state.status == MeetingCaptureStatus.loadingSources) {
      _set(MeetingCaptureState.initial());
    }
    return MeetingCaptureEntryOutcome.ready;
  }

  Future<void> _ensureSourcesInitialized() {
    if (_initialized) return Future<void>.value();
    final existing = _sourceInitialization;
    if (existing != null) return existing;
    late final Future<void> operation;
    operation =
        () async {
          _set(_state.copyWith(status: MeetingCaptureStatus.loadingSources));
          await _recordingLibrary.load();
          if (_disposed) return;
          if (_recordingCard.isConnected) await _recordingCard.scanFiles();
          if (_disposed) return;
          _initialized = true;
        }().whenComplete(() {
          if (identical(_sourceInitialization, operation)) {
            _sourceInitialization = null;
          }
        });
    _sourceInitialization = operation;
    return operation;
  }

  Future<void> refreshSources() async {
    if (_state.isBusy || _state.isCaptureActive) return;
    _set(_state.copyWith(status: MeetingCaptureStatus.loadingSources));
    await _recordingLibrary.load();
    if (_recordingCard.isConnected) await _recordingCard.scanFiles();
    if (_state.status == MeetingCaptureStatus.loadingSources) {
      _set(_state.copyWith(status: MeetingCaptureStatus.idle));
    }
  }

  Future<bool> startLiveRecording({bool distillToDigitalTwin = false}) async {
    if (_disposed || _state.isBusy || _state.isCaptureActive) return false;
    _leaveEndRequested = false;
    final journeyRevision = _journeyRevision;
    final correlationId = _newCorrelationId();
    _set(
      MeetingCaptureState(
        status: MeetingCaptureStatus.checkingPermission,
        source: MeetingCaptureSource.liveMicrophone,
        correlationId: correlationId,
      ),
    );
    var permission = await _recorder.getMicrophonePermission();
    if (_disposed || !_ownsJourney(journeyRevision)) return false;
    if (_consumeLeaveEndRequest()) return true;
    if (!permission.ok || permission.value == null) {
      _fail(
        permission.error?.code ?? 'VOICE_RECORDER_PERMISSION_UNAVAILABLE',
        MeetingFailureStage.permission,
      );
      return false;
    }
    if (!permission.value!.granted && permission.value!.canAskAgain) {
      permission = await _recorder.requestMicrophonePermission();
      if (_disposed || !_ownsJourney(journeyRevision)) return false;
      if (_consumeLeaveEndRequest()) return true;
    }
    if (!permission.ok ||
        permission.value == null ||
        !permission.value!.granted) {
      _fail(
        permission.error?.code ?? _permissionFailureCode(permission.value),
        MeetingFailureStage.permission,
      );
      return false;
    }
    if (_consumeLeaveEndRequest()) return true;
    _set(
      _state.copyWith(
        status: MeetingCaptureStatus.starting,
        clearError: true,
        clearFailureStage: true,
      ),
    );
    if (_checkpoint?.draft != null || _checkpoint?.localRecordingId != null) {
      _fail('MEETING_RECOVERY_REQUIRED', MeetingFailureStage.localRegistration);
      return false;
    }
    _checkpoint = MeetingCaptureCheckpoint(
      correlationId: _state.correlationId ?? _newCorrelationId(),
      distillToDigitalTwin: distillToDigitalTwin,
    );
    if (!await _saveCheckpoint()) return false;
    if (_consumeLeaveEndRequest()) return true;
    while (!_foreground && !_disposed && _ownsJourney(journeyRevision)) {
      await _waitForForeground();
      if (_consumeLeaveEndRequest()) return true;
    }
    if (_disposed || !_ownsJourney(journeyRevision)) return false;
    if (_consumeLeaveEndRequest()) return true;
    final started = await _recorder.startRecording(
      scene: VoiceRecordingScene.meeting,
    );
    if (_disposed || !_ownsJourney(journeyRevision)) {
      if (started.ok && started.value != null) {
        await _cancelStartedMeetingSession(started.value!);
      }
      return false;
    }
    if (_leaveEndRequested) {
      _leaveEndRequested = false;
      if (started.ok && started.value != null) {
        await _cancelStartedMeetingSession(started.value!);
      }
      if (!_disposed) _set(MeetingCaptureState.initial());
      return true;
    }
    if (!started.ok || started.value == null) {
      _fail(
        started.error?.code ?? 'VOICE_RECORDER_START_FAILED',
        MeetingFailureStage.nativeStart,
      );
      return false;
    }
    final session = started.value!;
    final nativeRecordingId = session.recordingId.trim();
    if (session.scene != VoiceRecordingScene.meeting ||
        session.state != VoiceRecorderState.recording ||
        nativeRecordingId.isEmpty) {
      await _cancelStartedMeetingSession(session);
      _fail(voiceRecorderSessionMismatchCode, MeetingFailureStage.nativeStart);
      return false;
    }
    _nativeSessionOwned = true;
    _set(
      _state.copyWith(
        status: MeetingCaptureStatus.recording,
        elapsedSeconds: session.elapsedSeconds,
        startedAt: session.startedAt,
        nativeRecordingId: nativeRecordingId,
        clearError: true,
        clearFailureStage: true,
      ),
    );
    _startLevelSubscription();
    _startSnapshotTimer();
    return true;
  }

  Future<bool> pause() async {
    if (_disposed ||
        _state.status != MeetingCaptureStatus.recording ||
        _nativeControlGate != null ||
        _nativeTerminalGate != null) {
      return false;
    }
    final gate = _beginNativeControl();
    try {
      final nativeRecordingId = _ownedNativeRecordingId;
      if (nativeRecordingId == null) {
        _fail(
          voiceRecorderSessionMismatchCode,
          MeetingFailureStage.nativeCapture,
        );
        return false;
      }
      final revision = ++_captureRevision;
      final result = await _recorder.pauseOwnedRecording(
        expectedScene: VoiceRecordingScene.meeting,
        expectedRecordingId: nativeRecordingId,
      );
      if (_disposed ||
          revision != _captureRevision ||
          !_state.isCaptureActive) {
        return false;
      }
      if (!result.ok || result.value == null) {
        _retainCaptureAfterControlFailure(
          result.error?.code ?? 'VOICE_RECORDER_PAUSE_FAILED',
          confirmedStatus: MeetingCaptureStatus.recording,
          stage: MeetingFailureStage.nativeCapture,
        );
        return false;
      }
      _applyRecorderSnapshot(result.value!);
      return _state.status == MeetingCaptureStatus.paused;
    } finally {
      _endNativeControl(gate);
    }
  }

  Future<bool> resume() async {
    if (_disposed ||
        _state.status != MeetingCaptureStatus.paused ||
        _nativeControlGate != null ||
        _nativeTerminalGate != null) {
      return false;
    }
    final gate = _beginNativeControl();
    try {
      final nativeRecordingId = _ownedNativeRecordingId;
      if (nativeRecordingId == null) {
        _fail(
          voiceRecorderSessionMismatchCode,
          MeetingFailureStage.nativeCapture,
        );
        return false;
      }
      final revision = ++_captureRevision;
      final result = await _recorder.resumeOwnedRecording(
        expectedScene: VoiceRecordingScene.meeting,
        expectedRecordingId: nativeRecordingId,
      );
      if (_disposed ||
          revision != _captureRevision ||
          !_state.isCaptureActive) {
        return false;
      }
      if (!result.ok || result.value == null) {
        _retainCaptureAfterControlFailure(
          result.error?.code ?? 'VOICE_RECORDER_RESUME_FAILED',
          confirmedStatus: MeetingCaptureStatus.paused,
          stage: MeetingFailureStage.nativeCapture,
        );
        return false;
      }
      _applyRecorderSnapshot(result.value!);
      return _state.status == MeetingCaptureStatus.recording;
    } finally {
      _endNativeControl(gate);
    }
  }

  Future<bool> stop() {
    if (_disposed || !_state.isCaptureActive || _nativeTerminalGate != null) {
      return Future<bool>.value(false);
    }
    final nativeRecordingId = _ownedNativeRecordingId;
    if (nativeRecordingId == null) {
      _fail(voiceRecorderSessionMismatchCode, MeetingFailureStage.nativeStop);
      return Future<bool>.value(false);
    }
    final terminalGate = _beginNativeTerminal();
    final previousControl = _nativeControlGate;
    final confirmedStatus = _state.status;
    final journeyRevision = _journeyRevision;
    _captureRevision++;
    _stopSnapshotTimer();
    _set(
      _state.copyWith(status: MeetingCaptureStatus.stopping, clearError: true),
    );
    return _stopAccepted(
      terminalGate: terminalGate,
      previousControl: previousControl,
      confirmedStatus: confirmedStatus,
      nativeRecordingId: nativeRecordingId,
      journeyRevision: journeyRevision,
    );
  }

  Future<bool> _stopAccepted({
    required Completer<void> terminalGate,
    required Completer<void>? previousControl,
    required MeetingCaptureStatus confirmedStatus,
    required String nativeRecordingId,
    required int journeyRevision,
  }) async {
    try {
      if (previousControl != null) await previousControl.future;
      if (!_nativeSessionOwned) return false;
      final gate = _beginNativeControl();
      late final VoiceRecorderResult<VoiceRecordingDraft> stopped;
      try {
        await _stopLevelSubscription();
        stopped = await _recorder.stopOwnedRecording(
          expectedScene: VoiceRecordingScene.meeting,
          expectedRecordingId: nativeRecordingId,
        );
        if (stopped.ok && stopped.value != null) _nativeSessionOwned = false;
      } finally {
        _endNativeControl(gate);
      }
      if (!stopped.ok || stopped.value == null) {
        final code = stopped.error?.code ?? 'VOICE_RECORDER_STOP_FAILED';
        if (_ownsJourney(journeyRevision)) {
          _retainCaptureAfterControlFailure(
            code,
            confirmedStatus: confirmedStatus,
            stage: _isDraftValidationFailure(code)
                ? MeetingFailureStage.draftValidation
                : MeetingFailureStage.nativeStop,
            reconcile: true,
          );
        }
        return false;
      }
      final draft = stopped.value!;
      if (draft.recordingId != nativeRecordingId ||
          (draft.scene != null && draft.scene != VoiceRecordingScene.meeting)) {
        if (_ownsJourney(journeyRevision)) {
          _fail(
            voiceRecorderSessionMismatchCode,
            MeetingFailureStage.draftValidation,
          );
        }
        return false;
      }
      _checkpoint =
          (_checkpoint ??
                  MeetingCaptureCheckpoint(
                    correlationId: _state.correlationId ?? _newCorrelationId(),
                    distillToDigitalTwin: false,
                  ))
              .copyWith(draft: draft);
      if (!await _saveCheckpoint()) return false;
      return _registerCapturedDraft(draft, journeyRevision);
    } finally {
      _endNativeTerminal(terminalGate);
    }
  }

  Future<bool> cancel() {
    if (_disposed || !_state.isCaptureActive || _nativeTerminalGate != null) {
      return Future<bool>.value(false);
    }
    final nativeRecordingId = _ownedNativeRecordingId;
    if (nativeRecordingId == null) {
      _fail(
        voiceRecorderSessionMismatchCode,
        MeetingFailureStage.nativeCapture,
      );
      return Future<bool>.value(false);
    }
    final terminalGate = _beginNativeTerminal();
    final previousControl = _nativeControlGate;
    final confirmedStatus = _state.status;
    _captureRevision++;
    _stopSnapshotTimer();
    _set(_state.copyWith(status: MeetingCaptureStatus.stopping));
    return _cancelAccepted(
      terminalGate: terminalGate,
      previousControl: previousControl,
      confirmedStatus: confirmedStatus,
      nativeRecordingId: nativeRecordingId,
    );
  }

  Future<bool> _cancelAccepted({
    required Completer<void> terminalGate,
    required Completer<void>? previousControl,
    required MeetingCaptureStatus confirmedStatus,
    required String nativeRecordingId,
  }) async {
    try {
      if (previousControl != null) await previousControl.future;
      if (!_nativeSessionOwned) return false;
      final gate = _beginNativeControl();
      late final VoiceRecorderResult<VoiceRecorderSnapshot> result;
      try {
        await _stopLevelSubscription();
        result = await _recorder.cancelOwnedRecording(
          expectedScene: VoiceRecordingScene.meeting,
          expectedRecordingId: nativeRecordingId,
        );
        if (result.ok && result.value != null) _nativeSessionOwned = false;
      } finally {
        _endNativeControl(gate);
      }
      if (!result.ok || result.value == null) {
        _retainCaptureAfterControlFailure(
          result.error?.code ?? 'VOICE_RECORDER_CANCEL_FAILED',
          confirmedStatus: confirmedStatus,
          stage: MeetingFailureStage.nativeCapture,
          reconcile: true,
        );
        return false;
      }
      try {
        await sessionStore?.clear();
      } catch (_) {
        _log(
          'meeting_checkpoint_clear_failed',
          errorCode: 'MEETING_CHECKPOINT_CLEAR_FAILED',
        );
      }
      _checkpoint = null;
      _set(MeetingCaptureState.initial());
      return true;
    } finally {
      _endNativeTerminal(terminalGate);
    }
  }

  Future<bool> _registerCapturedDraft(
    VoiceRecordingDraft draft,
    int journeyRevision,
  ) async {
    if (_ownsJourney(journeyRevision)) {
      _set(
        _state.copyWith(
          status: MeetingCaptureStatus.registeringLocal,
          elapsedSeconds: draft.durationSeconds,
        ),
      );
    }
    final registered = await _localRecordingRepository
        .registerNativeVoiceRecording(
          file: PrivateAudioFile(
            fileId: draft.recordingId,
            appPrivateUri: draft.appPrivateUri,
            displayName: _meetingFileName(
              draft.recordedAt ?? DateTime.now(),
              mimeType: draft.mimeType,
            ),
            mimeType: draft.mimeType,
            sizeBytes: draft.sizeBytes,
            durationSeconds: draft.durationSeconds,
            contentHash: draft.sha256,
            recordedAt: draft.recordedAt,
          ),
          recordedAt: draft.recordedAt,
          tagIds: const <String>[externalRecordingHistoryTagId],
        );
    if (!registered.ok || registered.value == null) {
      if (_ownsJourney(journeyRevision)) {
        _fail(
          registered.error?.code ?? 'MEETING_LOCAL_REGISTER_FAILED',
          MeetingFailureStage.localRegistration,
        );
      }
      return false;
    }
    await _recordingLibrary.load();
    return _uploadLocalItem(
      registered.value!,
      source: MeetingCaptureSource.liveMicrophone,
      journeyRevision: journeyRevision,
    );
  }

  /// Starts an explicit user-approved end without blocking route exit on
  /// registration, upload, or transcription tracking.
  Future<bool> endCaptureForLeave() {
    if (_disposed) return Future<bool>.value(false);
    switch (_state.status) {
      case MeetingCaptureStatus.checkingPermission:
      case MeetingCaptureStatus.starting:
        _leaveEndRequested = true;
        return Future<bool>.value(true);
      case MeetingCaptureStatus.recording:
      case MeetingCaptureStatus.paused:
        unawaited(stop());
        return Future<bool>.value(true);
      case MeetingCaptureStatus.stopping:
        return Future<bool>.value(true);
      case MeetingCaptureStatus.idle:
      case MeetingCaptureStatus.loadingSources:
      case MeetingCaptureStatus.registeringLocal:
      case MeetingCaptureStatus.downloadingDevice:
      case MeetingCaptureStatus.uploading:
      case MeetingCaptureStatus.completed:
      case MeetingCaptureStatus.failed:
        return Future<bool>.value(false);
    }
  }

  bool _consumeLeaveEndRequest() {
    if (!_leaveEndRequested) return false;
    _leaveEndRequested = false;
    _set(MeetingCaptureState.initial());
    return true;
  }

  Future<bool> selectLocalRecording(RecordingLibraryItem item) async {
    if (_state.isBusy || _state.isCaptureActive) return false;
    if (hasPendingRecovery) return false;
    if (!_isPlayableLocalRecording(item)) {
      _set(
        MeetingCaptureState(
          status: MeetingCaptureStatus.failed,
          source: MeetingCaptureSource.localLibrary,
          localItem: item,
          lastErrorCode: 'MEETING_LOCAL_RECORDING_UNAVAILABLE',
          failureStage: MeetingFailureStage.localSelection,
          correlationId: _newCorrelationId(),
        ),
      );
      return false;
    }
    return _uploadLocalItem(item, source: MeetingCaptureSource.localLibrary);
  }

  Future<bool> selectRecordingCardFile(RecordingCardScannedFile file) async {
    if (_state.isBusy || _state.isCaptureActive) return false;
    if (hasPendingRecovery) return false;
    final journeyRevision = _journeyRevision;
    final correlationId = _newCorrelationId();
    _set(
      MeetingCaptureState(
        status: MeetingCaptureStatus.downloadingDevice,
        source: MeetingCaptureSource.recordingCard,
        selectedDeviceFile: file,
        correlationId: correlationId,
      ),
    );
    if (!_recordingCard.isConnected) {
      _fail(
        'MEETING_RECORDING_CARD_NOT_CONNECTED',
        MeetingFailureStage.deviceDownload,
      );
      return false;
    }

    var localFileId = file.syncState == RecordingCardFileSyncState.synced
        ? file.localFileId
        : null;
    if (localFileId == null) {
      final result = await _recordingCard.downloadFile(file);
      final downloaded = result.value;
      if (!result.ok ||
          downloaded == null ||
          downloaded.localFileKey != file.localFileKey) {
        if (_ownsJourney(journeyRevision)) {
          _fail(
            result.error?.code ??
                _recordingCard.lastErrorCode ??
                'MEETING_DEVICE_DOWNLOAD_FAILED',
            MeetingFailureStage.deviceDownload,
          );
        }
        return false;
      }
      localFileId = downloaded.localFileId;
    }
    if (localFileId == null) {
      if (_ownsJourney(journeyRevision)) {
        _fail(
          'MEETING_DEVICE_LOCAL_MAPPING_MISSING',
          MeetingFailureStage.deviceDownload,
        );
      }
      return false;
    }

    await _recordingLibrary.load();
    final localItem = _findLocalRecording(localFileId);
    if (localItem == null || !_isPlayableLocalRecording(localItem)) {
      if (_ownsJourney(journeyRevision)) {
        _fail(
          'MEETING_DEVICE_LOCAL_RECORDING_UNAVAILABLE',
          MeetingFailureStage.deviceDownload,
        );
      }
      return false;
    }
    return _uploadLocalItem(
      localItem,
      source: MeetingCaptureSource.recordingCard,
      deviceFile: file,
      journeyRevision: journeyRevision,
    );
  }

  Future<bool> retry() async {
    if (_state.status != MeetingCaptureStatus.failed || _state.isBusy) {
      return false;
    }
    final item = _state.localItem;
    if (item != null && _isPlayableLocalRecording(item)) {
      return _uploadLocalItem(
        item,
        source: _state.source ?? MeetingCaptureSource.localLibrary,
        deviceFile: _state.selectedDeviceFile,
        keepCorrelationId: true,
      );
    }
    final deviceFile = _state.selectedDeviceFile;
    if (deviceFile != null) return selectRecordingCardFile(deviceFile);
    if (_checkpoint?.draft case final draft?) {
      if (!await _saveCheckpoint()) return false;
      return _registerCapturedDraft(draft, _journeyRevision);
    }
    return false;
  }

  Future<bool> _saveCheckpoint() async {
    try {
      if (_checkpoint != null) await sessionStore?.save(_checkpoint!);
      return true;
    } catch (_) {
      if (!_disposed)
        _fail(
          'MEETING_CHECKPOINT_SAVE_FAILED',
          MeetingFailureStage.localRegistration,
        );
      return false;
    }
  }

  Future<bool> _uploadLocalItem(
    RecordingLibraryItem item, {
    required MeetingCaptureSource source,
    RecordingCardScannedFile? deviceFile,
    bool keepCorrelationId = false,
    int? journeyRevision,
  }) async {
    final operationRevision = journeyRevision ?? _journeyRevision;
    if (_disposed) return false;
    if (!_isPlayableLocalRecording(item)) {
      if (_ownsJourney(operationRevision)) {
        _fail(
          'MEETING_LOCAL_RECORDING_UNAVAILABLE',
          MeetingFailureStage.localSelection,
        );
      }
      return false;
    }
    if (_ownsJourney(operationRevision)) {
      final transcriptionJobId = recordingFileJobId(item);
      _set(
        MeetingCaptureState(
          status: MeetingCaptureStatus.uploading,
          source: source,
          elapsedSeconds: source == MeetingCaptureSource.liveMicrophone
              ? _state.elapsedSeconds
              : item.durationSeconds,
          startedAt: source == MeetingCaptureSource.liveMicrophone
              ? _state.startedAt
              : item.createdAt,
          nativeRecordingId: source == MeetingCaptureSource.liveMicrophone
              ? _state.nativeRecordingId
              : null,
          localItem: item,
          transcriptionJobId: transcriptionJobId,
          awaitingMaterialQueue: _checkpoint?.distillToDigitalTwin == true,
          selectedDeviceFile: deviceFile ?? _state.selectedDeviceFile,
          correlationId: keepCorrelationId
              ? _state.correlationId ?? _newCorrelationId()
              : _state.correlationId ?? _newCorrelationId(),
        ),
      );
    }
    _log('meeting_upload_started');
    if (_checkpoint != null) {
      _checkpoint = _checkpoint!.copyWith(localRecordingId: item.recordingId);
      if (!await _saveCheckpoint()) return false;
      if (_disposed) return false;
      if (_checkpoint!.distillToDigitalTwin) {
        try {
          if (await onDistillationJobReady?.call(
                recordingFileJobId(item),
                '外录转写材料',
              ) !=
              true) {
            throw StateError('DIGITAL_TWIN_QUEUE_SAVE_FAILED');
          }
        } catch (_) {
          if (!_disposed)
            _fail('DIGITAL_TWIN_QUEUE_SAVE_FAILED', MeetingFailureStage.upload);
          return false;
        }
      }
    }
    if (_disposed) return false;
    final fileSource = switch (source) {
      MeetingCaptureSource.liveMicrophone => RecordingFileSource.meeting,
      MeetingCaptureSource.localLibrary => RecordingFileSource.localLibrary,
      MeetingCaptureSource.recordingCard => RecordingFileSource.recordingCard,
    };
    if (_ownsJourney(operationRevision) && _state.awaitingMaterialQueue) {
      _set(_state.copyWith(awaitingMaterialQueue: false));
    }
    final uploader = _uploader;
    final MeetingUploadResult uploaded;
    if (uploader is MeetingSourceAwareUploadPort) {
      uploaded = await (uploader as MeetingSourceAwareUploadPort)
          .uploadForSource(item, fileSource);
    } else {
      uploaded = await uploader.upload(item);
    }
    if (!uploaded.ok || uploaded.recordingId == null) {
      if (_ownsJourney(operationRevision)) {
        _fail(
          uploaded.errorCode ?? 'MEETING_UPLOAD_FAILED',
          MeetingFailureStage.upload,
        );
      }
      return false;
    }
    final recordingId = uploaded.recordingId!;
    try {
      await sessionStore?.clear();
      _checkpoint = null;
    } catch (_) {
      if (!_disposed)
        _fail('MEETING_CHECKPOINT_SAVE_FAILED', MeetingFailureStage.upload);
      return false;
    }
    if (!_ownsJourney(operationRevision)) return true;
    _set(
      _state.copyWith(
        status: MeetingCaptureStatus.completed,
        remoteRecordingId: recordingId,
        clearError: true,
        clearFailureStage: true,
      ),
    );
    return true;
  }

  bool _ownsJourney(int revision) => !_disposed && revision == _journeyRevision;

  RecordingLibraryItem? _findLocalRecording(String recordingId) {
    for (final item in _recordingLibrary.items) {
      if (item.recordingId == recordingId) return item;
    }
    return null;
  }

  void _sourceChanged() {
    if (!_disposed) notifyListeners();
  }

  String? get _ownedNativeRecordingId {
    final recordingId = _state.nativeRecordingId?.trim();
    return recordingId?.isNotEmpty == true ? recordingId : null;
  }

  Future<void> _cancelStartedMeetingSession(
    VoiceRecordingSession session,
  ) async {
    final recordingId = session.recordingId.trim();
    if (session.scene != VoiceRecordingScene.meeting || recordingId.isEmpty) {
      return;
    }
    await _recorder.cancelOwnedRecording(
      expectedScene: VoiceRecordingScene.meeting,
      expectedRecordingId: recordingId,
    );
  }

  Future<void> _waitForForeground() {
    if (_foreground || _disposed) return Future<void>.value();
    return (_foregroundWaiter ??= Completer<void>()).future;
  }

  void _releaseForegroundWaiter() {
    final waiter = _foregroundWaiter;
    _foregroundWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      _stopSnapshotTimer();
      unawaited(_stopLevelSubscription());
      return;
    }
    _releaseForegroundWaiter();
    final observationRevision = ++_observationRevision;
    if (_state.isCaptureActive) {
      unawaited(_resumeRecorderObservation(observationRevision));
    }
  }

  Future<void> _resumeRecorderObservation(int observationRevision) async {
    await _refreshRecorderState(observationRevision, waitForCurrent: true);
    if (!_ownsObservation(observationRevision)) return;
    if (_state.status == MeetingCaptureStatus.recording) {
      _startLevelSubscription();
    }
    _startSnapshotTimer(observationRevision: observationRevision);
  }

  void _startSnapshotTimer({int? observationRevision}) {
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    if (!_foreground || !_state.isCaptureActive) return;
    final revision = observationRevision ?? _observationRevision;
    if (!_ownsObservation(revision)) return;
    _snapshotTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_ownsObservation(revision)) {
        unawaited(_refreshRecorderState(revision));
      }
    });
  }

  Future<void> _refreshRecorderState(
    int observationRevision, {
    bool waitForCurrent = false,
  }) async {
    while (_snapshotRead != null) {
      if (!waitForCurrent) return;
      await _snapshotRead;
      if (!_ownsObservation(observationRevision)) return;
    }
    if (!_ownsObservation(observationRevision)) return;
    final captureRevision = _captureRevision;
    late final Future<void> read;
    read =
        _readRecorderState(
          observationRevision: observationRevision,
          captureRevision: captureRevision,
        ).whenComplete(() {
          if (identical(_snapshotRead, read)) _snapshotRead = null;
        });
    _snapshotRead = read;
    await read;
  }

  Future<void> _readRecorderState({
    required int observationRevision,
    required int captureRevision,
  }) async {
    try {
      final refreshed = await _recorder.refreshState();
      if (!_ownsObservation(observationRevision) ||
          captureRevision != _captureRevision) {
        return;
      }
      if (!refreshed.ok || refreshed.value == null) {
        _set(
          _state.copyWith(
            lastErrorCode:
                refreshed.error?.code ?? 'VOICE_RECORDER_STATE_REFRESH_FAILED',
          ),
        );
        return;
      }
      _applyRecorderSnapshot(refreshed.value!);
    } catch (_) {
      if (_ownsObservation(observationRevision) &&
          captureRevision == _captureRevision) {
        _set(
          _state.copyWith(lastErrorCode: 'VOICE_RECORDER_STATE_REFRESH_FAILED'),
        );
      }
    }
  }

  bool _ownsObservation(int revision) =>
      !_disposed &&
      _foreground &&
      revision == _observationRevision &&
      _state.isCaptureActive;

  void _stopSnapshotTimer() {
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _observationRevision++;
  }

  void _applyRecorderSnapshot(VoiceRecorderSnapshot snapshot) {
    if (snapshot.state == VoiceRecorderState.idle) {
      _nativeSessionOwned = false;
      _fail('MEETING_CAPTURE_INTERRUPTED', MeetingFailureStage.nativeCapture);
      return;
    }
    final session = snapshot.session;
    final nativeRecordingId = _ownedNativeRecordingId;
    if (snapshot.state == VoiceRecorderState.failed) {
      _nativeSessionOwned = false;
      if (session != null &&
          (session.scene != VoiceRecordingScene.meeting ||
              session.recordingId != nativeRecordingId)) {
        _fail(
          voiceRecorderSessionMismatchCode,
          MeetingFailureStage.nativeCapture,
        );
      } else {
        _fail(
          snapshot.lastErrorCode ?? 'VOICE_RECORDER_CAPTURE_FAILED',
          MeetingFailureStage.nativeCapture,
        );
      }
      return;
    }
    if (nativeRecordingId == null ||
        session == null ||
        session.scene != VoiceRecordingScene.meeting ||
        session.recordingId != nativeRecordingId ||
        session.state != snapshot.state) {
      _nativeSessionOwned = false;
      _fail(
        voiceRecorderSessionMismatchCode,
        MeetingFailureStage.nativeCapture,
      );
      return;
    }
    _nativeSessionOwned = true;
    final status = snapshot.state == VoiceRecorderState.recording
        ? MeetingCaptureStatus.recording
        : MeetingCaptureStatus.paused;
    if (status != _state.status) {
      if (status == MeetingCaptureStatus.recording) {
        _startLevelSubscription();
      } else {
        unawaited(_stopLevelSubscription());
      }
    }
    _set(
      _state.copyWith(
        status: status,
        elapsedSeconds: session.elapsedSeconds,
        startedAt: session.startedAt,
        lastErrorCode: snapshot.lastErrorCode,
        clearError: snapshot.lastErrorCode == null,
        failureStage: snapshot.lastErrorCode == null
            ? null
            : MeetingFailureStage.nativeCapture,
        clearFailureStage: snapshot.lastErrorCode == null,
      ),
    );
  }

  void _startLevelSubscription() {
    if (_foreground) waveform.start();
  }

  Future<void> _stopLevelSubscription() => waveform.stop();

  bool _isDraftValidationFailure(String code) =>
      code == 'NATIVE_VOICE_RECORDER_MALFORMED_PAYLOAD' ||
      code == 'VOICE_RECORDER_EMPTY_FILE' ||
      code == 'VOICE_RECORDER_FILE_UNAVAILABLE' ||
      code == 'VOICE_RECORDER_INVALID_CHECKSUM';

  String _permissionFailureCode(
    VoiceRecorderPermission? permission,
  ) => switch (permission?.state) {
    VoiceRecorderPermissionState.blocked => 'VOICE_RECORDER_PERMISSION_BLOCKED',
    VoiceRecorderPermissionState.denied => 'VOICE_RECORDER_PERMISSION_DENIED',
    VoiceRecorderPermissionState.unavailable =>
      'VOICE_RECORDER_PERMISSION_UNAVAILABLE',
    _ => 'VOICE_RECORDER_PERMISSION_NOT_GRANTED',
  };

  void _retainCaptureAfterControlFailure(
    String code, {
    required MeetingCaptureStatus confirmedStatus,
    required MeetingFailureStage stage,
    bool reconcile = false,
  }) {
    final safeCode = _safeOperationFailureCode(code);
    _log('meeting_${stage.name}_failed', errorCode: safeCode);
    _set(
      _state.copyWith(
        status: confirmedStatus,
        lastErrorCode: safeCode,
        failureStage: stage,
      ),
    );
    if (reconcile && _foreground && !_disposed) {
      final observationRevision = ++_observationRevision;
      unawaited(_resumeRecorderObservation(observationRevision));
    }
  }

  void _fail(String code, MeetingFailureStage stage) {
    final safeCode = _safeOperationFailureCode(code);
    _stopSnapshotTimer();
    unawaited(_stopLevelSubscription());
    _log('meeting_${stage.name}_failed', errorCode: safeCode);
    _set(
      _state.copyWith(
        status: MeetingCaptureStatus.failed,

        lastErrorCode: safeCode,
        failureStage: stage,
      ),
    );
  }

  String _safeOperationFailureCode(String code) =>
      RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(code)
      ? code
      : 'MEETING_OPERATION_FAILED';

  Completer<void> _beginNativeControl() {
    assert(_nativeControlGate == null);
    final gate = Completer<void>();
    _nativeControlGate = gate;
    return gate;
  }

  void _endNativeControl(Completer<void> gate) {
    if (identical(_nativeControlGate, gate)) _nativeControlGate = null;
    if (!gate.isCompleted) gate.complete();
  }

  Completer<void> _beginNativeTerminal() {
    assert(_nativeTerminalGate == null);
    final gate = Completer<void>();
    _nativeTerminalGate = gate;
    return gate;
  }

  void _endNativeTerminal(Completer<void> gate) {
    if (identical(_nativeTerminalGate, gate)) _nativeTerminalGate = null;
    if (!gate.isCompleted) gate.complete();
  }

  Future<void> _cancelOwnedNativeSessionAfterControls(
    String nativeRecordingId,
  ) async {
    final terminalGate = _nativeTerminalGate;
    if (terminalGate != null) {
      await terminalGate.future;
    } else {
      final controlGate = _nativeControlGate;
      if (controlGate != null) await controlGate.future;
    }
    if (!_nativeSessionOwned) return;
    try {
      final cancelled = await _recorder.cancelOwnedRecording(
        expectedScene: VoiceRecordingScene.meeting,
        expectedRecordingId: nativeRecordingId,
      );
      if (cancelled.ok && cancelled.value != null) {
        _nativeSessionOwned = false;
      }
    } catch (_) {
      // Disposal has no UI owner; the exact-session cancel is best effort.
    }
  }

  String _newCorrelationId() {
    final explicit = _correlationIdFactory?.call();
    final raw = explicit?.isNotEmpty == true
        ? explicit!
        : _diagnosticLogger?.createCorrelationId('meeting') ??
              'meeting-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9_:-]'), '');
    if (safe.isEmpty) return 'meeting';
    return safe.length <= 80 ? safe : safe.substring(0, 80);
  }

  void _log(String summary, {String? errorCode}) {
    final logger = _diagnosticLogger;
    final correlationId = _state.correlationId;
    if (logger == null || correlationId == null) return;
    logger.log(
      DiagnosticLogInput(
        category: DiagnosticCategory.upload,
        severity: errorCode == null
            ? DiagnosticSeverity.info
            : DiagnosticSeverity.error,
        safeSummary: summary,
        correlationId: correlationId,
        metadata: <String, Object?>{
          if (errorCode != null) 'errorCode': errorCode,
        },
      ),
    );
  }

  void _set(MeetingCaptureState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _releaseForegroundWaiter();
    _stopSnapshotTimer();
    waveform.dispose();
    _recordingLibrary.removeListener(_sourceChanged);
    _recordingCard.removeListener(_sourceChanged);
    final nativeRecordingId = _ownedNativeRecordingId;
    if (_nativeSessionOwned && nativeRecordingId != null) {
      unawaited(_cancelOwnedNativeSessionAfterControls(nativeRecordingId));
    }
    super.dispose();
  }
}

bool _isPlayableLocalRecording(RecordingLibraryItem item) =>
    item.status != RecordingLibraryStatus.recycled &&
    item.status != RecordingLibraryStatus.deviceOnly &&
    item.status != RecordingLibraryStatus.downloading &&
    item.localFileState == RecordingLocalFileState.ready &&
    item.appPrivateUri != null &&
    item.sizeBytes > 0 &&
    item.durationSeconds > 0;

String _meetingFileName(DateTime at, {required String mimeType}) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final extension = mimeType.toLowerCase() == 'audio/wav' ? 'wav' : 'm4a';
  return '外录-${local.year}${two(local.month)}${two(local.day)}-'
      '${two(local.hour)}${two(local.minute)}${two(local.second)}.$extension';
}

final meetingCaptureControllerProvider =
    ChangeNotifierProvider.autoDispose<MeetingCaptureController>((ref) {
      ref.keepAlive();
      final materials = ref.watch(
        digitalTwinMaterialControllerProvider.notifier,
      );
      final recordingLibrary = ref.watch(
        recordingLibraryControllerProvider.notifier,
      );
      final recordingCard = ref.watch(recordingCardControllerProvider.notifier);
      final uploadController = ref.watch(
        recordingUploadControllerProvider.notifier,
      );
      return MeetingCaptureController(
        sessionStore: MeetingCaptureSessionStore(
          database: ref.watch(appDatabaseProvider),
          scope:
              ref.watch(authenticatedRecordingUserScopeProvider) ??
              'signed-out',
        ),
        onDistillationJobReady: (jobId, title) => materials.enqueue(
          referenceKind: 'recording_job',
          referenceId: jobId,
          title: title,
        ),
        recorder: ref.watch(voiceRecorderPortProvider),
        localRecordingRepository: ref.watch(localRecordingRepositoryProvider),
        recordingLibrary: ControllerMeetingRecordingLibraryPort(
          recordingLibrary,
        ),
        recordingCard: ControllerMeetingRecordingCardPort(recordingCard),
        uploader: RecordingUploadMeetingPort(uploadController),
        diagnosticLogger: ref.watch(diagnosticLoggerProvider),
      );
    });
