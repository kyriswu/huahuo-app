import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/script_draft_models.dart';

abstract interface class ScriptDraftGenerationPort {
  Future<String> createThread({required String idempotencyKey});

  Future<String> submit({
    required String threadId,
    required ScriptDraftRequest request,
    required String idempotencyKey,
  });

  Future<Stream<ScriptDraftStreamSignal>> streamEvents({
    required String agentRunId,
    required int afterSequence,
  });

  Future<ScriptDraftEventPage> readEvents({
    required String agentRunId,
    required int afterSequence,
  });

  Future<ScriptDraftRunSnapshot> getRun({required String agentRunId});

  Future<void> cancelRun({
    required String agentRunId,
    required String idempotencyKey,
  });
}

enum ScriptDraftWriteOutcome { notApplicable, knownRejected, unknown }

final class ScriptDraftTransportException implements Exception {
  const ScriptDraftTransportException(
    this.code, {
    this.retryable = false,
    this.writeOutcome = ScriptDraftWriteOutcome.notApplicable,
    this.resumeAfterSequence,
    this.oldestAvailableSequence,
  }) : assert(resumeAfterSequence == null || resumeAfterSequence >= 0),
       assert(oldestAvailableSequence == null || oldestAvailableSequence >= 0);

  final String code;
  final bool retryable;
  final ScriptDraftWriteOutcome writeOutcome;
  final int? resumeAfterSequence;
  final int? oldestAvailableSequence;

  @override
  String toString() => 'ScriptDraftTransportException($code)';
}

@immutable
final class ScriptDraftRemoteEvent {
  const ScriptDraftRemoteEvent({
    required this.sequence,
    required this.status,
    this.deltaText,
    this.replace = false,
  }) : assert(sequence >= 0);

  final int sequence;
  final String status;
  final String? deltaText;
  final bool replace;

  bool get isTerminal => _terminalRunStatuses.contains(status);
}

enum ScriptDraftStreamSignalKind { event, gap, capacityUnavailable }

@immutable
final class ScriptDraftStreamSignal {
  const ScriptDraftStreamSignal.event(ScriptDraftRemoteEvent this.event)
    : kind = ScriptDraftStreamSignalKind.event,
      resumeAfterSequence = null;

  const ScriptDraftStreamSignal.gap({required int this.resumeAfterSequence})
    : kind = ScriptDraftStreamSignalKind.gap,
      event = null,
      assert(resumeAfterSequence >= 0);

  const ScriptDraftStreamSignal.capacityUnavailable()
    : kind = ScriptDraftStreamSignalKind.capacityUnavailable,
      event = null,
      resumeAfterSequence = null;

  final ScriptDraftStreamSignalKind kind;
  final ScriptDraftRemoteEvent? event;
  final int? resumeAfterSequence;
}

@immutable
final class ScriptDraftEventPage {
  ScriptDraftEventPage({
    required Iterable<ScriptDraftRemoteEvent> items,
    required this.nextAfterSequence,
    required this.hasMore,
    required this.gap,
    required this.oldestAvailableSequence,
  }) : items = List<ScriptDraftRemoteEvent>.unmodifiable(items),
       assert(nextAfterSequence >= 0),
       assert(oldestAvailableSequence >= 0);

  final List<ScriptDraftRemoteEvent> items;
  final int nextAfterSequence;
  final bool hasMore;
  final bool gap;
  final int oldestAvailableSequence;
}

@immutable
final class ScriptDraftRunSnapshot {
  const ScriptDraftRunSnapshot({
    required this.status,
    this.completionMode,
    this.finalAnswer,
    this.errorCode,
  });

  final String status;
  final String? completionMode;
  final String? finalAnswer;
  final String? errorCode;

  bool get isTerminal => _terminalRunStatuses.contains(status);

  bool get hasAuthoritativeAnswer =>
      status == 'succeeded' &&
      completionMode == 'normal' &&
      finalAnswer?.trim().isNotEmpty == true;
}

typedef ScriptDraftReceiptWriter =
    Future<void> Function(ScriptDraftGenerationReceipt receipt);
typedef ScriptDraftKeyFactory = String Function(String purpose);

