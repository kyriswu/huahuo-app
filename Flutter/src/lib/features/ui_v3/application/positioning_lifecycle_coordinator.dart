import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../chat/application/chat_run_tracker.dart';
import '../../chat/domain/chat_models.dart';
import '../../onboarding/data/onboarding_api.dart';
import '../domain/deep_positioning_models.dart';
import '../domain/document_change_proposal_models.dart';
import '../domain/positioning_lifecycle.dart';
import 'deep_positioning_controller.dart';

export '../domain/positioning_lifecycle.dart';

final class PositioningLifecycleCoordinator extends ChangeNotifier {
  PositioningLifecycleCoordinator({
    required this.scope,
    required this.workspaceId,
    required this.isCurrent,
    required this.reports,
    required this.updates,
    required this.store,
    required this.readAttempt,
    required this.hasLocalPending,
    required this.markBasicCompleted,
    this.tracker,
    TaskOrchestrator? orchestrator,
    this.onDiagnostic,
  }) {
    try {
      final completionStore = store;
      _basicCompleted =
          completionStore is PositioningCompletionStore &&
          (completionStore as PositioningCompletionStore).basicCompleted;
      _completionRecorded = _basicCompleted;
      for (final checkpoint in store.load()) {
        _checkpoints[checkpoint.runId] = checkpoint;
      }
    } catch (_) {
      _journalInvalid = true;
      errorCode = 'POSITIONING_JOURNAL_INVALID';
    }
    tracker?.addListener(_tasksChanged);
    if (orchestrator != null) {
      _poller = OrchestratedPoller(
        orchestrator: orchestrator,
        spec: TaskSpec(
          key: 'positioning:${positioningDigest(scope)}',
          owner: 'positioning-lifecycle',
          priority: TaskPriority.userVisible,
          resources: const {TaskResource.network},
          foregroundOnly: true,
          replaceExisting: true,
          retryable: true,
          deadline: const Duration(seconds: 30),
        ),
        interval: const Duration(seconds: 3),
        poll: (token) async {
          await reconcile();
          token.throwIfCancelled();
          final keepPolling = _valid && ++_pollCount < 20 && _needsRecovery;
          if (_valid && !keepPolling && _needsRecovery) {
            errorCode = 'POSITIONING_READBACK_PENDING';
            notifyListeners();
          }
          return keepPolling;
        },
      );
    }
  }

  final String scope;
  final String workspaceId;
  final bool Function() isCurrent;
  final DeepPositioningController reports;
  final PositioningUpdatePort updates;
  final PositioningUpdateStore store;
  final Future<InitialPositioningAttempt> Function() readAttempt;
  final bool Function() hasLocalPending;
  final VoidCallback markBasicCompleted;
  final ChatRunTracker? tracker;
  final void Function(String code)? onDiagnostic;
  String? _lastDiagnostic;
  final Map<String, PositioningUpdateCheckpoint> _checkpoints = {};
  OrchestratedPoller? _poller;
  Future<void>? _inFlight;
  bool _disposed = false;
  bool _foreground = false;
  bool _journalInvalid = false;
  bool _basicCompleted = false;
  bool _completionRecorded = false;
  bool _completionSaveFailed = false;
  int _pollCount = 0;
  InitialPositioningAccess access = InitialPositioningAccess.checking;
  InitialPositioningAttempt? attempt;
  String? errorCode;

  bool get _valid => !_disposed && isCurrent();
  bool get canStartBasic =>
      access == InitialPositioningAccess.notStarted ||
      access == InitialPositioningAccess.retryableFailure;
  List<PositioningUpdateCheckpoint> get checkpoints =>
      List.unmodifiable(_checkpoints.values);
  PositioningUpdateCheckpoint? get latestUpdate {
    final values = _checkpoints.values.toList()
      ..sort((first, second) => second.createdAt.compareTo(first.createdAt));
    return values.firstOrNull;
  }

  bool get _needsRecovery =>
      _completionSaveFailed ||
      access == InitialPositioningAccess.running ||
      access == InitialPositioningAccess.recovering ||
      _checkpoints.values.any((entry) => !entry.terminal);

  Future<void> start() async {
    if (!_valid) return;
    _foreground = true;
    await continueRecovery();
  }

  void pause() {
    _foreground = false;
    _poller?.stop();
  }

  Future<void> continueRecovery() async {
    _pollCount = 0;
    await reconcile();
    if (_valid && _foreground && _needsRecovery)
      _poller?.start(immediate: false);
  }

  Future<InitialPositioningAccess> checkBasicAccess() async {
    await reconcile();
    return _valid ? access : InitialPositioningAccess.unavailable;
  }

  void _tasksChanged() {
    if (!_valid || !_foreground) return;
    final hasNew = tracker!.taskLedger.any(
      (entry) =>
          entry.kind == 'chat' &&
          entry.purpose == ChatConversationPurpose.deepPositioning &&
          entry.taskId != attempt?.agentRunId &&
          !_checkpoints.containsKey(entry.taskId),
    );
    if (hasNew || _needsRecovery) unawaited(continueRecovery());
  }

