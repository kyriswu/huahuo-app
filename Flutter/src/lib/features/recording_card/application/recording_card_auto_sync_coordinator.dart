import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/native/recording_card_native_port.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../recordings/application/recording_processing_tracker.dart';
import '../../recordings/application/recording_upload_controller.dart';
import '../../recordings/data/local_recording_repository.dart';
import '../../recordings/domain/recording_library.dart';
import '../data/recording_card_auto_sync_store.dart';
import '../data/recording_card_sync_ledger_store.dart';
import '../domain/recording_card_account_binding.dart';
import '../domain/recording_card_auto_sync.dart';
import '../domain/recording_card_sync_ledger.dart';
import 'recording_card_controller.dart';
import 'recording_card_sync_planner.dart';

final class RecordingCardAutoSyncDownload {
  const RecordingCardAutoSyncDownload({
    required this.localRecordingId,
    this.contentHash,
  });

  final String localRecordingId;
  final String? contentHash;
}

abstract interface class RecordingCardAutoSyncActions implements Listenable {
  RecordingCardRuntimeSnapshot get snapshot;

  bool get hasActiveTransfer;

  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  loadConnectionFiles({bool forceRefresh = false});

  Future<RecordingCardResult<RecordingCardAutoSyncDownload>> download(
    RecordingCardScannedFile file,
  );
}

abstract interface class RecordingCardAutoSyncPauseActions {
  Future<void> pauseActiveTransfer();
}

abstract interface class RecordingCardBackgroundTransportActions {
  RecordingCardBackgroundTransferTransport? get activeTransferTransport;
}

abstract interface class RecordingCardSuccessfulFileRefreshActions {
  int get successfulFileRefreshRevision;
}

abstract interface class RecordingCardCompletionRefreshLifecycleActions {
  bool get hasPendingRecordingCompletionRefresh;

  String? get fileCatalogFailureCode;
}

abstract interface class RecordingCardAutoTranscriptionPort {
  Future<RecordingCardResult<bool>> transcribe(String localRecordingId);
}

final class RecordingCardAutoTranscriptionOperation {
  RecordingCardAutoTranscriptionOperation({
    required this.result,
    VoidCallback? onCancel,
  }) : _onCancel = onCancel;

  final Future<RecordingCardResult<bool>> result;
  VoidCallback? _onCancel;

  void cancel() {
    final onCancel = _onCancel;
    _onCancel = null;
    onCancel?.call();
  }
}

abstract interface class RecordingCardAutoTranscriptionOperationPort
    implements RecordingCardAutoTranscriptionPort {
  RecordingCardAutoTranscriptionOperation startTranscription(
    String localRecordingId,
  );
}

final class DeferredRecordingCardAutoTranscriptionPort
    implements RecordingCardAutoTranscriptionOperationPort {
  const DeferredRecordingCardAutoTranscriptionPort(this._resolve);

  final RecordingCardAutoTranscriptionPort Function() _resolve;

  @override
  Future<RecordingCardResult<bool>> transcribe(String localRecordingId) {
    return startTranscription(localRecordingId).result;
  }

  @override
  RecordingCardAutoTranscriptionOperation startTranscription(
    String localRecordingId,
  ) {
    final delegate = _resolve();
    if (delegate is RecordingCardAutoTranscriptionOperationPort) {
      return delegate.startTranscription(localRecordingId);
    }
    return RecordingCardAutoTranscriptionOperation(
      result: delegate.transcribe(localRecordingId),
    );
  }
}

final class RecordingUploadAutoTranscriptionPort
    implements RecordingCardAutoTranscriptionOperationPort {
  RecordingUploadAutoTranscriptionPort({
    required LocalRecordingRepository repository,
    required RecordingUploadController uploadController,
    required RecordingProcessingCompletionPort completionPort,
  }) : _repository = repository,
       _uploadController = uploadController,
       _completionPort = completionPort;

  final LocalRecordingRepository _repository;
  final RecordingUploadController _uploadController;
  final RecordingProcessingCompletionPort _completionPort;

  @override
  Future<RecordingCardResult<bool>> transcribe(String localRecordingId) =>
      startTranscription(localRecordingId).result;

  @override
  RecordingCardAutoTranscriptionOperation startTranscription(
    String localRecordingId,
  ) {
    final cancellation = _RecordingCardAutoTranscriptionCancellation();
    final transcription = _transcribe(localRecordingId, cancellation);
    return RecordingCardAutoTranscriptionOperation(
      result: Future.any<RecordingCardResult<bool>>(
        <Future<RecordingCardResult<bool>>>[
          transcription,
          cancellation.whenCancelled.then((_) => _cancelledResult()),
        ],
      ),
      onCancel: cancellation.cancel,
    );
  }

  Future<RecordingCardResult<bool>> _transcribe(
    String localRecordingId,
    _RecordingCardAutoTranscriptionCancellation cancellation,
  ) async {
    if (cancellation.isCancelled) return _cancelledResult();
    final item = _repository.findById(localRecordingId);
    if (item == null || item.localFileState != RecordingLocalFileState.ready) {
      return RecordingCardResult<bool>.failure(
        _failure('RECORDING_CARD_AUTO_TRANSCRIPTION_LOCAL_FILE_MISSING'),
      );
    }
    try {
      final linkedRecordingId = item.remoteRecordingId?.trim();
      if (linkedRecordingId != null && linkedRecordingId.isNotEmpty) {
        return _handoff(item.recordingId, linkedRecordingId, cancellation);
      }
      final submitted = await _uploadController.uploadLocalRecording(
        item: item,
        sourceScene: 'raw_material',
        fileSource: RecordingFileSource.recordingCard,
        title: item.displayName,
        contentLineId: item.contentLineId,
      );
      if (submitted == null) {
        return RecordingCardResult<bool>.failure(
          _transcriptionFailure(
            _uploadController.state.lastErrorCode ??
                'RECORDING_CARD_AUTO_TRANSCRIPTION_SUBMIT_FAILED',
          ),
        );
      }
      return _handoff(
        item.recordingId,
        submitted.recording.recordingId,
        cancellation,
      );
    } on Object {
      return RecordingCardResult<bool>.failure(
        _transcriptionFailure(
          'RECORDING_CARD_AUTO_TRANSCRIPTION_UNEXPECTED_FAILURE',
        ),
      );
    }
  }

  Future<RecordingCardResult<bool>> _handoff(
    String localRecordingId,
    String recordingId,
    _RecordingCardAutoTranscriptionCancellation cancellation,
  ) async {
    final handoff = _uploadController.handoffQueuedProcessingForLocalRecording(
      localRecordingId: localRecordingId,
      recordingId: recordingId,
    );
    if (!handoff.accepted) {
      return RecordingCardResult<bool>.failure(
        _transcriptionFailure(
          handoff.failureCode ??
              'RECORDING_CARD_AUTO_TRANSCRIPTION_PROCESSING_NOT_QUEUED',
        ),
      );
    }
    if (cancellation.isCancelled) return _cancelledResult();
    final completion = await _waitForCompletion(recordingId, cancellation);
    if (cancellation.isCancelled) return _cancelledResult();
    return switch (completion.status) {
      RecordingProcessingCompletionStatus.completed =>
        RecordingCardResult<bool>.success(true),
      RecordingProcessingCompletionStatus.failed =>
        RecordingCardResult<bool>.failure(
          _transcriptionFailure(
            _completionErrorCode(
              completion.errorCode,
              'RECORDING_CARD_AUTO_TRANSCRIPTION_PROCESSING_FAILED',
            ),
          ),
        ),
      RecordingProcessingCompletionStatus.unavailable =>
        RecordingCardResult<bool>.failure(
          _transcriptionFailure(
            _completionErrorCode(
              completion.errorCode,
              'RECORDING_CARD_AUTO_TRANSCRIPTION_COMPLETION_UNAVAILABLE',
            ),
          ),
        ),
    };
  }

  Future<RecordingProcessingCompletion> _waitForCompletion(
    String recordingId,
    _RecordingCardAutoTranscriptionCancellation cancellation,
  ) async {
    final completionPort = _completionPort;
    if (completionPort is RecordingProcessingCompletionSubscriptionPort) {
      final subscriptionPort =
          completionPort as RecordingProcessingCompletionSubscriptionPort;
      final subscription = subscriptionPort.observeTerminal(recordingId);
      final cancelSubscription = subscription.cancel;
      cancellation.addListener(cancelSubscription);
      try {
        return await subscription.completion;
      } finally {
        cancellation.removeListener(cancelSubscription);
      }
    }
    return completionPort.waitForTerminal(recordingId);
  }

  RecordingCardResult<bool> _cancelledResult() {
    return RecordingCardResult<bool>.failure(
      _transcriptionFailure('RECORDING_CARD_AUTO_TRANSCRIPTION_CANCELLED'),
    );
  }
}

final class _RecordingCardAutoTranscriptionCancellation {
  final Set<VoidCallback> _listeners = <VoidCallback>{};
  final Completer<void> _cancelledSignal = Completer<void>();
  var _cancelled = false;

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledSignal.future;