@immutable
final class ScriptDraftControllerState {
  const ScriptDraftControllerState({
    this.phase = ScriptDraftGenerationPhase.idle,
    this.receipt,
    this.errorCode,
    this.errorRetryable = false,
  });

  final ScriptDraftGenerationPhase phase;
  final ScriptDraftGenerationReceipt? receipt;
  final String? errorCode;
  final bool errorRetryable;

  String get partialMarkdown => receipt?.partialMarkdown ?? '';
  bool get partialIsComplete => receipt?.partialIsComplete ?? true;
  String? get finalMarkdown =>
      receipt?.hasAuthoritativeResult == true ? receipt!.finalMarkdown : null;

  bool get isBusy => switch (phase) {
    ScriptDraftGenerationPhase.resolving ||
    ScriptDraftGenerationPhase.creatingThread ||
    ScriptDraftGenerationPhase.submitting ||
    ScriptDraftGenerationPhase.streaming => true,
    _ => false,
  };

  bool get canAbandon =>
      isBusy ||
      (phase == ScriptDraftGenerationPhase.failed &&
          (receipt?.agentRunId != null ||
              (errorRetryable && receipt?.threadId != null)));
}

final class ScriptDraftController extends ChangeNotifier {
  ScriptDraftController(
    this._port, {
    ScriptDraftReceiptWriter? persistReceipt,
    ScriptDraftKeyFactory? keyFactory,
    this.reconnectDelay = const Duration(milliseconds: 250),
    this.maxAutomaticReconnects = 2,
  }) : _persistReceipt = persistReceipt ?? _ignoreReceipt,
       _keyFactory = keyFactory ?? _defaultScriptDraftKey;

  final ScriptDraftGenerationPort _port;
  final ScriptDraftReceiptWriter _persistReceipt;
  final ScriptDraftKeyFactory _keyFactory;
  final Duration reconnectDelay;
  final int maxAutomaticReconnects;

  ScriptDraftControllerState _state = const ScriptDraftControllerState();
  ScriptDraftGenerationReceipt? _receipt;
  StreamIterator<ScriptDraftStreamSignal>? _activeIterator;
  Future<String>? _activeSubmission;
  String? _activeSubmissionSessionId;
  String? _submissionCancellationSessionId;
  Future<void>? _activeCancellation;
  int _generationToken = 0;
  bool _disposed = false;

  ScriptDraftControllerState get state => _state;
  ScriptDraftGenerationPhase get phase => _state.phase;
  ScriptDraftGenerationReceipt? get receipt => _state.receipt;
  String? get errorCode => _state.errorCode;
  bool get canAbandon => _state.canAbandon;

  Future<bool> start({
    required ScriptDraftSourceSnapshot source,
    ScriptDraftGenerationReceipt? persistedReceipt,
  }) async {
    if (_state.isBusy) return false;
    final restored = persistedReceipt?.matchesSource(source) == true
        ? persistedReceipt
        : null;
    if (restored != null) {
      _receipt = restored;
      if (restored.phase == ScriptDraftGenerationPhase.ready ||
          restored.phase == ScriptDraftGenerationPhase.failed ||
          restored.phase == ScriptDraftGenerationPhase.cancelled) {
        _emit(
          ScriptDraftControllerState(
            phase: restored.phase,
            receipt: restored,
            errorCode: restored.failureCode,
            errorRetryable: restored.failureRetryable,
          ),
        );
        return restored.hasAuthoritativeResult;
      }
      return _beginDrive(restored);
    }
    return generateFresh(source);
  }

  Future<bool> generateFresh(ScriptDraftSourceSnapshot source) async {
    if (_state.isBusy) return false;
    final now = DateTime.now().toUtc();
    final sessionId = _keyFactory('session');
    final fresh = ScriptDraftGenerationReceipt(
      sessionId: sessionId,
      source: source,
      createThreadIdempotencyKey: _keyFactory('create-thread'),
      messageIdempotencyKey: _keyFactory('send-message'),
      cancelIdempotencyKey: _keyFactory('cancel-run'),
      phase: ScriptDraftGenerationPhase.resolving,
      updatedAt: now,
    );
    final token = ++_generationToken;
    try {
      if (!await _checkpoint(fresh, token)) return false;
      return _drive(token);
    } on _ScriptDraftPersistenceException {
      return false;
    }
  }

