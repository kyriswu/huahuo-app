import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/foundation.dart';

import '../../../core/auth/session_store.dart';
import '../../chat/application/chat_run_tracker.dart';
import '../../chat/domain/chat_models.dart';
import '../../ui_v3/data/deep_positioning_repository.dart';
import '../../ui_v3/application/positioning_lifecycle_coordinator.dart';
import '../data/initial_positioning_agent.dart';
import '../data/onboarding_api.dart';
import '../data/onboarding_progress_repository.dart';
import 'content_line_onboarding_controller.dart';

typedef InitialPositioningReportAcknowledger = bool Function(String agentRunId);

typedef InitialPositioningRunRegistrar =
    Future<bool> Function(String agentRunId);

enum InitialPositioningTaskStatus {
  idle,
  registering,
  running,
  finalizing,
  succeeded,
  failed,
}

@immutable
final class InitialPositioningTaskState {
  const InitialPositioningTaskState({
    this.status = InitialPositioningTaskStatus.idle,
    this.workspaceId,
    this.agentRunId,
    this.reportReadyAgentRunId,
    this.threadId,
    this.errorCode,
    this.updatedAt,
    this.toolTrace = const <AgentRunToolTrace>[],
  });

  final InitialPositioningTaskStatus status;
  final String? workspaceId;
  final String? agentRunId;
  final String? reportReadyAgentRunId;
  final String? threadId;
  final String? errorCode;
  final DateTime? updatedAt;
  final List<AgentRunToolTrace> toolTrace;

  bool get isTerminal =>
      status == InitialPositioningTaskStatus.succeeded ||
      status == InitialPositioningTaskStatus.failed;

  bool isReportReadyFor(String? candidateAgentRunId) {
    final candidate = candidateAgentRunId?.trim();
    return candidate != null &&
        candidate.isNotEmpty &&
        status == InitialPositioningTaskStatus.succeeded &&
        agentRunId == candidate &&
        reportReadyAgentRunId == candidate;
  }
}

enum InitialPositioningServerPhase {
  notStarted,
  queued,
  running,
  finalizing,
  completed,
  failed,
  unavailable,
}

@immutable
final class InitialPositioningServerState {
  const InitialPositioningServerState({
    required this.workspaceId,
    required this.phase,
    this.attemptId,
    this.agentRunId,
    this.errorCode,
    this.retryable = false,
  });

  factory InitialPositioningServerState.fromAttempt(
    InitialPositioningAttempt attempt,
  ) {
    final phase = switch (attempt.state) {
      'not_started' => InitialPositioningServerPhase.notStarted,
      'queued' => InitialPositioningServerPhase.queued,
      'running' => InitialPositioningServerPhase.running,
      'finalizing' => InitialPositioningServerPhase.finalizing,
      'completed' => InitialPositioningServerPhase.completed,
      'failed_retryable' ||
      'failed_terminal' ||
      'cancelled' ||
      'superseded' => InitialPositioningServerPhase.failed,
      _ => InitialPositioningServerPhase.unavailable,
    };
    final attemptId = attempt.attemptId?.trim();
    final agentRunId = attempt.agentRunId?.trim();
    if (phase != InitialPositioningServerPhase.notStarted &&
        (attemptId == null ||
            attemptId.isEmpty ||
            agentRunId == null ||
            agentRunId.isEmpty)) {
      return InitialPositioningServerState.unavailable(
        workspaceId: attempt.workspaceId,
        errorCode: 'INITIAL_POSITIONING_CURRENT_INVALID',
        retryable: false,
      );
    }
    return InitialPositioningServerState(
      workspaceId: attempt.workspaceId,
      phase: phase,
      attemptId: attemptId,
      agentRunId: agentRunId,
      errorCode: phase == InitialPositioningServerPhase.failed
          ? attempt.failureCode ?? 'ONBOARDING_FORMALIZATION_FAILED'
          : null,
    );
  }

  factory InitialPositioningServerState.unavailable({
    required String workspaceId,
    String? errorCode,
    bool retryable = true,
  }) {
    return InitialPositioningServerState(
      workspaceId: workspaceId,
      phase: InitialPositioningServerPhase.unavailable,
      errorCode: errorCode ?? 'INITIAL_POSITIONING_CURRENT_UNAVAILABLE',
      retryable: retryable,
    );
  }

  final String workspaceId;
  final InitialPositioningServerPhase phase;
  final String? attemptId;
  final String? agentRunId;
  final String? errorCode;
  final bool retryable;

  bool get isCompleted => phase == InitialPositioningServerPhase.completed;

  bool get shouldPoll => switch (phase) {
    InitialPositioningServerPhase.queued ||
    InitialPositioningServerPhase.running ||
    InitialPositioningServerPhase.finalizing => true,
    InitialPositioningServerPhase.unavailable => retryable,
    InitialPositioningServerPhase.notStarted ||
    InitialPositioningServerPhase.completed ||
    InitialPositioningServerPhase.failed => false,
  };

