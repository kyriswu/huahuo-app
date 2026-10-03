import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/native/recording_card_native_port.dart';
import 'recording_card_auto_sync_coordinator.dart';
import 'recording_card_controller.dart';

enum RecordingCardQuickWifiPhase {
  idle,
  preparingHandoff,
  refreshingDirectory,
  persistingPlan,
  openingHotspot,
  joiningHotspot,
  transferring,
  verifying,
  registering,
  reconciling,
  stopping,
  paused,
  completed,
  failed,
  cancelled,
}

enum RecordingCardQuickWifiExistingAction { start, resume, retryFailed }

@immutable
final class RecordingCardQuickWifiState {
  const RecordingCardQuickWifiState({
    required this.phase,
    required this.updatedAt,
    this.requestId,
    this.expectedCardSnDigest,
    this.expectedDeviceFingerprint,
    this.batchId,
    this.targetCount = 0,
    this.targetFileKeys = const <String>[],
    this.failureCode,
    this.canRetry = false,
  });

  factory RecordingCardQuickWifiState.idle(DateTime at) {
    return RecordingCardQuickWifiState(
      phase: RecordingCardQuickWifiPhase.idle,
      updatedAt: at,
    );
  }

  final RecordingCardQuickWifiPhase phase;
  final DateTime updatedAt;
  final String? requestId;
  final String? expectedCardSnDigest;
  final String? expectedDeviceFingerprint;
  final String? batchId;
  final int targetCount;
  final List<String> targetFileKeys;
  final String? failureCode;
  final bool canRetry;

  bool get hasIntent => requestId != null;

  bool get isPreparing => switch (phase) {
    RecordingCardQuickWifiPhase.preparingHandoff ||
    RecordingCardQuickWifiPhase.refreshingDirectory ||
    RecordingCardQuickWifiPhase.persistingPlan => true,
    _ => false,
  };

  bool get isTerminal => switch (phase) {
    RecordingCardQuickWifiPhase.completed ||
    RecordingCardQuickWifiPhase.failed ||
    RecordingCardQuickWifiPhase.cancelled => true,
    _ => false,
  };

  bool get keepsSyncCardVisible =>
      hasIntent && phase != RecordingCardQuickWifiPhase.idle;

  RecordingCardQuickWifiState copyWith({
    RecordingCardQuickWifiPhase? phase,
    DateTime? updatedAt,
    String? batchId,
    int? targetCount,
    List<String>? targetFileKeys,
    String? failureCode,
    bool? canRetry,
    bool clearBatch = false,
    bool clearFailure = false,
  }) {
    return RecordingCardQuickWifiState(
      phase: phase ?? this.phase,
      updatedAt: updatedAt ?? this.updatedAt,
      requestId: requestId,
      expectedCardSnDigest: expectedCardSnDigest,
      expectedDeviceFingerprint: expectedDeviceFingerprint,
      batchId: clearBatch ? null : batchId ?? this.batchId,
      targetCount: targetCount ?? this.targetCount,
      targetFileKeys: List<String>.unmodifiable(
        targetFileKeys ?? this.targetFileKeys,
      ),
      failureCode: clearFailure ? null : failureCode ?? this.failureCode,
      canRetry: canRetry ?? this.canRetry,
    );
  }
}

typedef RecordingCardQuickWifiCandidateResolver =
    List<RecordingCardScannedFile> Function(
      List<RecordingCardScannedFile> directory,
      String cardSnDigest,
    );

abstract interface class RecordingCardQuickWifiRuntime implements Listenable {
  RecordingCardControllerState get cardState;

  String? get connectedCardSnDigest;

  bool get automaticSyncPaused;

  List<RecordingCardScannedFile> resolveCandidates(
    List<RecordingCardScannedFile> directory,
    String cardSnDigest,
  );

  Future<void> pauseAutomaticSync();

  void continueAutomaticSync();

  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  prepareWifiHandoff(String expectedCardSnDigest);

  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>> queueWifiBatch(
    List<RecordingCardScannedFile> files, {
    required String expectedCardSnDigest,
  });

  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>> runExistingBatch(
    RecordingCardQuickWifiExistingAction action,
  );

  Future<bool> dismissWifiBatch();
}