  Future<bool> retryTransport() async {
    final current = _receipt;
    if (_state.phase != ScriptDraftGenerationPhase.failed ||
        !_state.errorRetryable ||
        current == null) {
      return false;
    }
    final resumed = current.copyWith(
      phase: ScriptDraftGenerationPhase.resolving,
      finalMarkdown: null,
      failureCode: null,
      failureRetryable: false,
      updatedAt: DateTime.now().toUtc(),
    );
    return _beginDrive(resumed);
  }

  Future<bool> regenerate() async {
    final current = _receipt;
    if (current == null || _state.isBusy) return false;
    if (_hasUnresolvedThreadCreation(current)) return false;
    final source = current.source;
    if (_state.phase == ScriptDraftGenerationPhase.failed &&
        (current.agentRunId != null ||
            current.failureCode == 'SCRIPT_DRAFT_SUBMISSION_OUTCOME_UNKNOWN')) {
      await cancel();
      if (_state.phase != ScriptDraftGenerationPhase.cancelled) return false;
    }
    return generateFresh(source);
  }

  Future<bool> cancelPersistedReceipt(
    ScriptDraftGenerationReceipt persistedReceipt,
  ) async {
    if (_state.phase != ScriptDraftGenerationPhase.idle || _receipt != null) {
      return false;
    }
    _receipt = persistedReceipt;
    _emit(
      ScriptDraftControllerState(
        phase: persistedReceipt.phase,
        receipt: persistedReceipt,
        errorCode: persistedReceipt.failureCode,
        errorRetryable: persistedReceipt.failureRetryable,
      ),
    );
    if (_hasUnresolvedSubmission(persistedReceipt) &&
        !await _resolveSubmissionForCancellation()) {
      return false;
    }
    if (!_state.canAbandon) return true;
    await cancel();
    return _state.phase == ScriptDraftGenerationPhase.cancelled;
  }

  Future<void> cancel() {
    final active = _activeCancellation;
    if (active != null) return active;
    final operation = _cancel();
    _activeCancellation = operation;
    return operation.whenComplete(() {
      if (identical(_activeCancellation, operation)) {
        _activeCancellation = null;
      }
    });
  }

  Future<void> _cancel() async {
    if (!_state.canAbandon) return;
    final unresolved = _receipt;
    if (unresolved != null &&
        _hasUnresolvedSubmission(unresolved) &&
        !await _resolveSubmissionForCancellation()) {
      return;
    }
    if (!_state.canAbandon) return;
    final token = ++_generationToken;
    final iterator = _activeIterator;
    _activeIterator = null;
    if (iterator != null) {
      try {
        await iterator.cancel();
      } catch (_) {}
    }
    final current = _receipt;
    if (current == null) return;
    final cancelled = current.copyWith(
      phase: ScriptDraftGenerationPhase.cancelled,
      finalMarkdown: null,
      failureCode: null,
      failureRetryable: false,
      updatedAt: DateTime.now().toUtc(),
    );
    try {
      await _checkpoint(cancelled, token);
    } on _ScriptDraftPersistenceException {
      _receipt = current;
      _emit(
        ScriptDraftControllerState(
          phase: ScriptDraftGenerationPhase.failed,
          receipt: current,
          errorCode: 'SCRIPT_DRAFT_RECEIPT_PERSIST_FAILED',
        ),
      );
      // Remote cancellation still uses the previously durable receipt below.
    }
    final agentRunId = current.agentRunId;
    if (agentRunId == null) return;
    await _cancelRunBestEffort(
      agentRunId: agentRunId,
      idempotencyKey: current.cancelIdempotencyKey,
    );
  }

  Future<bool> _beginDrive(ScriptDraftGenerationReceipt receipt) async {
    final token = ++_generationToken;
    final resolving = receipt.copyWith(
      phase: ScriptDraftGenerationPhase.resolving,
      finalMarkdown: null,
      failureCode: null,
      failureRetryable: false,
      updatedAt: DateTime.now().toUtc(),
    );
    try {
      if (!await _checkpoint(resolving, token)) return false;
      return _drive(token);
    } on _ScriptDraftPersistenceException {
      return false;
    }
  }

