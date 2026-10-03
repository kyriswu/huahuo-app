import 'recording_transcription_receipt.dart';

const recordingBatchObservationWindow = Duration(hours: 24);

enum RecordingTranscriptionDispatchKind { disabled, single, batch }

enum RecordingTranscriptionClassification {
  eligible,
  alreadyCompleted,
  existingRemoteCompleted,
  alreadyProcessing,
  awaitingVerification,
  retryExisting,
  unavailable,
}

enum RecordingTranscriptionRemoteFact {
  none,
  unknown,
  processing,
  transcriptReady,
  assetReady,
  retryableFailure,
  terminalFailure,
  timedOut,
}

enum RecordingBatchTranscriptionStatus {
  active,
  completed,
  completedWithIssues,
}

enum RecordingBatchTranscriptionItemStatus {
  pending,
  submitting,
  processing,
  completed,
  failed,
  timedOut,
  skipped;

  bool get isActive => switch (this) {
    pending || submitting || processing => true,
    completed || failed || timedOut || skipped => false,
  };

  bool get isTerminal => !isActive;
}

enum RecordingBatchTranscriptionPhase {
  uploading,
  transcribing,
  storingAsset,
  assetReady,
}

enum RecordingBatchOutlineStatus { notStarted, generating, completed, failed }

enum RecordingBatchWaitingReason {
  networkRequired,
  remoteVerificationRequired,
  accountScopeChanged,
}

enum RecordingBatchFailureCategory {
  unavailable,
  upload,
  transcription,
  assetStorage,
  authorization,
  persistence,
  remote,
  unknown,
}

/// Frozen local selection evidence used by both single and multi-file paths.
final class RecordingTranscriptionCandidate {
  const RecordingTranscriptionCandidate({
    required this.itemId,
    required this.title,
    required this.fileIdentity,
    required this.localRecordingId,
    required this.jobId,
    this.deviceFilename,
    this.contentHash,
    this.remoteRecordingId,
    this.remoteFact = RecordingTranscriptionRemoteFact.none,
    this.remoteProgress,
    this.noteId,
    this.transcriptCompletedAt,
    this.assetReadyAt,
    this.transcriptionNotRequired = false,
    this.localFileAvailable = true,
    this.formatSupported = true,
    this.retryable = false,
    this.errorCode,
  }) : assert(itemId != ''),
       assert(title != ''),
       assert(fileIdentity != ''),
       assert(localRecordingId != ''),
       assert(jobId != ''),
       assert(
         remoteProgress == null ||
             (remoteProgress >= 0 && remoteProgress <= 100),
       );

  final String itemId;
  final String title;
  final String fileIdentity;
  final String localRecordingId;
  final String jobId;
  final String? deviceFilename;
  final String? contentHash;
  final String? remoteRecordingId;
  final RecordingTranscriptionRemoteFact remoteFact;
  final int? remoteProgress;
  final String? noteId;
  final DateTime? transcriptCompletedAt;
  final DateTime? assetReadyAt;
  final bool transcriptionNotRequired;
  final bool localFileAvailable;
  final bool formatSupported;
  final bool retryable;
  final String? errorCode;
}

final class RecordingTranscriptionPreflight {
  const RecordingTranscriptionPreflight({
    required this.classification,
    required this.candidate,
    this.receipt,
  });

  final RecordingTranscriptionClassification classification;
  final RecordingTranscriptionCandidate candidate;
  final RecordingTranscriptionReceipt? receipt;
}

final class RecordingTranscriptionSelectionPreviewCounts {
  const RecordingTranscriptionSelectionPreviewCounts({
    required this.total,
    required this.eligible,
    required this.alreadyCompleted,
    required this.existingRemoteCompleted,
    required this.alreadyProcessing,
    required this.awaitingVerification,
    required this.retryExisting,
    required this.unavailable,
  }) : assert(
         total ==
             eligible +
                 alreadyCompleted +
                 existingRemoteCompleted +
                 alreadyProcessing +
                 awaitingVerification +
                 retryExisting +
                 unavailable,
       );

