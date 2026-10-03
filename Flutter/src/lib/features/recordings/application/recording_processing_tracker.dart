import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/storage/upload_draft_store.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../data/recording_api.dart';
import '../domain/recording_batch_transcription.dart';
import '../domain/recording_library.dart';

/// Narrow handoff from upload completion to the server-owned recording flow.
abstract interface class RecordingProcessingPort {
  Future<void> track(UploadDraft draft);
}

/// Re-enrolls a durable local checkpoint after its detail page receives an
/// authorized retry acknowledgement from the server.
abstract interface class RecordingProcessingRetryPort {
  Future<bool> reenrollAfterRetry(String recordingId);
}

enum RecordingProcessingCompletionStatus { completed, failed, unavailable }

enum RecordingProcessingPhase {
  transcribing,
  storingCloudNote,
  completed,
  failed,
}

final class RecordingProcessingCompletion {
  const RecordingProcessingCompletion({required this.status, this.errorCode});

  final RecordingProcessingCompletionStatus status;
  final String? errorCode;
}

final class RecordingProcessingCompletionSubscription {
  RecordingProcessingCompletionSubscription({
    required this.completion,
    required VoidCallback onCancel,
  }) : _onCancel = onCancel;

  final Future<RecordingProcessingCompletion> completion;
  VoidCallback? _onCancel;

  void cancel() {
    final onCancel = _onCancel;
    _onCancel = null;
    onCancel?.call();
  }
}

/// Observes the terminal result of the one shared recording lifecycle.
abstract interface class RecordingProcessingCompletionPort {
  Future<RecordingProcessingCompletion> waitForTerminal(String recordingId);
}

/// Gives a lifecycle owner an independently cancellable terminal waiter.
abstract interface class RecordingProcessingCompletionSubscriptionPort {
  RecordingProcessingCompletionSubscription observeTerminal(String recordingId);
}

/// Shares the tracker-owned recording detail read with visible detail pages.
abstract interface class RecordingProcessingDetailObservationPort {
  RecordingProcessingTask? processingTaskFor(String recordingId);

  void addProcessingDetailListener(VoidCallback listener);

  void removeProcessingDetailListener(VoidCallback listener);
}

enum RecordingSpeakerAutoAdvanceStatus { notRequired, submitted, retryWaiting }

final class RecordingSpeakerAutoAdvanceOutcome {
  const RecordingSpeakerAutoAdvanceOutcome(this.status, {this.errorCode});

  final RecordingSpeakerAutoAdvanceStatus status;
  final String? errorCode;
}

/// Shares one version-latched speaker transition between background processing
/// and a visible historical recording detail.
abstract interface class RecordingSpeakerAutoAdvancePort {
  Future<RecordingSpeakerAutoAdvanceOutcome> advanceSpeakerStageIfNeeded(
    RecordingDetail detail,
  );
}

final class RecordingProcessingTask {
  const RecordingProcessingTask({
    required this.draft,
    required this.phase,
    required this.updatedAt,
    this.detail,
    this.errorCode,
  });

  final UploadDraft draft;
  final RecordingProcessingPhase phase;
  final DateTime updatedAt;
  final RecordingDetail? detail;
  final String? errorCode;

  RecordingFileJobStatus get status => switch (phase) {
    RecordingProcessingPhase.transcribing ||
    RecordingProcessingPhase.storingCloudNote =>
      RecordingFileJobStatus.processing,
    RecordingProcessingPhase.completed => RecordingFileJobStatus.ready,
    RecordingProcessingPhase.failed => RecordingFileJobStatus.failed,
  };

  AppTaskState get appTaskState => switch (phase) {
    RecordingProcessingPhase.transcribing ||
    RecordingProcessingPhase.storingCloudNote => const AppTaskRunning(),
    RecordingProcessingPhase.completed => const AppTaskSucceeded(),
    RecordingProcessingPhase.failed => AppTaskFailed(
      errorCategory: _safeRecordingTaskErrorCategory(errorCode),
      retryable: detail?.effectiveRetryActions.isNotEmpty == true,
    ),
  };

  AppTaskProjection get appTaskProjection => AppTaskProjection(
    // performance-rfc: recording-processing-poll
    spec: TaskSpec(
      key:
          'recording:lifecycle:'
          '${_stableOpaquePollId(draft.recordingId ?? draft.draftId)}',
      owner: 'recording-processing',
      priority: TaskPriority.foregroundDeferred,
      resources: const <TaskResource>{TaskResource.network},
      foregroundOnly: true,
      replaceExisting: true,
      retryable: true,
    ),
    state: appTaskState,
  );

  bool get isActive =>
      phase == RecordingProcessingPhase.transcribing ||
      phase == RecordingProcessingPhase.storingCloudNote;

  RecordingProcessingTask copyWith({
    UploadDraft? draft,
    RecordingProcessingPhase? phase,
    DateTime? updatedAt,
    RecordingDetail? detail,
    String? errorCode,
    bool clearError = false,
  }) {
    return RecordingProcessingTask(
      draft: draft ?? this.draft,
      phase: phase ?? this.phase,
      updatedAt: updatedAt ?? this.updatedAt,
      detail: detail ?? this.detail,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
    );
  }
}

final class RecordingProcessingState {
  const RecordingProcessingState({
    this.tasks = const <RecordingProcessingTask>[],
  });

  factory RecordingProcessingState.initial() =>
      const RecordingProcessingState();

  final List<RecordingProcessingTask> tasks;

  RecordingProcessingTask? taskFor(String recordingId) {
    for (final task in tasks) {
      if (task.draft.recordingId == recordingId) return task;
    }
    return null;
  }

  RecordingProcessingTask? taskForDraft(String draftId) {
    for (final task in tasks) {
      if (task.draft.draftId == draftId) return task;
    }
    return null;
  }
}

typedef RecordingProcessingDelay = Future<void> Function(Duration duration);
typedef RecordingProcessingDetailObserver =
    Future<bool> Function(RecordingDetail detail);
typedef _PendingRecordingDetailProjection = ({
  int generation,
  RecordingDetail detail,
  String signature,
});
typedef _RecordingDetailProjectionResult = ({
  int generation,
  String signature,
  bool acknowledged,
  bool timedOut,
});
typedef _ExhaustedRecordingDetailProjection = ({
  int generation,
  String signature,
});
typedef _AutomaticSpeakerAdvanceRequest = ({
  String recordingId,
  String asrTaskId,
  int version,
  String identity,
  String idempotencyKey,
});

