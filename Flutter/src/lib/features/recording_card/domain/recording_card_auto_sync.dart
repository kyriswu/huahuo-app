import 'recording_card_sync_ledger.dart';

enum RecordingCardAutoSyncTaskState {
  queued,
  waitingForDevice,
  waitingForRecording,
  waitingForTransfer,
  downloading,
  downloaded,
  transcribing,
  completed,
  failed,
}

enum RecordingCardAutoSyncStatus {
  idle,
  waitingForRetry,
  waitingForDevice,
  waitingForRecording,
  waitingForTransfer,
  scanning,
  downloading,
  verifying,
  committing,
  pausing,
  paused,
  transcribing,
  completed,
  failed,
}

final class RecordingCardAutoSyncPreferences {
  const RecordingCardAutoSyncPreferences({
    this.autoSyncEnabled = true,
    this.autoTranscriptionEnabled = false,
  });

  final bool autoSyncEnabled;
  final bool autoTranscriptionEnabled;

  RecordingCardAutoSyncPreferences copyWith({
    bool? autoSyncEnabled,
    bool? autoTranscriptionEnabled,
  }) => RecordingCardAutoSyncPreferences(
    autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
    autoTranscriptionEnabled:
        autoTranscriptionEnabled ?? this.autoTranscriptionEnabled,
  );
}

final class RecordingCardAutoSyncTask {
  const RecordingCardAutoSyncTask({
    required this.taskId,
    required this.deviceFingerprint,
    required this.deviceFileId,
    required this.deviceFilename,
    required this.localFileKey,
    required this.order,
    required this.state,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.expectedSizeBytes,
    this.cardSnDigest,
    this.sourceSignature,
    this.recordedAt,
    this.contentHash,
    this.localRecordingId,
    this.transcriptionRequested = false,
    this.errorCode,
    this.retryability,
    this.nextRetryAt,
  });

  final String taskId;
  final String deviceFingerprint;
  final String deviceFileId;
  final String deviceFilename;
  final String localFileKey;
  final int order;
  final RecordingCardAutoSyncTaskState state;
  final int attemptCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int? expectedSizeBytes;
  final String? cardSnDigest;
  final String? sourceSignature;
  final DateTime? recordedAt;
  final String? contentHash;
  final String? localRecordingId;
  final bool transcriptionRequested;
  final String? errorCode;
  final RecordingCardSyncRetryability? retryability;
  final DateTime? nextRetryAt;

  bool get isTerminal => state == RecordingCardAutoSyncTaskState.completed;
  bool get hasSynchronizedFile =>
      isTerminal || (localRecordingId?.trim().isNotEmpty ?? false);

  RecordingCardAutoSyncTask copyWith({
    RecordingCardAutoSyncTaskState? state,
    int? attemptCount,
    DateTime? updatedAt,
    String? cardSnDigest,
    String? sourceSignature,
    DateTime? recordedAt,
    String? contentHash,
    String? localRecordingId,
    bool? transcriptionRequested,
    String? errorCode,
    RecordingCardSyncRetryability? retryability,
    DateTime? nextRetryAt,
    bool clearError = false,
    bool clearRetryability = false,
    bool clearNextRetryAt = false,
  }) => RecordingCardAutoSyncTask(
    taskId: taskId,
    deviceFingerprint: deviceFingerprint,
    deviceFileId: deviceFileId,
    deviceFilename: deviceFilename,
    localFileKey: localFileKey,
    order: order,
    state: state ?? this.state,
    attemptCount: attemptCount ?? this.attemptCount,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    localRecordingId: localRecordingId ?? this.localRecordingId,
    expectedSizeBytes: expectedSizeBytes,
    cardSnDigest: cardSnDigest ?? this.cardSnDigest,
    sourceSignature: sourceSignature ?? this.sourceSignature,
    recordedAt: recordedAt ?? this.recordedAt,
    contentHash: contentHash ?? this.contentHash,
    transcriptionRequested:
        transcriptionRequested ?? this.transcriptionRequested,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    retryability: clearRetryability ? null : retryability ?? this.retryability,
    nextRetryAt: clearNextRetryAt ? null : nextRetryAt ?? this.nextRetryAt,
  );
}

final class RecordingCardAutoSyncState {
  const RecordingCardAutoSyncState({
    required this.status,
    required this.preferences,
    this.tasks = const <RecordingCardAutoSyncTask>[],
    this.activeTaskId,
    this.lastErrorCode,
    this.waitingReason,
  });

  factory RecordingCardAutoSyncState.initial() =>
      const RecordingCardAutoSyncState(
        status: RecordingCardAutoSyncStatus.idle,
        preferences: RecordingCardAutoSyncPreferences(),
      );

  final RecordingCardAutoSyncStatus status;
  final RecordingCardAutoSyncPreferences preferences;
  final List<RecordingCardAutoSyncTask> tasks;
  final String? activeTaskId;
  final String? lastErrorCode;
  final RecordingCardSyncWaitingReason? waitingReason;

  int get completedCount => tasks
      .where((task) => task.state == RecordingCardAutoSyncTaskState.completed)
      .length;

  int get pendingCount => tasks.length - completedCount;

  int get fileSyncCompletedCount =>
      tasks.where((task) => task.hasSynchronizedFile).length;

  int get pendingFileSyncCount => tasks.length - fileSyncCompletedCount;

  RecordingCardAutoSyncState copyWith({
    RecordingCardAutoSyncStatus? status,
    RecordingCardAutoSyncPreferences? preferences,
    List<RecordingCardAutoSyncTask>? tasks,
    String? activeTaskId,
    String? lastErrorCode,
    RecordingCardSyncWaitingReason? waitingReason,
    bool clearActiveTask = false,
    bool clearError = false,
    bool clearWaitingReason = false,
  }) => RecordingCardAutoSyncState(
    status: status ?? this.status,
    preferences: preferences ?? this.preferences,
    tasks: tasks ?? this.tasks,
    activeTaskId: clearActiveTask ? null : activeTaskId ?? this.activeTaskId,
    lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
    waitingReason: clearWaitingReason
        ? null
        : waitingReason ?? this.waitingReason,
  );
}