  Future<bool> _drive(int token) async {
    try {
      var current = _receipt!;
      var threadId = current.threadId;
      if (threadId == null) {
        current = current.copyWith(
          phase: ScriptDraftGenerationPhase.creatingThread,
          updatedAt: DateTime.now().toUtc(),
        );
        if (!await _checkpoint(current, token)) return false;
        threadId = await _port.createThread(
          idempotencyKey: current.createThreadIdempotencyKey,
        );
        if (!_isCurrent(token)) return false;
        current = current.copyWith(
          phase: ScriptDraftGenerationPhase.submitting,
          threadId: threadId,
          updatedAt: DateTime.now().toUtc(),
        );
        if (!await _checkpoint(current, token)) return false;
      } else if (current.agentRunId == null) {
        current = current.copyWith(
          phase: ScriptDraftGenerationPhase.submitting,
          updatedAt: DateTime.now().toUtc(),
        );
        if (!await _checkpoint(current, token)) return false;
      }

      var agentRunId = current.agentRunId;
      if (agentRunId == null) {
        final submission = _port.submit(
          threadId: threadId,
          request: ScriptDraftRequest(source: current.source),
          idempotencyKey: current.messageIdempotencyKey,
        );
        _activeSubmission = submission;
        _activeSubmissionSessionId = current.sessionId;
        try {
          agentRunId = await submission;
        } finally {
          if (identical(_activeSubmission, submission)) {
            _activeSubmission = null;
            _activeSubmissionSessionId = null;
          }
        }
        if (!_isCurrent(token)) {
          if (_submissionCancellationSessionId != current.sessionId) {
            await _cancelRunBestEffort(
              agentRunId: agentRunId,
              idempotencyKey: current.cancelIdempotencyKey,
            );
          }
          return false;
        }
        current = current.copyWith(
          phase: ScriptDraftGenerationPhase.streaming,
          agentRunId: agentRunId,
          updatedAt: DateTime.now().toUtc(),
        );
        try {
          if (!await _checkpoint(current, token)) {
            await _cancelRunBestEffort(
              agentRunId: agentRunId,
              idempotencyKey: current.cancelIdempotencyKey,
            );
            return false;
          }
        } on _ScriptDraftPersistenceException {
          if (!_isCurrent(token)) {
            await _cancelRunBestEffort(
              agentRunId: agentRunId,
              idempotencyKey: current.cancelIdempotencyKey,
            );
            return false;
          }
          rethrow;
        }
      } else if (current.phase != ScriptDraftGenerationPhase.streaming) {
        current = current.copyWith(
          phase: ScriptDraftGenerationPhase.streaming,
          updatedAt: DateTime.now().toUtc(),
        );
        if (!await _checkpoint(current, token)) return false;
      }

      return await _consumeRun(agentRunId, token);
    } on _ScriptDraftPersistenceException {
      return false;
    } on ScriptDraftTransportException catch (error) {
      if (!_isCurrent(token)) return false;
      final failedReceipt = _receipt;
      final hasUnlatchedThreadCreation =
          failedReceipt != null &&
          failedReceipt.phase == ScriptDraftGenerationPhase.creatingThread &&
          failedReceipt.threadId == null;
      final hasUnlatchedSubmission =
          failedReceipt != null &&
          failedReceipt.phase == ScriptDraftGenerationPhase.submitting &&
          _hasUnresolvedSubmission(failedReceipt);
      final writeOutcomeUnknown =
          error.writeOutcome != ScriptDraftWriteOutcome.knownRejected;
      await _fail(
        hasUnlatchedThreadCreation && writeOutcomeUnknown
            ? 'SCRIPT_DRAFT_THREAD_CREATE_OUTCOME_UNKNOWN'
            : hasUnlatchedSubmission && writeOutcomeUnknown
            ? 'SCRIPT_DRAFT_SUBMISSION_OUTCOME_UNKNOWN'
            : error.code,
        retryable: hasUnlatchedThreadCreation || hasUnlatchedSubmission
            ? writeOutcomeUnknown
            : error.retryable,
        token: token,
      );
      return false;
    } catch (_) {
      if (!_isCurrent(token)) return false;
      final failedReceipt = _receipt;
      final threadCreationOutcomeUnknown =
          failedReceipt != null &&
          failedReceipt.phase == ScriptDraftGenerationPhase.creatingThread &&
          failedReceipt.threadId == null;
      final submissionOutcomeUnknown =
          failedReceipt != null &&
          failedReceipt.phase == ScriptDraftGenerationPhase.submitting &&
          _hasUnresolvedSubmission(failedReceipt);
      await _fail(
        threadCreationOutcomeUnknown
            ? 'SCRIPT_DRAFT_THREAD_CREATE_OUTCOME_UNKNOWN'
            : submissionOutcomeUnknown
            ? 'SCRIPT_DRAFT_SUBMISSION_OUTCOME_UNKNOWN'
            : 'SCRIPT_DRAFT_GENERATION_FAILED',
        retryable: threadCreationOutcomeUnknown || submissionOutcomeUnknown,
        token: token,
      );
      return false;
    }
  }