  void addListener(VoidCallback listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledSignal.complete();
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

enum RecordingCardBackgroundExecutionMode { processBound, appResumeOnly }

enum RecordingCardBackgroundTransferTransport {
  bluetooth('bluetooth'),
  wifi('wifi');

  const RecordingCardBackgroundTransferTransport(this.wireValue);

  final String wireValue;
}

@immutable
final class RecordingCardBackgroundExecutionRequest {
  const RecordingCardBackgroundExecutionRequest({
    required this.keepAlive,
    required this.transferActive,
    this.transport,
  }) : assert(transferActive == (transport != null));

  const RecordingCardBackgroundExecutionRequest.disabled()
    : this(keepAlive: false, transferActive: false);

  final bool keepAlive;
  final bool transferActive;
  final RecordingCardBackgroundTransferTransport? transport;

  bool get enabled => keepAlive || transferActive;

  Map<String, Object?> toWire() => <String, Object?>{
    // Retained for app binaries whose native host predates structured state.
    'enabled': enabled,
    'keepAlive': keepAlive,
    'transferActive': transferActive,
    'transport': transport?.wireValue,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecordingCardBackgroundExecutionRequest &&
          keepAlive == other.keepAlive &&
          transferActive == other.transferActive &&
          transport == other.transport;

  @override
  int get hashCode => Object.hash(keepAlive, transferActive, transport);
}

final class RecordingCardBackgroundExecutionCapability {
  const RecordingCardBackgroundExecutionCapability({
    required this.mode,
    required this.enabled,
    required this.restoresAfterProcessDeath,
    required this.resumesOnNextAppLaunch,
  });

  const RecordingCardBackgroundExecutionCapability.appResumeOnly({
    required bool enabled,
  }) : this(
         mode: RecordingCardBackgroundExecutionMode.appResumeOnly,
         enabled: enabled,
         restoresAfterProcessDeath: false,
         resumesOnNextAppLaunch: true,
       );

  factory RecordingCardBackgroundExecutionCapability.fromWire(
    Object? value, {
    required bool enabled,
  }) {
    if (value is! Map) {
      return RecordingCardBackgroundExecutionCapability.appResumeOnly(
        enabled: enabled,
      );
    }
    final mode = value['mode'] == 'processBound'
        ? RecordingCardBackgroundExecutionMode.processBound
        : RecordingCardBackgroundExecutionMode.appResumeOnly;
    return RecordingCardBackgroundExecutionCapability(
      mode: mode,
      enabled: value['enabled'] == true,
      restoresAfterProcessDeath: value['restoresAfterProcessDeath'] == true,
      resumesOnNextAppLaunch: value['resumesOnNextAppLaunch'] != false,
    );
  }

  final RecordingCardBackgroundExecutionMode mode;
  final bool enabled;
  final bool restoresAfterProcessDeath;
  final bool resumesOnNextAppLaunch;
}

abstract interface class RecordingCardBackgroundExecutionPort {
  Future<RecordingCardBackgroundExecutionCapability> update(
    RecordingCardBackgroundExecutionRequest request,
  );
}

final class MethodChannelRecordingCardBackgroundExecutionPort
    implements RecordingCardBackgroundExecutionPort {
  const MethodChannelRecordingCardBackgroundExecutionPort({
    MethodChannel channel = const MethodChannel('huahuoai/native_file'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<RecordingCardBackgroundExecutionCapability> setEnabled(bool enabled) {
    return update(
      RecordingCardBackgroundExecutionRequest(
        keepAlive: enabled,
        transferActive: false,
      ),
    );
  }

  @override
  Future<RecordingCardBackgroundExecutionCapability> update(
    RecordingCardBackgroundExecutionRequest request,
  ) async {
    try {
      final response = await _channel.invokeMethod<Object?>(
        'setRecordingCardAutoSyncBackgroundEnabled',
        request.toWire(),
      );
      return RecordingCardBackgroundExecutionCapability.fromWire(
        response,
        enabled: request.enabled,
      );
    } on MissingPluginException {
      return RecordingCardBackgroundExecutionCapability.appResumeOnly(
        enabled: request.enabled,
      );
    } on PlatformException {
      return RecordingCardBackgroundExecutionCapability.appResumeOnly(
        enabled: request.enabled,
      );
    }
  }
}

final class ControllerRecordingCardAutoSyncActions
    implements
        RecordingCardAutoSyncActions,
        RecordingCardAutoSyncPauseActions,
        RecordingCardBackgroundTransportActions,
        RecordingCardSuccessfulFileRefreshActions,
        RecordingCardCompletionRefreshLifecycleActions {
  const ControllerRecordingCardAutoSyncActions(this._controller);

  final RecordingCardController _controller;

  @override
  RecordingCardRuntimeSnapshot get snapshot => _controller.state.snapshot;

  @override
  bool get hasActiveTransfer =>
      _controller.hasActiveTransfer ||
      _controller.hasAutomaticSyncBlockingWifiBatch;

  @override
  RecordingCardBackgroundTransferTransport? get activeTransferTransport {
    final operation = _controller.state.operation;
    if (!operation.isActive) return null;
    return switch (operation.kind) {
      RecordingCardOperationKind.bluetoothTransfer =>
        RecordingCardBackgroundTransferTransport.bluetooth,
      RecordingCardOperationKind.wifiTransfer =>
        RecordingCardBackgroundTransferTransport.wifi,
      _ => null,
    };
  }

  @override
  int get successfulFileRefreshRevision =>
      _controller.successfulFileRefreshRevision;

  @override
  bool get hasPendingRecordingCompletionRefresh =>
      _controller.hasPendingRecordingCompletionRefresh;

  @override
  String? get fileCatalogFailureCode => _controller.fileCatalogFailureCode;

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  loadConnectionFiles({bool forceRefresh = false}) async {
    final successfulRevisionBefore = _controller.successfulFileRefreshRevision;
    if (forceRefresh) {
      await _controller.refreshFiles(
        reason: RecordingCardFileRefreshReason.transferCompleted,
      );
    } else if (_controller.state.fileCatalog.phase ==
        RecordingCardFileCatalogPhase.failed) {
      await _controller.refreshFiles(
        reason: RecordingCardFileRefreshReason.appResumed,
      );
    } else {
      await _controller.ensureFilesLoadedForCurrentConnection();
    }
    final state = _controller.state;
    if (forceRefresh &&
        (_controller.successfulFileRefreshRevision <=
                successfulRevisionBefore ||
            !_controller.hasLoadedFilesForCurrentConnection)) {
      final code =
          state.fileCatalog.errorCode ??
          state.lastErrorCode ??
          (state.snapshot.recordingInfo.state !=
                  RecordingCardRecordingState.idle
              ? 'RECORDING_CARD_RECORDING_ACTIVE'
              : _controller.hasActiveTransfer
              ? 'RECORDING_CARD_TRANSFER_BUSY'
              : 'RECORDING_CARD_SCAN_NOT_ACCEPTED');
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        _failure(code),
      );
    }
    if (state.lastErrorCode != null &&
        state.status == RecordingCardControllerStatus.error) {
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        _failure(state.lastErrorCode!),
      );
    }
    return RecordingCardResult<List<RecordingCardScannedFile>>.success(
      state.snapshot.files,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardAutoSyncDownload>> download(
    RecordingCardScannedFile file,
  ) async {
    final result = await _controller.downloadFileResult(
      file,
      refreshAfterTransfer: false,
      origin: RecordingCardOperationOrigin.automatic,
    );
    final downloaded = result.value;
    if (!result.ok ||
        downloaded == null ||
        downloaded.localFileKey != file.localFileKey ||
        downloaded.localFileId == null) {
      return RecordingCardResult<RecordingCardAutoSyncDownload>.failure(
        result.error ??
            _failure(
              _controller.state.lastErrorCode ??
                  _controller.operationBlockCode ??
                  'RECORDING_CARD_AUTO_SYNC_DOWNLOAD_FAILED',
            ),
      );
    }
    return RecordingCardResult<RecordingCardAutoSyncDownload>.success(
      RecordingCardAutoSyncDownload(
        localRecordingId: downloaded.localFileId!,
        contentHash: downloaded.contentHash,
      ),
    );
  }

  @override
  Future<void> pauseActiveTransfer() => _controller.cancelFileTransfer();
}

final class RecordingCardAutoSyncCoordinator extends ChangeNotifier {
  static const autoSyncTaskKey = 'recording-card:auto-sync';
  // performance-rfc: runtime-activation-resident-tasks
  static final _autoSyncTaskSpec = TaskSpec(
    key: autoSyncTaskKey,
    owner: 'recording-card-auto-sync',
    priority: TaskPriority.foregroundDeferred,
    resources: const <TaskResource>{TaskResource.network, TaskResource.media},
    foregroundOnly: false,
    retryable: true,
  );

  RecordingCardAutoSyncCoordinator({
    required RecordingCardAutoSyncPersistencePort persistence,
    required RecordingCardAutoSyncActions actions,
    RecordingCardAutoTranscriptionPort? transcriptionPort,
    RecordingCardBackgroundExecutionPort? backgroundExecutionPort,
    TaskOrchestrator? taskOrchestrator,
    DateTime Function()? clock,
    RecordingCardSyncPlanner syncPlanner = const RecordingCardSyncPlanner(),
    RecordingCardSyncRetryPolicy retryPolicy =
        const RecordingCardSyncRetryPolicy(),
    Future<void> Function(Duration delay)? retryDelay,
  }) : _persistence = persistence,
       _ledgerPersistence = _asLedgerPersistence(persistence),
       _actions = actions,
       _transcriptionPort = transcriptionPort,
       _backgroundExecutionPort = backgroundExecutionPort,
       _taskOrchestrator = taskOrchestrator ?? TaskOrchestrator(),
       _ownsTaskOrchestrator = taskOrchestrator == null,
       _clock = clock ?? DateTime.now,
       _syncPlanner = syncPlanner,
       _retryPolicy = retryPolicy,
       _retryDelay = retryDelay ?? Future<void>.delayed,
       _state = RecordingCardAutoSyncState(
         status: RecordingCardAutoSyncStatus.idle,
         preferences: persistence.loadPreferences(),
         tasks: persistence.loadTasks(),
       ) {
    if (!_state.preferences.autoSyncEnabled) _sessionMachine.disable();
    _reconcileKnownTasksWithLedger();
    _actions.addListener(_onActionsChanged);
    _onActionsChanged();
  }

  final RecordingCardAutoSyncPersistencePort _persistence;
  final RecordingCardSyncLedgerPersistencePort? _ledgerPersistence;
  final RecordingCardAutoSyncActions _actions;
  final RecordingCardAutoTranscriptionPort? _transcriptionPort;
  final RecordingCardBackgroundExecutionPort? _backgroundExecutionPort;
  final TaskOrchestrator _taskOrchestrator;
  final bool _ownsTaskOrchestrator;
  final DateTime Function() _clock;
  final RecordingCardSyncPlanner _syncPlanner;
  final RecordingCardSyncRetryPolicy _retryPolicy;
  final Future<void> Function(Duration delay) _retryDelay;
  final RecordingCardSyncSessionMachine _sessionMachine =
      RecordingCardSyncSessionMachine();
  final RecordingCardSyncTriggerGate _triggerGate =
      RecordingCardSyncTriggerGate();

  RecordingCardAutoSyncState _state;
  Future<void>? _runInFlight;
  Future<void>? _pauseInFlight;
  final Map<String, RecordingCardAutoTranscriptionOperation>
  _transcriptionOperations =
      <String, RecordingCardAutoTranscriptionOperation>{};
  final Set<RecordingCardAutoTranscriptionOperation>
  _backfillTranscriptionOperations =
      <RecordingCardAutoTranscriptionOperation>{};
  final Set<String> _scheduledRetryTaskIds = <String>{};
  RecordingCardSyncPlan? _waitingPlan;
  bool _rescheduleRequested = false;
  bool _suppressOwnedActionReschedule = false;
  int _projectedFileRefreshRevision = 0;
  int _plannedFileRefreshRevision = 0;
  bool _paused = false;
  String? _pendingCheckpointCardSnDigest;
  RecordingCardSyncCheckpoint? _checkpointBeforePendingCommit;
  bool _disposed = false;
  var _backgroundGeneration = 0;
  RecordingCardBackgroundExecutionRequest? _backgroundRequest;
  RecordingCardBackgroundExecutionCapability _backgroundCapability =
      const RecordingCardBackgroundExecutionCapability.appResumeOnly(
        enabled: false,
      );

  RecordingCardAutoSyncState get state => _state;
  RecordingCardSyncSessionState get syncSession => _sessionMachine.state;
  bool get isPaused => _paused;
  RecordingCardBackgroundExecutionCapability get backgroundCapability =>
      _backgroundCapability;

  bool get hasObjectivePrerequisiteWait => _isObjectivePrerequisite(
    _sessionMachine.state.waitingReason ?? _state.waitingReason,
  );

  String? get connectedCardSnDigest => _cardDigestFor(_actions.snapshot);

  List<RecordingCardFileLedgerEntry> get connectedCardLedger {
    final digest = connectedCardSnDigest;
    final persistence = _ledgerPersistence;
    if (digest == null || persistence == null) {
      return const <RecordingCardFileLedgerEntry>[];
    }
    return persistence.loadFileLedger(digest);
  }

  RecordingCardSyncCheckpoint? get connectedCardCheckpoint {
    final digest = connectedCardSnDigest;
    if (digest != null && digest == _pendingCheckpointCardSnDigest) {
      return _checkpointBeforePendingCommit;
    }
    return digest == null
        ? null
        : _ledgerPersistence?.loadSyncCheckpoint(digest);
  }

  Future<void> setAutoSyncEnabled(bool enabled) async {
    if (enabled &&
        _sessionMachine.state.status ==
            RecordingCardSyncSessionStatus.pausing) {
      return;
    }
    _paused = false;
    final preferences = _state.preferences.copyWith(autoSyncEnabled: enabled);
    _persistence.savePreferences(preferences);
    _state = _state.copyWith(preferences: preferences, clearError: true);
    notifyListeners();
    if (!enabled) {
      _cancelAutoSync('recording-card-auto-sync-disabled');
      _sessionMachine.disable();
      _setStatus(RecordingCardAutoSyncStatus.idle);
    }
    await _refreshBackgroundExecution();
    if (enabled) {
      _signalAndSchedule(RecordingCardSyncTrigger.autoSyncEnabled);
    }
  }

  void setAutoTranscriptionEnabled(bool enabled) {
    final preferences = _state.preferences.copyWith(
      autoTranscriptionEnabled: enabled,
    );
    _persistence.savePreferences(preferences);
    _state = _state.copyWith(preferences: preferences, clearError: true);
    notifyListeners();
  }

  Future<int> backfillHistoricalTranscriptions(
    Iterable<RecordingLibraryItem> items,
  ) async {
    final port = _transcriptionPort;
    if (port == null) {
      _fail('RECORDING_CARD_AUTO_TRANSCRIPTION_UNAVAILABLE');
      return 0;
    }
    var completed = 0;
    final unique = <String, RecordingLibraryItem>{
      for (final item in items)
        if (item.source == RecordingLibrarySource.device)
          item.recordingId: item,
    }.values;
    for (final item in unique) {
      if (_disposed) break;
      _setStatus(RecordingCardAutoSyncStatus.transcribing);
      final operation = _beginTranscription(port, item.recordingId);
      _backfillTranscriptionOperations.add(operation);
      late final RecordingCardResult<bool> result;
      try {
        result = await operation.result;
      } finally {
        _backfillTranscriptionOperations.remove(operation);
      }
      if (result.ok && result.value == true) {
        completed += 1;
      } else {
        _fail(result.error?.code ?? 'RECORDING_CARD_AUTO_TRANSCRIPTION_FAILED');
      }
    }
    if (!_disposed && completed == unique.length) {
      _setStatus(RecordingCardAutoSyncStatus.completed);
    }
    return completed;
  }

  void retry() {
    _paused = false;
    final now = _clock().toUtc();
    final tasks = <RecordingCardAutoSyncTask>[
      for (final task in _state.tasks)
        if (task.state == RecordingCardAutoSyncTaskState.failed)
          task.copyWith(
            state: RecordingCardAutoSyncTaskState.queued,
            updatedAt: now,
            clearError: true,
          )
        else
          task,
    ];
    for (final task in tasks) {
      _persistence.saveTask(task);
      final cardSnDigest = task.cardSnDigest;
      final sourceSignature = task.sourceSignature;
      final ledgerPersistence = _ledgerPersistence;
      if (ledgerPersistence != null &&
          cardSnDigest != null &&
          sourceSignature != null) {
        final entry = ledgerPersistence.findFileLedgerEntry(
          cardSnDigest: cardSnDigest,
          sourceSignature: sourceSignature,
        );
        if (entry?.localState == RecordingCardFileLocalState.failed) {
          ledgerPersistence.saveFileLedgerEntry(
            entry!.queue(at: now, manual: true, resetAttemptCount: true),
          );
        }
      }
    }
    _state = _state.copyWith(tasks: tasks, clearError: true);
    notifyListeners();
    unawaited(_refreshBackgroundExecution());
    _signalAndSchedule(RecordingCardSyncTrigger.explicitRetry);
  }

  void resume({bool requestDeviceSync = true}) {
    _resumeLocalTranscriptions();
    if (!requestDeviceSync) return;
    final taskState = _taskOrchestrator.projectionFor(autoSyncTaskKey)?.state;
    if (_runInFlight != null &&
        (taskState is AppTaskQueued || taskState is AppTaskRunning)) {
      return;
    }
    final hasRecoverableWork = _state.tasks.any(
      (task) =>
          !task.isTerminal &&
          task.state != RecordingCardAutoSyncTaskState.failed,
    );
    final interruptedBeforePlanning =
        _actions.snapshot.deviceState.isOperationallyConnected &&
        _sessionMachine.state.status !=
            RecordingCardSyncSessionStatus.completed &&
        _sessionMachine.state.status != RecordingCardSyncSessionStatus.failed &&
        _sessionMachine.state.status != RecordingCardSyncSessionStatus.paused;
    if (_state.preferences.autoSyncEnabled &&
        !_paused &&
        (hasRecoverableWork || interruptedBeforePlanning)) {
      _signalAndSchedule(RecordingCardSyncTrigger.appResumed);
    }
  }

  void notifyNetworkRestored() {
    _resumeForWaitingReason(
      RecordingCardSyncWaitingReason.networkRequired,
      RecordingCardSyncTrigger.networkRestored,
    );
  }

  void notifyPermissionRestored() {
    _resumeForWaitingReason(
      RecordingCardSyncWaitingReason.permissionRequired,
      RecordingCardSyncTrigger.permissionRestored,
    );
  }

  void notifyStorageRestored() {
    _resumeForWaitingReason(
      RecordingCardSyncWaitingReason.storageInsufficient,
      RecordingCardSyncTrigger.storageRestored,
    );
  }

  void notifyStorageAvailable() => notifyStorageRestored();

  void notifyPersistenceRestored() {
    _resumeForWaitingReason(
      RecordingCardSyncWaitingReason.persistenceRequired,
      RecordingCardSyncTrigger.persistenceRestored,
    );
  }

  void _resumeForWaitingReason(
    RecordingCardSyncWaitingReason reason,
    RecordingCardSyncTrigger trigger,
  ) {
    if (_disposed ||
        _paused ||
        !_state.preferences.autoSyncEnabled ||
        _sessionMachine.state.waitingReason != reason) {
      return;
    }
    _signalAndSchedule(trigger);
  }

  Future<void> pause() => _requestPause(force: false);

  Future<void> _requestPause({required bool force}) {
    final running = _pauseInFlight;
    if (running != null) return running;
    if (_disposed ||
        _paused ||
        (!force &&
            (!_state.preferences.autoSyncEnabled ||
                _state.pendingFileSyncCount == 0))) {
      return Future<void>.value();
    }
    late final Future<void> operation;
    operation = _pauseAndSettle().whenComplete(() {
      if (identical(_pauseInFlight, operation)) _pauseInFlight = null;
    });
    _pauseInFlight = operation;
    return operation;
  }

  Future<void> _pauseAndSettle() async {
    final wasDownloading =
        _state.status == RecordingCardAutoSyncStatus.downloading;
    final run = _runInFlight;
    _paused = true;
    _sessionMachine.requestPause();
    _setStatus(RecordingCardAutoSyncStatus.pausing);
    _cancelAutoSync('recording-card-auto-sync-paused');
    final actions = _actions;
    if (wasDownloading) {
      if (actions case final RecordingCardAutoSyncPauseActions pauseActions) {
        await pauseActions.pauseActiveTransfer();
      }
    }
    if (run != null) {
      try {
        await run;
      } on Object {
        // The scheduled run owns cancellation/error projection.
      }
    }
    if (_disposed) return;
    _settlePauseIfQuiescent();
    await _flushInterruptedPersistence();
    await _refreshBackgroundExecution();
  }

  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  prepareWifiHandoff({required String expectedCardSnDigest}) async {
    if (_disposed || connectedCardSnDigest != expectedCardSnDigest) {
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        _failure('RECORDING_CARD_WIFI_HANDOFF_CARD_CHANGED'),
      );
    }
    await _requestPause(force: true);
    if (_disposed || _actions.hasActiveTransfer || !_paused) {
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        _failure('RECORDING_CARD_WIFI_HANDOFF_TRANSFER_NOT_SETTLED'),
      );
    }
    final snapshot = _actions.snapshot;
    if (!snapshot.deviceState.isOperationallyConnected) {
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        _failure('RECORDING_CARD_WIFI_HANDOFF_DEVICE_DISCONNECTED'),
      );
    }
    if (_cardDigestFor(snapshot) != expectedCardSnDigest) {
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        _failure('RECORDING_CARD_WIFI_HANDOFF_CARD_CHANGED'),
      );
    }
    final refreshed = await _runOwnedAction(
      () => _actions.loadConnectionFiles(forceRefresh: true),
    );
    if (!refreshed.ok || refreshed.value == null) return refreshed;
    if (_disposed ||
        _cardDigestFor(_actions.snapshot) != expectedCardSnDigest ||
        _actions.hasActiveTransfer) {
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        _failure('RECORDING_CARD_WIFI_HANDOFF_CARD_CHANGED'),
      );
    }
    if (!await _flushInterruptedPersistence()) {
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        _failure('RECORDING_CARD_WIFI_HANDOFF_PERSISTENCE_FAILED'),
      );
    }
    return RecordingCardResult<List<RecordingCardScannedFile>>.success(
      refreshed.value!,
    );
  }

