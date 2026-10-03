import '../../../core/native/recording_card_native_port.dart';

final class RecordingCardBatchDeleteResult {
  const RecordingCardBatchDeleteResult({
    required this.requestedCount,
    required this.deletedCount,
    required this.failureCodes,
  });

  final int requestedCount;
  final int deletedCount;
  final Map<String, String> failureCodes;

  int get failedCount => failureCodes.length;
  bool get completed => requestedCount > 0 && failedCount == 0;
}

enum RecordingCardWifiBatchState {
  queued,
  awaitingHotspot,
  openingSession,
  transferring,
  verifying,
  registering,
  reconciling,
  paused,
  completed,
  failed,
  cancelled,
}

enum RecordingCardWifiOperationPhase {
  idle,
  recovering,
  preparingHotspot,
  joiningHotspot,
  stopping,
}

enum RecordingCardWifiBatchItemState {
  queued,
  transferring,
  verifying,
  registering,
  completed,
  failed,
  cancelled,
  skipped,
}

final class RecordingCardWifiBatchItem {
  const RecordingCardWifiBatchItem({
    required this.file,
    required this.state,
    required this.order,
    required this.expectedSizeBytes,
    this.attemptCount = 0,
    this.errorCode,
    this.localRecordingId,
    this.ledgerSourceSignature,
    this.stagedDownload,
    this.plannedNativeFileId,
  });

  final RecordingCardScannedFile file;
  final RecordingCardWifiBatchItemState state;
  final int order;
  final int expectedSizeBytes;
  final int attemptCount;
  final String? errorCode;
  final String? localRecordingId;
  final String? ledgerSourceSignature;
  final RecordingCardDownloadedFile? stagedDownload;
  final String? plannedNativeFileId;

  int get effectiveSizeBytes {
    final stagedSize = stagedDownload?.sizeBytes;
    if (stagedSize != null && stagedSize > 0) return stagedSize;
    final currentSize = file.sizeBytes;
    if (currentSize != null && currentSize > 0) return currentSize;
    return expectedSizeBytes < 0 ? 0 : expectedSizeBytes;
  }

  bool get hasTransferredBytes =>
      stagedDownload != null ||
      state == RecordingCardWifiBatchItemState.completed ||
      state == RecordingCardWifiBatchItemState.skipped;

  bool get isCompleted =>
      state == RecordingCardWifiBatchItemState.completed ||
      state == RecordingCardWifiBatchItemState.skipped;

  bool get isTerminal =>
      isCompleted ||
      state == RecordingCardWifiBatchItemState.failed ||
      state == RecordingCardWifiBatchItemState.cancelled;

  RecordingCardWifiBatchItem copyWith({
    RecordingCardScannedFile? file,
    RecordingCardWifiBatchItemState? state,
    int? attemptCount,
    String? errorCode,
    String? localRecordingId,
    String? ledgerSourceSignature,
    RecordingCardDownloadedFile? stagedDownload,
    bool clearError = false,
    bool clearStagedDownload = false,
    String? plannedNativeFileId,
    bool clearPlannedDownload = false,
  }) {
    return RecordingCardWifiBatchItem(
      file: file ?? this.file,
      state: state ?? this.state,
      order: order,
      expectedSizeBytes: expectedSizeBytes,
      attemptCount: attemptCount ?? this.attemptCount,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
      localRecordingId: localRecordingId ?? this.localRecordingId,
      ledgerSourceSignature:
          ledgerSourceSignature ?? this.ledgerSourceSignature,
      plannedNativeFileId: clearPlannedDownload
          ? null
          : plannedNativeFileId ?? this.plannedNativeFileId,
      stagedDownload: clearStagedDownload
          ? null
          : stagedDownload ?? this.stagedDownload,
    );
  }
}

