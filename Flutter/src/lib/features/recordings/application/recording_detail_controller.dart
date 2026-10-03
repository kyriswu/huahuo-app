import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import 'recording_processing_tracker.dart';
import '../data/recording_api.dart';
import '../domain/recording_library.dart';

enum RecordingDetailControllerStatus {
  idle,
  loading,
  polling,
  terminal,
  retrying,
  failed,
}

final class RecordingDetailState {
  const RecordingDetailState({
    required this.status,
    required this.pollCount,
    this.detail,
    this.accountScope,
    this.lastErrorCode,
  });

  factory RecordingDetailState.initial() {
    return const RecordingDetailState(
      status: RecordingDetailControllerStatus.idle,
      pollCount: 0,
    );
  }

  final RecordingDetailControllerStatus status;
  final int pollCount;
  final RecordingDetail? detail;
  final String? accountScope;
  final String? lastErrorCode;

  RecordingDetailState copyWith({
    RecordingDetailControllerStatus? status,
    int? pollCount,
    Object? detail = _detailUnset,
    Object? accountScope = _detailUnset,
    Object? lastErrorCode = _detailUnset,
  }) {
    return RecordingDetailState(
      status: status ?? this.status,
      pollCount: pollCount ?? this.pollCount,
      detail: identical(detail, _detailUnset)
          ? this.detail
          : detail as RecordingDetail?,
      accountScope: identical(accountScope, _detailUnset)
          ? this.accountScope
          : accountScope as String?,
      lastErrorCode: identical(lastErrorCode, _detailUnset)
          ? this.lastErrorCode
          : lastErrorCode as String?,
    );
  }
}

const _DetailUnset _detailUnset = _DetailUnset();

final class _DetailUnset {
  const _DetailUnset();
}

typedef PollDelay = Future<void> Function(Duration duration);

final class RecordingDetailController extends ChangeNotifier {
  RecordingDetailController({
    required RecordingApiPort api,
    this.pollInterval = const Duration(seconds: 3),
    this.maxPollAttempts = 200,
    PollDelay? delay,
    String Function()? idempotencyKeyFactory,
    String? accountScope,
    String? Function()? activeAccountScope,
    RecordingProcessingRetryPort? processingRetryPort,
    RecordingProcessingDetailObservationPort? processingObservationPort,
    RecordingSpeakerAutoAdvancePort? speakerAutoAdvancePort,
  }) : _api = api,
       _delay = delay ?? Future<void>.delayed,
       _idempotencyKeyFactory = idempotencyKeyFactory,
       _accountScope = _normalizeAccountScope(accountScope),
       _activeAccountScope = activeAccountScope,
       _processingRetryPort = processingRetryPort,
       _processingObservationPort = processingObservationPort,
       _speakerAutoAdvancePort = speakerAutoAdvancePort {
    _processingObservationPort?.addProcessingDetailListener(
      _handleSharedProcessingChanged,
    );
  }

  final RecordingApiPort _api;
  final PollDelay _delay;
  final String Function()? _idempotencyKeyFactory;
  final String? _accountScope;
  final String? Function()? _activeAccountScope;
  final RecordingProcessingRetryPort? _processingRetryPort;
  final RecordingProcessingDetailObservationPort? _processingObservationPort;
  final RecordingSpeakerAutoAdvancePort? _speakerAutoAdvancePort;
  final Duration pollInterval;
  final int maxPollAttempts;

  RecordingDetailState _state = RecordingDetailState.initial();
  int _generation = 0;
  bool _disposed = false;
  bool _pollingRouteActive = true;
  String? _activePollingRecordingId;
  int? _activePollingGeneration;
  String? _requestedRecordingId;
  int? _requestedGeneration;
  bool _observingSharedProcessing = false;
  int _pollAttempts = 0;
  Completer<void>? _pollCompletion;
  OrchestratedPoller? _poller;
  TaskOrchestrator? _orchestrator;
  RuntimeActivityMetrics? _activityMetrics;

  RecordingDetailState get state => _state;

  void attachPollingRuntime({
    required TaskOrchestrator orchestrator,
    required RuntimeActivityMetrics activityMetrics,
  }) {
    if (_disposed) return;
    final changed =
        !identical(_orchestrator, orchestrator) ||
        !identical(_activityMetrics, activityMetrics);
    if (changed) {
      _poller?.dispose();
      _poller = null;
      _orchestrator = orchestrator;
      _activityMetrics = activityMetrics;
    }
    _installActivePoller();
  }

  void setPollingRouteActive(bool active) {
    if (_disposed || _pollingRouteActive == active) return;
    _pollingRouteActive = active;
    if (!active) {
      _poller?.stop();
      return;
    }
    if (_poller == null) {
      _installActivePoller();
    } else {
      _poller!.start();
    }
  }