  InitialPositioningTaskState get taskState => InitialPositioningTaskState(
    status: switch (phase) {
      InitialPositioningServerPhase.queued ||
      InitialPositioningServerPhase.running =>
        InitialPositioningTaskStatus.running,
      InitialPositioningServerPhase.finalizing =>
        InitialPositioningTaskStatus.finalizing,
      InitialPositioningServerPhase.completed =>
        InitialPositioningTaskStatus.succeeded,
      InitialPositioningServerPhase.failed =>
        InitialPositioningTaskStatus.failed,
      InitialPositioningServerPhase.notStarted ||
      InitialPositioningServerPhase.unavailable =>
        InitialPositioningTaskStatus.idle,
    },
    workspaceId: workspaceId,
    agentRunId: agentRunId,
    errorCode: errorCode,
  );
}

typedef InitialPositioningServerStateReader =
    Future<InitialPositioningServerState> Function({
      required String workspaceId,
    });

/// Completes an accepted initial-positioning Run independently of the
/// questionnaire page. The persisted checkpoint is account-isolated and the
/// only durable source used to recover after a page/app lifecycle transition.
final class InitialPositioningTaskCoordinator extends ChangeNotifier {
  InitialPositioningTaskCoordinator({
    required OnboardingApiPort onboardingApi,
    required InitialPositioningAgentPort positioningAgent,
    required SessionStore sessionStore,
    required InitialPositioningReportSink reportSink,
    required OnboardingContinuationController continuation,
    required ChatRunTracker taskTracker,
    DateTime Function()? now,
    Duration reportReadbackRetryInterval = const Duration(seconds: 3),
    PositioningLifecycleCoordinator? reportLifecycle,
    Future<bool> Function(String runId, String workspaceId)? verifyRunWorkspace,
  }) : _onboardingApi = onboardingApi,
       _positioningAgent = positioningAgent,
       _sessionStore = sessionStore,
       _reportSink = reportSink,
       _continuation = continuation,
       _taskTracker = taskTracker,
       _reportLifecycle = reportLifecycle,
       _verifyRunWorkspace = verifyRunWorkspace,
       _workspaceId = sessionStore.state.workspace?.workspaceId,
       _now = now ?? DateTime.now,
       _reportReadbackRetryInterval = reportReadbackRetryInterval {
    _sessionStore.addListener(_scheduleRefresh);
    _continuation.addListener(_scheduleRefresh);
    _taskTracker.addListener(_handleTaskChanged);
  }

  final OnboardingApiPort _onboardingApi;
  final InitialPositioningAgentPort _positioningAgent;
  final SessionStore _sessionStore;
  final InitialPositioningReportSink _reportSink;
  final OnboardingContinuationController _continuation;
  final ChatRunTracker _taskTracker;
  final PositioningLifecycleCoordinator? _reportLifecycle;
  final Future<bool> Function(String runId, String workspaceId)?
  _verifyRunWorkspace;
  final String? _workspaceId;
  final DateTime Function() _now;
  final Duration _reportReadbackRetryInterval;

  InitialPositioningTaskState _state = const InitialPositioningTaskState();
  Future<void>? _refreshInFlight;
  Future<void>? _finalizationInFlight;
  Timer? _finalizationRetryTimer;
  Future<_CompletedReportReadback>? _reportReadbackInFlight;
  String? _reportReadbackKey;
  String? _savedReportUserId;
  String? _savedReportRunId;
  String? _receiptPersistencePendingUserId;
  String? _receiptPersistencePendingRunId;
  OnboardingAcceptedRunReportSource _receiptPersistencePendingReportSource =
      OnboardingAcceptedRunReportSource.agentReply;
  final Map<String, Future<bool>> _registrationsInFlight = {};
  bool _foreground = false;
  bool _disposed = false;
  bool _taskRefreshPending = false;
  int _readbackRetries = 0;

  InitialPositioningTaskState get state => _state;

  Future<void> start() {
    if (_disposed) return Future<void>.value();
    _foreground = true;
    _readbackRetries = 0;
    unawaited(_reportLifecycle?.start());
    return refresh();
  }

  Future<void> resume() => start();

  Future<bool> ensureBackendRegistered(String agentRunId) {
    final userId = _currentUserId;
    final workspaceId = _sessionStore.state.workspace?.workspaceId;
    final accepted = _continuation.acceptedRunFor(userId);
    if (_disposed ||
        !_workspaceReady ||
        accepted == null ||
        accepted.agentRunId != agentRunId ||
        (accepted.workspaceId != null && accepted.workspaceId != workspaceId)) {
      return Future<bool>.value(false);
    }
    if (accepted.isRegisteredFor(workspaceId)) return Future<bool>.value(true);
    final key = '$userId:$workspaceId:$agentRunId';
    return _registrationsInFlight.putIfAbsent(key, () {
      return _bindAcceptedRun(userId, accepted).whenComplete(() {
        _registrationsInFlight.remove(key);
      });
    });
  }