  factory RecordingTranscriptionSelectionPreviewCounts.fromItems(
    Iterable<RecordingTranscriptionPreflight> items,
  ) {
    var total = 0;
    var eligible = 0;
    var alreadyCompleted = 0;
    var existingRemoteCompleted = 0;
    var alreadyProcessing = 0;
    var awaitingVerification = 0;
    var retryExisting = 0;
    var unavailable = 0;
    for (final item in items) {
      total += 1;
      switch (item.classification) {
        case RecordingTranscriptionClassification.eligible:
          eligible += 1;
        case RecordingTranscriptionClassification.alreadyCompleted:
          alreadyCompleted += 1;
        case RecordingTranscriptionClassification.existingRemoteCompleted:
          existingRemoteCompleted += 1;
        case RecordingTranscriptionClassification.alreadyProcessing:
          alreadyProcessing += 1;
        case RecordingTranscriptionClassification.awaitingVerification:
          awaitingVerification += 1;
        case RecordingTranscriptionClassification.retryExisting:
          retryExisting += 1;
        case RecordingTranscriptionClassification.unavailable:
          unavailable += 1;
      }
    }
    return RecordingTranscriptionSelectionPreviewCounts(
      total: total,
      eligible: eligible,
      alreadyCompleted: alreadyCompleted,
      existingRemoteCompleted: existingRemoteCompleted,
      alreadyProcessing: alreadyProcessing,
      awaitingVerification: awaitingVerification,
      retryExisting: retryExisting,
      unavailable: unavailable,
    );
  }

  final int total;
  final int eligible;
  final int alreadyCompleted;
  final int existingRemoteCompleted;
  final int alreadyProcessing;
  final int awaitingVerification;
  final int retryExisting;
  final int unavailable;

  int get willSubmit => eligible;
  int get willObserve => alreadyProcessing + awaitingVerification;
  int get willSkip => alreadyCompleted + existingRemoteCompleted;
  int get needsAttention => retryExisting + unavailable;
}

final class RecordingTranscriptionSelectionPreview {
  RecordingTranscriptionSelectionPreview({
    required this.previewId,
    required this.accountScope,
    required this.workspaceScope,
    required this.createdAt,
    required List<RecordingTranscriptionCandidate> candidates,
    required List<RecordingTranscriptionPreflight> items,
  }) : assert(previewId != ''),
       assert(accountScope != ''),
       assert(workspaceScope != ''),
       assert(candidates.length == items.length),
       assert(
         List<bool>.generate(
           candidates.length,
           (index) => candidates[index].itemId == items[index].candidate.itemId,
         ).every((matches) => matches),
       ),
       candidates = List<RecordingTranscriptionCandidate>.unmodifiable(
         candidates,
       ),
       items = List<RecordingTranscriptionPreflight>.unmodifiable(items),
       counts = RecordingTranscriptionSelectionPreviewCounts.fromItems(items);

  final String previewId;
  final String accountScope;
  final String workspaceScope;
  final DateTime createdAt;
  final List<RecordingTranscriptionCandidate> candidates;
  final List<RecordingTranscriptionPreflight> items;
  final RecordingTranscriptionSelectionPreviewCounts counts;
}

final class RecordingBatchTranscriptionItem {
  const RecordingBatchTranscriptionItem({
    required this.itemId,
    required this.title,
    required this.fileIdentity,
    required this.localRecordingId,
    required this.jobId,
    required this.status,
    required this.outlineStatus,
    required this.retryable,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.deviceFilename,
    this.contentHash,
    this.remoteRecordingId,
    this.noteId,
    this.phase,
    this.progress,
    this.errorCode,
    this.outlineErrorCode,
    this.outlineTaskId,
    this.supersededOutlineTaskId,
    this.failureCategory,
    this.waitingReason,
    this.observationStartedAt,
    this.lastAuthoritativeProgressAt,
    this.observationDeadlineAt,
    this.transcriptCompletedAt,
    this.assetReadyAt,
  }) : assert(itemId != ''),
       assert(title != ''),
       assert(fileIdentity != ''),
       assert(localRecordingId != ''),
       assert(jobId != ''),
       assert(attemptCount >= 0),
       assert(progress == null || (progress >= 0 && progress <= 100));

  final String itemId;
  final String title;
  final String fileIdentity;
  final String localRecordingId;
  final String jobId;
  final String? deviceFilename;
  final String? contentHash;
  final String? remoteRecordingId;
  final String? noteId;
  final RecordingBatchTranscriptionItemStatus status;
  final RecordingBatchTranscriptionPhase? phase;
  final RecordingBatchOutlineStatus outlineStatus;
  final int? progress;
  final bool retryable;
  final int attemptCount;
  final String? errorCode;
  final String? outlineErrorCode;
  final String? outlineTaskId;
  final String? supersededOutlineTaskId;
  final RecordingBatchFailureCategory? failureCategory;
  final RecordingBatchWaitingReason? waitingReason;
  final DateTime? observationStartedAt;
  final DateTime? lastAuthoritativeProgressAt;
  final DateTime? observationDeadlineAt;
  final DateTime? transcriptCompletedAt;
  final DateTime? assetReadyAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isUnavailable =>
      status == RecordingBatchTranscriptionItemStatus.failed &&
      failureCategory == RecordingBatchFailureCategory.unavailable;