final class ControllerRecordingCardQuickWifiRuntime
    implements RecordingCardQuickWifiRuntime {
  const ControllerRecordingCardQuickWifiRuntime({
    required RecordingCardController controller,
    required RecordingCardAutoSyncCoordinator automaticSync,
    required RecordingCardQuickWifiCandidateResolver candidateResolver,
  }) : _controller = controller,
       _automaticSync = automaticSync,
       _candidateResolver = candidateResolver;

  final RecordingCardController _controller;
  final RecordingCardAutoSyncCoordinator _automaticSync;
  final RecordingCardQuickWifiCandidateResolver _candidateResolver;

  @override
  RecordingCardControllerState get cardState => _controller.state;

  @override
  String? get connectedCardSnDigest => _automaticSync.connectedCardSnDigest;

  @override
  bool get automaticSyncPaused => _automaticSync.isPaused;

  @override
  void addListener(VoidCallback listener) {
    _controller.addListener(listener);
    _automaticSync.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _controller.removeListener(listener);
    _automaticSync.removeListener(listener);
  }

  @override
  List<RecordingCardScannedFile> resolveCandidates(
    List<RecordingCardScannedFile> directory,
    String cardSnDigest,
  ) => _candidateResolver(directory, cardSnDigest);

  @override
  Future<void> pauseAutomaticSync() => _automaticSync.pause();

  @override
  void continueAutomaticSync() => _automaticSync.continueSync();

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  prepareWifiHandoff(String expectedCardSnDigest) => _automaticSync
      .prepareWifiHandoff(expectedCardSnDigest: expectedCardSnDigest);

  @override
  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>> queueWifiBatch(
    List<RecordingCardScannedFile> files, {
    required String expectedCardSnDigest,
  }) => _controller.queueWifiBatch(
    files,
    expectedCardSnDigest: expectedCardSnDigest,
  );

  @override
  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>> runExistingBatch(
    RecordingCardQuickWifiExistingAction action,
  ) => switch (action) {
    RecordingCardQuickWifiExistingAction.start =>
      _controller.startQueuedWifiBatch(),
    RecordingCardQuickWifiExistingAction.resume =>
      _controller.resumeWifiBatch(),
    RecordingCardQuickWifiExistingAction.retryFailed =>
      _controller.retryFailedWifiBatch(),
  };

  @override
  Future<bool> dismissWifiBatch() => _controller.dismissWifiBatch();
}

enum _RecordingCardQuickWifiRequestKind { allUnsynced, selected, existing }

final class _RecordingCardQuickWifiRequest {
  const _RecordingCardQuickWifiRequest({
    required this.requestId,
    required this.kind,
    required this.expectedCardSnDigest,
    required this.expectedDeviceFingerprint,
    required this.selectedFiles,
    this.existingAction,
  });

  final String requestId;
  final _RecordingCardQuickWifiRequestKind kind;
  final String expectedCardSnDigest;
  final String expectedDeviceFingerprint;
  final List<RecordingCardScannedFile> selectedFiles;
  final RecordingCardQuickWifiExistingAction? existingAction;
}

final class RecordingCardQuickWifiCoordinator extends ChangeNotifier {
  RecordingCardQuickWifiCoordinator({
    required RecordingCardQuickWifiRuntime runtime,
    DateTime Function()? clock,
  }) : _runtime = runtime,
       _clock = clock ?? DateTime.now,
       _state = RecordingCardQuickWifiState.idle((clock ?? DateTime.now)()) {
    _runtime.addListener(_handleRuntimeChanged);
  }

  final RecordingCardQuickWifiRuntime _runtime;
  final DateTime Function() _clock;
  RecordingCardQuickWifiState _state;
  _RecordingCardQuickWifiRequest? _request;
  Future<void>? _execution;
  String? _executionRequestId;
  String? _baselineBatchId;
  String? _ownedBatchId;
  int _requestSequence = 0;
  bool _disposed = false;
  bool _resumeAutomaticAfterSettlement = false;

  RecordingCardQuickWifiState get state => _state;

  String beginAllUnsynced() => _beginSelection(
    kind: _RecordingCardQuickWifiRequestKind.allUnsynced,
    selectedFiles: const <RecordingCardScannedFile>[],
  );

  String beginSelected(Iterable<RecordingCardScannedFile> files) =>
      _beginSelection(
        kind: _RecordingCardQuickWifiRequestKind.selected,
        selectedFiles: List<RecordingCardScannedFile>.unmodifiable(files),
      );

