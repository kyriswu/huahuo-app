import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_quick_wifi_coordinator.dart';

const _cardDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _fingerprint = 'recording-card-fingerprint';
const _file = RecordingCardScannedFile(
  deviceFileId: 'device-file-1',
  localFileKey: 'local-file-key-1',
  deviceFilename: '20260913090000.m4a',
  sizeBytes: 4096,
  contentHash:
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  format: RecordingCardFileFormat.m4a,
  mimeType: 'audio/mp4',
);

void main() {
  test(
    'publishes intent synchronously and executes the ordered handoff once',
    () async {
      final runtime = _FakeQuickWifiRuntime();
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);

      final requestId = coordinator.beginSelected(
        const <RecordingCardScannedFile>[_file],
      );

      expect(coordinator.state.requestId, requestId);
      expect(
        coordinator.state.phase,
        RecordingCardQuickWifiPhase.preparingHandoff,
      );
      expect(runtime.calls, isEmpty);

      final first = coordinator.execute(requestId);
      final second = coordinator.execute(requestId);
      expect(identical(first, second), isTrue);
      await first;

      expect(runtime.calls, <String>[
        'pause',
        'handoff',
        'resolve',
        'queue',
        'start',
        'continue',
      ]);
      expect(runtime.queueCalls, 1);
      expect(runtime.startCalls, 1);
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.completed);
      expect(coordinator.state.batchId, 'quick-wifi-batch');
    },
  );

  test('rejects a different physical card after the pause boundary', () async {
    final pause = Completer<void>();
    final runtime = _FakeQuickWifiRuntime(pauseCompleter: pause);
    final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
    addTearDown(coordinator.dispose);
    final requestId = coordinator.beginAllUnsynced();

    final execution = coordinator.execute(requestId);
    runtime.replaceFingerprint('different-card');
    pause.complete();
    await execution;

    expect(coordinator.state.phase, RecordingCardQuickWifiPhase.failed);
    expect(
      coordinator.state.failureCode,
      'RECORDING_CARD_WIFI_HANDOFF_CARD_CHANGED',
    );
    expect(runtime.queueCalls, 0);
    expect(runtime.startCalls, 0);
  });

  test(
    'keeps pre-batch failure visible and restores introduced auto sync',
    () async {
      final runtime = _FakeQuickWifiRuntime(
        handoffFailureCode: 'RECORDING_CARD_WIFI_HOTSPOT_TIMEOUT',
      );
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);
      final requestId = coordinator.beginAllUnsynced();

      await coordinator.execute(requestId);

      expect(coordinator.state.keepsSyncCardVisible, isTrue);
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.failed);
      expect(coordinator.state.canRetry, isTrue);
      expect(
        coordinator.state.failureCode,
        'RECORDING_CARD_WIFI_HOTSPOT_TIMEOUT',
      );
      expect(runtime.calls.last, 'continue');
    },
  );

  test(
    'synchronous validation failure does not expose a no-op retry',
    () async {
      final runtime = _FakeQuickWifiRuntime();
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);

      final requestId = coordinator.beginSelected(
        const <RecordingCardScannedFile>[],
      );
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.failed);
      expect(coordinator.state.canRetry, isFalse);

      await coordinator.retry(requestId);
      expect(runtime.calls, isEmpty);
    },
  );

  test(
    'restores a pause introduced by the handoff after ordinary pause no-op',
    () async {
      final runtime = _FakeQuickWifiRuntime(
        pauseChangesState: false,
        handoffForcesPause: true,
      );
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);
      final requestId = coordinator.beginAllUnsynced();

      await coordinator.execute(requestId);

      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.completed);
      expect(runtime.calls, containsAllInOrder(<String>['pause', 'handoff']));
      expect(runtime.calls.last, 'continue');
      expect(runtime.automaticSyncPaused, isFalse);
    },
  );

  test('matches a legacy batch whose persisted card digest is blank', () {
    final runtime = _FakeQuickWifiRuntime();
    final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
    addTearDown(coordinator.dispose);
    final legacy = _batch(
      RecordingCardWifiBatchState.paused,
      RecordingCardWifiBatchItemState.queued,
      cardSnDigest: ' ',
    );
    runtime.replaceBatch(legacy);

    coordinator.beginExistingBatch(
      legacy,
      RecordingCardQuickWifiExistingAction.resume,
    );
    runtime.replaceBatch(
      _batch(
        RecordingCardWifiBatchState.transferring,
        RecordingCardWifiBatchItemState.transferring,
        cardSnDigest: '',
      ),
    );

    expect(coordinator.state.expectedCardSnDigest, _cardDigest);
    expect(coordinator.state.phase, RecordingCardQuickWifiPhase.transferring);
  });

  test(
    'settles automatic BLE before resuming an existing Wi-Fi batch',
    () async {
      final handoff = Completer<void>();
      final runtime = _FakeQuickWifiRuntime(
        handoffCompleter: handoff,
        handoffForcesPause: true,
      );
      final batch = _batch(
        RecordingCardWifiBatchState.paused,
        RecordingCardWifiBatchItemState.queued,
      );
      runtime.replaceBatch(batch);
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);
      final requestId = coordinator.beginExistingBatch(
        batch,
        RecordingCardQuickWifiExistingAction.resume,
      );

      final execution = coordinator.execute(requestId);
      await _waitFor(() => runtime.calls.contains('handoff'));
      expect(runtime.calls, isNot(contains('resume')));
      expect(
        coordinator.state.phase,
        RecordingCardQuickWifiPhase.refreshingDirectory,
      );

      handoff.complete();
      await execution;

      expect(runtime.calls, <String>['handoff', 'resume', 'continue']);
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.completed);
      expect(runtime.automaticSyncPaused, isFalse);
    },
  );

  test('does not run an existing batch when its BLE handoff fails', () async {
    final runtime = _FakeQuickWifiRuntime(
      handoffFailureCode: 'RECORDING_CARD_WIFI_HANDOFF_TRANSFER_NOT_SETTLED',
      handoffForcesPause: true,
    );
    final batch = _batch(
      RecordingCardWifiBatchState.failed,
      RecordingCardWifiBatchItemState.failed,
    );
    runtime.replaceBatch(batch);
    final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
    addTearDown(coordinator.dispose);
    final requestId = coordinator.beginExistingBatch(
      batch,
      RecordingCardQuickWifiExistingAction.retryFailed,
    );

    await coordinator.execute(requestId);

    expect(runtime.calls, <String>['handoff', 'continue']);
    expect(runtime.startCalls, 0);
    expect(coordinator.state.phase, RecordingCardQuickWifiPhase.failed);
    expect(runtime.automaticSyncPaused, isFalse);
  });

  test(
    'fresh request ignores the same-card batch visible at its baseline',
    () async {
      final pause = Completer<void>();
      final runtime = _FakeQuickWifiRuntime(pauseCompleter: pause);
      final oldBatch = _batch(
        RecordingCardWifiBatchState.paused,
        RecordingCardWifiBatchItemState.queued,
        batchId: 'old-batch',
      );
      runtime.replaceBatch(oldBatch);
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);
      final requestId = coordinator.beginSelected(
        const <RecordingCardScannedFile>[_file],
      );

      final execution = coordinator.execute(requestId);
      runtime.replaceBatch(
        _batch(
          RecordingCardWifiBatchState.transferring,
          RecordingCardWifiBatchItemState.transferring,
          batchId: 'old-batch',
        ),
      );

      expect(
        coordinator.state.phase,
        RecordingCardQuickWifiPhase.preparingHandoff,
      );
      expect(coordinator.state.batchId, isNull);
      pause.complete();
      await execution;
      expect(coordinator.state.batchId, 'quick-wifi-batch');
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.completed);
    },
  );

  test(
    'new request does not reuse an older settling execution Future',
    () async {
      final runGate = Completer<void>();
      final runtime = _FakeQuickWifiRuntime(runCompleter: runGate);
      final oldBatch = _batch(
        RecordingCardWifiBatchState.paused,
        RecordingCardWifiBatchItemState.queued,
        batchId: 'old-batch',
      );
      runtime.replaceBatch(oldBatch);
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);
      final oldRequestId = coordinator.beginExistingBatch(
        oldBatch,
        RecordingCardQuickWifiExistingAction.resume,
      );
      final oldExecution = coordinator.execute(oldRequestId);
      runtime.replaceBatch(
        _batch(
          RecordingCardWifiBatchState.completed,
          RecordingCardWifiBatchItemState.completed,
          batchId: 'old-batch',
        ),
      );
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.completed);

      final newRequestId = coordinator.beginSelected(
        const <RecordingCardScannedFile>[_file],
      );
      final newExecution = coordinator.execute(newRequestId);

      expect(identical(newExecution, oldExecution), isFalse);
      await _waitFor(() => runtime.calls.contains('pause'));
      runGate.complete();
      await Future.wait(<Future<void>>[oldExecution, newExecution]);
      expect(coordinator.state.requestId, newRequestId);
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.completed);
    },
  );

  test(
    'cancelled intent resumes auto sync before projection and clears when ready',
    () async {
      final runtime = _FakeQuickWifiRuntime(
        runBatchState: RecordingCardWifiBatchState.cancelled,
      );
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);
      final requestId = coordinator.beginSelected(
        const <RecordingCardScannedFile>[_file],
      );
      await coordinator.execute(requestId);
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.cancelled);
      expect(runtime.automaticSyncPaused, isFalse);
      expect(runtime.calls.last, 'continue');

      expect(
        await coordinator.acknowledgeCancelledProjection(
          requestId: requestId,
          cardSnDigest: _cardDigest,
          projectionReady: false,
        ),
        isFalse,
      );
      expect(runtime.dismissCalls, 0);
      expect(runtime.automaticSyncPaused, isFalse);
      expect(coordinator.state.keepsSyncCardVisible, isTrue);

      expect(
        await coordinator.acknowledgeCancelledProjection(
          requestId: requestId,
          cardSnDigest: _cardDigest,
          projectionReady: true,
        ),
        isTrue,
      );
      expect(runtime.dismissCalls, 1);
      expect(runtime.automaticSyncPaused, isFalse);
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.idle);
    },
  );

  test(
    'runtime cancellation waits for BLE recovery before resuming auto sync',
    () async {
      final runtime = _FakeQuickWifiRuntime(
        runBatchState: RecordingCardWifiBatchState.transferring,
      );
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);
      final requestId = coordinator.beginSelected(
        const <RecordingCardScannedFile>[_file],
      );
      await coordinator.execute(requestId);
      expect(runtime.automaticSyncPaused, isTrue);

      runtime.replaceBatch(
        _batch(
          RecordingCardWifiBatchState.cancelled,
          RecordingCardWifiBatchItemState.cancelled,
          operationPhase: RecordingCardWifiOperationPhase.recovering,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.reconciling);
      expect(coordinator.state.keepsSyncCardVisible, isTrue);
      expect(runtime.automaticSyncPaused, isTrue);
      expect(runtime.calls.last, isNot('continue'));

      runtime.replaceBatch(
        _batch(
          RecordingCardWifiBatchState.cancelled,
          RecordingCardWifiBatchItemState.cancelled,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.cancelled);
      expect(runtime.automaticSyncPaused, isFalse);
      expect(runtime.calls.last, 'continue');
      expect(runtime.dismissCalls, 0);
      expect(runtime.cardState.wifiBatch, isNotNull);
    },
  );

  test(
    'paused and failed batches release auto sync only after recovery',
    () async {
      for (final state in <RecordingCardWifiBatchState>[
        RecordingCardWifiBatchState.paused,
        RecordingCardWifiBatchState.failed,
      ]) {
        final runtime = _FakeQuickWifiRuntime(
          runBatchState: RecordingCardWifiBatchState.transferring,
        );
        final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
        addTearDown(coordinator.dispose);
        final requestId = coordinator.beginSelected(
          const <RecordingCardScannedFile>[_file],
        );
        await coordinator.execute(requestId);

        runtime.replaceBatch(
          _batch(
            state,
            state == RecordingCardWifiBatchState.failed
                ? RecordingCardWifiBatchItemState.failed
                : RecordingCardWifiBatchItemState.queued,
            operationPhase: RecordingCardWifiOperationPhase.recovering,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(runtime.automaticSyncPaused, isTrue, reason: state.name);

        runtime.replaceBatch(
          _batch(
            state,
            state == RecordingCardWifiBatchState.failed
                ? RecordingCardWifiBatchItemState.failed
                : RecordingCardWifiBatchItemState.queued,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(runtime.automaticSyncPaused, isFalse, reason: state.name);
        expect(
          runtime.calls.where((call) => call == 'continue'),
          hasLength(1),
          reason: state.name,
        );
      }
    },
  );

  test(
    'clears completion only after page projection and batch dismissal',
    () async {
      final runtime = _FakeQuickWifiRuntime();
      final coordinator = RecordingCardQuickWifiCoordinator(runtime: runtime);
      addTearDown(coordinator.dispose);
      final requestId = coordinator.beginSelected(
        const <RecordingCardScannedFile>[_file],
      );
      await coordinator.execute(requestId);

      expect(
        await coordinator.acknowledgeCompletedProjection(
          requestId: requestId,
          cardSnDigest: _cardDigest,
          remainingTargetCount: 1,
        ),
        isFalse,
      );
      expect(coordinator.state.keepsSyncCardVisible, isTrue);

      expect(
        await coordinator.acknowledgeCompletedProjection(
          requestId: requestId,
          cardSnDigest: _cardDigest,
          remainingTargetCount: 0,
        ),
        isTrue,
      );
      expect(runtime.dismissCalls, 1);
      expect(coordinator.state.phase, RecordingCardQuickWifiPhase.idle);
    },
  );
}

final class _FakeQuickWifiRuntime extends ChangeNotifier
    implements RecordingCardQuickWifiRuntime {
  _FakeQuickWifiRuntime({
    this.pauseCompleter,
    this.handoffCompleter,
    this.handoffFailureCode,
    this.pauseChangesState = true,
    this.handoffForcesPause = false,
    this.runCompleter,
    this.runBatchState = RecordingCardWifiBatchState.completed,
  }) : _cardState = _connectedState();

  final Completer<void>? pauseCompleter;
  final Completer<void>? handoffCompleter;
  final String? handoffFailureCode;
  final bool pauseChangesState;
  final bool handoffForcesPause;
  final Completer<void>? runCompleter;
  final RecordingCardWifiBatchState runBatchState;
  final List<String> calls = <String>[];
  RecordingCardControllerState _cardState;
  bool _automaticSyncPaused = false;
  int queueCalls = 0;
  int startCalls = 0;
  int dismissCalls = 0;

  @override
  RecordingCardControllerState get cardState => _cardState;

  @override
  String? get connectedCardSnDigest => _cardDigest;

  @override
  bool get automaticSyncPaused => _automaticSyncPaused;

  void replaceFingerprint(String fingerprint) {
    _cardState = _cardState.copyWith(
      snapshot: _cardState.snapshot.copyWith(
        deviceState: _cardState.snapshot.deviceState.copyWith(
          safeDeviceFingerprint: fingerprint,
        ),
      ),
    );
    notifyListeners();
  }

  void replaceBatch(RecordingCardWifiBatchSnapshot batch) {
    _cardState = _cardState.copyWith(wifiBatch: batch);
    notifyListeners();
  }

  @override
  Future<void> pauseAutomaticSync() async {
    calls.add('pause');
    if (pauseChangesState) _automaticSyncPaused = true;
    await pauseCompleter?.future;
  }

  @override
  void continueAutomaticSync() {
    calls.add('continue');
    _automaticSyncPaused = false;
  }

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  prepareWifiHandoff(String expectedCardSnDigest) async {
    calls.add('handoff');
    if (handoffForcesPause) _automaticSyncPaused = true;
    await handoffCompleter?.future;
    if (handoffFailureCode case final code?) {
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        recordingCardFailure(code, 'fixture failure', isRetryable: true),
      );
    }
    return RecordingCardResult<List<RecordingCardScannedFile>>.success(
      const <RecordingCardScannedFile>[_file],
    );
  }

  @override
  List<RecordingCardScannedFile> resolveCandidates(
    List<RecordingCardScannedFile> directory,
    String cardSnDigest,
  ) {
    calls.add('resolve');
    return directory;
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>> queueWifiBatch(
    List<RecordingCardScannedFile> files, {
    required String expectedCardSnDigest,
  }) async {
    calls.add('queue');
    queueCalls += 1;
    final batch = _batch(
      RecordingCardWifiBatchState.queued,
      RecordingCardWifiBatchItemState.queued,
    );
    _cardState = _cardState.copyWith(wifiBatch: batch);
    notifyListeners();
    return RecordingCardResult<RecordingCardWifiBatchSnapshot>.success(batch);
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>> runExistingBatch(
    RecordingCardQuickWifiExistingAction action,
  ) async {
    calls.add(
      action == RecordingCardQuickWifiExistingAction.start
          ? 'start'
          : action.name,
    );
    startCalls += 1;
    await runCompleter?.future;
    final currentBatchId = _cardState.wifiBatch?.batchId ?? 'quick-wifi-batch';
    final itemState = runBatchState == RecordingCardWifiBatchState.completed
        ? RecordingCardWifiBatchItemState.completed
        : runBatchState == RecordingCardWifiBatchState.cancelled
        ? RecordingCardWifiBatchItemState.cancelled
        : RecordingCardWifiBatchItemState.queued;
    final batch = _batch(runBatchState, itemState, batchId: currentBatchId);
    _cardState = _cardState.copyWith(wifiBatch: batch);
    notifyListeners();
    return RecordingCardResult<RecordingCardWifiBatchSnapshot>.success(batch);
  }

  @override
  Future<bool> dismissWifiBatch() async {
    dismissCalls += 1;
    _cardState = _cardState.copyWith(clearWifiBatch: true);
    notifyListeners();
    return true;
  }
}

RecordingCardControllerState _connectedState() {
  return RecordingCardControllerState.initial(
    RecordingCardRuntimeSnapshot(
      deviceState: const RecordingCardDeviceState(
        connectionState: RecordingCardConnectionState.connected,
        connectionStage: RecordingCardConnectionStage.connected,
        safeDeviceFingerprint: _fingerprint,
        serialNumber: 'SP63A03003',
        wifiSupported: true,
      ),
      recordingInfo: RecordingCardRecordingInfo.idle(),
      files: const <RecordingCardScannedFile>[_file],
    ),
  );
}

RecordingCardWifiBatchSnapshot _batch(
  RecordingCardWifiBatchState state,
  RecordingCardWifiBatchItemState itemState, {
  String? cardSnDigest = _cardDigest,
  String batchId = 'quick-wifi-batch',
  RecordingCardWifiOperationPhase operationPhase =
      RecordingCardWifiOperationPhase.idle,
}) {
  final at = DateTime.utc(2026, 9, 13, 9);
  return RecordingCardWifiBatchSnapshot(
    batchId: batchId,
    deviceFingerprint: _fingerprint,
    deviceIdentity: 'serial:SP63A03003',
    cardSnDigest: cardSnDigest,
    state: state,
    operationPhase: operationPhase,
    items: <RecordingCardWifiBatchItem>[
      RecordingCardWifiBatchItem(
        file: _file,
        state: itemState,
        order: 0,
        expectedSizeBytes: 4096,
      ),
    ],
    createdAt: at,
    updatedAt: at,
  );
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Timed out waiting for quick-Wi-Fi test condition');
}