  void _settlePauseIfQuiescent() {
    if (_disposed || !_paused) return;
    if (_actions.hasActiveTransfer) {
      _setStatus(RecordingCardAutoSyncStatus.pausing);
      return;
    }
    _recoverActiveLedgerSyncs();
    if (_sessionMachine.state.status ==
        RecordingCardSyncSessionStatus.pausing) {
      _sessionMachine.pause();
    }
    _setStatus(RecordingCardAutoSyncStatus.paused);
  }

  void continueSync() {
    if (_disposed ||
        !_paused ||
        _sessionMachine.state.status ==
            RecordingCardSyncSessionStatus.pausing) {
      return;
    }
    _paused = false;
    _setStatus(RecordingCardAutoSyncStatus.idle);
    unawaited(_refreshBackgroundExecution());
    _signalAndSchedule(RecordingCardSyncTrigger.explicitContinue);
  }

  Future<void> _setBackgroundExecutionState(
    RecordingCardBackgroundExecutionRequest request,
  ) async {
    final port = _backgroundExecutionPort;
    final generation = ++_backgroundGeneration;
    final fallback = RecordingCardBackgroundExecutionCapability.appResumeOnly(
      enabled: request.enabled,
    );
    final capability = port == null
        ? fallback
        : await port.update(request).catchError((Object _) => fallback);
    if (_disposed || generation != _backgroundGeneration) return;
    _backgroundCapability = capability;
    notifyListeners();
  }

  void _onActionsChanged() {
    if (_disposed) return;
    unawaited(_refreshBackgroundExecution());
    final projectedDirectory = _projectSuccessfulDirectoryRefresh();
    final wasWaitingForOtherTransfer =
        _sessionMachine.state.waitingReason ==
        RecordingCardSyncWaitingReason.otherTransferActive;
    final wasWaitingForRecording =
        _sessionMachine.state.waitingReason ==
        RecordingCardSyncWaitingReason.deviceRecording;
    _resumeLocalTranscriptions();
    if (!_state.preferences.autoSyncEnabled) return;
    if (_paused) {
      _settlePauseIfQuiescent();
      return;
    }
    if (projectedDirectory && !_suppressOwnedActionReschedule) {
      _triggerGate.signal(RecordingCardSyncTrigger.directoryRefreshed);
    }
    final snapshot = _actions.snapshot;
    final cardSnDigest = _cardDigestFor(snapshot);
    _triggerGate.observe(
      RecordingCardSyncTriggerObservation(
        autoSyncEnabled: _state.preferences.autoSyncEnabled,
        isConnected: snapshot.deviceState.isOperationallyConnected,
        isRecording:
            snapshot.recordingInfo.state != RecordingCardRecordingState.idle,
        hasConflictingTransfer: _actions.hasActiveTransfer,
        cardSnDigest: cardSnDigest,
      ),
      includeDirectoryChanges: false,
      includeRecordingChanges: false,
      includeTransferChanges:
          !_suppressOwnedActionReschedule && wasWaitingForOtherTransfer,
    );
    if (!snapshot.deviceState.isOperationallyConnected) {
      _cancelAutoSync('recording-card-disconnected');
      _recoverActiveLedgerSyncs();
      unawaited(_flushInterruptedPersistence());
      _sessionMachine.waitFor(
        RecordingCardSyncWaitingReason.deviceDisconnected,
        cardSnDigest: cardSnDigest,
      );
      if (_transcriptionOperations.isNotEmpty) {
        _setStatus(RecordingCardAutoSyncStatus.transcribing);
      } else if (_state.status != RecordingCardAutoSyncStatus.failed) {
        _setStatus(RecordingCardAutoSyncStatus.waitingForDevice);
      }
      return;
    }
    if (_suppressOwnedActionReschedule) return;
    if (snapshot.recordingInfo.state != RecordingCardRecordingState.idle) {
      _sessionMachine.waitFor(
        RecordingCardSyncWaitingReason.deviceRecording,
        cardSnDigest: cardSnDigest,
      );
      _setStatus(RecordingCardAutoSyncStatus.waitingForRecording);
      return;
    }
    final completionRefresh =
        _actions is RecordingCardCompletionRefreshLifecycleActions
        ? _actions as RecordingCardCompletionRefreshLifecycleActions
        : null;
    final completionFailureCode = completionRefresh?.fileCatalogFailureCode;
    if (wasWaitingForRecording &&
        completionRefresh?.hasPendingRecordingCompletionRefresh == true) {
      _setStatus(RecordingCardAutoSyncStatus.waitingForRecording);
      return;
    }
    if (wasWaitingForRecording &&
        completionRefresh != null &&
        !completionRefresh.hasPendingRecordingCompletionRefresh &&
        completionFailureCode != null) {
      _sessionMachine.fail(completionFailureCode);
      _fail(completionFailureCode);
      return;
    }
    if (_actions.hasActiveTransfer &&
        (_runInFlight != null || _triggerGate.hasPending)) {
      _sessionMachine.waitFor(
        RecordingCardSyncWaitingReason.otherTransferActive,
        cardSnDigest: cardSnDigest,
      );
      _setStatus(RecordingCardAutoSyncStatus.waitingForTransfer);
      return;
    }
    if (_isObjectivePrerequisite(_sessionMachine.state.waitingReason)) return;
    if (_triggerGate.hasPending) _schedule();
  }