  String beginExistingBatch(
    RecordingCardWifiBatchSnapshot batch,
    RecordingCardQuickWifiExistingAction action,
  ) {
    final activeId = _activeRequestId;
    if (activeId != null &&
        _state.batchId == batch.batchId &&
        _executionRequestId == activeId) {
      return activeId;
    }
    final digest =
        _text(batch.cardSnDigest) ?? _text(_runtime.connectedCardSnDigest);
    final fingerprint = _text(batch.deviceFingerprint);
    final requestId = _nextRequestId();
    if (digest == null || fingerprint == null) {
      _publishNewFailure(
        requestId: requestId,
        failureCode: 'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
      );
      return requestId;
    }
    _request = _RecordingCardQuickWifiRequest(
      requestId: requestId,
      kind: _RecordingCardQuickWifiRequestKind.existing,
      expectedCardSnDigest: digest,
      expectedDeviceFingerprint: fingerprint,
      selectedFiles: const <RecordingCardScannedFile>[],
      existingAction: action,
    );
    _baselineBatchId = batch.batchId;
    _ownedBatchId = batch.batchId;
    _resumeAutomaticAfterSettlement = false;
    _state = RecordingCardQuickWifiState(
      phase: RecordingCardQuickWifiPhase.preparingHandoff,
      updatedAt: _clock(),
      requestId: requestId,
      expectedCardSnDigest: digest,
      expectedDeviceFingerprint: fingerprint,
      batchId: batch.batchId,
      targetCount: batch.remainingCount,
      targetFileKeys: List<String>.unmodifiable(
        batch.items.map((item) => item.file.localFileKey),
      ),
      failureCode: batch.failureCode,
    );
    notifyListeners();
    return requestId;
  }

  String _beginSelection({
    required _RecordingCardQuickWifiRequestKind kind,
    required List<RecordingCardScannedFile> selectedFiles,
  }) {
    final activeId = _activeRequestId;
    if (activeId != null) return activeId;
    final requestId = _nextRequestId();
    final digest = _text(_runtime.connectedCardSnDigest);
    final fingerprint = _text(
      _runtime.cardState.snapshot.deviceState.safeDeviceFingerprint,
    );
    if (digest == null || fingerprint == null) {
      _publishNewFailure(
        requestId: requestId,
        failureCode: 'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
      );
      return requestId;
    }
    if (kind == _RecordingCardQuickWifiRequestKind.selected &&
        selectedFiles.isEmpty) {
      _publishNewFailure(
        requestId: requestId,
        failureCode: 'RECORDING_CARD_WIFI_BATCH_EMPTY',
      );
      return requestId;
    }
    _request = _RecordingCardQuickWifiRequest(
      requestId: requestId,
      kind: kind,
      expectedCardSnDigest: digest,
      expectedDeviceFingerprint: fingerprint,
      selectedFiles: selectedFiles,
    );
    _baselineBatchId = _runtime.cardState.wifiBatch?.batchId;
    _ownedBatchId = null;
    _resumeAutomaticAfterSettlement = false;
    _state = RecordingCardQuickWifiState(
      phase: RecordingCardQuickWifiPhase.preparingHandoff,
      updatedAt: _clock(),
      requestId: requestId,
      expectedCardSnDigest: digest,
      expectedDeviceFingerprint: fingerprint,
      targetCount: selectedFiles.length,
      targetFileKeys: List<String>.unmodifiable(
        selectedFiles.map((file) => file.localFileKey),
      ),
    );
    notifyListeners();
    return requestId;
  }

  String? get _activeRequestId {
    if (!_state.hasIntent || _state.isTerminal) return null;
    return _state.requestId;
  }

  String _nextRequestId() {
    _requestSequence += 1;
    return 'recording-card-quick-wifi-'
        '${_clock().toUtc().microsecondsSinceEpoch}-$_requestSequence';
  }

  Future<void> execute(String requestId) {
    final existing = _execution;
    if (existing != null && _executionRequestId == requestId) return existing;
    if (_request?.requestId != requestId || _state.isTerminal) {
      return Future<void>.value();
    }
    late final Future<void> operation;
    operation = _executeOwned(requestId).whenComplete(() {
      if (identical(_execution, operation)) {
        _execution = null;
        _executionRequestId = null;
      }
    });
    _execution = operation;
    _executionRequestId = requestId;
    return operation;
  }