  Future<void> reconcile() {
    if (!_valid) return Future.value();
    final active = _inFlight;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _reconcile().whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
    _inFlight = operation;
    return operation;
  }

  Future<void> _reconcile() async {
    await reports.refreshForReportPresentation();
    if (!_valid) return;
    final read = reports.reportRead;
    final proven = read.provesCompletion || read.report?.formalVerified == true;
    if (proven || _basicCompleted) {
      await _recordBasicCompletion();
      if (!_valid) return;
    }
    if (proven) {
      access = InitialPositioningAccess.completed;
      markBasicCompleted();
    }
    try {
      final current = await readAttempt();
      if (!_valid) return;
      if (current.workspaceId != workspaceId)
        throw StateError('POSITIONING_WORKSPACE_MISMATCH');
      attempt = current;
      if (current.isCompleted) await _recordBasicCompletion();
      if (!_valid) return;
      if (!proven) {
        access = _basicCompleted
            ? InitialPositioningAccess.recovering
            : !current.isNotStarted && !current.isFailure
            ? InitialPositioningAccess.running
            : hasLocalPending()
            ? InitialPositioningAccess.running
            : read.origin != PositioningReportOrigin.absent
            ? InitialPositioningAccess.unavailable
            : current.isFailure
            ? InitialPositioningAccess.retryableFailure
            : InitialPositioningAccess.notStarted;
      }
      errorCode = null;
    } catch (_) {
      if (!_valid) return;
      if (!proven)
        access = _basicCompleted
            ? InitialPositioningAccess.recovering
            : InitialPositioningAccess.unavailable;
      errorCode = 'POSITIONING_ATTEMPT_READ_FAILED';
    }
    if (_journalInvalid) {
      if (!proven && !_basicCompleted)
        access = InitialPositioningAccess.unavailable;
      errorCode = 'POSITIONING_JOURNAL_INVALID';
      notifyListeners();
      return;
    }
    try {
      for (final entry in tracker?.taskLedger ?? <AgentTaskLedgerEntry>[]) {
        if (entry.kind == 'chat' &&
            entry.purpose == ChatConversationPurpose.deepPositioning &&
            entry.taskId != attempt?.agentRunId &&
            !_checkpoints.containsKey(entry.taskId)) {
          _checkpoints[entry.taskId] = PositioningUpdateCheckpoint(
            runId: entry.taskId,
            createdAt: entry.createdAt,
          );
        }
      }
      final latest = await updates.latest();
      if (!_valid) return;
      final proposal = latest?.proposal;
      final sourceRunId = proposal == null
          ? null
          : positioningProposalSourceRunId(proposal);
      if (proposal != null && sourceRunId == null) {
        errorCode = 'POSITIONING_SOURCE_UNVERIFIED';
      } else if (proposal != null &&
          sourceRunId != null &&
          !_checkpoints.containsKey(sourceRunId)) {
        if (await updates.verifySource(proposal)) {
          if (!_valid) return;
          _checkpoints[sourceRunId] = PositioningUpdateCheckpoint(
            runId: sourceRunId,
            createdAt:
                proposal.createdAt ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          );
        } else if (_valid) {
          errorCode = 'POSITIONING_SOURCE_UNVERIFIED';
        }
      }
      await _persist();
      for (final checkpoint in _checkpoints.values.toList()) {
        if (!_valid) return;
        if (checkpoint.terminal) continue;
        try {
          await _advance(checkpoint, latest);
        } on DocumentChangeProposalException catch (error) {
          if (!_valid) return;
          final blocked = RegExp(
            'MISMATCH|CHANGED|INVALID|STALE|CONFLICT|PRECONDITION|REJECTED',
          ).hasMatch(error.code);
          await _save(
            (_checkpoints[checkpoint.runId] ?? checkpoint).advance(
              blocked
                  ? PositioningUpdateStage.blocked
                  : PositioningUpdateStage.retryableFailure,
              errorCode: error.code,
            ),
          );
        }
      }
    } catch (_) {
      if (_valid) errorCode = 'POSITIONING_RECOVERY_UNAVAILABLE';
    }
    if (_valid) {
      if (_completionSaveFailed)
        errorCode ??= 'POSITIONING_COMPLETION_SAVE_FAILED';
      final diagnostic =
          '${access.name}:${latestUpdate?.stage.name}:${latestUpdate?.errorCode ?? errorCode ?? 'ok'}';
      if (_lastDiagnostic != diagnostic) {
        _lastDiagnostic = diagnostic;
        onDiagnostic?.call(diagnostic);
      }
      notifyListeners();
    }
  }