  Future<void> loadAndPoll(String recordingId) async {
    if (_cancelIfAccountChanged()) return;
    final generation = ++_generation;
    _state = _state.copyWith(
      status: RecordingDetailControllerStatus.loading,
      pollCount: 0,
      detail: null,
      accountScope: _accountScope,
      lastErrorCode: null,
    );
    _publish();
    await _startPolling(recordingId, generation: generation);
  }

  Future<void> retryRecording(String stage) async {
    if (_cancelIfAccountChanged()) return;
    final detail = _state.detail;
    final recordingId = detail?.recording.recordingId;
    final normalizedStage = stage.trim();
    final allowed = detail?.isRetryAllowed(normalizedStage);
    if (recordingId == null) {
      _fail(recordingApiFailure('RECORDING_DETAIL_MISSING'));
      return;
    }
    if (allowed != true) {
      _fail(recordingApiFailure('RECORDING_RETRY_NOT_ALLOWED'));
      return;
    }
    final generation = ++_generation;
    _state = _state.copyWith(
      status: RecordingDetailControllerStatus.retrying,
      lastErrorCode: null,
    );
    _publish();
    final result = await _api.retryRecording(
      recordingId: recordingId,
      stage: normalizedStage,
      idempotencyKey: _nextIdempotencyKey('retry-recording'),
    );
    if (_cancelIfAccountChanged() || generation != _generation) return;
    if (!result.ok) {
      _fail(result.error ?? recordingApiFailure('RECORDING_RETRY_FAILED'));
      return;
    }
    final receipt = result.data;
    if (receipt == null ||
        receipt.recordingId != recordingId ||
        receipt.stage != normalizedStage ||
        !receipt.status.isAccepted) {
      _fail(recordingApiFailure('RECORDING_RETRY_RESPONSE_INVALID'));
      return;
    }
    final sharedObservationReenrolled = await _reenrollProcessingAfterRetry(
      recordingId,
    );
    if (_cancelIfAccountChanged() || generation != _generation) return;
    await _startPolling(
      recordingId,
      generation: generation,
      allowSharedObservation: sharedObservationReenrolled,
    );
  }

  Future<bool> _reenrollProcessingAfterRetry(String recordingId) async {
    final processingRetryPort = _processingRetryPort;
    if (processingRetryPort == null) return false;
    try {
      return await processingRetryPort.reenrollAfterRetry(recordingId);
    } on Object {
      // The server has accepted the retry. Foreground detail observation still
      // remains useful when a local durable checkpoint cannot be updated.
      return false;
    }
  }

  Future<void> _startPolling(
    String recordingId, {
    required int generation,
    bool allowSharedObservation = true,
  }) {
    _cancelPollingRun();
    _requestedRecordingId = recordingId;
    _requestedGeneration = generation;
    if (allowSharedObservation &&
        _adoptSharedProcessing(recordingId, generation: generation)) {
      return Future<void>.value();
    }
    return _startDirectPolling(recordingId, generation: generation);
  }

  bool _adoptSharedProcessing(String recordingId, {required int generation}) {
    final task = _processingObservationPort?.processingTaskFor(recordingId);
    if (task == null || (!task.isActive && task.detail == null)) return false;
    _cancelDirectPollingRun();
    _observingSharedProcessing = true;
    _applySharedProcessingTask(task, generation: generation);
    return true;
  }

  void _handleSharedProcessingChanged() {
    if (_disposed || _cancelIfAccountChanged()) return;
    final recordingId = _requestedRecordingId;
    final generation = _requestedGeneration;
    if (recordingId == null ||
        generation == null ||
        generation != _generation) {
      return;
    }
    final task = _processingObservationPort?.processingTaskFor(recordingId);
    if (task == null) {
      if (_observingSharedProcessing) {
        _observingSharedProcessing = false;
        unawaited(_startDirectPolling(recordingId, generation: generation));
      }
      return;
    }
    if (!_observingSharedProcessing) {
      if (!task.isActive) return;
      _cancelDirectPollingRun();
      _observingSharedProcessing = true;
    }
    _applySharedProcessingTask(task, generation: generation);
  }