  void pause() {
    _foreground = false;
    _reportLifecycle?.pause();
    _finalizationRetryTimer?.cancel();
    _finalizationRetryTimer = null;
  }

  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    final active = _refreshInFlight;
    if (active != null) return active;
    final completion = Completer<void>();
    final operation = completion.future;
    _refreshInFlight = operation;
    unawaited(_runRefresh(operation, completion));
    return operation;
  }

  Future<void> _runRefresh(
    Future<void> operation,
    Completer<void> completion,
  ) async {
    try {
      do {
        _taskRefreshPending = false;
        await _refresh();
      } while (_taskRefreshPending && _foreground && !_disposed);
      if (!completion.isCompleted) completion.complete();
    } catch (error, stackTrace) {
      if (!completion.isCompleted) completion.completeError(error, stackTrace);
    } finally {
      if (identical(_refreshInFlight, operation)) {
        _refreshInFlight = null;
      }
    }
  }

  bool acknowledgeReportShown({required String agentRunId}) {
    final userId = _currentUserId;
    if (userId.isEmpty || !_state.isReportReadyFor(agentRunId)) {
      return false;
    }
    final saved = _continuation.acknowledgeSucceededRun(userId);
    if (saved) _publish(const InitialPositioningTaskState());
    return saved;
  }

  void _scheduleRefresh() {
    if (!_foreground || _disposed) return;
    unawaited(refresh());
  }

  void _handleTaskChanged() {
    if (!_foreground || _disposed) return;
    if (_refreshInFlight != null) {
      _taskRefreshPending = true;
      return;
    }
    _scheduleRefresh();
  }

  Future<void> _refresh() async {
    if (_disposed || !_foreground) return;
    final userId = _currentUserId;
    if (userId.isEmpty) {
      _publish(const InitialPositioningTaskState());
      return;
    }
    var accepted = _continuation.acceptedRunFor(userId);
    if (accepted == null) {
      _publish(const InitialPositioningTaskState());
      return;
    }
    if (!accepted.isBackendRegistered &&
        accepted.lifecycle != OnboardingAcceptedRunLifecycle.failed) {
      _publish(_stateFor(accepted, InitialPositioningTaskStatus.registering));
      final registered = await ensureBackendRegistered(accepted.agentRunId);
      if (!_isCurrentUser(userId) ||
          _continuation.acceptedRunFor(userId)?.agentRunId !=
              accepted.agentRunId) {
        _taskRefreshPending = true;
        return;
      }
      accepted = _continuation.acceptedRunFor(userId)!;
      if (!registered) return;
    }
    if (_receiptPersistencePendingUserId == userId &&
        _receiptPersistencePendingRunId == accepted.agentRunId) {
      if (!_continuation.markRunSucceeded(
        userId,
        reportSource: _receiptPersistencePendingReportSource,
      )) {
        _publish(_stateFor(accepted, InitialPositioningTaskStatus.finalizing));
        _scheduleFinalizationRetry();
        return;
      }
      _receiptPersistencePendingUserId = null;
      _receiptPersistencePendingRunId = null;
      _receiptPersistencePendingReportSource =
          OnboardingAcceptedRunReportSource.agentReply;
      accepted = _continuation.acceptedRunFor(userId);
      if (accepted == null) return;
    }
    if (accepted.lifecycle == OnboardingAcceptedRunLifecycle.succeeded) {
      _publish(_stateFor(accepted, InitialPositioningTaskStatus.succeeded));
      final reportReadback = await _ensureSucceededReport(userId, accepted);
      if (!_isCurrentUser(userId)) return;
      final current = _continuation.acceptedRunFor(userId);
      if (current == null || current.agentRunId != accepted.agentRunId) return;
      if (current.lifecycle == OnboardingAcceptedRunLifecycle.failed) {
        _publish(_stateFor(current, InitialPositioningTaskStatus.failed));
        return;
      }
      if (reportReadback == _CompletedReportReadback.saved) {
        _publish(_stateFor(current, InitialPositioningTaskStatus.succeeded));
      } else if (reportReadback == _CompletedReportReadback.retrying ||
          reportReadback == _CompletedReportReadback.unsupported) {
        _scheduleFinalizationRetry();
      }
      return;
    }
    final reconcileFinalization = accepted.needsFinalizationReconciliation;
    if (accepted.lifecycle == OnboardingAcceptedRunLifecycle.failed &&
        !reconcileFinalization) {
      final recovered = await _recoverCommittedReportAfterRuntimeGap(
        userId,
        accepted,
      );
      if (!_isCurrentUser(userId)) return;
      final current = _continuation.acceptedRunFor(userId);
      if (current == null || current.agentRunId != accepted.agentRunId) {
        _taskRefreshPending = true;
        return;
      }
      if (!recovered) {
        _publish(_stateFor(current, InitialPositioningTaskStatus.failed));
      }
      return;
    }
    if (!_workspaceReady ||
        (reconcileFinalization &&
            !isSafeChatIdentifier(
              _sessionStore.state.workspace?.workspaceId?.trim() ?? '',
            ))) {
      final status = reconcileFinalization
          ? InitialPositioningTaskStatus.failed
          : accepted.lifecycle == OnboardingAcceptedRunLifecycle.finalizing
          ? InitialPositioningTaskStatus.finalizing
          : InitialPositioningTaskStatus.running;
      _publish(_stateFor(accepted, status));
      return;
    }

    await _taskTracker.track(
      agentRunId: accepted.agentRunId,
      threadId: accepted.threadId,
      scene: ChatScene.workAi,
      purpose: ChatConversationPurpose.deepPositioning,
    );
    if (!_isCurrentUser(userId)) return;

    if (_continuation.acceptedRunFor(userId)?.agentRunId !=
        accepted.agentRunId) {
      _taskRefreshPending = true;
      return;
    }

    if (accepted.lifecycle == OnboardingAcceptedRunLifecycle.finalizing) {
      await _finalizeAcceptedRun(userId, accepted);
      return;
    }

    AgentTaskLedgerEntry? tracked;
    for (final entry in _taskTracker.taskLedger) {
      if (entry.kind == 'chat' &&
          entry.taskId == accepted.agentRunId &&
          entry.threadId == accepted.threadId) {
        tracked = entry;
        break;
      }
    }
    if (tracked == null || !tracked.isTerminal) {
      _publish(
        _stateFor(
          accepted,
          reconcileFinalization
              ? InitialPositioningTaskStatus.failed
              : InitialPositioningTaskStatus.running,
        ),
      );
      return;
    }
    if (tracked.status != 'succeeded') {
      _markFailed(
        userId,
        tracked.failureCode ?? _runFailureCode(tracked.status),
      );
      return;
    }
    await _finalizeAcceptedRun(userId, accepted);
  }

  Future<bool> _recoverCommittedReportAfterRuntimeGap(
    String userId,
    OnboardingAcceptedRun accepted,
  ) async {
    final workspaceId = _sessionStore.state.workspace?.workspaceId?.trim();
    if (!_workspaceReady ||
        workspaceId == null ||
        !accepted.isRegisteredFor(workspaceId) ||
        !_isRuntimeGapRecoveryFailure(accepted.failureCode)) {
      return false;
    }

    await _taskTracker.track(
      agentRunId: accepted.agentRunId,
      threadId: accepted.threadId,
      scene: ChatScene.workAi,
      purpose: ChatConversationPurpose.deepPositioning,
    );
    if (!_isCurrentUser(userId) ||
        _continuation.acceptedRunFor(userId)?.agentRunId !=
            accepted.agentRunId) {
      return true;
    }

    AgentTaskLedgerEntry? tracked;
    for (final entry in _taskTracker.taskLedger) {
      if (entry.kind == 'chat' &&
          entry.taskId == accepted.agentRunId &&
          entry.threadId == accepted.threadId) {
        tracked = entry;
        break;
      }
    }
    if (tracked == null ||
        !_isRuntimeGapTerminalEvidence(accepted.failureCode, tracked)) {
      return false;
    }

    final api = _onboardingApi;
    if (api is! OnboardingInitialPositioningPort) return false;
    final current = await (api as OnboardingInitialPositioningPort)
        .currentInitialPositioning(workspaceId: workspaceId);
    if (!_isCurrentUser(userId) ||
        _continuation.acceptedRunFor(userId)?.agentRunId !=
            accepted.agentRunId) {
      return true;
    }
    final attempt = current.data;
    if (!current.ok ||
        attempt == null ||
        attempt.workspaceId != workspaceId ||
        attempt.attemptId != accepted.attemptId ||
        attempt.agentRunId != accepted.agentRunId ||
        !attempt.hasCommittedReportForTerminalGap) {
      return false;
    }

    final reportReadback = await _readWorkspaceProfileReport(
      userId,
      accepted,
      savedAt: attempt.reportEvidence!.lastUpdated,
    );
    if (reportReadback == _CompletedReportReadback.cancelled) return true;
    if (reportReadback != _CompletedReportReadback.saved) return false;
    _completeFinalization(
      userId,
      accepted,
      reportSource: OnboardingAcceptedRunReportSource.workspaceProfile,
    );
    return true;
  }

  Future<bool> _bindAcceptedRun(
    String userId,
    OnboardingAcceptedRun accepted,
  ) async {
    final workspaceId = _sessionStore.state.workspace?.workspaceId;
    final api = _onboardingApi;
    if (api is! OnboardingInitialPositioningPort || workspaceId == null) {
      _markFailed(userId, 'ONBOARDING_FORMALIZATION_UNAVAILABLE');
      return false;
    }
    final formalApi = api as OnboardingInitialPositioningPort;
    bool isCurrent() =>
        _isCurrentUser(userId) &&
        _sessionStore.state.workspace?.workspaceId == workspaceId &&
        _continuation.acceptedRunFor(userId)?.agentRunId == accepted.agentRunId;
    bool retry(String code) {
      if (!isCurrent()) return false;
      _continuation.recordRunRegistration(
        userId,
        agentRunId: accepted.agentRunId,
        workspaceId: workspaceId,
        errorCode: code,
      );
      _publish(
        _stateFor(
          (_continuation.acceptedRunFor(userId) ?? accepted).copyWith(
            registrationErrorCode: code,
          ),
          InitialPositioningTaskStatus.registering,
        ),
      );
      _scheduleFinalizationRetry();
      return false;
    }

    try {
      if (accepted.workspaceId == null &&
          _verifyRunWorkspace != null &&
          !await _verifyRunWorkspace(accepted.agentRunId, workspaceId)) {
        return retry('POSITIONING_LEGACY_SCOPE_UNVERIFIED');
      }
      if (!isCurrent()) return false;
      final current = await formalApi.currentInitialPositioning(
        workspaceId: workspaceId,
      );
      if (!isCurrent()) return false;
      if (!current.ok || current.data == null) {
        return retry(
          current.error?.code ?? 'ONBOARDING_REGISTRATION_UNAVAILABLE',
        );
      }
      var attempt = current.data!;
      if (attempt.agentRunId != accepted.agentRunId &&
          !attempt.isNotStarted &&
          !attempt.isFailure) {
        return retry('INITIAL_POSITIONING_OTHER_ATTEMPT_ACTIVE');
      }
      if (attempt.isNotStarted || attempt.agentRunId != accepted.agentRunId) {
        final created = await formalApi.createInitialPositioningAttempt(
          workspaceId: workspaceId,
          agentRunId: accepted.agentRunId,
        );
        if (!isCurrent()) return false;
        if (!created.ok || created.data == null) {
          if (!created.ok && !_isRetryableAttemptCreateFailure(created.error)) {
            _markFailed(
              userId,
              created.error?.code ?? 'ONBOARDING_FORMALIZATION_FAILED',
            );
          } else {
            return retry(
              created.error?.code ?? 'ONBOARDING_REGISTRATION_UNAVAILABLE',
            );
          }
          return false;
        }
        attempt = created.data!;
      }
      if (attempt.agentRunId != accepted.agentRunId ||
          attempt.workspaceId != workspaceId ||
          attempt.attemptId?.isNotEmpty != true ||
          attempt.isNotStarted) {
        return retry('ONBOARDING_ATTEMPT_BINDING_INVALID');
      }
      if (!_continuation.recordRunRegistration(
        userId,
        agentRunId: accepted.agentRunId,
        workspaceId: workspaceId,
        attemptId: attempt.attemptId,
      )) {
        return retry('ONBOARDING_PROGRESS_SAVE_FAILED');
      }
      if (attempt.isFailure && attempt.state != 'failed_retryable') {
        _markFailed(
          userId,
          attempt.failureCode ?? 'ONBOARDING_FORMALIZATION_FAILED',
        );
        return false;
      }
      final registered = _continuation.acceptedRunFor(userId)!;
      _publish(
        _stateFor(registered, switch (registered.lifecycle) {
          OnboardingAcceptedRunLifecycle.running =>
            InitialPositioningTaskStatus.running,
          OnboardingAcceptedRunLifecycle.finalizing =>
            InitialPositioningTaskStatus.finalizing,
          OnboardingAcceptedRunLifecycle.succeeded =>
            InitialPositioningTaskStatus.succeeded,
          OnboardingAcceptedRunLifecycle.failed =>
            InitialPositioningTaskStatus.failed,
        }),
      );
      return true;
    } catch (_) {
      return retry('ONBOARDING_REGISTRATION_UNAVAILABLE');
    }
  }

  Future<void> _finalizeAcceptedRun(
    String userId,
    OnboardingAcceptedRun accepted,
  ) {
    final active = _finalizationInFlight;
    if (active != null) return active;
    final completion = Completer<void>();
    final operation = completion.future;
    _finalizationInFlight = operation;
    unawaited(_runFinalization(userId, accepted, operation, completion));
    return operation;
  }

  Future<void> _runFinalization(
    String userId,
    OnboardingAcceptedRun accepted,
    Future<void> operation,
    Completer<void> completion,
  ) async {
    try {
      await _performFinalization(userId, accepted);
    } catch (_) {
      if (_isCurrentUser(userId)) {
        _retryFinalization(userId, accepted);
      }
    } finally {
      if (identical(_finalizationInFlight, operation)) {
        _finalizationInFlight = null;
      }
      if (!completion.isCompleted) completion.complete();
    }
  }

  Future<void> _performFinalization(
    String userId,
    OnboardingAcceptedRun accepted,
  ) async {
    if (!_isCurrentUser(userId)) return;
    if (!_continuation.markRunFinalizing(userId)) {
      _retryFinalization(userId, accepted);
      return;
    }
    _publish(_stateFor(accepted, InitialPositioningTaskStatus.finalizing));

    final formalApi = _onboardingApi;
    if (formalApi is! OnboardingInitialPositioningPort) {
      _markFailed(userId, 'ONBOARDING_FORMALIZATION_UNAVAILABLE');
      return;
    }
    final initialPositioningApi = formalApi as OnboardingInitialPositioningPort;
    final workspaceId = _sessionStore.state.workspace?.workspaceId?.trim();
    if (workspaceId == null || workspaceId.isEmpty) {
      _retryFinalization(userId, accepted);
      return;
    }

    final current = await initialPositioningApi.currentInitialPositioning(
      workspaceId: workspaceId,
    );
    if (!_isCurrentUser(userId)) return;
    final existing = current.data;
    if (!current.ok ||
        existing == null ||
        existing.workspaceId != workspaceId ||
        (!existing.isNotStarted &&
            existing.agentRunId != accepted.agentRunId)) {
      _retryFinalization(userId, accepted);
      return;
    }
    if (!existing.isNotStarted && existing.agentRunId == accepted.agentRunId) {
      await _applyFormalAttemptState(userId, accepted, existing);
      return;
    }
    final created = await initialPositioningApi.createInitialPositioningAttempt(
      workspaceId: workspaceId,
      agentRunId: accepted.agentRunId,
    );
    if (!_isCurrentUser(userId)) return;
    final attempt = created.data;
    if (!created.ok || attempt == null) {
      if (attempt == null &&
          (created.ok || _isRetryableAttemptCreateFailure(created.error))) {
        _retryFinalization(userId, accepted);
        return;
      }
      _markFailed(
        userId,
        created.error?.code ?? 'ONBOARDING_FORMALIZATION_FAILED',
      );
      return;
    }
    await _applyFormalAttemptState(userId, accepted, attempt);
  }

  Future<void> _applyFormalAttemptState(
    String userId,
    OnboardingAcceptedRun accepted,
    InitialPositioningAttempt attempt,
  ) async {
    if (!_isCurrentUser(userId)) return;
    if (attempt.agentRunId != accepted.agentRunId) {
      _retryFinalization(userId, accepted);
      return;
    }
    final workspaceId =
        accepted.workspaceId ?? _sessionStore.state.workspace?.workspaceId;
    if (attempt.workspaceId != workspaceId ||
        attempt.attemptId == null ||
        !_continuation.recordRunRegistration(
          userId,
          agentRunId: accepted.agentRunId,
          workspaceId: attempt.workspaceId,
          attemptId: attempt.attemptId,
        )) {
      _retryFinalization(userId, accepted);
      return;
    }
    if (attempt.hasCommittedReportForTerminalGap &&
        attempt.attemptId == accepted.attemptId &&
        _savedReportUserId == userId &&
        _savedReportRunId == accepted.agentRunId) {
      _completeFinalization(
        userId,
        accepted,
        reportSource: OnboardingAcceptedRunReportSource.workspaceProfile,
      );
      return;
    }
    if (attempt.isCompleted) {
      final reportReadback = await _ensureCompletedReport(userId, accepted);
      if (!_isCurrentUser(userId) ||
          reportReadback == _CompletedReportReadback.failed ||
          reportReadback == _CompletedReportReadback.cancelled) {
        return;
      }
      if (reportReadback == _CompletedReportReadback.saved) {
        _completeFinalization(userId, accepted);
        return;
      }
      if (_isCurrentUser(userId)) {
        _continuation.markRunFinalizing(userId);
        _publish(_stateFor(accepted, InitialPositioningTaskStatus.finalizing));
        _scheduleFinalizationRetry();
      }
      return;
    }
    if (attempt.state == 'failed_retryable') {
      _retryFinalization(userId, accepted);
      return;
    }
    if (attempt.isFailure) {
      _markFailed(
        userId,
        attempt.failureCode ?? 'ONBOARDING_FORMALIZATION_FAILED',
      );
      return;
    }
    _continuation.markRunFinalizing(userId);
    _publish(_stateFor(accepted, InitialPositioningTaskStatus.finalizing));
    _scheduleFinalizationRetry();
  }

  Future<_CompletedReportReadback> _ensureCompletedReport(
    String userId,
    OnboardingAcceptedRun accepted,
  ) {
    if (_savedReportUserId == userId &&
        _savedReportRunId == accepted.agentRunId) {
      return Future<_CompletedReportReadback>.value(
        _CompletedReportReadback.saved,
      );
    }
    final active = _reportReadbackInFlight;
    final key = '$userId:${accepted.agentRunId}';
    if (active != null) {
      if (_reportReadbackKey == key) return active;
      return active.then((_) => _ensureCompletedReport(userId, accepted));
    }
    late final Future<_CompletedReportReadback> operation;
    operation =
        _readWorkspaceProfileReport(
          userId,
          accepted,
          savedAt: accepted.completedAt ?? _now().toUtc(),
        ).whenComplete(() {
          if (identical(_reportReadbackInFlight, operation)) {
            _reportReadbackInFlight = null;
            _reportReadbackKey = null;
          }
        });
    _reportReadbackKey = key;
    _reportReadbackInFlight = operation;
    return operation;
  }

  Future<_CompletedReportReadback> _ensureSucceededReport(
    String userId,
    OnboardingAcceptedRun accepted,
  ) async {
    if (_savedReportUserId == userId &&
        _savedReportRunId == accepted.agentRunId) {
      return _CompletedReportReadback.saved;
    }
    final workspaceId = _sessionStore.state.workspace?.workspaceId?.trim();
    if (workspaceId == null || !accepted.isRegisteredFor(workspaceId)) {
      return _CompletedReportReadback.retrying;
    }
    return _readWorkspaceProfileReport(
      userId,
      accepted,
      savedAt: accepted.completedAt ?? _now().toUtc(),
    );
  }

  Future<_CompletedReportReadback> _readWorkspaceProfileReport(
    String userId,
    OnboardingAcceptedRun accepted, {
    required DateTime savedAt,
  }) async {
    try {
      final expectedWorkspace = _sessionStore.state.workspace?.workspaceId;
      final profileRead = await _positioningAgent.readSavedProfile();
      if (!_isCurrentUser(userId) ||
          _continuation.acceptedRunFor(userId)?.agentRunId !=
              accepted.agentRunId) {
        return _CompletedReportReadback.cancelled;
      }
      final profile = profileRead.profile;
      final workspaceId = _sessionStore.state.workspace?.workspaceId?.trim();
      final report = profile?.positioning.trim();
      if (!profileRead.ok ||
          profile == null ||
          profile.workspaceId != workspaceId ||
          workspaceId != expectedWorkspace ||
          report == null ||
          report.isEmpty) {
        return _CompletedReportReadback.retrying;
      }
      final sink = _reportSink;
      final saved = sink is InitialPositioningFormalReportSink
          ? await (sink as InitialPositioningFormalReportSink)
                .refreshFormalReport()
          : await sink.saveInitialReport(
              markdown: report,
              savedAt: savedAt.toUtc(),
            );
      if (!_isCurrentUser(userId) ||
          _continuation.acceptedRunFor(userId)?.agentRunId !=
              accepted.agentRunId) {
        return _CompletedReportReadback.cancelled;
      }
      if (!saved) return _CompletedReportReadback.retrying;
      _savedReportUserId = userId;
      _savedReportRunId = accepted.agentRunId;
      return _CompletedReportReadback.saved;
    } catch (_) {
      return _CompletedReportReadback.retrying;
    }
  }

  bool _completeFinalization(
    String userId,
    OnboardingAcceptedRun accepted, {
    OnboardingAcceptedRunReportSource reportSource =
        OnboardingAcceptedRunReportSource.workspaceProfile,
  }) {
    final applied = _sessionStore.applyInitialPositioningAttemptCompletion(
      completedAt: _now().toUtc(),
    );
    if (!applied) {
      _retryFinalization(userId, accepted);
      return false;
    }
    if (!_continuation.markRunSucceeded(userId, reportSource: reportSource)) {
      _receiptPersistencePendingUserId = userId;
      _receiptPersistencePendingRunId = accepted.agentRunId;
      _receiptPersistencePendingReportSource = reportSource;
      _retryFinalization(userId, accepted);
      return false;
    }
    _receiptPersistencePendingUserId = null;
    _receiptPersistencePendingRunId = null;
    _receiptPersistencePendingReportSource =
        OnboardingAcceptedRunReportSource.agentReply;
    final completed = _continuation.acceptedRunFor(userId);
    if (completed == null || completed.agentRunId != accepted.agentRunId) {
      return false;
    }
    _publish(_stateFor(completed, InitialPositioningTaskStatus.succeeded));
    return true;
  }

  void _retryFinalization(String userId, OnboardingAcceptedRun accepted) {
    if (!_isCurrentUser(userId)) return;
    final current = _continuation.acceptedRunFor(userId);
    if (current == null || current.agentRunId != accepted.agentRunId) return;
    if (current.lifecycle != OnboardingAcceptedRunLifecycle.succeeded) {
      _continuation.markRunFinalizing(userId);
    }
    final retained = _continuation.acceptedRunFor(userId) ?? current;
    final receiptPersistencePending =
        _receiptPersistencePendingUserId == userId &&
        _receiptPersistencePendingRunId == accepted.agentRunId;
    final status =
        !receiptPersistencePending &&
            retained.lifecycle == OnboardingAcceptedRunLifecycle.succeeded
        ? InitialPositioningTaskStatus.succeeded
        : InitialPositioningTaskStatus.finalizing;
    _publish(_stateFor(retained, status));
    _scheduleFinalizationRetry();
  }

  void _markFailed(String userId, String code) {
    final safeCode = code.trim().isEmpty
        ? 'ONBOARDING_FINALIZATION_FAILED'
        : code.trim();
    _continuation.markRunFailed(userId, safeCode);
    final accepted = _continuation.acceptedRunFor(userId);
    if (accepted != null) {
      _publish(_stateFor(accepted, InitialPositioningTaskStatus.failed));
    }
  }

  InitialPositioningTaskState _stateFor(
    OnboardingAcceptedRun accepted,
    InitialPositioningTaskStatus status,
  ) {
    return InitialPositioningTaskState(
      status: status,
      workspaceId: accepted.workspaceId,
      agentRunId: accepted.agentRunId,
      reportReadyAgentRunId:
          _savedReportUserId == _currentUserId &&
              _savedReportRunId == accepted.agentRunId
          ? accepted.agentRunId
          : null,
      threadId: accepted.threadId,
      errorCode: status == InitialPositioningTaskStatus.failed
          ? accepted.failureCode
          : status == InitialPositioningTaskStatus.registering
          ? accepted.registrationErrorCode
          : null,
      updatedAt: accepted.updatedAt,
      toolTrace: List<AgentRunToolTrace>.unmodifiable(
        _taskTracker.threadToolTrace(accepted.threadId),
      ),
    );
  }

  String get _currentUserId {
    final session = _sessionStore.state;
    if (session.authState != SessionAuthState.authenticated) return '';
    return session.user?.userId.trim() ?? '';
  }

  bool _isCurrentUser(String userId) =>
      !_disposed &&
      userId.isNotEmpty &&
      _currentUserId == userId &&
      _sessionStore.state.workspace?.workspaceId == _workspaceId;

  bool get _workspaceReady {
    final session = _sessionStore.state;
    return session.authState == SessionAuthState.authenticated &&
        session.workspaceStatus == SessionWorkspaceStatus.ready &&
        session.workspace?.workspaceId?.trim().isNotEmpty == true;
  }

  void _scheduleFinalizationRetry() {
    if (!_foreground || _disposed || _readbackRetries >= 20) return;
    _readbackRetries += 1;
    _finalizationRetryTimer?.cancel();
    _finalizationRetryTimer = Timer(_reportReadbackRetryInterval, () {
      _finalizationRetryTimer = null;
      if (_foreground && !_disposed) unawaited(refresh());
    });
  }

  void _publish(InitialPositioningTaskState next) {
    if (_disposed || _sameState(_state, next)) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _finalizationRetryTimer?.cancel();
    _finalizationRetryTimer = null;
    _sessionStore.removeListener(_scheduleRefresh);
    _continuation.removeListener(_scheduleRefresh);
    _taskTracker.removeListener(_handleTaskChanged);
    super.dispose();
  }
}