  Future<void> retry(String requestId) {
    if (!_ownsRequest(requestId) ||
        !_state.canRetry ||
        _state.batchId != null ||
        _state.phase != RecordingCardQuickWifiPhase.failed) {
      return Future<void>.value();
    }
    _transition(requestId, RecordingCardQuickWifiPhase.preparingHandoff);
    return execute(requestId);
  }

  Future<void> _executeOwned(String requestId) async {
    final request = _request;
    if (request == null || request.requestId != requestId) return;
    if (request.kind == _RecordingCardQuickWifiRequestKind.existing) {
      if (!_ownsCard(request)) {
        _failOwned(requestId, 'RECORDING_CARD_WIFI_HANDOFF_CARD_CHANGED');
        return;
      }
      final wasPaused = _runtime.automaticSyncPaused;
      _transition(requestId, RecordingCardQuickWifiPhase.refreshingDirectory);
      final handoff = await _runtime.prepareWifiHandoff(
        request.expectedCardSnDigest,
      );
      if (!_ownsRequest(requestId)) return;
      _resumeAutomaticAfterSettlement =
          !wasPaused && _runtime.automaticSyncPaused;
      if (!handoff.ok || handoff.value == null) {
        _failOwned(
          requestId,
          handoff.error?.code ?? 'RECORDING_CARD_WIFI_HANDOFF_FAILED',
        );
        _continueAutomaticAfterSettlement();
        return;
      }
      if (!_ownsCard(request)) {
        _failOwned(requestId, 'RECORDING_CARD_WIFI_HANDOFF_CARD_CHANGED');
        _continueAutomaticAfterSettlement();
        return;
      }
      final result = await _runtime.runExistingBatch(request.existingAction!);
      _settleRunResult(requestId, result);
      return;
    }

    if (!_ownsCard(request)) {
      _failOwned(requestId, 'RECORDING_CARD_WIFI_HANDOFF_CARD_CHANGED');
      return;
    }
    final wasPaused = _runtime.automaticSyncPaused;
    await _runtime.pauseAutomaticSync();
    if (!_ownsRequest(requestId)) return;
    _transition(requestId, RecordingCardQuickWifiPhase.refreshingDirectory);
    final handoff = await _runtime.prepareWifiHandoff(
      request.expectedCardSnDigest,
    );
    if (!_ownsRequest(requestId)) return;
    _resumeAutomaticAfterSettlement =
        !wasPaused && _runtime.automaticSyncPaused;
    if (!handoff.ok || handoff.value == null) {
      _failOwned(
        requestId,
        handoff.error?.code ?? 'RECORDING_CARD_WIFI_HANDOFF_FAILED',
      );
      _continueAutomaticAfterPreBatchFailure();
      return;
    }
    if (!_ownsCard(request)) {
      _failOwned(requestId, 'RECORDING_CARD_WIFI_HANDOFF_CARD_CHANGED');
      _continueAutomaticAfterPreBatchFailure();
      return;
    }

    final directory = List<RecordingCardScannedFile>.unmodifiable(
      handoff.value!,
    );
    final candidates = _runtime.resolveCandidates(
      directory,
      request.expectedCardSnDigest,
    );
    final selected = _resolveSelection(request, directory, candidates);
    if (selected == null) {
      _failOwned(requestId, 'RECORDING_CARD_FILE_SELECTION_STALE');
      _continueAutomaticAfterPreBatchFailure();
      return;
    }
    if (selected.isEmpty) {
      _transition(requestId, RecordingCardQuickWifiPhase.completed);
      _continueAutomaticAfterSettlement();
      return;
    }

    _transition(
      requestId,
      RecordingCardQuickWifiPhase.persistingPlan,
      targetCount: selected.length,
      targetFileKeys: selected.map((file) => file.localFileKey).toList(),
    );
    final queued = await _runtime.queueWifiBatch(
      selected,
      expectedCardSnDigest: request.expectedCardSnDigest,
    );
    if (!_ownsRequest(requestId)) return;
    final queuedBatch = queued.ok
        ? _lockFreshQueuedBatch(request, queued.value) ??
              _lockFreshQueuedBatch(request, _runtime.cardState.wifiBatch)
        : queued.error?.code == 'RECORDING_CARD_WIFI_BATCH_ALREADY_SYNCED'
        ? _lockFreshQueuedBatch(request, _runtime.cardState.wifiBatch)
        : null;
    if (!queued.ok || queuedBatch == null) {
      if (queued.error?.code == 'RECORDING_CARD_WIFI_BATCH_ALREADY_SYNCED' &&
          queuedBatch?.state == RecordingCardWifiBatchState.completed) {
        _adoptBatch(requestId, queuedBatch!);
        _continueAutomaticAfterSettlement();
        return;
      }
      _failOwned(
        requestId,
        queued.error?.code ?? 'RECORDING_CARD_WIFI_BATCH_PERSISTENCE_FAILED',
      );
      _continueAutomaticAfterPreBatchFailure();
      return;
    }
    _adoptBatch(requestId, queuedBatch);
    final result = await _runtime.runExistingBatch(
      RecordingCardQuickWifiExistingAction.start,
    );
    _settleRunResult(requestId, result);
  }