  Future<bool> _consumeRun(String agentRunId, int token) async {
    var reconnects = 0;
    while (_isCurrent(token)) {
      final current = _receipt!;
      ScriptDraftTransportException? retryableFailure;
      try {
        final stream = await _port.streamEvents(
          agentRunId: agentRunId,
          afterSequence: current.afterSequence,
        );
        if (!_isCurrent(token)) return false;
        final iterator = StreamIterator<ScriptDraftStreamSignal>(stream);
        _activeIterator = iterator;
        var shouldReadRun = false;
        try {
          while (await iterator.moveNext()) {
            if (!_isCurrent(token)) return false;
            final signal = iterator.current;
            switch (signal.kind) {
              case ScriptDraftStreamSignalKind.event:
                final event = signal.event!;
                if (event.sequence > _receipt!.afterSequence + 1) {
                  await _recoverEventPages(agentRunId, token);
                  if (!_isCurrent(token)) return false;
                }
                await _applyEvent(event, token);
                if (event.isTerminal) shouldReadRun = true;
              case ScriptDraftStreamSignalKind.gap:
                await _recoverEventPages(
                  agentRunId,
                  token,
                  resumeAfterSequence: signal.resumeAfterSequence,
                );
                shouldReadRun = true;
              case ScriptDraftStreamSignalKind.capacityUnavailable:
                await _recoverEventPages(agentRunId, token);
                shouldReadRun = true;
            }
            if (shouldReadRun) break;
          }
        } finally {
          if (identical(_activeIterator, iterator)) _activeIterator = null;
          await iterator.cancel();
        }
      } on ScriptDraftTransportException catch (error) {
        if (!error.retryable) rethrow;
        retryableFailure = error;
      }
      if (!_isCurrent(token)) return false;

      bool? settled;
      try {
        settled = await _reconcileRun(agentRunId, token);
      } on ScriptDraftTransportException catch (error) {
        if (!error.retryable) rethrow;
        retryableFailure = error;
      }
      if (settled != null) return settled;
      if (reconnects >= maxAutomaticReconnects) {
        throw ScriptDraftTransportException(
          retryableFailure?.code ?? 'SCRIPT_DRAFT_STREAM_INTERRUPTED',
          retryable: true,
        );
      }
      reconnects++;
      if (reconnectDelay > Duration.zero) {
        await Future<void>.delayed(reconnectDelay);
      }
    }
    return false;
  }

  Future<bool?> _reconcileRun(String agentRunId, int token) async {
    final run = await _port.getRun(agentRunId: agentRunId);
    if (!_isCurrent(token)) return false;
    if (run.isTerminal) return _settleRun(run, token);
    await _recoverEventPages(agentRunId, token);
    if (!_isCurrent(token)) return false;
    final refreshed = await _port.getRun(agentRunId: agentRunId);
    if (!_isCurrent(token)) return false;
    if (refreshed.isTerminal) return _settleRun(refreshed, token);
    return null;
  }