  void _applySharedProcessingTask(
    RecordingProcessingTask task, {
    required int generation,
  }) {
    if (_disposed || generation != _generation) return;
    final detail = task.detail;
    final expectedRecordingId = _requestedRecordingId;
    if (detail != null && detail.recording.recordingId != expectedRecordingId) {
      return;
    }
    final terminal =
        task.status == RecordingFileJobStatus.ready ||
        task.status == RecordingFileJobStatus.failed;
    final localFailure =
        task.status == RecordingFileJobStatus.failed && detail == null;
    _state = _state.copyWith(
      status: localFailure
          ? RecordingDetailControllerStatus.failed
          : detail == null
          ? RecordingDetailControllerStatus.loading
          : terminal
          ? RecordingDetailControllerStatus.terminal
          : RecordingDetailControllerStatus.polling,
      detail: detail,
      accountScope: _accountScope,
      lastErrorCode: localFailure ? task.errorCode : null,
    );
    _publish();
  }

  Future<void> _startDirectPolling(
    String recordingId, {
    required int generation,
  }) {
    if (_disposed || generation != _generation) return Future<void>.value();
    if (_orchestrator == null ||
        _activityMetrics == null ||
        pollInterval <= Duration.zero) {
      return _pollWithInjectedDelay(recordingId, generation: generation);
    }
    _activePollingRecordingId = recordingId;
    _activePollingGeneration = generation;
    _pollAttempts = 0;
    final completion = Completer<void>();
    _pollCompletion = completion;
    _installActivePoller();
    return completion.future;
  }

  Future<void> _pollWithInjectedDelay(
    String recordingId, {
    required int generation,
  }) async {
    if (_cancelIfAccountChanged()) return;
    var attempts = 0;
    var consecutiveReadFailures = 0;
    while (attempts < maxPollAttempts) {
      if (_cancelIfAccountChanged() ||
          generation != _generation ||
          _observingSharedProcessing) {
        return;
      }
      attempts += 1;
      final result = await _api.getRecordingDetail(recordingId);
      if (_cancelIfAccountChanged() ||
          generation != _generation ||
          _observingSharedProcessing) {
        return;
      }
      if (!result.ok || result.data == null) {
        final failure =
            result.error ?? recordingApiFailure('RECORDING_DETAIL_FAILED');
        if (failure.isRetryable) {
          consecutiveReadFailures += 1;
          _state = _state.copyWith(
            status: _state.detail == null
                ? RecordingDetailControllerStatus.loading
                : RecordingDetailControllerStatus.polling,
            pollCount: attempts,
            lastErrorCode: null,
          );
          _publish();
          if (attempts < maxPollAttempts) {
            await _delay(_detailReadFailureDelay(consecutiveReadFailures));
          }
          continue;
        }
        _fail(failure);
        return;
      }
      consecutiveReadFailures = 0;
      final detail = result.data!;
      _state = _state.copyWith(
        status: detail.shouldStopPolling
            ? RecordingDetailControllerStatus.terminal
            : RecordingDetailControllerStatus.polling,
        detail: detail,
        pollCount: attempts,
        lastErrorCode: null,
      );
      _publish();
      final speakerAdvance = await _advanceSpeakerStage(detail);
      if (_cancelIfAccountChanged() ||
          generation != _generation ||
          _observingSharedProcessing) {
        return;
      }
      if (speakerAdvance.status !=
          RecordingSpeakerAutoAdvanceStatus.notRequired) {
        if (attempts < maxPollAttempts) await _delay(pollInterval);
        continue;
      }
      if (detail.shouldStopPolling) return;
      await _delay(pollInterval);
      if (_cancelIfAccountChanged() || generation != _generation) return;
    }
  }