final class RecordingCardWifiBatchSnapshot {
  const RecordingCardWifiBatchSnapshot({
    required this.batchId,
    required this.deviceFingerprint,
    required this.deviceIdentity,
    required this.state,
    required this.items,
    required this.createdAt,
    required this.updatedAt,
    this.cardSnDigest,
    this.attemptId,
    this.stopRequested = false,
    this.operationPhase = RecordingCardWifiOperationPhase.idle,
    this.failureCode,
    this.currentItemIndex,
    this.receivedBytes = 0,
    double? bytesPerSecond,
    int? estimatedRemainingSeconds,
    int? currentFileEstimatedRemainingSeconds,
    int? aggregateEstimatedRemainingSeconds,
    int rateSampleCount = 0,
  }) : rateSampleCount = state == RecordingCardWifiBatchState.transferring
           ? (rateSampleCount < 0 ? 0 : rateSampleCount)
           : 0,
       bytesPerSecond =
           state == RecordingCardWifiBatchState.transferring &&
               rateSampleCount >= 2
           ? bytesPerSecond
           : null,
       currentFileEstimatedRemainingSeconds =
           state == RecordingCardWifiBatchState.transferring &&
               rateSampleCount >= 2
           ? currentFileEstimatedRemainingSeconds
           : null,
       aggregateEstimatedRemainingSeconds =
           state == RecordingCardWifiBatchState.transferring &&
               rateSampleCount >= 2
           ? aggregateEstimatedRemainingSeconds ?? estimatedRemainingSeconds
           : null;

  final String batchId;
  final String deviceFingerprint;
  final String deviceIdentity;
  final String? cardSnDigest;
  final String? attemptId;
  final bool stopRequested;
  final RecordingCardWifiOperationPhase operationPhase;
  final String? failureCode;
  final RecordingCardWifiBatchState state;
  final List<RecordingCardWifiBatchItem> items;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int? currentItemIndex;
  final int receivedBytes;
  final double? bytesPerSecond;
  final int? currentFileEstimatedRemainingSeconds;
  final int? aggregateEstimatedRemainingSeconds;
  final int rateSampleCount;

  @Deprecated('Use aggregateEstimatedRemainingSeconds')
  int? get estimatedRemainingSeconds => aggregateEstimatedRemainingSeconds;

  int get totalCount => items.length;
  int get completedCount => items.where((item) => item.isCompleted).length;
  int get remainingCount => totalCount - completedCount;
  int get failedCount => items
      .where((item) => item.state == RecordingCardWifiBatchItemState.failed)
      .length;
  int get totalBytes =>
      items.fold<int>(0, (total, item) => total + item.effectiveSizeBytes);
  int get completedBytes => items.fold<int>(0, (total, item) {
    return item.hasTransferredBytes ? total + item.effectiveSizeBytes : total;
  });
  int get aggregateReceivedBytes =>
      (completedBytes + receivedBytes).clamp(0, totalBytes);
  int get currentFileReceivedBytes {
    final total = currentFileTotalBytes;
    return total <= 0
        ? (receivedBytes < 0 ? 0 : receivedBytes)
        : receivedBytes.clamp(0, total).toInt();
  }

  int get currentFileTotalBytes => currentItem?.effectiveSizeBytes ?? 0;
  double? get fraction =>
      totalBytes <= 0 ? null : aggregateReceivedBytes / totalBytes;
  RecordingCardWifiBatchItem? get currentItem {
    final index = currentItemIndex;
    return index == null || index < 0 || index >= items.length
        ? null
        : items[index];
  }

  bool get isTerminal =>
      state == RecordingCardWifiBatchState.completed ||
      state == RecordingCardWifiBatchState.failed ||
      state == RecordingCardWifiBatchState.cancelled;
  bool get isBusy =>
      operationPhase != RecordingCardWifiOperationPhase.idle ||
      state == RecordingCardWifiBatchState.openingSession ||
      state == RecordingCardWifiBatchState.transferring ||
      state == RecordingCardWifiBatchState.verifying ||
      state == RecordingCardWifiBatchState.registering ||
      state == RecordingCardWifiBatchState.reconciling;

  bool get recoveryBlocked =>
      failureCode == 'RECORDING_CARD_WIFI_BATCH_RECORD_INVALID';

  bool get canContinue =>
      !recoveryBlocked &&
      !stopRequested &&
      ((state == RecordingCardWifiBatchState.reconciling &&
              operationPhase == RecordingCardWifiOperationPhase.idle) ||
          (!isBusy &&
              (state == RecordingCardWifiBatchState.queued ||
                  state == RecordingCardWifiBatchState.awaitingHotspot ||
                  state == RecordingCardWifiBatchState.paused)));