/// Keeps server-derived recording work alive after its detail page is closed.
/// The only compatibility mutation advances unmatched speaker results with
/// anonymous labels; every later lifecycle stage remains read-only observation.
final class RecordingProcessingTracker extends ChangeNotifier
    implements
        RecordingProcessingPort,
        RecordingProcessingRetryPort,
        RecordingProcessingCompletionPort,
        RecordingProcessingCompletionSubscriptionPort,
        RecordingProcessingDetailObservationPort,
        RecordingSpeakerAutoAdvancePort {
  RecordingProcessingTracker({
    required RecordingApiPort recordingApi,
    required UploadDraftStore draftStore,
    RecordingSpeakerAutoAdvanceApiPort? speakerAutoAdvanceApi,
    RecordingProcessingDelay? delay,
    DateTime Function()? now,
    String? accountScope,
    String? Function()? activeAccountScope,
    String? workspaceScope,
    String? Function()? activeWorkspaceScope,
    RecordingProcessingDetailObserver? onDetailChanged,
    this.pollInterval = const Duration(seconds: 3),
    this.maxObservationDuration = recordingBatchObservationWindow,
    int detailProjectionRetryLimit = 8,
    Duration detailProjectionRetryWindow = const Duration(minutes: 5),
    Duration detailProjectionAttemptTimeout = const Duration(seconds: 20),
  }) : assert(detailProjectionRetryLimit > 0),
       assert(detailProjectionRetryWindow > Duration.zero),
       assert(detailProjectionAttemptTimeout > Duration.zero),
       _detailProjectionRetryLimit = detailProjectionRetryLimit,
       _detailProjectionRetryWindow = detailProjectionRetryWindow,
       _detailProjectionAttemptTimeout = detailProjectionAttemptTimeout,
       _recordingApi = recordingApi,
       _speakerAutoAdvanceApi =
           speakerAutoAdvanceApi ??
           (recordingApi is RecordingSpeakerAutoAdvanceApiPort
               ? recordingApi as RecordingSpeakerAutoAdvanceApiPort
               : null),
       _draftStore = draftStore,
       _delay = delay ?? Future<void>.delayed,
       _usesInjectedDelay = delay != null,
       _now = now ?? DateTime.now,
       _accountScope = _normalizeAccountScope(accountScope),
       _activeAccountScope = activeAccountScope,
       _workspaceScope = _normalizeWorkspaceScope(workspaceScope),
       _activeWorkspaceScope = activeWorkspaceScope,
       _onDetailChanged = onDetailChanged;

  final RecordingApiPort _recordingApi;
  final RecordingSpeakerAutoAdvanceApiPort? _speakerAutoAdvanceApi;
  final UploadDraftStore _draftStore;
  final RecordingProcessingDelay _delay;
  final bool _usesInjectedDelay;
  final DateTime Function() _now;
  final String? _accountScope;
  final String? Function()? _activeAccountScope;
  final String? _workspaceScope;
  final String? Function()? _activeWorkspaceScope;
  final RecordingProcessingDetailObserver? _onDetailChanged;
  final int _detailProjectionRetryLimit;
  final Duration _detailProjectionRetryWindow;
  final Duration _detailProjectionAttemptTimeout;
  final Duration pollInterval;
  final Duration maxObservationDuration;

  final Map<String, RecordingProcessingTask> _tasks =
      <String, RecordingProcessingTask>{};
  final Map<String, int> _generationByRecording = <String, int>{};
  final Map<String, String> _detailSignatures = <String, String>{};
  final Map<String, OrchestratedPoller> _pollers =
      <String, OrchestratedPoller>{};
  final Map<String, OrchestratedPoller> _projectionPollers =
      <String, OrchestratedPoller>{};
  final Map<String, _PendingRecordingDetailProjection>
  _pendingDetailProjections = <String, _PendingRecordingDetailProjection>{};
  final Map<String, Future<_RecordingDetailProjectionResult>>
  _detailProjectionInFlight =
      <String, Future<_RecordingDetailProjectionResult>>{};
  final Map<String, int> _detailProjectionAttempts = <String, int>{};
  final Map<String, DateTime> _detailProjectionDeadlines = <String, DateTime>{};
  final Map<String, _ExhaustedRecordingDetailProjection>
  _exhaustedDetailProjections = <String, _ExhaustedRecordingDetailProjection>{};
  final Map<String, Completer<void>> _observationCompleters =
      <String, Completer<void>>{};
  final Map<String, List<Completer<RecordingProcessingCompletion>>>
  _terminalWaiters = <String, List<Completer<RecordingProcessingCompletion>>>{};
  final Map<String, DateTime> _observationDeadlines = <String, DateTime>{};
  final Map<String, Future<RecordingSpeakerAutoAdvanceOutcome>>
  _speakerAdvanceInFlight =
      <String, Future<RecordingSpeakerAutoAdvanceOutcome>>{};
  final Map<String, String> _speakerAdvanceLatchByRecording =
      <String, String>{};
  TaskOrchestrator? _orchestrator;
  RuntimeActivityMetrics? _activityMetrics;
  RecordingProcessingState _state = RecordingProcessingState.initial();
  var _nextGeneration = 0;
  var _disposed = false;

  RecordingProcessingState get state => _state;

  @override
  RecordingProcessingTask? processingTaskFor(String recordingId) {
    final normalized = _normalizeRecordingId(recordingId);
    if (normalized == null || _cancelIfScopeChanged()) return null;
    return _tasks[normalized];
  }

  @override
  void addProcessingDetailListener(VoidCallback listener) {
    addListener(listener);
  }

  @override
  void removeProcessingDetailListener(VoidCallback listener) {
    removeListener(listener);
  }

  @override
  Future<RecordingSpeakerAutoAdvanceOutcome> advanceSpeakerStageIfNeeded(
    RecordingDetail detail,
  ) async {
    if (_cancelIfScopeChanged()) {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.retryWaiting,
        errorCode: 'RECORDING_SPEAKER_SCOPE_CHANGED',
      );
    }
    if (!_requiresAutomaticSpeakerAdvance(detail)) {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.notRequired,
      );
    }
    final request = _automaticSpeakerAdvanceRequest(detail);
    if (request == null) {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.retryWaiting,
        errorCode: 'RECORDING_SPEAKER_SNAPSHOT_INCOMPLETE',
      );
    }
    if (_speakerAdvanceLatchByRecording[request.recordingId] ==
        request.identity) {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.submitted,
      );
    }
    final existing = _speakerAdvanceInFlight[request.identity];
    if (existing != null) return existing;

    final future = _submitAutomaticSpeakerAdvance(request);
    _speakerAdvanceInFlight[request.identity] = future;
    try {
      return await future;
    } finally {
      if (identical(_speakerAdvanceInFlight[request.identity], future)) {
        _speakerAdvanceInFlight.remove(request.identity);
      }
    }
  }

  Future<RecordingSpeakerAutoAdvanceOutcome> _submitAutomaticSpeakerAdvance(
    _AutomaticSpeakerAdvanceRequest request,
  ) async {
    final api = _speakerAutoAdvanceApi;
    if (api == null) {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.retryWaiting,
        errorCode: 'RECORDING_SPEAKER_AUTO_ADVANCE_UNAVAILABLE',
      );
    }
    try {
      final result = await api.autoAdvanceSpeakerLabels(
        recordingId: request.recordingId,
        asrTaskId: request.asrTaskId,
        baseAsrTaskVersion: request.version,
        idempotencyKey: request.idempotencyKey,
      );
      if (_disposed || _cancelIfScopeChanged()) {
        return const RecordingSpeakerAutoAdvanceOutcome(
          RecordingSpeakerAutoAdvanceStatus.retryWaiting,
          errorCode: 'RECORDING_SPEAKER_SCOPE_CHANGED',
        );
      }
      if (!result.ok) {
        return RecordingSpeakerAutoAdvanceOutcome(
          RecordingSpeakerAutoAdvanceStatus.retryWaiting,
          errorCode:
              result.error?.code ?? 'RECORDING_SPEAKER_AUTO_ADVANCE_FAILED',
        );
      }
      _speakerAdvanceLatchByRecording[request.recordingId] = request.identity;
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.submitted,
      );
    } on Object {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.retryWaiting,
        errorCode: 'RECORDING_SPEAKER_AUTO_ADVANCE_FAILED',
      );
    }
  }

  @override
  Future<RecordingProcessingCompletion> waitForTerminal(String recordingId) =>
      observeTerminal(recordingId).completion;

  @override
  RecordingProcessingCompletionSubscription observeTerminal(
    String recordingId,
  ) {
    if (_cancelIfScopeChanged()) {
      return _completedTerminalSubscription(
        const RecordingProcessingCompletion(
          status: RecordingProcessingCompletionStatus.unavailable,
          errorCode: 'RECORDING_PROCESSING_SCOPE_UNAVAILABLE',
        ),
      );
    }
    final normalizedRecordingId = _normalizeRecordingId(recordingId);
    if (normalizedRecordingId == null) {
      return _completedTerminalSubscription(
        const RecordingProcessingCompletion(
          status: RecordingProcessingCompletionStatus.unavailable,
          errorCode: 'RECORDING_ID_INVALID',
        ),
      );
    }
    _restoreTerminalTasks();
    final terminal = _terminalCompletion(_tasks[normalizedRecordingId]);
    if (terminal != null) {
      return _completedTerminalSubscription(terminal);
    }
    final hasDurableCheckpoint = _queuedDraftsForScope().any(
      (draft) => _recordingIdFor(draft) == normalizedRecordingId,
    );
    if (!hasDurableCheckpoint && !_tasks.containsKey(normalizedRecordingId)) {
      return _completedTerminalSubscription(
        const RecordingProcessingCompletion(
          status: RecordingProcessingCompletionStatus.unavailable,
          errorCode: 'RECORDING_PROCESSING_NOT_QUEUED',
        ),
      );
    }
    final completer = Completer<RecordingProcessingCompletion>();
    _terminalWaiters
        .putIfAbsent(
          normalizedRecordingId,
          () => <Completer<RecordingProcessingCompletion>>[],
        )
        .add(completer);
    return RecordingProcessingCompletionSubscription(
      completion: completer.future,
      onCancel: () {
        final waiters = _terminalWaiters[normalizedRecordingId];
        waiters?.remove(completer);
        if (waiters?.isEmpty == true) {
          _terminalWaiters.remove(normalizedRecordingId);
        }
        if (!completer.isCompleted) {
          completer.complete(
            const RecordingProcessingCompletion(
              status: RecordingProcessingCompletionStatus.unavailable,
              errorCode: 'RECORDING_PROCESSING_COMPLETION_CANCELLED',
            ),
          );
        }
      },
    );
  }

  RecordingProcessingCompletionSubscription _completedTerminalSubscription(
    RecordingProcessingCompletion completion,
  ) {
    return RecordingProcessingCompletionSubscription(
      completion: Future<RecordingProcessingCompletion>.value(completion),
      onCancel: () {},
    );
  }

  void attachPollingRuntime({
    required TaskOrchestrator orchestrator,
    required RuntimeActivityMetrics activityMetrics,
  }) {
    if (_disposed) return;
    final runtimeChanged =
        !identical(_orchestrator, orchestrator) ||
        !identical(_activityMetrics, activityMetrics);
    if (runtimeChanged) {
      _disposePollers();
      _disposeProjectionPollers();
      _orchestrator = orchestrator;
      _activityMetrics = activityMetrics;
    }
    for (final entry in _tasks.entries.toList(growable: false)) {
      final generation = _generationByRecording[entry.key];
      if (!entry.value.isActive || generation == null) continue;
      _observationDeadlines.putIfAbsent(
        entry.key,
        () => _now().toUtc().add(maxObservationDuration),
      );
      _observationCompleters.putIfAbsent(entry.key, Completer<void>.new);
      _installPoller(entry.key, entry.value.draft, generation: generation);
    }
    for (final recordingId in _pendingDetailProjections.keys.toList()) {
      _installProjectionPoller(recordingId);
    }
  }

  /// Restores only remote-processing checkpoints. Incomplete binary uploads
  /// remain the upload controller's responsibility.
  Future<void> recoverPending() async {
    if (_cancelIfScopeChanged()) return;
    _restoreTerminalTasks();
    for (final draft in _queuedDraftsForScope()) {
      unawaited(track(draft));
    }
  }

  /// Restarts stale foreground work without creating a new recording request.
  Future<void> refreshPending() async {
    if (_cancelIfScopeChanged()) return;
    _restoreTerminalTasks();
    final queuedByRecording = <String, UploadDraft>{
      for (final draft in _queuedDraftsForScope())
        if (_recordingIdFor(draft) case final recordingId?) recordingId: draft,
    };
    for (final draft in queuedByRecording.values) {
      unawaited(track(draft));
    }
    for (final task in _tasks.values) {
      final recordingId = _recordingIdFor(task.draft);
      if (!task.isActive ||
          recordingId == null ||
          queuedByRecording.containsKey(recordingId)) {
        continue;
      }
      unawaited(track(task.draft));
    }
  }

  @override
  Future<void> track(UploadDraft draft) {
    if (_cancelIfScopeChanged() ||
        !_belongsToTrackerScope(draft) ||
        draft.stage != UploadDraftStage.asrQueued) {
      return Future<void>.value();
    }
    final recordingId = _recordingIdFor(draft);
    if (recordingId == null) return Future<void>.value();
    final generation = ++_nextGeneration;
    _generationByRecording[recordingId] = generation;
    _stopPoller(recordingId);
    _stopProjectionPoller(recordingId);
    _pendingDetailProjections.remove(recordingId);
    _detailProjectionAttempts.remove(recordingId);
    _detailProjectionDeadlines.remove(recordingId);
    _exhaustedDetailProjections.remove(recordingId);
    _completeObservation(recordingId);
    _observationDeadlines[recordingId] = _now().toUtc().add(
      maxObservationDuration,
    );
    final previous = _tasks[recordingId];
    _tasks[recordingId] = RecordingProcessingTask(
      draft: draft,
      phase:
          previous?.isActive == true && previous?.draft.draftId == draft.draftId
          ? previous!.phase
          : RecordingProcessingPhase.transcribing,
      updatedAt: _now().toUtc(),
      detail:
          previous?.isActive == true && previous?.draft.draftId == draft.draftId
          ? previous?.detail
          : null,
    );
    _publish();
    if (_orchestrator != null && _activityMetrics != null) {
      final completer = Completer<void>();
      _observationCompleters[recordingId] = completer;
      _installPoller(recordingId, draft, generation: generation);
      return completer.future;
    }
    if (_usesInjectedDelay) {
      return _pollWithInjectedDelay(recordingId, draft, generation: generation);
    }
    return Future<void>.error(
      StateError(
        'RecordingProcessingTracker requires attachPollingRuntime() in '
        'production or an explicit delay in tests.',
      ),
    );
  }

  @override
  Future<bool> reenrollAfterRetry(String recordingId) async {
    if (_cancelIfScopeChanged() || !_hasUsableOwnershipScope) return false;
    final normalizedRecordingId = _normalizeRecordingId(recordingId);
    if (normalizedRecordingId == null) return false;
    UploadDraft? failedDraft;
    for (final candidate in _draftStore.listTerminalRecordingProcessingDrafts(
      workspaceId: _workspaceScope,
    )) {
      if (candidate.stage != UploadDraftStage.asrFailed ||
          !_belongsToTrackerScope(candidate) ||
          _recordingIdFor(candidate) != normalizedRecordingId) {
        continue;
      }
      failedDraft = candidate;
    }
    if (failedDraft == null) return false;
    final saved = _draftStore.saveDraft(
      failedDraft.copyWith(
        stage: UploadDraftStage.asrQueued,
        updatedAt: _now().toUtc(),
        clearLastError: true,
      ),
    );
    final checkpoint = saved.value;
    if (!saved.ok || checkpoint == null) return false;
    // Do not make a successful retry tap wait for the entire background
    // lifecycle. `track` owns its generation and immediate first GET.
    unawaited(track(checkpoint));
    return true;
  }

  Future<void> _pollWithInjectedDelay(
    String recordingId,
    UploadDraft draft, {
    required int generation,
  }) async {
    var consecutiveReadFailures = 0;
    while (_isCurrent(recordingId, generation)) {
      final deadline = _observationDeadlines[recordingId];
      if (deadline == null || !_now().toUtc().isBefore(deadline)) {
        _pauseObservationWindow(recordingId);
        _completeObservation(recordingId);
        return;
      }
      final result = await _recordingApi.getRecordingDetail(recordingId);
      if (!_isCurrent(recordingId, generation)) return;
      final detail = result.data;
      if (!result.ok || detail == null) {
        consecutiveReadFailures += 1;
        _setProcessingError(
          recordingId,
          result.error?.code ?? 'RECORDING_PROCESSING_READ_FAILED',
        );
        await _delay(_readFailureDelay(consecutiveReadFailures));
        continue;
      }
      consecutiveReadFailures = 0;
      if (detail.recording.recordingId != recordingId) {
        _finish(
          recordingId,
          draft,
          phase: RecordingProcessingPhase.failed,
          stage: UploadDraftStage.asrFailed,
          errorCode: 'RECORDING_PROCESSING_RECORDING_MISMATCH',
          preserveDetail: false,
        );
        return;
      }
      _rememberDetail(recordingId, draft, detail);
      _queueDetailProjection(
        recordingId,
        generation: generation,
        detail: detail,
      );
      if (!_isCurrent(recordingId, generation)) return;
      final speakerAdvance = await advanceSpeakerStageIfNeeded(detail);
      if (!_isCurrent(recordingId, generation)) return;
      if (speakerAdvance.status !=
          RecordingSpeakerAutoAdvanceStatus.notRequired) {
        if (speakerAdvance.status ==
            RecordingSpeakerAutoAdvanceStatus.retryWaiting) {
          _setProcessingError(
            recordingId,
            speakerAdvance.errorCode ?? 'RECORDING_SPEAKER_AUTO_ADVANCE_FAILED',
          );
        } else {
          _setTask(
            recordingId,
            _tasks[recordingId]!.copyWith(
              draft: draft,
              updatedAt: _now().toUtc(),
              detail: detail,
              clearError: true,
            ),
          );
        }
        await _delay(pollInterval);
        continue;
      }
      final failureCode = _terminalFailureCode(detail);
      if (failureCode != null) {
        _finish(
          recordingId,
          draft,
          phase: RecordingProcessingPhase.failed,
          stage: UploadDraftStage.asrFailed,
          errorCode: failureCode,
        );
        return;
      }
      if (detail.hasCloudAsset) {
        _finish(
          recordingId,
          draft,
          phase: RecordingProcessingPhase.completed,
          stage: UploadDraftStage.asrCompleted,
        );
        return;
      }
      _setTask(
        recordingId,
        _tasks[recordingId]!.copyWith(
          draft: draft,
          updatedAt: _now().toUtc(),
          detail: detail,
          clearError: true,
        ),
      );
      await _delay(pollInterval);
    }
  }

  void _installPoller(
    String recordingId,
    UploadDraft draft, {
    required int generation,
  }) {
    final orchestrator = _orchestrator;
    final activityMetrics = _activityMetrics;
    if (orchestrator == null || activityMetrics == null || _disposed) return;
    _stopPoller(recordingId);
    final stableId = _stableOpaquePollId(recordingId);
    // performance-rfc: recording-processing-poll
    final poller = OrchestratedPoller(
      orchestrator: orchestrator,
      spec: TaskSpec(
        key: 'recording:processing:$stableId',
        owner: 'recording-processing',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        deadline: _detailProjectionAttemptTimeout + const Duration(seconds: 1),
        retryable: true,
        replaceExisting: true,
      ),
      interval: pollInterval,
      maxBackoff: pollInterval > const Duration(seconds: 30)
          ? pollInterval
          : const Duration(seconds: 30),
      activityMetrics: activityMetrics,
      metricsOwner: 'recording.processing.$stableId',
      poll: (token) =>
          _pollOnce(recordingId, draft, generation: generation, token: token),
    );
    _pollers[recordingId] = poller;
    poller.start();
  }

  Future<bool> _pollOnce(
    String recordingId,
    UploadDraft draft, {
    required int generation,
    required AppTaskCancellationToken token,
  }) async {
    token.throwIfCancelled();
    if (!_isCurrent(recordingId, generation)) return false;
    final deadline = _observationDeadlines[recordingId];
    if (deadline == null) return false;
    if (!_now().toUtc().isBefore(deadline)) {
      _pauseObservationWindow(recordingId);
      _completeObservation(recordingId);
      return false;
    }
    final result = await _recordingApi.getRecordingDetail(recordingId);
    token.throwIfCancelled();
    if (!_isCurrent(recordingId, generation)) return false;
    final detail = result.data;
    if (!result.ok || detail == null) {
      final errorCode =
          result.error?.code ?? 'RECORDING_PROCESSING_READ_FAILED';
      _setProcessingError(recordingId, errorCode);
      throw StateError(errorCode);
    }
    if (detail.recording.recordingId != recordingId) {
      _finish(
        recordingId,
        draft,
        phase: RecordingProcessingPhase.failed,
        stage: UploadDraftStage.asrFailed,
        errorCode: 'RECORDING_PROCESSING_RECORDING_MISMATCH',
        preserveDetail: false,
      );
      _completeObservation(recordingId);
      return false;
    }
    _rememberDetail(recordingId, draft, detail);
    _queueDetailProjection(recordingId, generation: generation, detail: detail);
    token.throwIfCancelled();
    if (!_isCurrent(recordingId, generation)) return false;
    final speakerAdvance = await advanceSpeakerStageIfNeeded(detail);
    token.throwIfCancelled();
    if (!_isCurrent(recordingId, generation)) return false;
    if (speakerAdvance.status !=
        RecordingSpeakerAutoAdvanceStatus.notRequired) {
      if (speakerAdvance.status ==
          RecordingSpeakerAutoAdvanceStatus.retryWaiting) {
        final errorCode =
            speakerAdvance.errorCode ?? 'RECORDING_SPEAKER_AUTO_ADVANCE_FAILED';
        _setProcessingError(recordingId, errorCode);
        throw StateError(errorCode);
      }
      _setTask(
        recordingId,
        _tasks[recordingId]!.copyWith(
          draft: draft,
          updatedAt: _now().toUtc(),
          detail: detail,
          clearError: true,
        ),
      );
      return true;
    }
    final failureCode = _terminalFailureCode(detail);
    if (failureCode != null) {
      _finish(
        recordingId,
        draft,
        phase: RecordingProcessingPhase.failed,
        stage: UploadDraftStage.asrFailed,
        errorCode: failureCode,
      );
      _completeObservation(recordingId);
      return false;
    }
    if (detail.hasCloudAsset) {
      _finish(
        recordingId,
        draft,
        phase: RecordingProcessingPhase.completed,
        stage: UploadDraftStage.asrCompleted,
      );
      _completeObservation(recordingId);
      return false;
    }
    _setTask(
      recordingId,
      _tasks[recordingId]!.copyWith(
        draft: draft,
        updatedAt: _now().toUtc(),
        detail: detail,
        clearError: true,
      ),
    );
    return true;
  }

  void _finish(
    String recordingId,
    UploadDraft draft, {
    required RecordingProcessingPhase phase,
    required UploadDraftStage stage,
    String? errorCode,
    bool preserveDetail = true,
  }) {
    final now = _now().toUtc();
    final terminalCheckpoint = draft.copyWith(
      stage: stage,
      updatedAt: now,
      lastErrorCode: errorCode,
      clearLastError: errorCode == null,
    );
    final saved = _draftStore.saveDraft(terminalCheckpoint);
    final checkpoint = saved.value;
    if (!saved.ok || checkpoint == null) {
      _setTask(
        recordingId,
        RecordingProcessingTask(
          draft: draft,
          phase: RecordingProcessingPhase.failed,
          updatedAt: now,
          detail: preserveDetail ? _tasks[recordingId]?.detail : null,
          errorCode:
              saved.error?.code ??
              'RECORDING_PROCESSING_CHECKPOINT_WRITE_FAILED',
        ),
      );
      return;
    }
    _setTask(
      recordingId,
      RecordingProcessingTask(
        draft: checkpoint,
        phase: phase,
        updatedAt: now,
        detail: preserveDetail ? _tasks[recordingId]?.detail : null,
        errorCode: errorCode,
      ),
    );
  }

  List<UploadDraft> _queuedDraftsForScope() {
    if (!_hasUsableOwnershipScope) return const <UploadDraft>[];
    return _draftStore
        .listQueuedRecordingProcessingDrafts(workspaceId: _workspaceScope)
        .where(_belongsToTrackerScope)
        .toList(growable: false);
  }

  void _restoreTerminalTasks() {
    if (!_hasUsableOwnershipScope) return;
    var changed = false;
    for (final draft in _draftStore.listTerminalRecordingProcessingDrafts(
      workspaceId: _workspaceScope,
    )) {
      if (!_belongsToTrackerScope(draft)) continue;
      final recordingId = _recordingIdFor(draft);
      if (recordingId == null) continue;
      final phase = switch (draft.stage) {
        UploadDraftStage.asrCompleted => RecordingProcessingPhase.completed,
        UploadDraftStage.asrFailed => RecordingProcessingPhase.failed,
        _ => null,
      };
      if (phase == null) continue;
      final restored = RecordingProcessingTask(
        draft: draft,
        phase: phase,
        updatedAt: draft.updatedAt,
        detail: _tasks[recordingId]?.detail,
        errorCode: draft.lastErrorCode,
      );
      final current = _tasks[recordingId];
      if (current?.draft.draftId == restored.draft.draftId &&
          current?.phase == restored.phase &&
          current?.updatedAt == restored.updatedAt &&
          current?.errorCode == restored.errorCode) {
        continue;
      }
      _tasks[recordingId] = restored;
      _completeTerminalWaiters(recordingId, restored);
      changed = true;
    }
    if (changed) _publish();
  }

  void _queueDetailProjection(
    String recordingId, {
    required int generation,
    required RecordingDetail detail,
  }) {
    if (_onDetailChanged == null) return;
    final signature = _recordingDetailSignature(detail);
    if (_detailSignatures[recordingId] == signature) return;
    final exhausted = _exhaustedDetailProjections[recordingId];
    if (exhausted?.generation == generation &&
        exhausted?.signature == signature) {
      return;
    }
    final previous = _pendingDetailProjections[recordingId];
    final isNewProjection =
        previous?.generation != generation || previous?.signature != signature;
    if (isNewProjection) {
      _detailProjectionAttempts[recordingId] = 0;
      _detailProjectionDeadlines[recordingId] = _now().toUtc().add(
        _detailProjectionRetryWindow,
      );
      _exhaustedDetailProjections.remove(recordingId);
    }
    _pendingDetailProjections[recordingId] = (
      generation: generation,
      detail: detail,
      signature: signature,
    );
    if (_orchestrator != null && _activityMetrics != null) {
      _installProjectionPoller(recordingId);
      return;
    }
    unawaited(_projectPendingDetailOnce(recordingId));
  }

  void _installProjectionPoller(String recordingId) {
    final orchestrator = _orchestrator;
    final activityMetrics = _activityMetrics;
    if (orchestrator == null || activityMetrics == null || _disposed) return;
    final existing = _projectionPollers[recordingId];
    if (existing != null) {
      if (!existing.isRunning) existing.start();
      return;
    }
    final stableId = _stableOpaquePollId(recordingId);
    final poller = OrchestratedPoller(
      orchestrator: orchestrator,
      spec: TaskSpec(
        key: 'recording:projection:$stableId',
        owner: 'recording-projection',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        deadline: const Duration(seconds: 30),
        retryable: true,
        replaceExisting: true,
      ),
      interval: pollInterval,
      maxBackoff: pollInterval > const Duration(seconds: 30)
          ? pollInterval
          : const Duration(seconds: 30),
      activityMetrics: activityMetrics,
      metricsOwner: 'recording.projection.$stableId',
      poll: (token) => _pollDetailProjection(recordingId, token: token),
    );
    _projectionPollers[recordingId] = poller;
    poller.start();
  }

  Future<bool> _pollDetailProjection(
    String recordingId, {
    required AppTaskCancellationToken token,
  }) async {
    token.throwIfCancelled();
    final pending = _pendingDetailProjections[recordingId];
    if (pending == null || !_isCurrent(recordingId, pending.generation)) {
      _discardDetailProjection(recordingId);
      return false;
    }
    if (!_hasDetailProjectionBudget(recordingId)) {
      _exhaustDetailProjection(recordingId, pending);
      return false;
    }
    if (_detailProjectionInFlight.containsKey(recordingId)) return true;
    final result = await token.waitFor(
      _startOrJoinDetailProjection(recordingId, pending),
    );
    token.throwIfCancelled();
    final current = _pendingDetailProjections[recordingId];
    if (current == null) return false;
    if (!_isCurrent(recordingId, current.generation)) {
      _discardDetailProjection(recordingId);
      return false;
    }
    if (!_hasDetailProjectionBudget(recordingId)) {
      _exhaustDetailProjection(recordingId, current);
      return false;
    }
    final isSameProjection =
        current.generation == result.generation &&
        current.signature == result.signature;
    if (isSameProjection && !result.acknowledged) {
      throw StateError('RECORDING_DETAIL_PROJECTION_RETRY');
    }
    return true;
  }

  Future<void> _projectPendingDetailOnce(String recordingId) async {
    while (!_disposed && _orchestrator == null) {
      final pending = _pendingDetailProjections[recordingId];
      if (pending == null) return;
      if (!_isCurrent(recordingId, pending.generation)) {
        _discardDetailProjection(recordingId);
        return;
      }
      if (!_hasDetailProjectionBudget(recordingId)) {
        _exhaustDetailProjection(recordingId, pending);
        return;
      }
      final result = await _startOrJoinDetailProjection(recordingId, pending);
      final current = _pendingDetailProjections[recordingId];
      if (current == null || _orchestrator != null) return;
      final resultWasSuperseded =
          current.generation != result.generation ||
          current.signature != result.signature;
      if (!resultWasSuperseded) return;
    }
  }

  Future<_RecordingDetailProjectionResult> _startOrJoinDetailProjection(
    String recordingId,
    _PendingRecordingDetailProjection pending,
  ) {
    final existing = _detailProjectionInFlight[recordingId];
    if (existing != null) return existing;
    late final Future<_RecordingDetailProjectionResult> inFlight;
    inFlight = _projectDetail(recordingId, pending)
        .then((result) {
          _applyDetailProjectionResult(recordingId, result);
          return result;
        })
        .whenComplete(() {
          if (identical(_detailProjectionInFlight[recordingId], inFlight)) {
            _detailProjectionInFlight.remove(recordingId);
          }
        });
    _detailProjectionInFlight[recordingId] = inFlight;
    return inFlight;
  }

  Future<_RecordingDetailProjectionResult> _projectDetail(
    String recordingId,
    _PendingRecordingDetailProjection pending,
  ) async {
    final observer = _onDetailChanged;
    if (observer == null ||
        _detailSignatures[recordingId] == pending.signature) {
      return (
        generation: pending.generation,
        signature: pending.signature,
        acknowledged: true,
        timedOut: false,
      );
    }
    if (!_isCurrent(recordingId, pending.generation)) {
      return (
        generation: pending.generation,
        signature: pending.signature,
        acknowledged: false,
        timedOut: false,
      );
    }
    var acknowledged = false;
    var timedOut = false;
    final retryDeadline = _detailProjectionDeadlines[recordingId];
    final remainingBudget = retryDeadline?.difference(_now().toUtc());
    final attemptTimeout =
        remainingBudget != null &&
            remainingBudget < _detailProjectionAttemptTimeout
        ? remainingBudget
        : _detailProjectionAttemptTimeout;
    if (attemptTimeout <= Duration.zero) {
      return (
        generation: pending.generation,
        signature: pending.signature,
        acknowledged: false,
        timedOut: true,
      );
    }
    try {
      acknowledged = await observer(pending.detail).timeout(attemptTimeout);
    } on TimeoutException {
      timedOut = true;
    } on Object {
      // Local cache projection is best-effort; server facts own completion.
      acknowledged = false;
    }
    return (
      generation: pending.generation,
      signature: pending.signature,
      acknowledged: acknowledged,
      timedOut: timedOut,
    );
  }

  void _applyDetailProjectionResult(
    String recordingId,
    _RecordingDetailProjectionResult result,
  ) {
    final current = _pendingDetailProjections[recordingId];
    if (current == null ||
        current.generation != result.generation ||
        current.signature != result.signature) {
      return;
    }
    if (!_isCurrent(recordingId, result.generation)) {
      _discardDetailProjection(recordingId);
      return;
    }
    if (result.timedOut) {
      _exhaustDetailProjection(recordingId, current);
      return;
    }
    if (result.acknowledged) {
      _detailSignatures[recordingId] = result.signature;
      _completeDetailProjection(recordingId);
      return;
    }
    final attempts = (_detailProjectionAttempts[recordingId] ?? 0) + 1;
    _detailProjectionAttempts[recordingId] = attempts;
    if (attempts >= _detailProjectionRetryLimit ||
        !_hasDetailProjectionBudget(recordingId)) {
      _exhaustDetailProjection(recordingId, current);
    }
  }

  bool _hasDetailProjectionBudget(String recordingId) {
    final deadline = _detailProjectionDeadlines[recordingId];
    return (_detailProjectionAttempts[recordingId] ?? 0) <
            _detailProjectionRetryLimit &&
        deadline != null &&
        _now().toUtc().isBefore(deadline);
  }

  void _completeDetailProjection(String recordingId) {
    _exhaustedDetailProjections.remove(recordingId);
    _discardDetailProjection(recordingId);
  }

  void _exhaustDetailProjection(
    String recordingId,
    _PendingRecordingDetailProjection pending,
  ) {
    _exhaustedDetailProjections[recordingId] = (
      generation: pending.generation,
      signature: pending.signature,
    );
    _discardDetailProjection(recordingId);
  }

  void _discardDetailProjection(String recordingId) {
    _pendingDetailProjections.remove(recordingId);
    _detailProjectionAttempts.remove(recordingId);
    _detailProjectionDeadlines.remove(recordingId);
    Timer.run(() => _reconcileProjectionPoller(recordingId));
  }

  void _rememberDetail(
    String recordingId,
    UploadDraft draft,
    RecordingDetail detail,
  ) {
    final current = _tasks[recordingId];
    final phase = _latchedActivePhase(current?.phase, detail);
    _setTask(
      recordingId,
      RecordingProcessingTask(
        draft: current?.draft ?? draft,
        phase: phase,
        updatedAt: _now().toUtc(),
        detail: detail,
      ),
    );
  }

  void _setProcessingError(String recordingId, String errorCode) {
    final current = _tasks[recordingId];
    if (current == null || !current.isActive) return;
    _setTask(
      recordingId,
      current.copyWith(updatedAt: _now().toUtc(), errorCode: errorCode),
    );
  }

  void _pauseObservationWindow(String recordingId) {
    final current = _tasks[recordingId];
    if (current == null || !current.isActive) return;
    _setTask(
      recordingId,
      current.copyWith(updatedAt: _now().toUtc(), clearError: true),
    );
  }

  void _setTask(String recordingId, RecordingProcessingTask task) {
    if (_disposed) return;
    _tasks[recordingId] = task;
    _completeTerminalWaiters(recordingId, task);
    _publish();
  }

  void _completeTerminalWaiters(
    String recordingId,
    RecordingProcessingTask task,
  ) {
    final completion = _terminalCompletion(task);
    if (completion == null) return;
    final waiters = _terminalWaiters.remove(recordingId);
    if (waiters == null) return;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete(completion);
    }
  }

  void _completeAllTerminalWaiters(String errorCode) {
    const status = RecordingProcessingCompletionStatus.unavailable;
    for (final waiters in _terminalWaiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) {
          waiter.complete(
            RecordingProcessingCompletion(status: status, errorCode: errorCode),
          );
        }
      }
    }
    _terminalWaiters.clear();
  }

  void _publish() {
    final tasks = _tasks.values.toList()
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    _state = RecordingProcessingState(
      tasks: List<RecordingProcessingTask>.unmodifiable(tasks),
    );
    if (!_disposed) notifyListeners();
  }

  bool _isCurrent(String recordingId, int generation) {
    if (_disposed || _cancelIfScopeChanged()) return false;
    return _generationByRecording[recordingId] == generation;
  }

  bool get _usesScopedOwnership =>
      _accountScope != null ||
      _workspaceScope != null ||
      _activeAccountScope != null ||
      _activeWorkspaceScope != null;

  bool get _hasUsableOwnershipScope {
    if (!_usesScopedOwnership) return true;
    return _accountScope != null && _workspaceScope != null;
  }

  bool _belongsToTrackerScope(UploadDraft draft) {
    if (!_usesScopedOwnership) return true;
    final workspaceScope = _workspaceScope;
    return workspaceScope != null &&
        _normalizeWorkspaceScope(draft.workspaceId) == workspaceScope;
  }

  bool _cancelIfScopeChanged() {
    if (_disposed) return true;
    if (!_usesScopedOwnership) return false;
    final accountScope = _accountScope;
    final workspaceScope = _workspaceScope;
    final activeAccountScope = _activeAccountScope;
    final activeWorkspaceScope = _activeWorkspaceScope;
    final isCurrent =
        accountScope != null &&
        workspaceScope != null &&
        activeAccountScope != null &&
        activeWorkspaceScope != null &&
        accountScope == _normalizeAccountScope(activeAccountScope()) &&
        workspaceScope == _normalizeWorkspaceScope(activeWorkspaceScope());
    if (isCurrent) return false;
    _disposePollers();
    _disposeProjectionPollers();
    _completeAllObservations();
    _completeAllTerminalWaiters('RECORDING_PROCESSING_SCOPE_CHANGED');
    final changed =
        _generationByRecording.isNotEmpty ||
        _tasks.isNotEmpty ||
        _detailSignatures.isNotEmpty;
    _generationByRecording.clear();
    _tasks.clear();
    _detailSignatures.clear();
    _pendingDetailProjections.clear();
    _detailProjectionAttempts.clear();
    _detailProjectionDeadlines.clear();
    _exhaustedDetailProjections.clear();
    _observationDeadlines.clear();
    _speakerAdvanceInFlight.clear();
    _speakerAdvanceLatchByRecording.clear();
    if (changed) _publish();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _disposePollers();
    _disposeProjectionPollers();
    _completeAllObservations();
    _completeAllTerminalWaiters('RECORDING_PROCESSING_DISPOSED');
    _generationByRecording.clear();
    _detailSignatures.clear();
    _pendingDetailProjections.clear();
    _detailProjectionAttempts.clear();
    _detailProjectionDeadlines.clear();
    _exhaustedDetailProjections.clear();
    _observationDeadlines.clear();
    _speakerAdvanceInFlight.clear();
    _speakerAdvanceLatchByRecording.clear();
    super.dispose();
  }

  void _stopPoller(String recordingId) {
    _pollers.remove(recordingId)?.dispose();
  }

  void _stopProjectionPoller(String recordingId) {
    _projectionPollers.remove(recordingId)?.dispose();
  }

  void _reconcileProjectionPoller(String recordingId) {
    if (_disposed) return;
    if (_pendingDetailProjections.containsKey(recordingId)) {
      _installProjectionPoller(recordingId);
    } else {
      _stopProjectionPoller(recordingId);
    }
  }

  void _disposePollers() {
    for (final poller in _pollers.values) {
      poller.dispose();
    }
    _pollers.clear();
  }

  void _disposeProjectionPollers() {
    for (final poller in _projectionPollers.values) {
      poller.dispose();
    }
    _projectionPollers.clear();
  }

  void _completeObservation(String recordingId) {
    _observationDeadlines.remove(recordingId);
    final completer = _observationCompleters.remove(recordingId);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _completeAllObservations() {
    _observationDeadlines.clear();
    for (final completer in _observationCompleters.values) {
      if (!completer.isCompleted) completer.complete();
    }
    _observationCompleters.clear();
  }
}