  bool _projectSuccessfulDirectoryRefresh() {
    final actions = _actions;
    final persistence = _ledgerPersistence;
    if (actions is! RecordingCardSuccessfulFileRefreshActions) {
      return false;
    }
    final revisionActions =
        actions as RecordingCardSuccessfulFileRefreshActions;
    final revision = revisionActions.successfulFileRefreshRevision;
    if (revision <= _projectedFileRefreshRevision) return false;
    final snapshot = actions.snapshot;
    final cardSnDigest = _cardDigestFor(snapshot);
    final fingerprint = snapshot.deviceState.safeDeviceFingerprint?.trim();
    if (!snapshot.deviceState.isOperationallyConnected ||
        cardSnDigest == null ||
        fingerprint == null ||
        fingerprint.isEmpty) {
      return false;
    }
    if (persistence == null) {
      _projectedFileRefreshRevision = revision;
      return true;
    }
    final now = _clock().toUtc();
    try {
      persistence.seedLegacyData(
        cardSnDigest: cardSnDigest,
        legacyDeviceFingerprint: fingerprint,
        directoryFiles: snapshot.files,
        at: now,
      );
      final observation = _syncPlanner.observeDirectory(
        cardSnDigest: cardSnDigest,
        directoryFiles: snapshot.files,
        ledger: persistence.loadFileLedger(cardSnDigest),
        directoryReadAt: now,
      );
      final checkpoint =
          persistence.loadSyncCheckpoint(cardSnDigest) ??
          RecordingCardSyncCheckpoint.empty(
            cardSnDigest: cardSnDigest,
            at: now,
          );
      persistence.commitVerifiedSync(
        entries: observation.entries,
        checkpoint: checkpoint.noteDirectoryRead(now),
      );
      _projectedFileRefreshRevision = revision;
      notifyListeners();
      return true;
    } on Object {
      // Keep the revision unconsumed so a later controller event can retry.
      return false;
    }
  }

  Future<void> _refreshBackgroundExecution() {
    final actions = _actions;
    final transport = actions is RecordingCardBackgroundTransportActions
        ? (actions as RecordingCardBackgroundTransportActions)
              .activeTransferTransport
        : null;
    final request = _disposed
        ? const RecordingCardBackgroundExecutionRequest.disabled()
        : RecordingCardBackgroundExecutionRequest(
            keepAlive: actions.snapshot.deviceState.isOperationallyConnected,
            transferActive: transport != null,
            transport: transport,
          );
    if (_backgroundRequest == request) {
      return Future<void>.value();
    }
    _backgroundRequest = request;
    return _setBackgroundExecutionState(request);
  }