enum _CompletedReportReadback {
  saved,
  retrying,
  failed,
  unsupported,
  cancelled,
}

bool _isRuntimeGapRecoveryFailure(String? code) => switch (code?.trim()) {
  'RUNTIME_EVENT_GAP' ||
  'AGENT_RUN_TERMINAL' ||
  'CHAT_AGENT_RUN_ORPHANED' ||
  'ONBOARDING_AGENT_RUN_ORPHANED' => true,
  _ => false,
};

bool _isRuntimeGapTerminalEvidence(
  String? acceptedFailureCode,
  AgentTaskLedgerEntry tracked,
) {
  if (!tracked.isTerminal) return false;
  if (tracked.failureCode == 'RUNTIME_EVENT_GAP') return true;
  return tracked.status == 'orphaned' &&
      const <String>{
        'RUNTIME_EVENT_GAP',
        'AGENT_RUN_TERMINAL',
        'CHAT_AGENT_RUN_ORPHANED',
        'ONBOARDING_AGENT_RUN_ORPHANED',
      }.contains(acceptedFailureCode?.trim());
}

bool _sameState(
  InitialPositioningTaskState left,
  InitialPositioningTaskState right,
) =>
    left.status == right.status &&
    left.workspaceId == right.workspaceId &&
    left.agentRunId == right.agentRunId &&
    left.reportReadyAgentRunId == right.reportReadyAgentRunId &&
    left.threadId == right.threadId &&
    left.errorCode == right.errorCode &&
    left.updatedAt == right.updatedAt &&
    listEquals(left.toolTrace, right.toolTrace);

String _runFailureCode(String status) => switch (status) {
  'failed' => 'ONBOARDING_AGENT_RUN_FAILED',
  'timeout' => 'ONBOARDING_AGENT_RUN_TIMEOUT',
  'cancelled' => 'ONBOARDING_AGENT_RUN_CANCELLED',
  'orphaned' => 'ONBOARDING_AGENT_RUN_ORPHANED',
  _ => 'ONBOARDING_AGENT_RUN_RESULT_INVALID',
};

bool _isRetryableAttemptCreateFailure(AppFailure? failure) =>
    failure?.isRetryable == true ||
    failure?.code == 'INITIAL_POSITIONING_ATTEMPT_ACTIVE';