RecordingProcessingCompletion? _terminalCompletion(
  RecordingProcessingTask? task,
) {
  if (task == null) return null;
  return switch (task.phase) {
    RecordingProcessingPhase.completed => const RecordingProcessingCompletion(
      status: RecordingProcessingCompletionStatus.completed,
    ),
    RecordingProcessingPhase.failed => RecordingProcessingCompletion(
      status: RecordingProcessingCompletionStatus.failed,
      errorCode: task.errorCode ?? 'RECORDING_PROCESSING_FAILED',
    ),
    RecordingProcessingPhase.transcribing ||
    RecordingProcessingPhase.storingCloudNote => null,
  };
}

String? _recordingIdFor(UploadDraft draft) {
  final recordingId = draft.recordingId?.trim();
  return recordingId == null || recordingId.isEmpty ? null : recordingId;
}

String _stableOpaquePollId(String value) {
  final digest = sha256.convert(utf8.encode(value)).toString();
  return digest.substring(0, 16);
}

String _safeRecordingTaskErrorCategory(String? value) {
  final normalized = (value ?? 'RECORDING_PROCESSING_FAILED').replaceAll(
    RegExp(r'[^A-Za-z0-9._-]+'),
    '_',
  );
  return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
}

bool _requiresAutomaticSpeakerAdvance(RecordingDetail detail) {
  if (detail.hasFinalTranscriptFact ||
      detail.rawTerminalFailureStatus != null) {
    return false;
  }
  final transcriptStatus = _normalizedRecordingStage(
    detail.recording.transcriptStatus,
  );
  final speakerLabelStatus = _normalizedRecordingStage(
    detail.recording.speakerLabelStatus,
  );
  return detail.recording.status == RecordingRemoteStatus.speakerLabelPending ||
      detail.asrTask?.status == RecordingRemoteStatus.speakerLabelPending ||
      transcriptStatus == 'transcribed' ||
      transcriptStatus == 'speaker_labeling' ||
      speakerLabelStatus == 'pending' ||
      speakerLabelStatus == 'speaker_label_pending';
}