  void _schedule() {
    if (_disposed || _paused || !_triggerGate.hasPending) return;
    if (_runInFlight != null) {
      _rescheduleRequested = true;
      return;
    }
    final operation = _taskOrchestrator.schedule<void>(_autoSyncTaskSpec, _run);
    _runInFlight = operation;
    unawaited(
      operation
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              _handleRunError(error);
            },
          )
          .whenComplete(() {
            if (identical(_runInFlight, operation)) _runInFlight = null;
            if (_state.status == RecordingCardAutoSyncStatus.completed ||
                _state.status == RecordingCardAutoSyncStatus.transcribing) {
              _settleAfterTranscription();
            }
            if (_rescheduleRequested && !_disposed) {
              _rescheduleRequested = false;
              _schedule();
            }
          }),
    );
  }

  void _signalAndSchedule(RecordingCardSyncTrigger trigger) {
    _triggerGate.signal(trigger);
    _schedule();
  }

  Future<void> _run(AppTaskCancellationToken token) async {
    final triggers = _triggerGate.beginRun();
    if (triggers.isEmpty) return;
    try {
      await _runTriggered(token, triggers);
    } finally {
      final pending = _triggerGate.finishRun();
      if (pending.isNotEmpty && !_disposed) {
        for (final trigger in pending) {
          _triggerGate.signal(trigger);
        }
        _rescheduleRequested = true;
      }
    }
  }

  Future<void> _runTriggered(
    AppTaskCancellationToken token,
    Set<RecordingCardSyncTrigger> triggers,
  ) async {
    token.throwIfCancelled();
    _resumeLocalTranscriptions();
    if (!_state.preferences.autoSyncEnabled || _paused) return;
    final snapshot = _actions.snapshot;
    if (!snapshot.deviceState.isOperationallyConnected) {
      _sessionMachine.waitFor(
        RecordingCardSyncWaitingReason.deviceDisconnected,
      );
      if (_transcriptionOperations.isNotEmpty) {
        _setStatus(RecordingCardAutoSyncStatus.transcribing);
      } else if (_state.status != RecordingCardAutoSyncStatus.failed) {
        _setStatus(RecordingCardAutoSyncStatus.waitingForDevice);
      }
      return;
    }
    final cardSnDigest = _cardDigestFor(snapshot);
    if (cardSnDigest == null) {
      _sessionMachine.fail('RECORDING_CARD_AUTO_SYNC_DEVICE_IDENTITY_MISSING');
      _fail('RECORDING_CARD_AUTO_SYNC_DEVICE_IDENTITY_MISSING');
      return;
    }
    if (snapshot.recordingInfo.state != RecordingCardRecordingState.idle) {
      _sessionMachine.waitFor(
        RecordingCardSyncWaitingReason.deviceRecording,
        cardSnDigest: cardSnDigest,
      );
      _setStatus(RecordingCardAutoSyncStatus.waitingForRecording);
      return;
    }
    if (_actions.hasActiveTransfer) {
      _sessionMachine.waitFor(
        RecordingCardSyncWaitingReason.otherTransferActive,
        cardSnDigest: cardSnDigest,
      );
      _setStatus(RecordingCardAutoSyncStatus.waitingForTransfer);
      return;
    }

    final sessionWaitingReason = _sessionMachine.state.waitingReason;
    final latchedWaitingReason = _isObjectivePrerequisite(sessionWaitingReason)
        ? sessionWaitingReason
        : _state.waitingReason;
    if (_isObjectivePrerequisite(latchedWaitingReason) &&
        !_containsRestorationTrigger(triggers, latchedWaitingReason!)) {
      return;
    }
    final recoveryPlan = _isObjectivePrerequisite(latchedWaitingReason)
        ? _waitingPlan
        : null;

    final trigger = triggers.contains(RecordingCardSyncTrigger.autoSyncEnabled)
        ? RecordingCardSyncTrigger.autoSyncEnabled
        : triggers.contains(RecordingCardSyncTrigger.explicitContinue)
        ? RecordingCardSyncTrigger.explicitContinue
        : triggers.contains(RecordingCardSyncTrigger.explicitRetry)
        ? RecordingCardSyncTrigger.explicitRetry
        : triggers.first;
    if (!_sessionMachine.start(trigger: trigger, cardSnDigest: cardSnDigest)) {
      return;
    }
    _setStatus(RecordingCardAutoSyncStatus.scanning);
    final loaded = await _runOwnedAction(() => _actions.loadConnectionFiles());
    token.throwIfCancelled();
    if (_disposed) return;
    if (_stopForCardIdentityChange(cardSnDigest)) return;
    if (!loaded.ok || loaded.value == null) {
      if (_waitForFailurePrerequisite(
        loaded.error,
        cardSnDigest: cardSnDigest,
      )) {
        return;
      }
      _fail(loaded.error?.code ?? 'RECORDING_CARD_AUTO_SYNC_SCAN_FAILED');
      return;
    }
    final availableRefreshRevision =
        _actions is RecordingCardSuccessfulFileRefreshActions
        ? (_actions as RecordingCardSuccessfulFileRefreshActions)
              .successfulFileRefreshRevision
        : 0;
    final hasFreshVerifiedDirectory =
        availableRefreshRevision > _plannedFileRefreshRevision;
    final confirmed = hasFreshVerifiedDirectory
        ? loaded
        : await _runOwnedAction(
            () => _actions.loadConnectionFiles(forceRefresh: true),
          );
    token.throwIfCancelled();
    if (_disposed) return;
    if (_stopForCardIdentityChange(cardSnDigest)) return;
    if (!confirmed.ok || confirmed.value == null) {
      if (_waitForFailurePrerequisite(
        confirmed.error,
        cardSnDigest: cardSnDigest,
      )) {
        return;
      }
      _fail(
        confirmed.error?.code ?? 'RECORDING_CARD_AUTO_SYNC_PRECHECK_FAILED',
      );
      return;
    }
    _consumePlanningRefreshRevision();
    final fingerprint = _actions.snapshot.deviceState.safeDeviceFingerprint;
    if (fingerprint == null || fingerprint.trim().isEmpty) {
      _sessionMachine.fail('RECORDING_CARD_AUTO_SYNC_DEVICE_IDENTITY_MISSING');
      _fail('RECORDING_CARD_AUTO_SYNC_DEVICE_IDENTITY_MISSING');
      return;
    }
    final ledgerPersistence = _ledgerPersistence;
    RecordingCardSyncPlan? syncPlan;
    if (ledgerPersistence != null) {
      ledgerPersistence.seedLegacyData(
        cardSnDigest: cardSnDigest,
        legacyDeviceFingerprint: fingerprint,
        directoryFiles: confirmed.value!,
        at: _clock().toUtc(),
      );
      final recovered = ledgerPersistence.recoverInterruptedEntries(
        cardSnDigest: cardSnDigest,
        at: _clock().toUtc(),
        localFileExists: (entry) => confirmed.value!.any(
          (file) =>
              file.syncState == RecordingCardFileSyncState.synced &&
              file.localFileId == entry.localRecordingId,
        ),
      );
      final confirmedSnapshotHash = _directorySnapshotHash(
        cardSnDigest,
        confirmed.value!,
      );
      final resumesFrozenPlan =
          recoveryPlan?.cardSnDigest == cardSnDigest &&
          recoveryPlan?.snapshotHash == confirmedSnapshotHash;
      if (recoveryPlan != null && !resumesFrozenPlan) {
        _waitingPlan = null;
      }
      final planned = resumesFrozenPlan
          ? recoveryPlan!
          : _syncPlanner.planAutomatic(
              cardSnDigest: cardSnDigest,
              directoryFiles: confirmed.value!,
              ledger: recovered,
              directoryReadAt: _clock().toUtc(),
              resetTransientAttempts: !triggers.contains(
                RecordingCardSyncTrigger.transientRetryReady,
              ),
            );
      syncPlan = planned;
      _sessionMachine.directoryScanned(planned.snapshotHash);
      _setStatus(RecordingCardAutoSyncStatus.scanning);
      if (!resumesFrozenPlan) {
        ledgerPersistence.saveFileLedgerEntries(planned.entries);
      }
      _reconcileTasksWithLedger(
        cardSnDigest,
        ledgerPersistence.loadFileLedger(cardSnDigest),
      );
      final previousCheckpoint = ledgerPersistence.loadSyncCheckpoint(
        cardSnDigest,
      );
      ledgerPersistence.saveSyncCheckpoint(
        (previousCheckpoint ??
                RecordingCardSyncCheckpoint.empty(
                  cardSnDigest: cardSnDigest,
                  at: planned.directoryReadAt,
                ))
            .noteDirectoryRead(planned.directoryReadAt),
      );
      if (!resumesFrozenPlan) {
        _mergePlannedTasks(fingerprint, planned, confirmed.value!);
      } else if (latchedWaitingReason ==
          RecordingCardSyncWaitingReason.persistenceRequired) {
        ledgerPersistence.saveFileLedgerEntries(
          ledgerPersistence.loadFileLedger(cardSnDigest),
        );
        for (final task in _state.tasks) {
          if (task.cardSnDigest == cardSnDigest) _persistence.saveTask(task);
        }
      }
      _resumeLocalTranscriptions();
      _schedulePersistedTransientRetries(cardSnDigest);
      final reconciledFailure = _state.tasks
          .where(
            (task) =>
                task.cardSnDigest == cardSnDigest &&
                task.state == RecordingCardAutoSyncTaskState.failed,
          )
          .firstOrNull;
      if (planned.isEmpty && reconciledFailure != null) {
        if (_state.tasks.any(
          (task) =>
              task.cardSnDigest == cardSnDigest &&
              _scheduledRetryTaskIds.contains(task.taskId),
        )) {
          _waitForRetry(cardSnDigest);
          return;
        }
        _fail(
          reconciledFailure.errorCode ??
              'RECORDING_CARD_AUTO_SYNC_DOWNLOAD_FAILED',
        );
        return;
      }
      if (!await _flushPlanPersistence(ledgerPersistence, planned, token)) {
        return;
      }
      token.throwIfCancelled();
      if (_disposed || _stopForCardIdentityChange(cardSnDigest)) return;
      if (_sessionMachine.state.status !=
          RecordingCardSyncSessionStatus.planning) {
        return;
      }
      _sessionMachine.planPersisted(hasCandidates: !planned.isEmpty);
      if (planned.isEmpty) {
        if (_transcriptionOperations.isNotEmpty) {
          _setStatus(RecordingCardAutoSyncStatus.transcribing);
        } else {
          _setStatus(RecordingCardAutoSyncStatus.completed);
        }
        return;
      }
    } else {
      _mergeTasks(fingerprint, confirmed.value!);
    }
    var transferAttempted = false;
    var transientRetryScheduled = false;

    for (final queued in List<RecordingCardAutoSyncTask>.from(_state.tasks)) {
      token.throwIfCancelled();
      if (_disposed || !_state.preferences.autoSyncEnabled || _paused) return;
      if (_stopForCardIdentityChange(cardSnDigest)) return;
      if (queued.deviceFingerprint != fingerprint ||
          (syncPlan != null &&
              (queued.sourceSignature == null ||
                  !syncPlan.frozenSourceSignatures.contains(
                    queued.sourceSignature,
                  ))) ||
          queued.isTerminal ||
          queued.state == RecordingCardAutoSyncTaskState.failed) {
        continue;
      }
      final queuedLocalRecordingId = queued.localRecordingId?.trim();
      if (queued.transcriptionRequested &&
          queuedLocalRecordingId != null &&
          queuedLocalRecordingId.isNotEmpty) {
        _startTranscriptionTask(queued, queuedLocalRecordingId);
        continue;
      }
      final latest = _actions.snapshot;
      if (latest.recordingInfo.state != RecordingCardRecordingState.idle) {
        _setStatus(RecordingCardAutoSyncStatus.waitingForRecording);
        return;
      }
      if (_actions.hasActiveTransfer) {
        _setStatus(RecordingCardAutoSyncStatus.waitingForTransfer);
        return;
      }
      final file = latest.files
          .where((candidate) => candidate.deviceFileId == queued.deviceFileId)
          .firstOrNull;
      if (file == null) {
        const errorCode = 'RECORDING_CARD_AUTO_SYNC_FILE_MISSING';
        _markLedgerFailed(
          queued,
          errorCode: errorCode,
          retryability: RecordingCardSyncRetryability.permanent,
        );
        _updateTask(
          queued.copyWith(
            state: RecordingCardAutoSyncTaskState.failed,
            updatedAt: _clock().toUtc(),
            errorCode: errorCode,
            retryability: RecordingCardSyncRetryability.permanent,
          ),
        );
        continue;
      }
      final frozenSourceSignature = queued.sourceSignature;
      if (frozenSourceSignature != null) {
        final currentSourceSignature =
            RecordingCardFileIdentity.sourceSignatureFor(
              cardSnDigest: cardSnDigest,
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
              sizeBytes: file.sizeBytes,
              recordedAt: file.recordedAt,
            );
        if (currentSourceSignature != frozenSourceSignature) {
          _sessionMachine.requestReplan();
          _triggerGate.signal(RecordingCardSyncTrigger.directoryRefreshed);
          _setStatus(RecordingCardAutoSyncStatus.scanning);
          return;
        }
      }
      if (file.syncState == RecordingCardFileSyncState.synced &&
          (file.localFileId != null || queued.localRecordingId != null)) {
        final localRecordingId = file.localFileId ?? queued.localRecordingId!;
        final downloaded = queued.copyWith(
          state: RecordingCardAutoSyncTaskState.downloaded,
          updatedAt: _clock().toUtc(),
          localRecordingId: localRecordingId,
          clearError: true,
        );
        _markLedgerSynced(
          downloaded,
          localRecordingId: localRecordingId,
          contentHash: file.contentHash,
        );
        _updateTask(downloaded);
        if (downloaded.transcriptionRequested) {
          _startTranscriptionTask(downloaded, localRecordingId);
        } else {
          _completeTask(downloaded);
        }
        if (!await _flushSettledFilePersistence(cardSnDigest, syncPlan)) {
          return;
        }
        token.throwIfCancelled();
        if (_stopForCardIdentityChange(cardSnDigest)) return;
        continue;
      }
      final downloading = queued.copyWith(
        state: RecordingCardAutoSyncTaskState.downloading,
        attemptCount: queued.attemptCount + 1,
        updatedAt: _clock().toUtc(),
        transcriptionRequested:
            queued.transcriptionRequested ||
            _state.preferences.autoTranscriptionEnabled,
        clearError: true,
        clearRetryability: true,
        clearNextRetryAt: true,
      );
      _markLedgerSyncing(downloading);
      _updateTask(downloading);
      _state = _state.copyWith(
        status: RecordingCardAutoSyncStatus.downloading,
        activeTaskId: downloading.taskId,
        clearError: true,
      );
      notifyListeners();
      transferAttempted = true;
      final downloaded = await _runOwnedAction(() => _actions.download(file));
      if (_disposed) return;
      if (downloaded.ok && downloaded.value != null) {
        final localRecordingId = downloaded.value!.localRecordingId;
        final settled = downloading.copyWith(
          state: RecordingCardAutoSyncTaskState.downloaded,
          updatedAt: _clock().toUtc(),
          localRecordingId: localRecordingId,
          clearError: true,
        );
        _markLedgerSynced(
          settled,
          localRecordingId: localRecordingId,
          contentHash: downloaded.value!.contentHash ?? file.contentHash,
        );
        _updateTask(settled);
        if (settled.transcriptionRequested) {
          _startTranscriptionTask(settled, localRecordingId);
        } else {
          _completeTask(settled);
        }
        if (!await _flushSettledFilePersistence(cardSnDigest, syncPlan)) {
          return;
        }
        token.throwIfCancelled();
        if (_stopForCardIdentityChange(cardSnDigest)) return;
        continue;
      }
      token.throwIfCancelled();
      if (_stopForCardIdentityChange(cardSnDigest)) return;
      if (!downloaded.ok || downloaded.value == null) {
        final waitingReason = _prerequisiteWaitingReason(downloaded.error);
        if (waitingReason != null) {
          _deferDownloadForPrerequisite(
            queued: queued,
            downloading: downloading,
          );
          if (!await _flushSettledFilePersistence(cardSnDigest, syncPlan)) {
            return;
          }
          token.throwIfCancelled();
          _waitForPrerequisite(
            waitingReason,
            cardSnDigest: cardSnDigest,
            recoveryPlan: syncPlan,
          );
          return;
        }
        final retryability = downloaded.error?.isRetryable == true
            ? RecordingCardSyncRetryability.transient
            : RecordingCardSyncRetryability.permanent;
        final errorCode =
            downloaded.error?.code ??
            'RECORDING_CARD_AUTO_SYNC_DOWNLOAD_FAILED';
        final failedAt = _clock().toUtc();
        final nextRetryAt =
            retryability == RecordingCardSyncRetryability.transient
            ? failedAt.add(
                _retryPolicy.delayBeforeAttempt(
                  downloading.attemptCount + 1,
                  jitterSeed: downloading.taskId.hashCode,
                ),
              )
            : null;
        _markLedgerFailed(
          downloading,
          errorCode: errorCode,
          retryability: retryability,
          nextRetryAt: nextRetryAt,
        );
        _updateTask(
          downloading.copyWith(
            state: RecordingCardAutoSyncTaskState.failed,
            updatedAt: failedAt,
            errorCode: errorCode,
            retryability: retryability,
            nextRetryAt: nextRetryAt,
          ),
        );
        if (retryability == RecordingCardSyncRetryability.transient &&
            _retryPolicy.canAttempt(downloading.attemptCount)) {
          transientRetryScheduled = true;
          _scheduleTransientRetry(
            downloading.copyWith(
              state: RecordingCardAutoSyncTaskState.failed,
              updatedAt: failedAt,
              errorCode: errorCode,
              retryability: retryability,
              nextRetryAt: nextRetryAt,
            ),
            nextRetryAt?.difference(failedAt) ?? Duration.zero,
          );
        }
        continue;
      }
    }
    token.throwIfCancelled();
    var verifiedFiles = confirmed.value!;
    if (transferAttempted) {
      _setStatus(RecordingCardAutoSyncStatus.scanning);
      final verified = await _runOwnedAction(
        () => _actions.loadConnectionFiles(forceRefresh: true),
      );
      token.throwIfCancelled();
      if (_disposed) return;
      if (_stopForCardIdentityChange(cardSnDigest)) return;
      if (!verified.ok || verified.value == null) {
        if (_waitForFailurePrerequisite(
          verified.error,
          cardSnDigest: cardSnDigest,
          recoveryPlan: syncPlan,
        )) {
          return;
        }
        _fail(
          verified.error?.code ??
              'RECORDING_CARD_AUTO_SYNC_VERIFICATION_FAILED',
        );
        return;
      }
      verifiedFiles = verified.value!;
      _consumePlanningRefreshRevision();
    }
    if (ledgerPersistence != null && syncPlan != null) {
      _sessionMachine.transfersSettled();
      _setStatus(RecordingCardAutoSyncStatus.verifying);
      final verification = _syncPlanner.verify(
        plan: syncPlan,
        verifiedDirectory: verifiedFiles,
        ledger: ledgerPersistence.loadFileLedger(cardSnDigest),
      );
      if (verification.needsReplan) {
        _waitingPlan = null;
        _sessionMachine.requestReplan();
        _triggerGate.signal(RecordingCardSyncTrigger.directoryRefreshed);
        _rescheduleRequested = true;
        return;
      }
      if (!verification.canCommit) {
        if (transientRetryScheduled) {
          _waitForRetry(cardSnDigest);
          return;
        }
        const code = 'RECORDING_CARD_AUTO_SYNC_VERIFICATION_INCOMPLETE';
        _sessionMachine.fail(code);
        _fail(code);
        return;
      }
      if (_stopForCardIdentityChange(cardSnDigest)) return;
      _sessionMachine.verificationAccepted();
      _setStatus(RecordingCardAutoSyncStatus.committing);
      final previousCheckpoint = ledgerPersistence.loadSyncCheckpoint(
        cardSnDigest,
      );
      final checkpoint = _syncPlanner.buildCommittedCheckpoint(
        plan: syncPlan,
        verification: verification,
        previous: ledgerPersistence.loadSyncCheckpoint(cardSnDigest),
        committedAt: _clock().toUtc(),
      );
      _pendingCheckpointCardSnDigest = cardSnDigest;
      _checkpointBeforePendingCommit = previousCheckpoint;
      try {
        ledgerPersistence.commitVerifiedSync(
          entries: ledgerPersistence.loadFileLedger(cardSnDigest),
          checkpoint: checkpoint,
        );
        await ledgerPersistence.flushSyncPersistence();
      } on Object {
        if (previousCheckpoint != null) {
          ledgerPersistence.saveSyncCheckpoint(previousCheckpoint);
        }
        token.throwIfCancelled();
        if (_disposed || _paused || !_state.preferences.autoSyncEnabled) return;
        if (_stopForCardIdentityChange(cardSnDigest)) return;
        _waitForPrerequisite(
          RecordingCardSyncWaitingReason.persistenceRequired,
          cardSnDigest: cardSnDigest,
          recoveryPlan: syncPlan,
        );
        return;
      } finally {
        _pendingCheckpointCardSnDigest = null;
        _checkpointBeforePendingCommit = null;
      }
      token.throwIfCancelled();
      if (_disposed || _stopForCardIdentityChange(cardSnDigest)) return;
      if (_sessionMachine.state.status !=
          RecordingCardSyncSessionStatus.committing) {
        return;
      }
      _waitingPlan = null;
      _sessionMachine.committed();
      if (_transcriptionOperations.isNotEmpty ||
          _state.tasks.any(
            (task) =>
                task.cardSnDigest == cardSnDigest &&
                task.state == RecordingCardAutoSyncTaskState.transcribing,
          )) {
        _setStatus(RecordingCardAutoSyncStatus.transcribing);
      } else {
        _setStatus(RecordingCardAutoSyncStatus.completed);
      }
      return;
    }
    _mergeTasks(fingerprint, verifiedFiles);
    final hasUnsyncedFiles = verifiedFiles.any(
      (file) => file.syncState != RecordingCardFileSyncState.synced,
    );
    final needsAnotherPass = _state.tasks.any(
      (task) =>
          task.deviceFingerprint == fingerprint &&
          !task.isTerminal &&
          task.state != RecordingCardAutoSyncTaskState.failed,
    );
    final failed = _state.tasks
        .where(
          (task) =>
              task.deviceFingerprint == fingerprint &&
              task.state == RecordingCardAutoSyncTaskState.failed,
        )
        .firstOrNull;
    if (hasUnsyncedFiles) {
      if (needsAnotherPass) {
        _rescheduleRequested = true;
      } else {
        _fail(
          failed?.errorCode ??
              'RECORDING_CARD_AUTO_SYNC_VERIFICATION_INCOMPLETE',
        );
      }
      return;
    }
    if (failed != null) {
      _fail(failed.errorCode ?? 'RECORDING_CARD_AUTO_SYNC_FAILED');
    } else if (_transcriptionOperations.isNotEmpty ||
        _state.tasks.any(
          (task) => task.state == RecordingCardAutoSyncTaskState.transcribing,
        )) {
      _setStatus(RecordingCardAutoSyncStatus.transcribing);
    } else {
      _state = _state.copyWith(
        status: RecordingCardAutoSyncStatus.completed,
        clearActiveTask: true,
        clearError: true,
        clearWaitingReason: true,
      );
      notifyListeners();
    }
  }

  void _mergeTasks(String fingerprint, List<RecordingCardScannedFile> files) {
    if (_disposed) return;
    final byIdentity = <String, RecordingCardAutoSyncTask>{
      for (final task in _state.tasks)
        '${task.deviceFingerprint}:${task.deviceFileId}': task,
    };
    final now = _clock().toUtc();
    for (var index = 0; index < files.length; index += 1) {
      final file = files[index];
      if (file.syncState == RecordingCardFileSyncState.synced) continue;
      final identity = '$fingerprint:${file.deviceFileId}';
      final existing = byIdentity[identity];
      final metadataChanged =
          existing != null &&
          (existing.deviceFilename != file.deviceFilename ||
              existing.localFileKey != file.localFileKey ||
              existing.expectedSizeBytes != file.sizeBytes);
      if (existing != null) {
        if (!existing.isTerminal && !metadataChanged) continue;
      }
      final task = RecordingCardAutoSyncTask(
        taskId: existing?.taskId ?? _taskId(fingerprint, file.deviceFileId),
        deviceFingerprint: fingerprint,
        deviceFileId: file.deviceFileId,
        deviceFilename: file.deviceFilename,
        localFileKey: file.localFileKey,
        order: index,
        state: RecordingCardAutoSyncTaskState.queued,
        attemptCount: 0,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        expectedSizeBytes: file.sizeBytes,
        transcriptionRequested:
            existing?.transcriptionRequested ??
            _state.preferences.autoTranscriptionEnabled,
      );
      byIdentity[identity] = task;
      _persistence.saveTask(task);
    }
    final tasks = byIdentity.values.toList(growable: false)
      ..sort((left, right) {
        final order = left.order.compareTo(right.order);
        return order != 0 ? order : left.taskId.compareTo(right.taskId);
      });
    _state = _state.copyWith(tasks: List.unmodifiable(tasks));
    notifyListeners();
  }

  void _mergePlannedTasks(
    String fingerprint,
    RecordingCardSyncPlan plan,
    List<RecordingCardScannedFile> files,
  ) {
    if (_disposed) return;
    final existingBySource = <String, RecordingCardAutoSyncTask>{
      for (final task in _state.tasks)
        if (task.sourceSignature != null) task.sourceSignature!: task,
    };
    final existingByLegacyIdentity = <String, RecordingCardAutoSyncTask>{
      for (final task in _state.tasks)
        '${task.deviceFingerprint}:${task.deviceFileId}': task,
    };
    final byTaskId = <String, RecordingCardAutoSyncTask>{
      for (final task in _state.tasks) task.taskId: task,
    };
    final now = _clock().toUtc();
    for (var index = 0; index < plan.candidates.length; index += 1) {
      final candidate = plan.candidates[index];
      final entry = candidate.entry;
      final file = files
          .where(
            (value) =>
                value.deviceFileId == entry.deviceFileId &&
                value.deviceFilename == entry.deviceFilename,
          )
          .firstOrNull;
      if (file == null) continue;
      final existing =
          existingBySource[entry.sourceSignature] ??
          existingByLegacyIdentity['$fingerprint:${entry.deviceFileId}'];
      final task = RecordingCardAutoSyncTask(
        taskId:
            existing?.taskId ??
            _taskId(plan.cardSnDigest, entry.sourceSignature),
        deviceFingerprint: fingerprint,
        deviceFileId: entry.deviceFileId,
        deviceFilename: entry.deviceFilename,
        localFileKey: file.localFileKey,
        order: index,
        state: RecordingCardAutoSyncTaskState.queued,
        attemptCount: entry.attemptCount,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        expectedSizeBytes: entry.sizeBytes,
        cardSnDigest: plan.cardSnDigest,
        sourceSignature: entry.sourceSignature,
        recordedAt: entry.recordedAt,
        contentHash: entry.contentHash ?? file.contentHash,
        localRecordingId: existing?.localRecordingId,
        transcriptionRequested:
            existing?.transcriptionRequested ??
            _state.preferences.autoTranscriptionEnabled,
      );
      byTaskId[task.taskId] = task;
      _persistence.saveTask(task);
    }
    final tasks = byTaskId.values.toList(growable: false)
      ..sort((left, right) {
        final order = left.order.compareTo(right.order);
        return order != 0 ? order : left.taskId.compareTo(right.taskId);
      });
    _state = _state.copyWith(tasks: List.unmodifiable(tasks));
    notifyListeners();
  }

  void _reconcileTasksWithLedger(
    String cardSnDigest,
    Iterable<RecordingCardFileLedgerEntry> entries,
  ) {
    if (_disposed) return;
    final ledgerBySource = <String, RecordingCardFileLedgerEntry>{
      for (final entry in entries) entry.sourceSignature: entry,
    };
    final now = _clock().toUtc();
    var changed = false;
    final tasks = <RecordingCardAutoSyncTask>[
      for (final task in _state.tasks)
        _reconciledTask(task, cardSnDigest, ledgerBySource, now),
    ];
    for (var index = 0; index < tasks.length; index += 1) {
      if (!identical(tasks[index], _state.tasks[index])) {
        changed = true;
        _persistence.saveTask(tasks[index]);
      }
    }
    if (!changed) return;
    _state = _state.copyWith(tasks: List.unmodifiable(tasks));
    notifyListeners();
  }

  void _reconcileKnownTasksWithLedger() {
    final persistence = _ledgerPersistence;
    if (persistence == null) return;
    for (final cardSnDigest in persistence.loadKnownCardDigests()) {
      _reconcileTasksWithLedger(
        cardSnDigest,
        persistence.loadFileLedger(cardSnDigest),
      );
    }
  }

  RecordingCardAutoSyncTask _reconciledTask(
    RecordingCardAutoSyncTask task,
    String cardSnDigest,
    Map<String, RecordingCardFileLedgerEntry> ledgerBySource,
    DateTime now,
  ) {
    final sourceSignature = task.sourceSignature;
    if (task.isTerminal ||
        task.cardSnDigest != cardSnDigest ||
        sourceSignature == null) {
      return task;
    }
    final entry = ledgerBySource[sourceSignature];
    if (entry == null) return task;

    final localRecordingId = entry.localRecordingId?.trim();
    final taskLocalRecordingId = task.localRecordingId?.trim();
    final hasActiveDownstreamWork =
        task.transcriptionRequested &&
        taskLocalRecordingId != null &&
        taskLocalRecordingId.isNotEmpty &&
        (task.state == RecordingCardAutoSyncTaskState.downloaded ||
            task.state == RecordingCardAutoSyncTaskState.transcribing ||
            task.state == RecordingCardAutoSyncTaskState.failed);
    if (hasActiveDownstreamWork) return task;

    if (entry.hasValidLocalRecording &&
        localRecordingId != null &&
        localRecordingId.isNotEmpty) {
      return task.copyWith(
        state: task.transcriptionRequested
            ? RecordingCardAutoSyncTaskState.downloaded
            : RecordingCardAutoSyncTaskState.completed,
        attemptCount: entry.attemptCount,
        updatedAt: now,
        localRecordingId: localRecordingId,
        contentHash: entry.contentHash,
        clearError: true,
        clearRetryability: true,
        clearNextRetryAt: true,
      );
    }

    if (entry.cardState == RecordingCardFilePresenceState.deleted ||
        entry.localState == RecordingCardFileLocalState.localDeleted ||
        entry.localState == RecordingCardFileLocalState.legacyUnknown) {
      return task.copyWith(
        state: RecordingCardAutoSyncTaskState.completed,
        attemptCount: entry.attemptCount,
        updatedAt: now,
        clearError: true,
        clearRetryability: true,
        clearNextRetryAt: true,
      );
    }

    if (entry.localState == RecordingCardFileLocalState.failed) {
      return task.copyWith(
        state: RecordingCardAutoSyncTaskState.failed,
        attemptCount: entry.attemptCount,
        updatedAt: now,
        errorCode:
            entry.errorCode ?? 'RECORDING_CARD_AUTO_SYNC_DOWNLOAD_FAILED',
        retryability: entry.retryability,
        nextRetryAt: entry.nextRetryAt,
        clearNextRetryAt: entry.nextRetryAt == null,
      );
    }
    return task;
  }

  void _markLedgerSyncing(RecordingCardAutoSyncTask task) {
    final persistence = _ledgerPersistence;
    final cardSnDigest = task.cardSnDigest;
    final sourceSignature = task.sourceSignature;
    if (persistence == null ||
        cardSnDigest == null ||
        sourceSignature == null) {
      return;
    }
    final entry = persistence.findFileLedgerEntry(
      cardSnDigest: cardSnDigest,
      sourceSignature: sourceSignature,
    );
    if (entry == null) {
      throw StateError('Automatic sync task has no file-ledger entry');
    }
    persistence.saveFileLedgerEntry(entry.beginSync(_clock().toUtc()));
  }

  void _markLedgerSynced(
    RecordingCardAutoSyncTask task, {
    required String localRecordingId,
    String? contentHash,
  }) {
    final persistence = _ledgerPersistence;
    final cardSnDigest = task.cardSnDigest;
    final sourceSignature = task.sourceSignature;
    if (persistence == null ||
        cardSnDigest == null ||
        sourceSignature == null) {
      return;
    }
    final entry = persistence.findFileLedgerEntry(
      cardSnDigest: cardSnDigest,
      sourceSignature: sourceSignature,
    );
    if (entry == null) {
      throw StateError('Automatic sync task has no file-ledger entry');
    }
    persistence.saveFileLedgerEntry(
      entry.markSynced(
        at: _clock().toUtc(),
        localRecordingId: localRecordingId,
        contentHash: contentHash ?? task.contentHash,
      ),
    );
  }

  void _markLedgerFailed(
    RecordingCardAutoSyncTask task, {
    required String errorCode,
    required RecordingCardSyncRetryability retryability,
    DateTime? nextRetryAt,
  }) {
    final persistence = _ledgerPersistence;
    final cardSnDigest = task.cardSnDigest;
    final sourceSignature = task.sourceSignature;
    if (persistence == null ||
        cardSnDigest == null ||
        sourceSignature == null) {
      return;
    }
    final entry = persistence.findFileLedgerEntry(
      cardSnDigest: cardSnDigest,
      sourceSignature: sourceSignature,
    );
    if (entry == null) {
      throw StateError('Automatic sync task has no file-ledger entry');
    }
    persistence.saveFileLedgerEntry(
      entry.markFailed(
        at: _clock().toUtc(),
        errorCode: errorCode,
        retryability: retryability,
        nextRetryAt: nextRetryAt,
      ),
    );
  }

  void _deferDownloadForPrerequisite({
    required RecordingCardAutoSyncTask queued,
    required RecordingCardAutoSyncTask downloading,
  }) {
    final persistence = _ledgerPersistence;
    final cardSnDigest = downloading.cardSnDigest;
    final sourceSignature = downloading.sourceSignature;
    if (persistence != null &&
        cardSnDigest != null &&
        sourceSignature != null) {
      final entry = persistence.findFileLedgerEntry(
        cardSnDigest: cardSnDigest,
        sourceSignature: sourceSignature,
      );
      if (entry?.localState == RecordingCardFileLocalState.syncing) {
        persistence.saveFileLedgerEntry(
          entry!.deferForPrerequisite(_clock().toUtc()),
        );
      }
    }
    _updateTask(
      downloading.copyWith(
        state: RecordingCardAutoSyncTaskState.queued,
        attemptCount: queued.attemptCount,
        updatedAt: _clock().toUtc(),
        clearError: true,
        clearRetryability: true,
        clearNextRetryAt: true,
      ),
    );
  }

  bool _waitForFailurePrerequisite(
    AppFailure? failure, {
    required String cardSnDigest,
    RecordingCardSyncPlan? recoveryPlan,
  }) {
    final reason = _prerequisiteWaitingReason(failure);
    if (reason == null) return false;
    _waitForPrerequisite(
      reason,
      cardSnDigest: cardSnDigest,
      recoveryPlan: recoveryPlan,
    );
    return true;
  }

  void _waitForPrerequisite(
    RecordingCardSyncWaitingReason reason, {
    required String cardSnDigest,
    RecordingCardSyncPlan? recoveryPlan,
  }) {
    _waitingPlan = recoveryPlan;
    _sessionMachine.waitFor(reason, cardSnDigest: cardSnDigest);
    _state = _state.copyWith(
      status: reason == RecordingCardSyncWaitingReason.deviceDisconnected
          ? RecordingCardAutoSyncStatus.waitingForDevice
          : RecordingCardAutoSyncStatus.idle,
      waitingReason: reason,
      clearActiveTask: true,
      clearError: true,
    );
    notifyListeners();
  }

  void _scheduleTransientRetry(
    RecordingCardAutoSyncTask failedTask,
    Duration delay,
  ) {
    if (!_scheduledRetryTaskIds.add(failedTask.taskId)) return;
    unawaited(
      (() async {
        try {
          if (delay > Duration.zero) await _retryDelay(delay);
          if (_disposed ||
              _paused ||
              !_state.preferences.autoSyncEnabled ||
              _cardDigestFor(_actions.snapshot) != failedTask.cardSnDigest) {
            return;
          }
          final latest = _state.tasks
              .where((task) => task.taskId == failedTask.taskId)
              .firstOrNull;
          if (latest == null ||
              latest.state != RecordingCardAutoSyncTaskState.failed ||
              latest.retryability != RecordingCardSyncRetryability.transient ||
              !_retryPolicy.canAttempt(latest.attemptCount)) {
            return;
          }
          final persistence = _ledgerPersistence;
          final cardSnDigest = latest.cardSnDigest;
          final sourceSignature = latest.sourceSignature;
          if (persistence == null ||
              cardSnDigest == null ||
              sourceSignature == null) {
            return;
          }
          final entry = persistence.findFileLedgerEntry(
            cardSnDigest: cardSnDigest,
            sourceSignature: sourceSignature,
          );
          if (entry == null ||
              entry.localState != RecordingCardFileLocalState.failed ||
              entry.retryability != RecordingCardSyncRetryability.transient) {
            return;
          }
          persistence.saveFileLedgerEntry(
            entry.queue(
              at: _clock().toUtc(),
              manual: false,
              resetAttemptCount: false,
            ),
          );
          _updateTask(
            latest.copyWith(
              state: RecordingCardAutoSyncTaskState.queued,
              updatedAt: _clock().toUtc(),
              clearError: true,
              clearRetryability: true,
              clearNextRetryAt: true,
            ),
          );
          _signalAndSchedule(RecordingCardSyncTrigger.transientRetryReady);
        } finally {
          _scheduledRetryTaskIds.remove(failedTask.taskId);
        }
      })(),
    );
  }

  void _schedulePersistedTransientRetries(String cardSnDigest) {
    final now = _clock().toUtc();
    for (final task in _state.tasks) {
      if (task.cardSnDigest != cardSnDigest ||
          task.state != RecordingCardAutoSyncTaskState.failed ||
          task.retryability != RecordingCardSyncRetryability.transient ||
          !_retryPolicy.canAttempt(task.attemptCount)) {
        continue;
      }
      final retryAt = task.nextRetryAt;
      final delay = retryAt != null && retryAt.isAfter(now)
          ? retryAt.difference(now)
          : Duration.zero;
      _scheduleTransientRetry(task, delay);
    }
  }

  void _waitForRetry(String cardSnDigest) {
    _sessionMachine.waitFor(
      RecordingCardSyncWaitingReason.retryBackoff,
      cardSnDigest: cardSnDigest,
    );
    _setStatus(RecordingCardAutoSyncStatus.waitingForRetry);
  }

  Future<bool> _flushPlanPersistence(
    RecordingCardSyncLedgerPersistencePort persistence,
    RecordingCardSyncPlan plan,
    AppTaskCancellationToken token,
  ) async {
    try {
      await persistence.flushSyncPersistence();
      return true;
    } on Object {
      token.throwIfCancelled();
      if (!_disposed &&
          !_paused &&
          _state.preferences.autoSyncEnabled &&
          !_stopForCardIdentityChange(plan.cardSnDigest)) {
        _waitForPrerequisite(
          RecordingCardSyncWaitingReason.persistenceRequired,
          cardSnDigest: plan.cardSnDigest,
          recoveryPlan: plan,
        );
      }
      return false;
    }
  }

  Future<bool> _flushSettledFilePersistence(
    String cardSnDigest,
    RecordingCardSyncPlan? recoveryPlan,
  ) async {
    if (await _flushInterruptedPersistence()) return true;
    if (!_disposed &&
        !_paused &&
        _state.preferences.autoSyncEnabled &&
        _cardDigestFor(_actions.snapshot) == cardSnDigest) {
      _waitForPrerequisite(
        RecordingCardSyncWaitingReason.persistenceRequired,
        cardSnDigest: cardSnDigest,
        recoveryPlan: recoveryPlan,
      );
    }
    return false;
  }

  Future<bool> _flushInterruptedPersistence() async {
    final persistence = _ledgerPersistence;
    if (persistence == null) return true;
    try {
      await persistence.flushSyncPersistence();
      return true;
    } on Object {
      return false;
    }
  }

  void _recoverActiveLedgerSyncs() {
    if (_actions.hasActiveTransfer && !_suppressOwnedActionReschedule) {
      return;
    }
    final cardSnDigest = _sessionMachine.state.cardSnDigest;
    if (cardSnDigest == null) return;
    final now = _clock().toUtc();
    final persistence = _ledgerPersistence;
    if (persistence != null) {
      final ledger = persistence.loadFileLedger(cardSnDigest);
      final recoveredLedger = <RecordingCardFileLedgerEntry>[
        for (final entry in ledger)
          if (entry.localState == RecordingCardFileLocalState.syncing)
            entry.deferForPrerequisite(now)
          else
            entry,
      ];
      persistence.saveFileLedgerEntries(recoveredLedger);
    }
    final recoveredTasks = <RecordingCardAutoSyncTask>[
      for (final task in _state.tasks)
        if (task.cardSnDigest == cardSnDigest &&
            task.state == RecordingCardAutoSyncTaskState.downloading)
          task.copyWith(
            state: RecordingCardAutoSyncTaskState.queued,
            attemptCount: task.attemptCount > 0 ? task.attemptCount - 1 : 0,
            updatedAt: now,
            clearError: true,
            clearRetryability: true,
            clearNextRetryAt: true,
          )
        else
          task,
    ];
    for (final task in recoveredTasks) {
      if (task.cardSnDigest == cardSnDigest) _persistence.saveTask(task);
    }
    _state = _state.copyWith(tasks: List.unmodifiable(recoveredTasks));
  }

  bool _stopForCardIdentityChange(String expectedCardSnDigest) {
    if (_cardDigestFor(_actions.snapshot) == expectedCardSnDigest) return false;
    _recoverActiveLedgerSyncs();
    unawaited(_flushInterruptedPersistence());
    _sessionMachine.waitFor(
      RecordingCardSyncWaitingReason.cardIdentityChanged,
      cardSnDigest: expectedCardSnDigest,
    );
    _setStatus(RecordingCardAutoSyncStatus.waitingForDevice);
    return true;
  }

  void _updateTask(RecordingCardAutoSyncTask task) {
    if (_disposed) return;
    _persistence.saveTask(task);
    final tasks = <RecordingCardAutoSyncTask>[
      for (final existing in _state.tasks)
        if (existing.taskId == task.taskId) task else existing,
    ];
    _state = _state.copyWith(tasks: List.unmodifiable(tasks));
    notifyListeners();
  }

  void _resumeLocalTranscriptions() {
    if (_disposed) return;
    for (final task in List<RecordingCardAutoSyncTask>.from(_state.tasks)) {
      if (task.isTerminal ||
          task.state == RecordingCardAutoSyncTaskState.failed ||
          !task.transcriptionRequested) {
        continue;
      }
      final localRecordingId = task.localRecordingId?.trim();
      if (localRecordingId == null || localRecordingId.isEmpty) continue;
      _startTranscriptionTask(task, localRecordingId);
    }
  }

  void _startTranscriptionTask(
    RecordingCardAutoSyncTask task,
    String localRecordingId,
  ) {
    if (_disposed || _transcriptionOperations.containsKey(task.taskId)) return;
    final port = _transcriptionPort;
    if (port == null) {
      const code = 'RECORDING_CARD_AUTO_TRANSCRIPTION_UNAVAILABLE';
      final failed = task.copyWith(
        state: RecordingCardAutoSyncTaskState.failed,
        updatedAt: _clock().toUtc(),
        errorCode: code,
      );
      _updateTask(failed);
      _settleAfterTranscription();
      return;
    }
    final transcribing = task.copyWith(
      state: RecordingCardAutoSyncTaskState.transcribing,
      updatedAt: _clock().toUtc(),
      localRecordingId: localRecordingId,
      transcriptionRequested: true,
      clearError: true,
    );
    final operation = _beginTranscription(port, localRecordingId);
    _transcriptionOperations[task.taskId] = operation;
    _updateTask(transcribing);
    _settleAfterTranscription();
    unawaited(
      _runTranscriptionOperation(
        taskId: task.taskId,
        localRecordingId: localRecordingId,
        operation: operation,
      ),
    );
  }

  RecordingCardAutoTranscriptionOperation _beginTranscription(
    RecordingCardAutoTranscriptionPort port,
    String localRecordingId,
  ) {
    try {
      if (port is RecordingCardAutoTranscriptionOperationPort) {
        return port.startTranscription(localRecordingId);
      }
      return RecordingCardAutoTranscriptionOperation(
        result: port.transcribe(localRecordingId),
      );
    } on Object catch (error, stackTrace) {
      return RecordingCardAutoTranscriptionOperation(
        result: Future<RecordingCardResult<bool>>.error(error, stackTrace),
      );
    }
  }

  Future<void> _runTranscriptionOperation({
    required String taskId,
    required String localRecordingId,
    required RecordingCardAutoTranscriptionOperation operation,
  }) async {
    RecordingCardResult<bool> result;
    try {
      result = await operation.result;
    } on Object {
      result = RecordingCardResult<bool>.failure(
        _transcriptionFailure(
          'RECORDING_CARD_AUTO_TRANSCRIPTION_UNEXPECTED_FAILURE',
        ),
      );
    }
    if (_disposed || !identical(_transcriptionOperations[taskId], operation)) {
      return;
    }
    _transcriptionOperations.remove(taskId);
    final latest = _state.tasks
        .where((task) => task.taskId == taskId)
        .firstOrNull;
    if (latest == null ||
        latest.isTerminal ||
        latest.state == RecordingCardAutoSyncTaskState.failed ||
        latest.localRecordingId?.trim() != localRecordingId) {
      _settleAfterTranscription();
      return;
    }
    if (!result.ok || result.value != true) {
      final code =
          result.error?.code ?? 'RECORDING_CARD_AUTO_TRANSCRIPTION_FAILED';
      _updateTask(
        latest.copyWith(
          state: RecordingCardAutoSyncTaskState.failed,
          updatedAt: _clock().toUtc(),
          errorCode: code,
        ),
      );
      _settleAfterTranscription();
      return;
    }
    _completeTask(latest);
    _settleAfterTranscription();
  }

  void _settleAfterTranscription() {
    if (_disposed ||
        _runInFlight != null ||
        _paused ||
        !_state.preferences.autoSyncEnabled ||
        _sessionMachine.state.waitingReason ==
            RecordingCardSyncWaitingReason.persistenceRequired ||
        (_state.pendingFileSyncCount > 0 &&
            _sessionMachine.state.status ==
                RecordingCardSyncSessionStatus.waiting)) {
      return;
    }
    if (_transcriptionOperations.isNotEmpty) {
      _setStatus(RecordingCardAutoSyncStatus.transcribing);
      return;
    }
    final failed = _state.tasks
        .where(
          (task) =>
              task.state == RecordingCardAutoSyncTaskState.failed &&
              task.transcriptionRequested &&
              (task.localRecordingId?.trim().isNotEmpty ?? false),
        )
        .firstOrNull;
    if (failed != null) {
      _state = _state.copyWith(
        status: RecordingCardAutoSyncStatus.failed,
        lastErrorCode:
            failed.errorCode ?? 'RECORDING_CARD_AUTO_TRANSCRIPTION_FAILED',
        clearActiveTask: true,
      );
      notifyListeners();
      return;
    }
    if (_state.tasks.isNotEmpty &&
        _state.tasks.every((task) => task.isTerminal)) {
      _setStatus(RecordingCardAutoSyncStatus.completed);
      return;
    }
    if (!_actions.snapshot.deviceState.isOperationallyConnected) {
      _setStatus(RecordingCardAutoSyncStatus.waitingForDevice);
      return;
    }
    if (_runInFlight == null &&
        _state.preferences.autoSyncEnabled &&
        !_paused) {
      _schedule();
    }
  }

  void _cancelAutoSync(String reason) {
    _rescheduleRequested = false;
    _taskOrchestrator.cancel(autoSyncTaskKey, reason: reason);
  }

  void _handleRunError(Object error) {
    if (_disposed) return;
    if (error is AppTaskCancelledException) {
      _recoverActiveLedgerSyncs();
      unawaited(_flushInterruptedPersistence());
      if (_paused) {
        _settlePauseIfQuiescent();
      } else if (!_state.preferences.autoSyncEnabled) {
        _sessionMachine.disable();
        _setStatus(RecordingCardAutoSyncStatus.idle);
      } else if (!_actions.snapshot.deviceState.isOperationallyConnected) {
        _sessionMachine.waitFor(
          RecordingCardSyncWaitingReason.deviceDisconnected,
        );
        _setStatus(
          _transcriptionOperations.isNotEmpty &&
                  _state.pendingFileSyncCount == 0
              ? RecordingCardAutoSyncStatus.transcribing
              : RecordingCardAutoSyncStatus.waitingForDevice,
        );
      } else if (!_taskOrchestrator.isForeground) {
        _sessionMachine.waitFor(RecordingCardSyncWaitingReason.appBackground);
        _setStatus(
          _transcriptionOperations.isNotEmpty &&
                  _state.pendingFileSyncCount == 0
              ? RecordingCardAutoSyncStatus.transcribing
              : RecordingCardAutoSyncStatus.idle,
        );
      } else if (_transcriptionOperations.isNotEmpty) {
        _setStatus(RecordingCardAutoSyncStatus.transcribing);
      }
      return;
    }
    _fail('RECORDING_CARD_AUTO_SYNC_UNEXPECTED_FAILURE');
  }

  void _completeTask(RecordingCardAutoSyncTask task) {
    _updateTask(
      task.copyWith(
        state: RecordingCardAutoSyncTaskState.completed,
        updatedAt: _clock().toUtc(),
        clearError: true,
      ),
    );
  }

  Future<T> _runOwnedAction<T>(Future<T> Function() action) async {
    _suppressOwnedActionReschedule = true;
    try {
      return await action();
    } finally {
      _suppressOwnedActionReschedule = false;
    }
  }

  void _consumePlanningRefreshRevision() {
    final actions = _actions;
    if (actions is! RecordingCardSuccessfulFileRefreshActions) return;
    final revision = (actions as RecordingCardSuccessfulFileRefreshActions)
        .successfulFileRefreshRevision;
    if (revision > _plannedFileRefreshRevision) {
      _plannedFileRefreshRevision = revision;
    }
  }

  void _setStatus(RecordingCardAutoSyncStatus status) {
    if (_disposed) return;
    if (_state.status == status && _state.lastErrorCode == null) return;
    _state = _state.copyWith(
      status: status,
      clearActiveTask:
          status != RecordingCardAutoSyncStatus.downloading &&
          status != RecordingCardAutoSyncStatus.transcribing &&
          status != RecordingCardAutoSyncStatus.paused,
      clearError: true,
      clearWaitingReason: true,
    );
    notifyListeners();
  }

  void _fail(String code) {
    if (_disposed) return;
    _waitingPlan = null;
    if (_sessionMachine.state.status !=
            RecordingCardSyncSessionStatus.completed &&
        _sessionMachine.state.status != RecordingCardSyncSessionStatus.paused) {
      _sessionMachine.fail(code);
    }
    _state = _state.copyWith(
      status: RecordingCardAutoSyncStatus.failed,
      lastErrorCode: code,
      clearActiveTask: true,
      clearWaitingReason: true,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelAutoSync('recording-card-auto-sync-disposed');
    _recoverActiveLedgerSyncs();
    for (final operation in _transcriptionOperations.values) {
      operation.cancel();
    }
    _transcriptionOperations.clear();
    for (final operation in _backfillTranscriptionOperations) {
      operation.cancel();
    }
    _backfillTranscriptionOperations.clear();
    _backgroundGeneration += 1;
    _backgroundRequest =
        const RecordingCardBackgroundExecutionRequest.disabled();
    _actions.removeListener(_onActionsChanged);
    final port = _backgroundExecutionPort;
    if (port != null) {
      unawaited(
        port
            .update(const RecordingCardBackgroundExecutionRequest.disabled())
            .catchError(
              (Object _) =>
                  const RecordingCardBackgroundExecutionCapability.appResumeOnly(
                    enabled: false,
                  ),
            ),
      );
    }
    if (_ownsTaskOrchestrator) _taskOrchestrator.dispose();
    super.dispose();
  }
}