  List<RecordingCardScannedFile>? _resolveSelection(
    _RecordingCardQuickWifiRequest request,
    List<RecordingCardScannedFile> directory,
    List<RecordingCardScannedFile> candidates,
  ) {
    if (request.kind == _RecordingCardQuickWifiRequestKind.allUnsynced) {
      return List<RecordingCardScannedFile>.unmodifiable(candidates);
    }
    final resolved = <RecordingCardScannedFile>[];
    for (final original in request.selectedFiles) {
      final current = directory
          .where((file) => _sameFile(file, original))
          .firstOrNull;
      if (current == null) return null;
      final candidate = candidates
          .where((file) => _sameFile(file, original))
          .firstOrNull;
      if (candidate != null) resolved.add(candidate);
    }
    return List<RecordingCardScannedFile>.unmodifiable(resolved);
  }

  bool _sameFile(
    RecordingCardScannedFile current,
    RecordingCardScannedFile original,
  ) {
    if (current.deviceFileId != original.deviceFileId ||
        current.deviceFilename != original.deviceFilename ||
        current.localFileKey != original.localFileKey) {
      return false;
    }
    final currentSize = current.sizeBytes;
    final originalSize = original.sizeBytes;
    if (currentSize != null &&
        originalSize != null &&
        currentSize != originalSize) {
      return false;
    }
    final currentHash = _text(current.contentHash);
    final originalHash = _text(original.contentHash);
    return currentHash == null ||
        originalHash == null ||
        currentHash == originalHash;
  }

  bool _ownsCard(_RecordingCardQuickWifiRequest request) {
    final digest = _text(_runtime.connectedCardSnDigest);
    final fingerprint = _text(
      _runtime.cardState.snapshot.deviceState.safeDeviceFingerprint,
    );
    return digest == request.expectedCardSnDigest &&
        fingerprint == request.expectedDeviceFingerprint;
  }

  RecordingCardWifiBatchSnapshot? _matchingRuntimeBatch(
    _RecordingCardQuickWifiRequest request,
  ) {
    final batch = _runtime.cardState.wifiBatch;
    final ownedBatchId = _ownedBatchId;
    if (batch == null ||
        ownedBatchId == null ||
        batch.batchId != ownedBatchId ||
        !_batchMatchesRequestIdentity(
          request,
          batch,
          allowMissingDigest:
              request.kind == _RecordingCardQuickWifiRequestKind.existing,
        )) {
      return null;
    }
    return batch;
  }

  RecordingCardWifiBatchSnapshot? _lockFreshQueuedBatch(
    _RecordingCardQuickWifiRequest request,
    RecordingCardWifiBatchSnapshot? batch,
  ) {
    if (batch == null ||
        request.kind == _RecordingCardQuickWifiRequestKind.existing ||
        batch.batchId == _baselineBatchId ||
        !_batchMatchesRequestIdentity(
          request,
          batch,
          allowMissingDigest: false,
        )) {
      return null;
    }
    _ownedBatchId = batch.batchId;
    return batch;
  }

  bool _batchMatchesRequestIdentity(
    _RecordingCardQuickWifiRequest request,
    RecordingCardWifiBatchSnapshot batch, {
    required bool allowMissingDigest,
  }) {
    final persistedDigest = _text(batch.cardSnDigest);
    return batch.deviceFingerprint == request.expectedDeviceFingerprint &&
        (persistedDigest == request.expectedCardSnDigest ||
            (allowMissingDigest && persistedDigest == null));
  }