_AutomaticSpeakerAdvanceRequest? _automaticSpeakerAdvanceRequest(
  RecordingDetail detail,
) {
  final recordingId = _normalizeRecordingId(detail.recording.recordingId);
  final asrTask = detail.asrTask;
  final asrTaskId = _normalizeRecordingId(asrTask?.asrTaskId);
  final version = asrTask?.version;
  if (recordingId == null ||
      asrTaskId == null ||
      version == null ||
      version < 1) {
    return null;
  }
  final identity = '$recordingId\u0000$asrTaskId\u0000$version';
  final digest = sha256.convert(utf8.encode(identity)).toString();
  return (
    recordingId: recordingId,
    asrTaskId: asrTaskId,
    version: version,
    identity: identity,
    idempotencyKey: 'idem-auto-speaker-${digest.substring(0, 32)}',
  );
}

String _normalizedRecordingStage(String? value) {
  return value
          ?.trim()
          .toLowerCase()
          .replaceAll('-', '_')
          .replaceAll(' ', '_') ??
      '';
}

String? _terminalFailureCode(RecordingDetail detail) {
  final failureStatus = detail.rawTerminalFailureStatus;
  if (failureStatus == null) return null;
  return failureStatus == RecordingRemoteStatus.timeout
      ? 'RECORDING_TRANSCRIPTION_TIMEOUT'
      : 'RECORDING_TRANSCRIPTION_FAILED';
}