String _taskId(String fingerprint, String fileId) {
  String safe(String value) {
    final normalized = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (normalized.length <= 60) return normalized;
    return normalized.substring(0, 60);
  }

  return 'recording-card-auto:${safe(fingerprint)}:${safe(fileId)}';
}

bool _isObjectivePrerequisite(RecordingCardSyncWaitingReason? reason) =>
    reason == RecordingCardSyncWaitingReason.networkRequired ||
    reason == RecordingCardSyncWaitingReason.permissionRequired ||
    reason == RecordingCardSyncWaitingReason.storageInsufficient ||
    reason == RecordingCardSyncWaitingReason.persistenceRequired;

bool _containsRestorationTrigger(
  Set<RecordingCardSyncTrigger> triggers,
  RecordingCardSyncWaitingReason reason,
) {
  if (triggers.contains(RecordingCardSyncTrigger.explicitRetry) ||
      triggers.contains(RecordingCardSyncTrigger.appResumed) ||
      triggers.contains(RecordingCardSyncTrigger.autoSyncEnabled)) {
    return true;
  }
  return switch (reason) {
    RecordingCardSyncWaitingReason.networkRequired => triggers.contains(
      RecordingCardSyncTrigger.networkRestored,
    ),
    RecordingCardSyncWaitingReason.permissionRequired => triggers.contains(
      RecordingCardSyncTrigger.permissionRestored,
    ),
    RecordingCardSyncWaitingReason.persistenceRequired => triggers.contains(
      RecordingCardSyncTrigger.persistenceRestored,
    ),
    RecordingCardSyncWaitingReason.storageInsufficient => triggers.contains(
      RecordingCardSyncTrigger.storageRestored,
    ),
    _ => false,
  };
}