  Future<void> _recoverEventPages(
    String agentRunId,
    int token, {
    int? resumeAfterSequence,
  }) async {
    if (resumeAfterSequence != null) {
      if (!await _checkpointGapRecovery(
        token: token,
        resumeAfterSequence: resumeAfterSequence,
      )) {
        return;
      }
    }
    while (_isCurrent(token)) {
      final before = _receipt!.afterSequence;
      late final ScriptDraftEventPage page;
      try {
        page = await _port.readEvents(
          agentRunId: agentRunId,
          afterSequence: before,
        );
      } on ScriptDraftTransportException catch (error) {
        if (error.code != 'RUNTIME_EVENT_GAP') rethrow;
        if (!await _checkpointGapRecovery(
          token: token,
          resumeAfterSequence: error.resumeAfterSequence,
          oldestAvailableSequence: error.oldestAvailableSequence,
        )) {
          return;
        }
        continue;
      }
      if (!_isCurrent(token)) return;
      if (page.gap) {
        if (!await _checkpointGapRecovery(
          token: token,
          oldestAvailableSequence: page.oldestAvailableSequence,
        )) {
          return;
        }
      }
      final ordered = page.items.toList(growable: false)
        ..sort((left, right) => left.sequence.compareTo(right.sequence));
      for (final event in ordered) {
        await _applyEvent(event, token);
        if (!_isCurrent(token)) return;
      }
      if (!page.hasMore) return;
      if (_receipt!.afterSequence <= before &&
          page.nextAfterSequence <= before) {
        throw const ScriptDraftTransportException(
          'SCRIPT_DRAFT_EVENT_PAGE_STALLED',
          retryable: true,
        );
      }
    }
  }

  Future<bool> _checkpointGapRecovery({
    required int token,
    int? resumeAfterSequence,
    int? oldestAvailableSequence,
  }) async {
    final derivedFromOldest = oldestAvailableSequence == null
        ? null
        : oldestAvailableSequence > 0
        ? oldestAvailableSequence - 1
        : 0;
    if (resumeAfterSequence != null &&
        derivedFromOldest != null &&
        resumeAfterSequence != derivedFromOldest) {
      throw const ScriptDraftTransportException(
        'SCRIPT_DRAFT_GAP_CURSOR_INVALID',
      );
    }
    final replayCursor = resumeAfterSequence ?? derivedFromOldest;
    final current = _receipt!;
    if (replayCursor == null || replayCursor < current.afterSequence) {
      throw const ScriptDraftTransportException(
        'SCRIPT_DRAFT_GAP_CURSOR_INVALID',
      );
    }
    if (replayCursor == current.afterSequence &&
        current.partialMarkdown.isEmpty &&
        !current.partialIsComplete) {
      throw const ScriptDraftTransportException(
        'SCRIPT_DRAFT_EVENT_GAP_STALLED',
        retryable: true,
      );
    }
    final incomplete = current.copyWith(
      afterSequence: replayCursor,
      partialMarkdown: '',
      partialIsComplete: false,
      updatedAt: DateTime.now().toUtc(),
    );
    return _checkpoint(incomplete, token);
  }

  bool _hasUnresolvedSubmission(ScriptDraftGenerationReceipt receipt) =>
      receipt.threadId != null &&
      receipt.agentRunId == null &&
      (receipt.phase == ScriptDraftGenerationPhase.submitting ||
          receipt.failureCode == 'SCRIPT_DRAFT_SUBMISSION_OUTCOME_UNKNOWN');

  bool _hasUnresolvedThreadCreation(ScriptDraftGenerationReceipt receipt) =>
      receipt.threadId == null &&
      (receipt.phase == ScriptDraftGenerationPhase.creatingThread ||
          receipt.failureCode == 'SCRIPT_DRAFT_THREAD_CREATE_OUTCOME_UNKNOWN');