  void _installActivePoller() {
    final orchestrator = _orchestrator;
    final activityMetrics = _activityMetrics;
    final recordingId = _activePollingRecordingId;
    final generation = _activePollingGeneration;
    if (_disposed ||
        orchestrator == null ||
        activityMetrics == null ||
        recordingId == null ||
        generation == null ||
        _poller != null) {
      return;
    }
    final stableId = _stableDetailPollId(recordingId);
    // performance-rfc: recording-detail-poll
    _poller = OrchestratedPoller(
      orchestrator: orchestrator,
      spec: TaskSpec(
        key: 'recording:detail:$stableId',
        owner: 'recording-detail',
        priority: TaskPriority.userVisible,
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
      metricsOwner: 'recording.detail.$stableId',
      poll: (token) =>
          _pollOnce(recordingId, generation: generation, token: token),
    );
    if (_pollingRouteActive) _poller!.start();
  }

  Future<bool> _pollOnce(
    String recordingId, {
    required int generation,
    required AppTaskCancellationToken token,
  }) async {
    token.throwIfCancelled();
    if (_cancelIfAccountChanged() || generation != _generation) return false;
    if (_pollAttempts >= maxPollAttempts) {
      _completePollingRun();
      return false;
    }
    _pollAttempts += 1;
    final result = await _api.getRecordingDetail(recordingId);
    token.throwIfCancelled();
    if (_cancelIfAccountChanged() || generation != _generation) return false;
    if (!result.ok || result.data == null) {
      final failure =
          result.error ?? recordingApiFailure('RECORDING_DETAIL_FAILED');
      if (failure.isRetryable) {
        _state = _state.copyWith(
          status: _state.detail == null
              ? RecordingDetailControllerStatus.loading
              : RecordingDetailControllerStatus.polling,
          pollCount: _pollAttempts,
          lastErrorCode: null,
        );
        _publish();
        if (_pollAttempts >= maxPollAttempts) {
          _completePollingRun();
          return false;
        }
        throw StateError(failure.code);
      }
      _fail(failure);
      _completePollingRun();
      return false;
    }
    final detail = result.data!;
    _state = _state.copyWith(
      status: detail.shouldStopPolling
          ? RecordingDetailControllerStatus.terminal
          : RecordingDetailControllerStatus.polling,
      detail: detail,
      pollCount: _pollAttempts,
      lastErrorCode: null,
    );
    _publish();
    final speakerAdvance = await _advanceSpeakerStage(detail);
    token.throwIfCancelled();
    if (_cancelIfAccountChanged() || generation != _generation) return false;
    if (speakerAdvance.status !=
        RecordingSpeakerAutoAdvanceStatus.notRequired) {
      if (_pollAttempts >= maxPollAttempts) {
        _completePollingRun();
        return false;
      }
      if (speakerAdvance.status ==
          RecordingSpeakerAutoAdvanceStatus.retryWaiting) {
        throw StateError(
          speakerAdvance.errorCode ?? 'RECORDING_SPEAKER_AUTO_ADVANCE_FAILED',
        );
      }
      return true;
    }
    if (detail.shouldStopPolling) {
      _completePollingRun();
      return false;
    }
    if (_pollAttempts >= maxPollAttempts) {
      _completePollingRun();
      return false;
    }
    return true;
  }

  Future<RecordingSpeakerAutoAdvanceOutcome> _advanceSpeakerStage(
    RecordingDetail detail,
  ) async {
    final port = _speakerAutoAdvancePort;
    if (port == null) {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.notRequired,
      );
    }
    try {
      return await port.advanceSpeakerStageIfNeeded(detail);
    } on Object {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.retryWaiting,
        errorCode: 'RECORDING_SPEAKER_AUTO_ADVANCE_FAILED',
      );
    }
  }

  String _nextIdempotencyKey(String operation) {
    final custom = _idempotencyKeyFactory?.call();
    if (custom != null && custom.isNotEmpty) return custom;
    return 'idem-$operation-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  }

  void _fail(AppFailure failure) {
    if (_cancelIfAccountChanged()) return;
    _state = _state.copyWith(
      status: RecordingDetailControllerStatus.failed,
      lastErrorCode: failure.code,
    );
    _publish();
  }

  bool _cancelIfAccountChanged() {
    if (_disposed) return true;
    final accountScope = _accountScope;
    final activeAccountScope = _activeAccountScope;
    if (accountScope == null || activeAccountScope == null) return false;
    if (accountScope == _normalizeAccountScope(activeAccountScope())) {
      return false;
    }

    _generation += 1;
    _cancelPollingRun();
    _state = _state.copyWith(
      status: RecordingDetailControllerStatus.failed,
      pollCount: 0,
      detail: null,
      accountScope: null,
      lastErrorCode: 'RECORDING_DETAIL_ACCOUNT_CHANGED',
    );
    _publish();
    return true;
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _cancelPollingRun();
    _processingObservationPort?.removeProcessingDetailListener(
      _handleSharedProcessingChanged,
    );
    super.dispose();
  }

  void _cancelPollingRun() {
    _cancelDirectPollingRun();
    _requestedRecordingId = null;
    _requestedGeneration = null;
    _observingSharedProcessing = false;
  }

  void _cancelDirectPollingRun() {
    _poller?.dispose();
    _poller = null;
    _activePollingRecordingId = null;
    _activePollingGeneration = null;
    final completion = _pollCompletion;
    _pollCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  void _completePollingRun() {
    _activePollingRecordingId = null;
    _activePollingGeneration = null;
    final completion = _pollCompletion;
    _pollCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }
}

Duration _detailReadFailureDelay(int consecutiveFailures) {
  final seconds = consecutiveFailures * 3;
  return Duration(seconds: seconds > 15 ? 15 : seconds);
}

String? _normalizeAccountScope(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _stableDetailPollId(String value) {
  final digest = sha256.convert(utf8.encode(value)).toString();
  return digest.substring(0, 16);
}