RecordingCardSyncWaitingReason? _prerequisiteWaitingReason(
  AppFailure? failure,
) {
  if (failure == null) return null;
  final code = failure.code.trim().toUpperCase();
  if (code == 'RECORDING_CARD_DISCONNECTED' ||
      code == 'RECORDING_CARD_NOT_CONNECTED') {
    return RecordingCardSyncWaitingReason.deviceDisconnected;
  }
  if (failure.category == AppFailureCategory.permission ||
      ((code.contains('BLUETOOTH') || code.contains('WIFI')) &&
          (code.contains('PERMISSION_REQUIRED') ||
              code.contains('UNAUTHORIZED')))) {
    return RecordingCardSyncWaitingReason.permissionRequired;
  }
  if (failure.category == AppFailureCategory.network ||
      code.contains('NETWORK_UNAVAILABLE') ||
      code.contains('NETWORK_REQUIRED') ||
      code == 'OFFLINE') {
    return RecordingCardSyncWaitingReason.networkRequired;
  }
  if (code == 'RECORDING_CARD_LOCAL_STORAGE_FAILED' ||
      code.contains('INSUFFICIENT_STORAGE') ||
      code.contains('STORAGE_INSUFFICIENT') ||
      code.contains('STORAGE_FULL') ||
      code.contains('DISK_FULL') ||
      code.contains('NO_SPACE') ||
      code.contains('ENOSPC')) {
    return RecordingCardSyncWaitingReason.storageInsufficient;
  }
  return null;
}