  Future<bool> _resolveSubmissionForCancellation() async {
    final current = _receipt;
    final threadId = current?.threadId;
    if (current == null || threadId == null || current.agentRunId != null) {
      return current?.agentRunId != null;
    }
    final pendingSubmission = _activeSubmissionSessionId == current.sessionId
        ? _activeSubmission
        : null;
    if (pendingSubmission != null) {
      _submissionCancellationSessionId = current.sessionId;
    }
    final token = ++_generationToken;
    String? resolvedRunId;
    try {
      if (pendingSubmission != null) {
        try {
          resolvedRunId = await pendingSubmission;
        } on ScriptDraftTransportException catch (error) {
          if (error.writeOutcome == ScriptDraftWriteOutcome.knownRejected) {
            return _checkpointKnownRejectedCancellation(current, token);
          }
          resolvedRunId = await _replaySubmission(current, threadId);
        } catch (_) {
          resolvedRunId = await _replaySubmission(current, threadId);
        }
      } else {
        resolvedRunId = await _replaySubmission(current, threadId);
      }
      if (!_isCurrent(token)) {
        await _cancelRunBestEffort(
          agentRunId: resolvedRunId,
          idempotencyKey: current.cancelIdempotencyKey,
        );
        return false;
      }
      final latched = current.copyWith(
        phase: ScriptDraftGenerationPhase.streaming,
        agentRunId: resolvedRunId,
        finalMarkdown: null,
        failureCode: null,
        failureRetryable: false,
        updatedAt: DateTime.now().toUtc(),
      );
      try {
        return await _checkpoint(latched, token);
      } on _ScriptDraftPersistenceException {
        await _cancelRunBestEffort(
          agentRunId: resolvedRunId,
          idempotencyKey: current.cancelIdempotencyKey,
        );
        return false;
      }
    } on _ScriptDraftPersistenceException {
      if (resolvedRunId != null) {
        await _cancelRunBestEffort(
          agentRunId: resolvedRunId,
          idempotencyKey: current.cancelIdempotencyKey,
        );
      }
      return false;
    } on ScriptDraftTransportException catch (error) {
      if (!_isCurrent(token)) return false;
      if (error.writeOutcome == ScriptDraftWriteOutcome.knownRejected) {
        return _checkpointKnownRejectedCancellation(current, token);
      }
      try {
        await _fail(
          'SCRIPT_DRAFT_SUBMISSION_OUTCOME_UNKNOWN',
          retryable: true,
          token: token,
        );
      } on _ScriptDraftPersistenceException {
        // The checkpoint helper already exposed the durable-write failure.
      }
      return false;
    } catch (_) {
      if (!_isCurrent(token)) return false;
      try {
        await _fail(
          'SCRIPT_DRAFT_SUBMISSION_OUTCOME_UNKNOWN',
          retryable: true,
          token: token,
        );
      } on _ScriptDraftPersistenceException {
        // The checkpoint helper already exposed the durable-write failure.
      }
      return false;
    } finally {
      if (_submissionCancellationSessionId == current.sessionId) {
        _submissionCancellationSessionId = null;
      }
    }
  }

  Future<bool> _checkpointKnownRejectedCancellation(
    ScriptDraftGenerationReceipt receipt,
    int token,
  ) async {
    final cancelled = receipt.copyWith(
      phase: ScriptDraftGenerationPhase.cancelled,
      finalMarkdown: null,
      failureCode: null,
      failureRetryable: false,
      updatedAt: DateTime.now().toUtc(),
    );
    try {
      return await _checkpoint(cancelled, token);
    } on _ScriptDraftPersistenceException {
      return false;
    }
  }

  Future<String> _replaySubmission(
    ScriptDraftGenerationReceipt receipt,
    String threadId,
  ) => _port.submit(
    threadId: threadId,
    request: ScriptDraftRequest(source: receipt.source),
    idempotencyKey: receipt.messageIdempotencyKey,
  );

  Future<void> _applyEvent(ScriptDraftRemoteEvent event, int token) async {
    final current = _receipt!;
    if (event.sequence <= current.afterSequence) return;
    var complete = current.partialIsComplete;
    if (event.sequence != current.afterSequence + 1) complete = false;
    final delta = event.deltaText;
    final partial = delta == null
        ? current.partialMarkdown
        : event.replace
        ? delta
        : '${current.partialMarkdown}$delta';
    if (partial.length > _maxScriptDraftChars) {
      throw const ScriptDraftTransportException(
        'SCRIPT_DRAFT_PREVIEW_TOO_LARGE',
      );
    }
    final next = current.copyWith(
      afterSequence: event.sequence,
      partialMarkdown: partial,
      partialIsComplete: complete,
      updatedAt: DateTime.now().toUtc(),
    );
    await _checkpoint(next, token);
  }