  Future<void> _advance(
    PositioningUpdateCheckpoint checkpoint,
    DocumentChangeProposalSnapshot? latest,
  ) async {
    final status = await updates.runStatus(checkpoint.runId);
    if (!_valid) return;
    if (const {'failed', 'cancelled', 'expired'}.contains(status)) {
      await _save(
        checkpoint.advance(
          PositioningUpdateStage.blocked,
          errorCode: 'POSITIONING_RUN_FAILED',
        ),
      );
      return;
    }
    if (status != 'succeeded') return;
    if (latest == null ||
        positioningProposalSourceRunId(latest.proposal) != checkpoint.runId) {
      await _save(
        checkpoint.advance(
          checkpoint.proposalId == null
              ? PositioningUpdateStage.waitingForCandidate
              : PositioningUpdateStage.blocked,
          errorCode: checkpoint.proposalId == null
              ? null
              : 'POSITIONING_CANDIDATE_NOT_CURRENT',
        ),
      );
      return;
    }
    var snapshot = await updates.get(latest.proposal.proposalId);
    if (!_valid) return;
    var proposal = snapshot.proposal;
    if (!isPositioningProposal(proposal) ||
        positioningProposalSourceRunId(proposal) != checkpoint.runId ||
        !await updates.verifySource(proposal)) {
      throw const DocumentChangeProposalException(
        'POSITIONING_SOURCE_MISMATCH',
      );
    }
    if (!_valid) return;
    if (checkpoint.proposalId != null &&
        (checkpoint.proposalId != proposal.proposalId ||
            checkpoint.proposalVersion != proposal.proposalVersion)) {
      throw const DocumentChangeProposalException(
        'POSITIONING_VERSION_CHANGED',
      );
    }
    if (const {
      DocumentProposalState.rejected,
      DocumentProposalState.stale,
      DocumentProposalState.generationFailed,
      DocumentProposalState.applyFailed,
    }.contains(proposal.state)) {
      await _save(
        checkpoint.advance(
          PositioningUpdateStage.blocked,
          errorCode: proposal.failureCode ?? 'POSITIONING_PROPOSAL_BLOCKED',
        ),
      );
      return;
    }
    if (proposal.state == DocumentProposalState.generating) return;
    if (proposal.hasChanges == false &&
        proposal.state == DocumentProposalState.ready) {
      await _save(checkpoint.advance(PositioningUpdateStage.noChanges));
      return;
    }
    final digest =
        checkpoint.contentHash ?? await updates.candidateDigest(proposal);
    if (!_valid) return;
    var saved = checkpoint.advance(
      PositioningUpdateStage.awaitingReadback,
      proposalId: proposal.proposalId,
      proposalVersion: proposal.proposalVersion,
      contentHash: digest,
    );
    if (proposal.state == DocumentProposalState.ready) {
      if (checkpoint.etag != null && checkpoint.etag != snapshot.etag)
        throw const DocumentChangeProposalException(
          'POSITIONING_VERSION_CHANGED',
        );
      saved = saved.advance(
        PositioningUpdateStage.applying,
        etag: snapshot.etag,
        idempotencyKey:
            checkpoint.idempotencyKey ??
            'positioning-${positioningDigest('$scope:${checkpoint.runId}:${proposal.proposalId}:${proposal.proposalVersion}')}',
      );
      await _save(saved);
      if (!_valid) return;
      final newest = await updates.latest();
      if (!_valid) return;
      if (newest?.proposal.proposalId != proposal.proposalId ||
          newest?.etag != snapshot.etag)
        throw const DocumentChangeProposalException(
          'POSITIONING_VERSION_CHANGED',
        );
      snapshot = await updates.apply(saved);
      if (!_valid) return;
      proposal = snapshot.proposal;
    }
    if (proposal.proposalId != saved.proposalId ||
        proposal.proposalVersion != saved.proposalVersion ||
        positioningProposalSourceRunId(proposal) != saved.runId ||
        !isPositioningProposal(proposal))
      throw const DocumentChangeProposalException(
        'POSITIONING_RECEIPT_MISMATCH',
      );
    await _save(saved.advance(PositioningUpdateStage.awaitingReadback));
    if (!_valid ||
        proposal.state != DocumentProposalState.applied ||
        proposal.appliedOwnerRevisionId == null ||
        proposal.appliedPartRevisionId == null)
      return;
    await reports.refreshForReportPresentation();
    if (!_valid) return;
    final read = reports.reportRead;
    if (read.isRemote && read.report?.formalContentDigest == digest) {
      await _save(saved.advance(PositioningUpdateStage.updated));
    }
  }

  Future<void> _save(PositioningUpdateCheckpoint checkpoint) async {
    if (!_valid) return;
    _checkpoints[checkpoint.runId] = checkpoint;
    await _persist();
  }

  Future<void> _recordBasicCompletion() async {
    if (!_valid || _completionRecorded) return;
    _basicCompleted = true;
    final completionStore = store;
    if (completionStore is PositioningCompletionStore) {
      try {
        await (completionStore as PositioningCompletionStore)
            .recordBasicCompletion();
        _completionRecorded = true;
        _completionSaveFailed = false;
      } catch (_) {
        _completionSaveFailed = true;
        if (_valid) errorCode = 'POSITIONING_COMPLETION_SAVE_FAILED';
      }
    }
  }

  Future<void> _persist() async {
    if (!_valid) return;
    await store.save(_checkpoints.values.toList());
  }

  @override
  void dispose() {
    _disposed = true;
    tracker?.removeListener(_tasksChanged);
    _poller?.dispose();
    super.dispose();
  }
}