AppFailure _failure(String code) => AppFailure(
  code: code,
  category: AppFailureCategory.compatibility,
  message: 'Recording-card automatic synchronization failed',
  userMessageKey: 'recordingCard.autoSync.failed',
  isRetryable: true,
);

AppFailure _transcriptionFailure(String code) => AppFailure(
  code: code,
  category: AppFailureCategory.api,
  message: 'Recording-card transcription could not enter shared processing',
  userMessageKey: 'recordingCard.autoTranscription.failed',
  isRetryable: true,
  recoveryActions: const <String>['retry'],
);

String _completionErrorCode(String? code, String fallback) {
  final normalized = code?.trim();
  return normalized == null || normalized.isEmpty ? fallback : normalized;
}

RecordingCardSyncLedgerPersistencePort? _asLedgerPersistence(
  RecordingCardAutoSyncPersistencePort persistence,
) {
  if (persistence is! RecordingCardSyncLedgerPersistencePort) return null;
  return persistence as RecordingCardSyncLedgerPersistencePort;
}

String? _cardDigestFor(RecordingCardRuntimeSnapshot snapshot) {
  final serial = snapshot.deviceState.serialNumber;
  if (serial == null) return null;
  final normalized = normalizeRecordingCardSerialNumberForOwnership(serial);
  return normalized == null
      ? null
      : RecordingCardFileIdentity.digestSerialNumber(normalized);
}

String _directorySnapshotHash(
  String cardSnDigest,
  Iterable<RecordingCardScannedFile> files,
) => RecordingCardFileIdentity.snapshotHash(<String>[
  for (final file in files)
    RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: cardSnDigest,
      deviceFileId: file.deviceFileId,
      deviceFilename: file.deviceFilename,
      sizeBytes: file.sizeBytes,
      recordedAt: file.recordedAt,
    ),
]);
