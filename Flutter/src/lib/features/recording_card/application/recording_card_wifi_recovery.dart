part of 'recording_card_controller.dart';

extension RecordingCardWifiRecovery on RecordingCardController {
  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>> _startWifiFlow({
    required bool failedOnly,
  }) {
    final running = _wifiFlowInFlight;
    if (running != null) return running;
    final completion =
        Completer<RecordingCardResult<RecordingCardWifiBatchSnapshot>>();
    final generation = ++_wifiFlowGeneration;
    _wifiFlowInFlight = completion.future;
    final abort = Completer<void>();
    _wifiFlowAbort = abort;
    unawaited(
      _executeWifiFlow(
        failedOnly: failedOnly,
        generation: generation,
        abort: abort,
      ).then(
        (result) {
          if (identical(_wifiFlowInFlight, completion.future)) {
            _wifiFlowInFlight = null;
            _wifiFlowAbort = null;
          }
          completion.complete(result);
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_wifiFlowInFlight, completion.future)) {
            _wifiFlowInFlight = null;
            _wifiFlowAbort = null;
          }
          completion.complete(
            RecordingCardResult.failure(
              recordingCardFailure(
                'RECORDING_CARD_WIFI_RECOVERY_FAILED',
                'Wi-Fi flow could not settle',
                cause: error,
              ),
            ),
          );
        },
      ),
    );
    return completion.future;
  }

  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>> _executeWifiFlow({
    required bool failedOnly,
    required int generation,
    required Completer<void> abort,
  }) async {
    bool ownsFlow() =>
        !_disposed && generation == _wifiFlowGeneration && !abort.isCompleted;
    Future<Value> observe<Value>(Future<Value> future) => Future.any([
      future,
      abort.future.then<Value>((_) => throw const _WifiFlowSuperseded()),
    ]);
    String? batchId;
    int? pendingTeardownLatchGeneration;
    try {
      final restoring = _wifiBatchRestoreInFlight;
      if (restoring != null) await observe(restoring);
      var current = _wifiBatchCoordinator.snapshot;
      final pendingTeardownKey = _wifiNativeTeardownPendingKey;
      final ownsPendingTeardown =
          current != null &&
          pendingTeardownKey != null &&
          pendingTeardownKey.batchId == current.batchId &&
          pendingTeardownKey.attemptId == current.attemptId;
      if (current == null ||
          current.stopRequested ||
          _wifiBatchCancelInFlight != null ||
          _wifiBatchPauseInFlight != null ||
          !(current.canContinue ||
              current.canRetryFailed ||
              ownsPendingTeardown)) {
        return RecordingCardResult.failure(
          _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE'),
        );
      }
      batchId = current.batchId;
      if (current.state == RecordingCardWifiBatchState.reconciling) {
        final failure = await observe(
          _completeWifiBatchReconciliation(current),
        );
        final settled = _wifiBatchCoordinator.snapshot;
        if (failure == null &&
            settled != null &&
            settled.batchId == batchId &&
            settled.state == RecordingCardWifiBatchState.completed) {
          return RecordingCardResult.success(settled);
        }
        return RecordingCardResult.failure(
          failure ??
              _fallbackFailure('RECORDING_CARD_WIFI_RECONCILIATION_FAILED'),
        );
      }
      if (pendingTeardownKey != null) {
        if (pendingTeardownKey.batchId != current.batchId ||
            pendingTeardownKey.attemptId != current.attemptId) {
          throw _fallbackFailure('RECORDING_CARD_WIFI_BATCH_SUPERSEDED');
        }
        pendingTeardownLatchGeneration = _claimWifiTransitionLatch();
        if (pendingTeardownLatchGeneration == null) {
          throw _operationAdmissionFailure();
        }
        final teardownFailure = await observe(
          _closeNativeWifiSession(
            pendingTeardownKey.batchId,
            attemptId: pendingTeardownKey.attemptId,
          ),
        );
        if (!ownsFlow()) throw const _WifiFlowSuperseded();
        final afterTeardown = _wifiBatchCoordinator.snapshot;
        if (afterTeardown == null ||
            afterTeardown.batchId != pendingTeardownKey.batchId ||
            afterTeardown.attemptId != pendingTeardownKey.attemptId ||
            afterTeardown.stopRequested) {
          throw const _WifiFlowSuperseded();
        }
        if (teardownFailure != null) throw teardownFailure;
        current = afterTeardown;
      }
      final attemptId = _newWifiAttemptId();
      final preparing = current.copyWith(
        attemptId: attemptId,
        operationPhase: RecordingCardWifiOperationPhase.recovering,
        updatedAt: _clock(),
        clearFailure: true,
      );
      _wifiBatchCoordinator.replace(preparing);
      var failure = await observe(_persistWifiBatchDurably(preparing));
      failure ??= await observe(_recoverPlannedWifiDownloads(batchId));
      if (failure != null) throw failure;
      final prepared = await observe(
        _startWifiBatchReprepare(failedOnly: failedOnly),
      );
      if (!prepared.ok || prepared.value == null) {
        if (_wifiBatchCoordinator.snapshot?.state ==
                RecordingCardWifiBatchState.completed &&
            _wifiBatchCoordinator.snapshot?.remainingCount == 0) {
          return RecordingCardResult.success(_wifiBatchCoordinator.snapshot!);
        }
        throw prepared.error ??
            _fallbackFailure('RECORDING_CARD_WIFI_PREPARE_FAILED');
      }
      if (!ownsFlow()) throw const _WifiFlowSuperseded();
      _setWifiOperation(RecordingCardWifiOperationPhase.joiningHotspot);
      final joined = await observe(_joinPreparedWifiNetwork(prepared.value!));
      if (!joined.ok || joined.value != true) {
        throw joined.error ??
            _fallbackFailure('RECORDING_CARD_WIFI_JOIN_FAILED');
      }
      if (!ownsFlow()) throw const _WifiFlowSuperseded();
      final handoff = await observe(_verifyPreparedWifiHandoff());
      if (!handoff.ok ||
          handoff.value?.status != RecordingCardWifiHandoffStatus.ready) {
        throw handoff.error ??
            _fallbackFailure('RECORDING_CARD_WIFI_CHECK_FAILED');
      }
      if (!ownsFlow()) throw const _WifiFlowSuperseded();
      _setWifiOperation(RecordingCardWifiOperationPhase.idle);
      await observe(_startPreparedWifiBatch());
      final settled = _wifiBatchCoordinator.snapshot;
      if (settled == null || settled.batchId != batchId) {
        throw const _WifiFlowSuperseded();
      }
      return settled.state == RecordingCardWifiBatchState.completed &&
              settled.remainingCount == 0
          ? RecordingCardResult.success(settled)
          : RecordingCardResult.failure(
              _fallbackFailure(
                settled.failureCode ??
                    _state.lastErrorCode ??
                    'RECORDING_CARD_WIFI_TRANSFER_PAUSED',
              ),
            );
    } on _WifiFlowSuperseded {
      return RecordingCardResult.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_PREPARATION_STALE'),
      );
    } catch (error) {
      final failure = error is AppFailure
          ? error
          : recordingCardFailure(
              'RECORDING_CARD_WIFI_RECOVERY_FAILED',
              'Wi-Fi recovery failed',
              cause: error,
              isRetryable: true,
            );
      if (ownsFlow() && _wifiBatchCoordinator.snapshot?.batchId == batchId) {
        final batch = _wifiBatchCoordinator.snapshot!;
        if (!batch.isTerminal &&
            batch.state != RecordingCardWifiBatchState.paused) {
          await _pauseWifiBatch(failure);
        } else {
          _fail(failure);
        }
      }
      return RecordingCardResult.failure(failure);
    } finally {
      if (ownsFlow()) {
        final current = _wifiBatchCoordinator.snapshot;
        final pendingTeardown = _wifiNativeTeardownPendingKey;
        final ownsPendingTeardown =
            current != null &&
            pendingTeardown != null &&
            pendingTeardown.batchId == current.batchId &&
            pendingTeardown.attemptId == current.attemptId;
        final latchGeneration = pendingTeardownLatchGeneration;
        if (latchGeneration != null) {
          _releaseTransferLatch(latchGeneration);
        }
        _setWifiOperation(
          ownsPendingTeardown
              ? RecordingCardWifiOperationPhase.stopping
              : RecordingCardWifiOperationPhase.idle,
        );
      }
    }
  }

  void _abortWifiFlow() {
    _wifiFlowGeneration += 1;
    final abort = _wifiFlowAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _wifiFlowInFlight = null;
    _wifiFlowAbort = null;
  }

  void _setWifiOperation(RecordingCardWifiOperationPhase phase) {
    final batch = _wifiBatchCoordinator.snapshot;
    if (_disposed || batch == null || batch.operationPhase == phase) return;
    _wifiBatchCoordinator.replace(batch.copyWith(operationPhase: phase));
  }

  void _onWifiSessionObservation(
    RecordingCardWifiSessionObservation observation,
  ) {
    final batch = _wifiBatchCoordinator.snapshot;
    if (_disposed ||
        batch == null ||
        batch.stopRequested ||
        observation.failureCode == null ||
        observation.batchId != batch.batchId ||
        observation.attemptId != batch.attemptId) {
      return;
    }
    _interruptWifiBatchDownload(observation.failureCode!);
    unawaited(reconcileWifiBatch(interruptionCode: observation.failureCode));
  }

  Future<void> _reconcileWifiBatch({String? interruptionCode}) {
    final running = _wifiReconciliationInFlight;
    if (running != null) return running;
    late final Future<void> operation;
    operation = _reconcileWifiRuntime(interruptionCode).whenComplete(() {
      if (identical(_wifiReconciliationInFlight, operation)) {
        _wifiReconciliationInFlight = null;
      }
    });
    _wifiReconciliationInFlight = operation;
    return operation;
  }

  Future<void> _reconcileWifiRuntime(String? interruptionCode) async {
    final restoring = _wifiBatchRestoreInFlight;
    if (restoring != null) await restoring;
    final batch = _wifiBatchCoordinator.snapshot;
    if (_disposed ||
        batch == null ||
        batch.stopRequested ||
        !batch.isBusy ||
        batch.state == RecordingCardWifiBatchState.registering ||
        batch.operationPhase == RecordingCardWifiOperationPhase.recovering ||
        batch.operationPhase == RecordingCardWifiOperationPhase.stopping) {
      return;
    }
    if (interruptionCode == null &&
        batch.operationPhase != RecordingCardWifiOperationPhase.idle) {
      return;
    }
    final port = _port;
    if (interruptionCode == null && port is RecordingCardWifiRecoveryPort) {
      try {
        final observed = await (port as RecordingCardWifiRecoveryPort)
            .queryWifiSession()
            .timeout(_wifiTeardownTimeout);
        if (_wifiBatchCoordinator.snapshot?.attemptId != batch.attemptId ||
            _disposed) {
          return;
        }
        final session = observed.value;
        if (observed.ok &&
            session != null &&
            session.active &&
            session.batchId == batch.batchId &&
            session.attemptId == batch.attemptId &&
            session.failureCode == null) {
          return;
        }
        interruptionCode = session?.failureCode ?? observed.error?.code;
      } catch (_) {
        interruptionCode = 'RECORDING_CARD_WIFI_SESSION_UNAVAILABLE';
      }
    } else if (interruptionCode == null &&
        port is! RecordingCardWifiRecoveryPort) {
      return;
    }
    if (_wifiBatchCoordinator.snapshot?.attemptId != batch.attemptId ||
        _disposed) {
      return;
    }
    final failure = _fallbackFailure(
      interruptionCode ?? 'RECORDING_CARD_WIFI_SESSION_INTERRUPTED',
    );
    await pauseWifiBatch();
    final paused = _wifiBatchCoordinator.snapshot;
    if (paused == null ||
        paused.batchId != batch.batchId ||
        paused.stopRequested ||
        paused.isTerminal ||
        paused.operationPhase != RecordingCardWifiOperationPhase.idle ||
        _disposed) {
      return;
    }
    final recoveryFailure = await _recoverPlannedWifiDownloads(paused.batchId);
    final latest = _wifiBatchCoordinator.snapshot!;
    final interrupted = latest.copyWith(
      state: RecordingCardWifiBatchState.paused,
      operationPhase: RecordingCardWifiOperationPhase.idle,
      failureCode: recoveryFailure?.code ?? failure.code,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
    _wifiBatchCoordinator.replace(interrupted);
    final persistenceFailure = await _persistWifiBatchDurably(interrupted);
    _fail(persistenceFailure ?? recoveryFailure ?? failure);
  }

  Future<AppFailure?> _recoverPlannedWifiDownloads(String batchId) async {
    final port = _port;
    if (port is! RecordingCardWifiRecoveryPort) return null;
    final recoveryPort = port as RecordingCardWifiRecoveryPort;
    final batch = _wifiBatchCoordinator.snapshot;
    if (batch == null || batch.batchId != batchId) return null;
    final stateGeneration = _wifiBatchStateGeneration;
    AppFailure? firstFailure;
    for (var index = 0; index < batch.items.length; index++) {
      final item = batch.items[index];
      final nativeFileId = item.plannedNativeFileId;
      if (nativeFileId == null ||
          item.isCompleted ||
          item.stagedDownload != null) {
        continue;
      }
      RecordingCardResult<RecordingCardWifiRecoveredDownload> result;
      try {
        result = await recoveryPort
            .recoverWifiDownload(item.file, nativeFileId: nativeFileId)
            .timeout(RecordingCardController._localVerificationTimeout);
      } catch (error) {
        result =
            RecordingCardResult<RecordingCardWifiRecoveredDownload>.failure(
              recordingCardFailure(
                'RECORDING_CARD_WIFI_LOCAL_RECOVERY_FAILED',
                'Committed Wi-Fi file could not be inspected',
                cause: error,
                isRetryable: true,
              ),
            );
      }
      final current = _wifiBatchCoordinator.snapshot;
      if (_disposed ||
          stateGeneration != _wifiBatchStateGeneration ||
          current == null ||
          current.batchId != batchId ||
          index >= current.items.length ||
          current.items[index].plannedNativeFileId != nativeFileId) {
        return null;
      }
      if (!result.ok) {
        firstFailure ??=
            result.error ??
            _fallbackFailure('RECORDING_CARD_WIFI_LOCAL_RECOVERY_FAILED');
        continue;
      }
      if (result.value == null) {
        firstFailure ??= _fallbackFailure(
          'RECORDING_CARD_WIFI_LOCAL_RECOVERY_FAILED',
        );
        continue;
      }
      final downloaded = result.value!.file;
      if (downloaded == null) continue;
      final staged = _validatedStagedWifiDownload(downloaded, item.file);
      if (staged == null) {
        firstFailure ??= _fallbackFailure(
          'RECORDING_CARD_DOWNLOAD_SIZE_MISMATCH',
        );
        continue;
      }
      final recovered = current.items[index].copyWith(
        stagedDownload: staged,
        state: RecordingCardWifiBatchItemState.verifying,
        clearError: true,
      );
      final failure = _persistWifiBatchItem(
        current,
        recovered,
        checkpointOnly: true,
      );
      if (failure != null) return failure;
      final items = [...current.items];
      items[index] = recovered;
      _wifiBatchCoordinator.replace(current.copyWith(items: items));
    }
    return firstFailure;
  }
}

final class _WifiFlowSuperseded implements Exception {
  const _WifiFlowSuperseded();
}

String _newWifiAttemptId() {
  final random = Random.secure();
  final entropy = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'wifi-$entropy';
}

String _plannedWifiTarget(
  RecordingCardWifiBatchSnapshot batch,
  RecordingCardWifiBatchItem item,
) {
  final digest = sha256.convert(
    utf8.encode(
      '${batch.batchId}:${batch.attemptId}:${item.order}:${item.attemptCount + 1}',
    ),
  );
  return 'card-${digest.toString().substring(0, 32)}';
}

String? _safePlannedWifiTarget(Object? value) =>
    value is String && RegExp(r'^card-[a-f0-9]{32}$').hasMatch(value)
    ? value
    : null;