  bool get hasAccessibleAsset =>
      noteId?.trim().isNotEmpty == true && assetReadyAt != null;

  RecordingBatchTranscriptionItem copyWith({
    String? remoteRecordingId,
    bool clearRemoteRecordingId = false,
    String? noteId,
    bool clearNoteId = false,
    RecordingBatchTranscriptionItemStatus? status,
    RecordingBatchTranscriptionPhase? phase,
    bool clearPhase = false,
    RecordingBatchOutlineStatus? outlineStatus,
    int? progress,
    bool clearProgress = false,
    bool? retryable,
    int? attemptCount,
    String? errorCode,
    bool clearError = false,
    String? outlineErrorCode,
    bool clearOutlineError = false,
    String? outlineTaskId,
    bool clearOutlineTaskId = false,
    String? supersededOutlineTaskId,
    bool clearSupersededOutlineTaskId = false,
    RecordingBatchFailureCategory? failureCategory,
    bool clearFailureCategory = false,
    RecordingBatchWaitingReason? waitingReason,
    bool clearWaitingReason = false,
    DateTime? observationStartedAt,
    bool clearObservationStartedAt = false,
    DateTime? lastAuthoritativeProgressAt,
    bool clearLastAuthoritativeProgressAt = false,
    DateTime? observationDeadlineAt,
    bool clearObservationDeadlineAt = false,
    DateTime? transcriptCompletedAt,
    bool clearTranscriptCompletedAt = false,
    DateTime? assetReadyAt,
    bool clearAssetReadyAt = false,
    DateTime? updatedAt,
  }) {
    return RecordingBatchTranscriptionItem(
      itemId: itemId,
      title: title,
      fileIdentity: fileIdentity,
      localRecordingId: localRecordingId,
      jobId: jobId,
      deviceFilename: deviceFilename,
      contentHash: contentHash,
      remoteRecordingId: clearRemoteRecordingId
          ? null
          : remoteRecordingId ?? this.remoteRecordingId,
      noteId: clearNoteId ? null : noteId ?? this.noteId,
      status: status ?? this.status,
      phase: clearPhase ? null : phase ?? this.phase,
      outlineStatus: outlineStatus ?? this.outlineStatus,
      progress: clearProgress ? null : progress ?? this.progress,
      retryable: retryable ?? this.retryable,
      attemptCount: attemptCount ?? this.attemptCount,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
      outlineErrorCode: clearOutlineError
          ? null
          : outlineErrorCode ?? this.outlineErrorCode,
      outlineTaskId: clearOutlineTaskId
          ? null
          : outlineTaskId ?? this.outlineTaskId,
      supersededOutlineTaskId: clearSupersededOutlineTaskId
          ? null
          : supersededOutlineTaskId ?? this.supersededOutlineTaskId,
      failureCategory: clearFailureCategory
          ? null
          : failureCategory ?? this.failureCategory,
      waitingReason: clearWaitingReason
          ? null
          : waitingReason ?? this.waitingReason,
      observationStartedAt: clearObservationStartedAt
          ? null
          : observationStartedAt ?? this.observationStartedAt,
      lastAuthoritativeProgressAt: clearLastAuthoritativeProgressAt
          ? null
          : lastAuthoritativeProgressAt ?? this.lastAuthoritativeProgressAt,
      observationDeadlineAt: clearObservationDeadlineAt
          ? null
          : observationDeadlineAt ?? this.observationDeadlineAt,
      transcriptCompletedAt: clearTranscriptCompletedAt
          ? null
          : transcriptCompletedAt ?? this.transcriptCompletedAt,
      assetReadyAt: clearAssetReadyAt
          ? null
          : assetReadyAt ?? this.assetReadyAt,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

final class RecordingBatchTranscriptionCounts {
  const RecordingBatchTranscriptionCounts({
    required this.total,
    required this.active,
    required this.completed,
    required this.skipped,
    required this.retryableFailed,
    required this.timedOut,
    required this.unavailable,
    required this.otherFailed,
  });

  final int total;
  final int active;
  final int completed;
  final int skipped;
  final int retryableFailed;
  final int timedOut;
  final int unavailable;
  final int otherFailed;

  int get failed => retryableFailed + unavailable + otherFailed;
  int get settled => completed + skipped + failed + timedOut;
}

final class RecordingBatchTranscriptionSnapshot {
  RecordingBatchTranscriptionSnapshot({
    required this.batchId,
    required this.accountScope,
    required this.workspaceScope,
    required this.primaryItemId,
    required List<RecordingBatchTranscriptionItem> items,
    required this.createdAt,
    required this.updatedAt,
  }) : assert(batchId != ''),
       assert(accountScope != ''),
       assert(workspaceScope != ''),
       assert(items.length >= 2),
       assert(items.any((item) => item.itemId == primaryItemId)),
       items = List<RecordingBatchTranscriptionItem>.unmodifiable(items);

  final String batchId;
  final String accountScope;
  final String workspaceScope;
  final String primaryItemId;
  final List<RecordingBatchTranscriptionItem> items;
  final DateTime createdAt;
  final DateTime updatedAt;

  RecordingBatchTranscriptionStatus get status {
    if (items.any((item) => item.status.isActive)) {
      return RecordingBatchTranscriptionStatus.active;
    }
    if (items.any(
      (item) =>
          item.status == RecordingBatchTranscriptionItemStatus.failed ||
          item.status == RecordingBatchTranscriptionItemStatus.timedOut,
    )) {
      return RecordingBatchTranscriptionStatus.completedWithIssues;
    }
    return RecordingBatchTranscriptionStatus.completed;
  }

  RecordingBatchTranscriptionItem? get primaryItem {
    for (final item in items) {
      if (item.itemId == primaryItemId) return item;
    }
    return null;
  }

  RecordingBatchTranscriptionItem? itemFor(String itemId) {
    for (final item in items) {
      if (item.itemId == itemId) return item;
    }
    return null;
  }

  RecordingBatchTranscriptionCounts get counts {
    var active = 0;
    var completed = 0;
    var skipped = 0;
    var retryableFailed = 0;
    var timedOut = 0;
    var unavailable = 0;
    var otherFailed = 0;
    for (final item in items) {
      switch (item.status) {
        case RecordingBatchTranscriptionItemStatus.pending:
        case RecordingBatchTranscriptionItemStatus.submitting:
        case RecordingBatchTranscriptionItemStatus.processing:
          active += 1;
        case RecordingBatchTranscriptionItemStatus.completed:
          completed += 1;
        case RecordingBatchTranscriptionItemStatus.skipped:
          skipped += 1;
        case RecordingBatchTranscriptionItemStatus.timedOut:
          timedOut += 1;
        case RecordingBatchTranscriptionItemStatus.failed:
          if (item.isUnavailable) {
            unavailable += 1;
          } else if (item.retryable) {
            retryableFailed += 1;
          } else {
            otherFailed += 1;
          }
      }
    }
    return RecordingBatchTranscriptionCounts(
      total: items.length,
      active: active,
      completed: completed,
      skipped: skipped,
      retryableFailed: retryableFailed,
      timedOut: timedOut,
      unavailable: unavailable,
      otherFailed: otherFailed,
    );
  }

  RecordingBatchTranscriptionSnapshot replaceItem(
    RecordingBatchTranscriptionItem replacement,
  ) {
    if (!items.any((item) => item.itemId == replacement.itemId)) {
      throw ArgumentError.value(replacement.itemId, 'replacement.itemId');
    }
    return RecordingBatchTranscriptionSnapshot(
      batchId: batchId,
      accountScope: accountScope,
      workspaceScope: workspaceScope,
      primaryItemId: primaryItemId,
      items: <RecordingBatchTranscriptionItem>[
        for (final item in items)
          if (item.itemId == replacement.itemId) replacement else item,
      ],
      createdAt: createdAt,
      updatedAt: replacement.updatedAt,
    );
  }
}

abstract interface class RecordingBatchTranscriptionStorePort {
  List<RecordingBatchTranscriptionSnapshot> loadBatches();

  void saveBatch(RecordingBatchTranscriptionSnapshot batch);

  void deleteBatch(String batchId);

  Future<bool> flush();
}

final class RecordingTranscriptionDispatch {
  const RecordingTranscriptionDispatch._({
    required this.kind,
    this.single,
    this.batch,
  });

  const RecordingTranscriptionDispatch.disabled()
    : this._(kind: RecordingTranscriptionDispatchKind.disabled);

  const RecordingTranscriptionDispatch.single(
    RecordingTranscriptionPreflight preflight,
  ) : this._(
        kind: RecordingTranscriptionDispatchKind.single,
        single: preflight,
      );

  const RecordingTranscriptionDispatch.batch(
    RecordingBatchTranscriptionSnapshot snapshot,
  ) : this._(kind: RecordingTranscriptionDispatchKind.batch, batch: snapshot);

  final RecordingTranscriptionDispatchKind kind;
  final RecordingTranscriptionPreflight? single;
  final RecordingBatchTranscriptionSnapshot? batch;
}