  void _settleRunResult(
    String requestId,
    RecordingCardResult<RecordingCardWifiBatchSnapshot> result,
  ) {
    if (!_ownsRequest(requestId)) return;
    final request = _request!;
    final returned = result.value;
    final batch =
        returned != null &&
            returned.batchId == _ownedBatchId &&
            _batchMatchesRequestIdentity(
              request,
              returned,
              allowMissingDigest:
                  request.kind == _RecordingCardQuickWifiRequestKind.existing,
            )
        ? returned
        : _matchingRuntimeBatch(request);
    if (batch != null) {
      _adoptBatch(requestId, batch);
      if (_batchHasSettledTransport(batch)) {
        _continueAutomaticIfTransportSettled();
      }
      return;
    }
    if (!result.ok) {
      _failOwned(
        requestId,
        result.error?.code ?? 'RECORDING_CARD_WIFI_TRANSFER_FAILED',
      );
      _continueAutomaticAfterPreBatchFailure();
    }
  }

  void _handleRuntimeChanged() {
    if (_disposed || !_state.hasIntent) return;
    final request = _request;
    if (request == null) return;
    final batch = _matchingRuntimeBatch(request);
    if (batch == null) return;
    _adoptBatch(request.requestId, batch);
    if (_batchHasSettledTransport(batch)) {
      scheduleMicrotask(_continueAutomaticIfTransportSettled);
    }
  }

  void _continueAutomaticIfTransportSettled() {
    if (_disposed || !_state.hasIntent) return;
    final request = _request;
    if (request == null) return;
    final latest = _matchingRuntimeBatch(request);
    if (latest != null && _batchHasSettledTransport(latest)) {
      _continueAutomaticAfterSettlement();
    }
  }

  bool _batchHasSettledTransport(RecordingCardWifiBatchSnapshot batch) {
    return batch.operationPhase == RecordingCardWifiOperationPhase.idle &&
        (batch.state == RecordingCardWifiBatchState.completed ||
            batch.state == RecordingCardWifiBatchState.paused ||
            batch.state == RecordingCardWifiBatchState.failed ||
            batch.state == RecordingCardWifiBatchState.cancelled);
  }

  void _adoptBatch(String requestId, RecordingCardWifiBatchSnapshot batch) {
    if (!_ownsRequest(requestId) || batch.batchId != _ownedBatchId) return;
    final next = _state.copyWith(
      phase: _phaseForBatch(batch),
      updatedAt: _clock(),
      batchId: batch.batchId,
      targetCount: batch.totalCount,
      targetFileKeys: batch.items
          .map((item) => item.file.localFileKey)
          .toList(),
      failureCode: batch.failureCode,
      clearFailure: batch.failureCode == null,
      canRetry: false,
    );
    if (_sameState(_state, next)) return;
    _state = next;
    notifyListeners();
  }

  RecordingCardQuickWifiPhase _phaseForBatch(
    RecordingCardWifiBatchSnapshot batch,
  ) {
    return switch (batch.operationPhase) {
      RecordingCardWifiOperationPhase.recovering =>
        RecordingCardQuickWifiPhase.reconciling,
      RecordingCardWifiOperationPhase.preparingHotspot =>
        RecordingCardQuickWifiPhase.openingHotspot,
      RecordingCardWifiOperationPhase.joiningHotspot =>
        RecordingCardQuickWifiPhase.joiningHotspot,
      RecordingCardWifiOperationPhase.stopping =>
        RecordingCardQuickWifiPhase.stopping,
      RecordingCardWifiOperationPhase.idle => switch (batch.state) {
        RecordingCardWifiBatchState.queued =>
          RecordingCardQuickWifiPhase.openingHotspot,
        RecordingCardWifiBatchState.awaitingHotspot ||
        RecordingCardWifiBatchState.openingSession =>
          RecordingCardQuickWifiPhase.joiningHotspot,
        RecordingCardWifiBatchState.transferring =>
          RecordingCardQuickWifiPhase.transferring,
        RecordingCardWifiBatchState.verifying =>
          RecordingCardQuickWifiPhase.verifying,
        RecordingCardWifiBatchState.registering =>
          RecordingCardQuickWifiPhase.registering,
        RecordingCardWifiBatchState.reconciling =>
          RecordingCardQuickWifiPhase.reconciling,
        RecordingCardWifiBatchState.paused =>
          RecordingCardQuickWifiPhase.paused,
        RecordingCardWifiBatchState.completed =>
          RecordingCardQuickWifiPhase.completed,
        RecordingCardWifiBatchState.failed =>
          RecordingCardQuickWifiPhase.failed,
        RecordingCardWifiBatchState.cancelled =>
          RecordingCardQuickWifiPhase.cancelled,
      },
    };
  }