  bool get canRetryFailed =>
      !recoveryBlocked &&
      !stopRequested &&
      !isBusy &&
      (state == RecordingCardWifiBatchState.failed ||
          (state == RecordingCardWifiBatchState.completed && failedCount > 0));

  bool get canFinish =>
      operationPhase != RecordingCardWifiOperationPhase.stopping &&
      state != RecordingCardWifiBatchState.cancelled &&
      state != RecordingCardWifiBatchState.reconciling &&
      (state != RecordingCardWifiBatchState.completed || remainingCount > 0);

  bool get isActive =>
      operationPhase != RecordingCardWifiOperationPhase.idle ||
      switch (state) {
        RecordingCardWifiBatchState.queued ||
        RecordingCardWifiBatchState.awaitingHotspot ||
        RecordingCardWifiBatchState.openingSession ||
        RecordingCardWifiBatchState.transferring ||
        RecordingCardWifiBatchState.verifying ||
        RecordingCardWifiBatchState.registering ||
        RecordingCardWifiBatchState.reconciling => true,
        _ => false,
      };

  RecordingCardWifiBatchSnapshot copyWith({
    String? deviceIdentity,
    String? cardSnDigest,
    String? attemptId,
    bool? stopRequested,
    RecordingCardWifiOperationPhase? operationPhase,
    RecordingCardWifiBatchState? state,
    List<RecordingCardWifiBatchItem>? items,
    DateTime? updatedAt,
    int? currentItemIndex,
    int? receivedBytes,
    double? bytesPerSecond,
    int? estimatedRemainingSeconds,
    int? currentFileEstimatedRemainingSeconds,
    int? aggregateEstimatedRemainingSeconds,
    int? rateSampleCount,
    String? failureCode,
    bool clearCurrentItem = false,
    bool clearRate = false,
    bool clearFailure = false,
  }) {
    final nextState = state ?? this.state;
    final nextCurrentItemIndex = clearCurrentItem
        ? null
        : currentItemIndex ?? this.currentItemIndex;
    final clearTransferRate =
        clearRate ||
        nextState != RecordingCardWifiBatchState.transferring ||
        nextCurrentItemIndex != this.currentItemIndex;
    return RecordingCardWifiBatchSnapshot(
      batchId: batchId,
      deviceFingerprint: deviceFingerprint,
      deviceIdentity: deviceIdentity ?? this.deviceIdentity,
      cardSnDigest: cardSnDigest ?? this.cardSnDigest,
      attemptId: attemptId ?? this.attemptId,
      stopRequested: stopRequested ?? this.stopRequested,
      operationPhase: operationPhase ?? this.operationPhase,
      failureCode: clearFailure ? null : failureCode ?? this.failureCode,
      state: nextState,
      items: List<RecordingCardWifiBatchItem>.unmodifiable(items ?? this.items),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      currentItemIndex: nextCurrentItemIndex,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      bytesPerSecond: clearTransferRate
          ? null
          : bytesPerSecond ?? this.bytesPerSecond,
      currentFileEstimatedRemainingSeconds: clearTransferRate
          ? null
          : currentFileEstimatedRemainingSeconds ??
                this.currentFileEstimatedRemainingSeconds,
      aggregateEstimatedRemainingSeconds: clearTransferRate
          ? null
          : aggregateEstimatedRemainingSeconds ??
                estimatedRemainingSeconds ??
                this.aggregateEstimatedRemainingSeconds,
      rateSampleCount: clearTransferRate
          ? 0
          : rateSampleCount ?? this.rateSampleCount,
    );
  }
}

final class RecordingCardWifiBatchCoordinator {
  RecordingCardWifiBatchCoordinator({required this.onChanged});

  final void Function(RecordingCardWifiBatchSnapshot? value) onChanged;
  RecordingCardWifiBatchSnapshot? _snapshot;

  RecordingCardWifiBatchSnapshot? get snapshot => _snapshot;

  void replace(RecordingCardWifiBatchSnapshot value) {
    final previous = _snapshot;
    final effective =
        previous?.batchId == value.batchId &&
            previous!.stopRequested &&
            !value.stopRequested
        ? value.copyWith(stopRequested: true)
        : value;
    _snapshot = effective;
    onChanged(effective);
  }

  void dismiss() {
    _snapshot = null;
    onChanged(null);
  }
}