  Future<bool> _settleRun(ScriptDraftRunSnapshot run, int token) async {
    if (run.hasAuthoritativeAnswer) {
      final answer = run.finalAnswer!;
      if (answer.length > _maxScriptDraftChars) {
        await _fail(
          'SCRIPT_DRAFT_FINAL_TOO_LARGE',
          retryable: false,
          token: token,
        );
        return false;
      }
      final ready = _receipt!.copyWith(
        phase: ScriptDraftGenerationPhase.ready,
        finalMarkdown: answer,
        failureCode: null,
        failureRetryable: false,
        updatedAt: DateTime.now().toUtc(),
      );
      return _checkpoint(ready, token);
    }
    final code = switch (run.status) {
      'succeeded' when run.finalAnswer?.trim().isEmpty != false =>
        'SCRIPT_DRAFT_FINAL_EMPTY',
      'succeeded' => 'SCRIPT_DRAFT_COMPLETION_NOT_AUTHORITATIVE',
      'cancelled' => 'SCRIPT_DRAFT_RUN_CANCELLED',
      'timeout' => 'SCRIPT_DRAFT_RUN_TIMEOUT',
      'orphaned' => 'SCRIPT_DRAFT_RUN_ORPHANED',
      _ => run.errorCode ?? 'SCRIPT_DRAFT_RUN_FAILED',
    };
    await _fail(code, retryable: false, token: token);
    return false;
  }

  Future<void> _fail(
    String code, {
    required bool retryable,
    required int token,
  }) async {
    final current = _receipt;
    if (current == null || !_isCurrent(token)) return;
    final failed = current.copyWith(
      phase: ScriptDraftGenerationPhase.failed,
      finalMarkdown: null,
      failureCode: code,
      failureRetryable: retryable,
      updatedAt: DateTime.now().toUtc(),
    );
    await _checkpoint(failed, token);
  }

  Future<bool> _checkpoint(ScriptDraftGenerationReceipt next, int token) async {
    if (!_isCurrent(token)) return false;
    try {
      await _persistReceipt(next);
    } catch (_) {
      if (_isCurrent(token)) {
        _receipt = next;
        _emit(
          ScriptDraftControllerState(
            phase: ScriptDraftGenerationPhase.failed,
            receipt: next,
            errorCode: 'SCRIPT_DRAFT_RECEIPT_PERSIST_FAILED',
            errorRetryable: true,
          ),
        );
      }
      throw const _ScriptDraftPersistenceException();
    }
    if (!_isCurrent(token)) return false;
    _receipt = next;
    _emit(
      ScriptDraftControllerState(
        phase: next.phase,
        receipt: next,
        errorCode: next.failureCode,
        errorRetryable: next.failureRetryable,
      ),
    );
    return true;
  }

  Future<void> _cancelRunBestEffort({
    required String agentRunId,
    required String idempotencyKey,
  }) async {
    try {
      await _port.cancelRun(
        agentRunId: agentRunId,
        idempotencyKey: idempotencyKey,
      );
    } catch (_) {
      // Local generation tokens remain authoritative when cancellation cannot
      // be delivered. No obsolete result is admitted back into state.
    }
  }

  bool _isCurrent(int token) => !_disposed && token == _generationToken;

  void _emit(ScriptDraftControllerState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generationToken++;
    final iterator = _activeIterator;
    _activeIterator = null;
    if (iterator != null) unawaited(iterator.cancel());
    super.dispose();
  }
}

const _terminalRunStatuses = <String>{
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'orphaned',
};
const _maxScriptDraftChars = 200000;

final class _ScriptDraftPersistenceException implements Exception {
  const _ScriptDraftPersistenceException();
}

Future<void> _ignoreReceipt(ScriptDraftGenerationReceipt receipt) async {}

int _scriptDraftKeySequence = 0;

String _defaultScriptDraftKey(String purpose) {
  _scriptDraftKeySequence++;
  return 'script-draft-$purpose-'
      '${DateTime.now().toUtc().microsecondsSinceEpoch}-'
      '$_scriptDraftKeySequence';
}