  void _transition(
    String requestId,
    RecordingCardQuickWifiPhase phase, {
    int? targetCount,
    List<String>? targetFileKeys,
  }) {
    if (!_ownsRequest(requestId)) return;
    _state = _state.copyWith(
      phase: phase,
      updatedAt: _clock(),
      targetCount: targetCount,
      targetFileKeys: targetFileKeys,
      clearFailure: true,
      canRetry: false,
    );
    notifyListeners();
  }

  void _failOwned(String requestId, String failureCode) {
    if (!_ownsRequest(requestId)) return;
    _state = _state.copyWith(
      phase: RecordingCardQuickWifiPhase.failed,
      failureCode: failureCode,
      updatedAt: _clock(),
      canRetry: true,
    );
    notifyListeners();
  }

  void _publishNewFailure({
    required String requestId,
    required String failureCode,
  }) {
    _request = null;
    _baselineBatchId = null;
    _ownedBatchId = null;
    _state = RecordingCardQuickWifiState(
      phase: RecordingCardQuickWifiPhase.failed,
      updatedAt: _clock(),
      requestId: requestId,
      failureCode: failureCode,
    );
    notifyListeners();
  }

  bool _ownsRequest(String requestId) =>
      !_disposed &&
      _request?.requestId == requestId &&
      _state.requestId == requestId;

  void _continueAutomaticAfterPreBatchFailure() {
    if (_state.batchId == null) _continueAutomaticAfterSettlement();
  }

  void _continueAutomaticAfterSettlement() {
    if (!_resumeAutomaticAfterSettlement || _disposed) return;
    _resumeAutomaticAfterSettlement = false;
    if (_runtime.automaticSyncPaused) _runtime.continueAutomaticSync();
  }

  Future<bool> acknowledgeCompletedProjection({
    required String requestId,
    required String cardSnDigest,
    required int remainingTargetCount,
  }) async {
    if (!_ownsRequest(requestId) ||
        _state.phase != RecordingCardQuickWifiPhase.completed ||
        _state.expectedCardSnDigest != cardSnDigest ||
        remainingTargetCount != 0) {
      return false;
    }
    final batchId = _state.batchId;
    if (batchId != null) {
      final request = _request!;
      final batch = _matchingRuntimeBatch(request);
      if (batch?.batchId != batchId ||
          batch?.state != RecordingCardWifiBatchState.completed ||
          !await _runtime.dismissWifiBatch()) {
        return false;
      }
    }
    if (!_ownsRequest(requestId)) return false;
    _clearAcknowledgedIntent();
    return true;
  }

  Future<bool> acknowledgeCancelledProjection({
    required String requestId,
    required String cardSnDigest,
    required bool projectionReady,
  }) async {
    if (!_ownsRequest(requestId) ||
        _state.phase != RecordingCardQuickWifiPhase.cancelled ||
        _state.expectedCardSnDigest != cardSnDigest ||
        !projectionReady) {
      return false;
    }
    final request = _request!;
    final batch = _matchingRuntimeBatch(request);
    if (batch == null ||
        batch.batchId != _state.batchId ||
        batch.state != RecordingCardWifiBatchState.cancelled ||
        !await _runtime.dismissWifiBatch()) {
      return false;
    }
    if (!_ownsRequest(requestId)) return false;
    _clearAcknowledgedIntent();
    return true;
  }

  void _clearAcknowledgedIntent() {
    _request = null;
    _baselineBatchId = null;
    _ownedBatchId = null;
    _state = RecordingCardQuickWifiState.idle(_clock());
    notifyListeners();
  }

  bool _sameState(
    RecordingCardQuickWifiState left,
    RecordingCardQuickWifiState right,
  ) =>
      left.phase == right.phase &&
      left.batchId == right.batchId &&
      left.targetCount == right.targetCount &&
      listEquals(left.targetFileKeys, right.targetFileKeys) &&
      left.failureCode == right.failureCode &&
      left.canRetry == right.canRetry;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _runtime.removeListener(_handleRuntimeChanged);
    super.dispose();
  }
}

String? _text(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