Duration _readFailureDelay(int consecutiveFailures) {
  final seconds = consecutiveFailures * 3;
  return Duration(seconds: seconds > 15 ? 15 : seconds);
}

RecordingProcessingPhase _latchedActivePhase(
  RecordingProcessingPhase? current,
  RecordingDetail detail,
) {
  final observed = !detail.hasFinalTranscriptFact
      ? RecordingProcessingPhase.transcribing
      : RecordingProcessingPhase.storingCloudNote;
  if (current == null ||
      !<RecordingProcessingPhase>{
        RecordingProcessingPhase.transcribing,
        RecordingProcessingPhase.storingCloudNote,
      }.contains(current)) {
    return observed;
  }
  return _activePhaseRank(observed) >= _activePhaseRank(current)
      ? observed
      : current;
}

int _activePhaseRank(RecordingProcessingPhase phase) => switch (phase) {
  RecordingProcessingPhase.transcribing => 0,
  RecordingProcessingPhase.storingCloudNote => 1,
  RecordingProcessingPhase.completed || RecordingProcessingPhase.failed => 2,
};

String? _normalizeAccountScope(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _normalizeWorkspaceScope(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _normalizeRecordingId(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _recordingDetailSignature(RecordingDetail detail) {
  final noteRef = detail.noteRef;
  final noteOutlineTask = detail.noteOutlineTask;
  return <String>[
    detail.recording.status.name,
    detail.asrTask?.status.name ?? '',
    detail.recording.transcriptStatus ?? '',
    detail.recording.speakerLabelStatus ?? '',
    detail.recording.minutesStatus ?? '',
    detail.recording.summaryStatus ?? '',
    detail.recording.depositStatus ?? '',
    noteRef?.noteId ?? '',
    noteRef?.rawPartRevisionId ?? '',
    noteRef?.outlinePartRevisionId ?? '',
    noteOutlineTask?.taskId ?? '',
    noteOutlineTask?.status.name ?? '',
    detail.hasGeneratedOutline ? 'outline' : '',
    detail.hasCloudAsset ? 'asset' : '',
  ].join('\u0000');
}
