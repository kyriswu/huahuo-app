import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'recording_card_account_binding.dart';

enum RecordingCardFileLocalState {
  neverSynced,
  legacyUnknown,
  queued,
  syncing,
  synced,
  deleting,
  localDeleted,
  failed,
}

enum RecordingCardFilePresenceState { present, deleted, unknown }

enum RecordingCardSyncRetryability { transient, permanent }

enum RecordingCardSyncOrigin { automatic, user }

enum RecordingCardSyncMigrationMode { newDevice, legacyData, normal }

enum RecordingCardSyncSessionStatus {
  idle,
  disabled,
  pausing,
  waiting,
  scanning,
  planning,
  transferring,
  verifying,
  committing,
  completed,
  paused,
  failed,
}

enum RecordingCardSyncWaitingReason {
  deviceDisconnected,
  deviceRecording,
  otherTransferActive,
  permissionRequired,
  networkRequired,
  storageInsufficient,
  accountScopeChanged,
  cardIdentityChanged,
  appBackground,
  persistenceRequired,
  retryBackoff,
}

enum RecordingCardSyncTrigger {
  deviceConnected,
  recordingBecameIdle,
  conflictingTransferEnded,
  autoSyncEnabled,
  appResumed,
  directoryRefreshed,
  networkRestored,
  permissionRestored,
  storageRestored,
  persistenceRestored,
  explicitRetry,
  explicitContinue,
  transientRetryReady,
}

enum RecordingCardSyncCandidateReason {
  interrupted,
  transientRetry,
  neverSynced,
  newlyDiscovered,
  manual,
}

final class RecordingCardFileIdentity {
  const RecordingCardFileIdentity({
    required this.cardSnDigest,
    required this.sourceSignature,
  });

  final String cardSnDigest;
  final String sourceSignature;

  static String? digestSerialNumber(String serialNumber) {
    final normalized = normalizeRecordingCardSerialNumberForOwnership(
      serialNumber,
    );
    if (normalized == null) return null;
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  static String sourceSignatureFor({
    required String cardSnDigest,
    required String deviceFileId,
    required String deviceFilename,
    int? sizeBytes,
    DateTime? recordedAt,
  }) {
    final digest = cardSnDigest.trim().toLowerCase();
    final fileId = deviceFileId.trim();
    final filename = deviceFilename.trim();
    if (!_isSha256(digest)) {
      throw ArgumentError.value(cardSnDigest, 'cardSnDigest');
    }
    if (fileId.isEmpty) throw ArgumentError.value(deviceFileId, 'deviceFileId');
    if (filename.isEmpty) {
      throw ArgumentError.value(deviceFilename, 'deviceFilename');
    }
    final payload = jsonEncode(<String, Object?>{
      'cardSnDigest': digest,
      'deviceFileId': fileId,
      'deviceFilename': filename,
      'sizeBytes': sizeBytes,
      'recordedAt': recordedAt?.toUtc().toIso8601String(),
    });
    return sha256.convert(utf8.encode(payload)).toString();
  }

  static String snapshotHash(Iterable<String> sourceSignatures) {
    final sorted = sourceSignatures.map((value) => value.trim()).toList()
      ..sort();
    return sha256.convert(utf8.encode(sorted.join('\n'))).toString();
  }
}

final class RecordingCardFileLedgerEntry {
  const RecordingCardFileLedgerEntry({
    required this.cardSnDigest,
    required this.sourceSignature,
    required this.deviceFileId,
    required this.deviceFilename,
    required this.localState,
    required this.cardState,
    required this.attemptCount,
    required this.lastSeenAt,
    required this.updatedAt,
    this.recordedAt,
    this.sizeBytes,
    this.durationSeconds,
    this.contentHash,
    this.localRecordingId,
    this.lastSyncedAt,
    this.localDeletedAt,
    this.errorCode,
    this.retryability,
    this.nextRetryAt,
    this.plannedNativeFileId,
    this.syncOrigin,
    this.resumeRequested = false,
  });

  factory RecordingCardFileLedgerEntry.discovered({
    required String cardSnDigest,
    required String sourceSignature,
    required String deviceFileId,
    required String deviceFilename,
    required DateTime seenAt,
    DateTime? recordedAt,
    int? sizeBytes,
    int? durationSeconds,
  }) => RecordingCardFileLedgerEntry(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    deviceFileId: deviceFileId,
    deviceFilename: deviceFilename,
    recordedAt: recordedAt?.toUtc(),
    sizeBytes: sizeBytes,
    durationSeconds: durationSeconds,
    localState: RecordingCardFileLocalState.neverSynced,
    cardState: RecordingCardFilePresenceState.present,
    attemptCount: 0,
    lastSeenAt: seenAt.toUtc(),
    updatedAt: seenAt.toUtc(),
  );

  factory RecordingCardFileLedgerEntry.legacyUnknown({
    required String cardSnDigest,
    required String sourceSignature,
    required String deviceFileId,
    required String deviceFilename,
    required DateTime seenAt,
    DateTime? recordedAt,
    int? sizeBytes,
    int? durationSeconds,
  }) => RecordingCardFileLedgerEntry(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    deviceFileId: deviceFileId,
    deviceFilename: deviceFilename,
    recordedAt: recordedAt?.toUtc(),
    sizeBytes: sizeBytes,
    durationSeconds: durationSeconds,
    localState: RecordingCardFileLocalState.legacyUnknown,
    cardState: RecordingCardFilePresenceState.present,
    attemptCount: 0,
    lastSeenAt: seenAt.toUtc(),
    updatedAt: seenAt.toUtc(),
  );

  final String cardSnDigest;
  final String sourceSignature;
  final String deviceFileId;
  final String deviceFilename;
  final DateTime? recordedAt;
  final int? sizeBytes;
  final int? durationSeconds;
  final String? contentHash;
  final String? localRecordingId;
  final RecordingCardFileLocalState localState;
  final RecordingCardFilePresenceState cardState;
  final DateTime? lastSyncedAt;
  final DateTime? localDeletedAt;
  final DateTime lastSeenAt;
  final String? errorCode;
  final RecordingCardSyncRetryability? retryability;
  final int attemptCount;
  final DateTime? nextRetryAt;
  final String? plannedNativeFileId;
  final RecordingCardSyncOrigin? syncOrigin;
  final bool resumeRequested;
  final DateTime updatedAt;

  bool get blocksAutomaticSync {
    if (!resumeRequested && syncOrigin == RecordingCardSyncOrigin.user) {
      return true;
    }
    return switch (localState) {
      RecordingCardFileLocalState.synced ||
      RecordingCardFileLocalState.localDeleted ||
      RecordingCardFileLocalState.legacyUnknown => true,
      RecordingCardFileLocalState.failed =>
        retryability == RecordingCardSyncRetryability.permanent,
      _ => false,
    };
  }

  bool get hasValidLocalRecording =>
      localState == RecordingCardFileLocalState.synced &&
      (localRecordingId?.trim().isNotEmpty ?? false);

  RecordingCardFileLedgerEntry seen({
    required DateTime at,
    required String deviceFileId,
    required String deviceFilename,
    DateTime? recordedAt,
    int? sizeBytes,
    int? durationSeconds,
  }) => _replace(
    deviceFileId: deviceFileId,
    deviceFilename: deviceFilename,
    recordedAt: recordedAt?.toUtc(),
    sizeBytes: sizeBytes,
    durationSeconds: durationSeconds,
    cardState: cardState == RecordingCardFilePresenceState.deleted
        ? RecordingCardFilePresenceState.deleted
        : RecordingCardFilePresenceState.present,
    lastSeenAt: at.toUtc(),
    updatedAt: at.toUtc(),
  );

  RecordingCardFileLedgerEntry queue({
    required DateTime at,
    required bool manual,
    bool resetAttemptCount = false,
  }) {
    final allowed = switch (localState) {
      RecordingCardFileLocalState.neverSynced ||
      RecordingCardFileLocalState.queued ||
      RecordingCardFileLocalState.syncing => true,
      RecordingCardFileLocalState.legacyUnknown ||
      RecordingCardFileLocalState.localDeleted ||
      RecordingCardFileLocalState.synced => manual,
      RecordingCardFileLocalState.failed =>
        manual || retryability == RecordingCardSyncRetryability.transient,
      RecordingCardFileLocalState.deleting => false,
    };
    if (!allowed) {
      throw StateError('Illegal local-state transition: $localState -> queued');
    }
    return _replace(
      localState: RecordingCardFileLocalState.queued,
      syncOrigin: manual
          ? RecordingCardSyncOrigin.user
          : RecordingCardSyncOrigin.automatic,
      resumeRequested: true,
      attemptCount: resetAttemptCount ? 0 : attemptCount,
      updatedAt: at.toUtc(),
      clearError: true,
      clearRetryability: true,
      clearNextRetryAt: true,
      clearLocalDeletedAt: manual,
    );
  }

  RecordingCardFileLedgerEntry beginSync(DateTime at) {
    if (localState != RecordingCardFileLocalState.queued) {
      throw StateError(
        'Illegal local-state transition: $localState -> syncing',
      );
    }
    return _replace(
      localState: RecordingCardFileLocalState.syncing,
      syncOrigin: syncOrigin ?? RecordingCardSyncOrigin.automatic,
      resumeRequested: true,
      attemptCount: attemptCount + 1,
      updatedAt: at.toUtc(),
      clearError: true,
      clearRetryability: true,
      clearNextRetryAt: true,
    );
  }

  RecordingCardFileLedgerEntry planBluetoothDownload({
    required DateTime at,
    required String plannedNativeFileId,
    required RecordingCardSyncOrigin syncOrigin,
    bool resumeRequested = true,
  }) {
    if (localState != RecordingCardFileLocalState.queued &&
        localState != RecordingCardFileLocalState.syncing) {
      throw StateError(
        'Bluetooth download can only be planned for queued/syncing entries',
      );
    }
    final normalized = plannedNativeFileId.trim().toLowerCase();
    if (!RegExp(r'^card-[a-f0-9]{32}$').hasMatch(normalized)) {
      throw ArgumentError.value(plannedNativeFileId, 'plannedNativeFileId');
    }
    return _replace(
      plannedNativeFileId: normalized,
      syncOrigin: syncOrigin,
      resumeRequested: resumeRequested,
      updatedAt: at.toUtc(),
    );
  }

  RecordingCardFileLedgerEntry clearBluetoothResumeRequest(DateTime at) =>
      _replace(resumeRequested: false, updatedAt: at.toUtc());

  RecordingCardFileLedgerEntry markSynced({
    required DateTime at,
    required String localRecordingId,
    String? contentHash,
    bool clearContentHashWhenMissing = false,
  }) {
    if (localState != RecordingCardFileLocalState.syncing &&
        localState != RecordingCardFileLocalState.queued) {
      throw StateError('Illegal local-state transition: $localState -> synced');
    }
    if (localRecordingId.trim().isEmpty) {
      throw ArgumentError.value(localRecordingId, 'localRecordingId');
    }
    return _replace(
      localState: RecordingCardFileLocalState.synced,
      localRecordingId: localRecordingId.trim(),
      contentHash: contentHash?.trim(),
      clearContentHash:
          clearContentHashWhenMissing &&
          (contentHash == null || contentHash.trim().isEmpty),
      lastSyncedAt: at.toUtc(),
      attemptCount: 0,
      updatedAt: at.toUtc(),
      clearError: true,
      clearRetryability: true,
      clearNextRetryAt: true,
      clearLocalDeletedAt: true,
      clearPlannedNativeFileId: true,
      resumeRequested: false,
    );
  }

  RecordingCardFileLedgerEntry markFailed({
    required DateTime at,
    required String errorCode,
    required RecordingCardSyncRetryability retryability,
    DateTime? nextRetryAt,
  }) {
    if (localState != RecordingCardFileLocalState.syncing &&
        localState != RecordingCardFileLocalState.queued) {
      throw StateError('Illegal local-state transition: $localState -> failed');
    }
    if (errorCode.trim().isEmpty) {
      throw ArgumentError.value(errorCode, 'errorCode');
    }
    return _replace(
      localState: RecordingCardFileLocalState.failed,
      errorCode: errorCode.trim(),
      retryability: retryability,
      nextRetryAt: retryability == RecordingCardSyncRetryability.transient
          ? nextRetryAt?.toUtc()
          : null,
      updatedAt: at.toUtc(),
      clearNextRetryAt:
          retryability == RecordingCardSyncRetryability.permanent ||
          nextRetryAt == null,
    );
  }

  RecordingCardFileLedgerEntry recoverInterrupted(DateTime at) {
    if (localState != RecordingCardFileLocalState.syncing) return this;
    return _replace(
      localState: RecordingCardFileLocalState.queued,
      updatedAt: at.toUtc(),
      clearError: true,
      clearRetryability: true,
      clearNextRetryAt: true,
    );
  }

  RecordingCardFileLedgerEntry requeueAfterLocalVerificationFailure(
    DateTime at,
  ) {
    if (localState != RecordingCardFileLocalState.synced) {
      throw StateError('Illegal local-state transition: $localState -> queued');
    }
    return _replace(
      localState: RecordingCardFileLocalState.queued,
      attemptCount: 0,
      updatedAt: at.toUtc(),
      clearLocalRecordingId: true,
      clearError: true,
      clearRetryability: true,
      clearNextRetryAt: true,
    );
  }

  RecordingCardFileLedgerEntry backfillVerifiedContentHash({
    required DateTime at,
    required String contentHash,
  }) {
    if (localState != RecordingCardFileLocalState.synced) {
      throw StateError('Content hash can only be backfilled after sync');
    }
    final normalizedHash = contentHash.trim().toLowerCase();
    if (normalizedHash.isEmpty) {
      throw ArgumentError.value(contentHash, 'contentHash');
    }
    final currentHash = this.contentHash?.trim().toLowerCase();
    if (currentHash != null &&
        currentHash.isNotEmpty &&
        currentHash != normalizedHash) {
      throw StateError('Conflicting verified content hash');
    }
    if (currentHash == normalizedHash) return this;
    return _replace(contentHash: normalizedHash, updatedAt: at.toUtc());
  }

  RecordingCardFileLedgerEntry deferForPrerequisite(DateTime at) {
    if (localState != RecordingCardFileLocalState.syncing) {
      throw StateError('Illegal local-state transition: $localState -> queued');
    }
    return _replace(
      localState: RecordingCardFileLocalState.queued,
      attemptCount: attemptCount > 0 ? attemptCount - 1 : 0,
      updatedAt: at.toUtc(),
      clearError: true,
      clearRetryability: true,
      clearNextRetryAt: true,
    );
  }

  RecordingCardFileLedgerEntry beginLocalDeletion(DateTime at) {
    if (localState != RecordingCardFileLocalState.synced) {
      throw StateError(
        'Illegal local-state transition: $localState -> deleting',
      );
    }
    return _replace(
      localState: RecordingCardFileLocalState.deleting,
      updatedAt: at.toUtc(),
    );
  }

  RecordingCardFileLedgerEntry finishLocalDeletion(DateTime at) {
    if (localState != RecordingCardFileLocalState.deleting) {
      throw StateError(
        'Illegal local-state transition: $localState -> localDeleted',
      );
    }
    return _replace(
      localState: RecordingCardFileLocalState.localDeleted,
      localDeletedAt: at.toUtc(),
      updatedAt: at.toUtc(),
      clearLocalRecordingId: true,
    );
  }

  RecordingCardFileLedgerEntry restoreLocalDeletion(DateTime at) {
    if (localState != RecordingCardFileLocalState.deleting) {
      throw StateError('Illegal local-state transition: $localState -> synced');
    }
    return _replace(
      localState: RecordingCardFileLocalState.synced,
      updatedAt: at.toUtc(),
    );
  }

  RecordingCardFileLedgerEntry recoverDeleting({
    required DateTime at,
    required bool localFileExists,
  }) => localFileExists ? restoreLocalDeletion(at) : finishLocalDeletion(at);

  RecordingCardFileLedgerEntry markCardDeleted(DateTime at) => _replace(
    cardState: RecordingCardFilePresenceState.deleted,
    updatedAt: at.toUtc(),
  );

  RecordingCardFileLedgerEntry confirmCardPresent(DateTime at) => _replace(
    cardState: RecordingCardFilePresenceState.present,
    lastSeenAt: at.toUtc(),
    updatedAt: at.toUtc(),
  );

  RecordingCardFileLedgerEntry markCardUnknown(DateTime at) => _replace(
    cardState: RecordingCardFilePresenceState.unknown,
    updatedAt: at.toUtc(),
  );

  RecordingCardFileLedgerEntry _replace({
    String? deviceFileId,
    String? deviceFilename,
    DateTime? recordedAt,
    int? sizeBytes,
    int? durationSeconds,
    String? contentHash,
    String? localRecordingId,
    RecordingCardFileLocalState? localState,
    RecordingCardFilePresenceState? cardState,
    DateTime? lastSyncedAt,
    DateTime? localDeletedAt,
    DateTime? lastSeenAt,
    String? errorCode,
    RecordingCardSyncRetryability? retryability,
    int? attemptCount,
    DateTime? nextRetryAt,
    String? plannedNativeFileId,
    RecordingCardSyncOrigin? syncOrigin,
    bool? resumeRequested,
    DateTime? updatedAt,
    bool clearLocalRecordingId = false,
    bool clearContentHash = false,
    bool clearLocalDeletedAt = false,
    bool clearError = false,
    bool clearRetryability = false,
    bool clearNextRetryAt = false,
    bool clearPlannedNativeFileId = false,
  }) => RecordingCardFileLedgerEntry(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    deviceFileId: deviceFileId ?? this.deviceFileId,
    deviceFilename: deviceFilename ?? this.deviceFilename,
    recordedAt: recordedAt ?? this.recordedAt,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    contentHash: clearContentHash ? null : contentHash ?? this.contentHash,
    localRecordingId: clearLocalRecordingId
        ? null
        : localRecordingId ?? this.localRecordingId,
    localState: localState ?? this.localState,
    cardState: cardState ?? this.cardState,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    localDeletedAt: clearLocalDeletedAt
        ? null
        : localDeletedAt ?? this.localDeletedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    retryability: clearRetryability ? null : retryability ?? this.retryability,
    attemptCount: attemptCount ?? this.attemptCount,
    nextRetryAt: clearNextRetryAt ? null : nextRetryAt ?? this.nextRetryAt,
    plannedNativeFileId: clearPlannedNativeFileId
        ? null
        : plannedNativeFileId ?? this.plannedNativeFileId,
    syncOrigin: syncOrigin ?? this.syncOrigin,
    resumeRequested: resumeRequested ?? this.resumeRequested,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

final class RecordingCardSyncCheckpoint {
  const RecordingCardSyncCheckpoint({
    required this.cardSnDigest,
    required this.migrationMode,
    required this.updatedAt,
    this.lastSuccessfulAutoSyncAt,
    this.lastTransferCompletedAt,
    this.lastDirectoryReadAt,
    this.committedThroughRecordedAt,
    this.committedSnapshotHash,
  });

  factory RecordingCardSyncCheckpoint.empty({
    required String cardSnDigest,
    required DateTime at,
    RecordingCardSyncMigrationMode migrationMode =
        RecordingCardSyncMigrationMode.newDevice,
  }) => RecordingCardSyncCheckpoint(
    cardSnDigest: cardSnDigest,
    migrationMode: migrationMode,
    updatedAt: at.toUtc(),
  );

  final String cardSnDigest;
  final DateTime? lastSuccessfulAutoSyncAt;
  final DateTime? lastTransferCompletedAt;
  final DateTime? lastDirectoryReadAt;
  final DateTime? committedThroughRecordedAt;
  final String? committedSnapshotHash;
  final RecordingCardSyncMigrationMode migrationMode;
  final DateTime updatedAt;

  RecordingCardSyncCheckpoint noteDirectoryRead(DateTime at) =>
      RecordingCardSyncCheckpoint(
        cardSnDigest: cardSnDigest,
        lastSuccessfulAutoSyncAt: lastSuccessfulAutoSyncAt,
        lastTransferCompletedAt: lastTransferCompletedAt,
        lastDirectoryReadAt: at.toUtc(),
        committedThroughRecordedAt: committedThroughRecordedAt,
        committedSnapshotHash: committedSnapshotHash,
        migrationMode: migrationMode,
        updatedAt: at.toUtc(),
      );

  RecordingCardSyncCheckpoint noteManualTransfer(DateTime at) =>
      RecordingCardSyncCheckpoint(
        cardSnDigest: cardSnDigest,
        lastSuccessfulAutoSyncAt: lastSuccessfulAutoSyncAt,
        lastTransferCompletedAt: at.toUtc(),
        lastDirectoryReadAt: lastDirectoryReadAt,
        committedThroughRecordedAt: committedThroughRecordedAt,
        committedSnapshotHash: committedSnapshotHash,
        migrationMode: migrationMode,
        updatedAt: at.toUtc(),
      );

  RecordingCardSyncCheckpoint commitAutomaticSync({
    required DateTime at,
    required String snapshotHash,
    required DateTime? committedThroughRecordedAt,
    required bool transferredFiles,
  }) => RecordingCardSyncCheckpoint(
    cardSnDigest: cardSnDigest,
    lastSuccessfulAutoSyncAt: at.toUtc(),
    lastTransferCompletedAt: transferredFiles
        ? at.toUtc()
        : lastTransferCompletedAt,
    lastDirectoryReadAt: at.toUtc(),
    committedThroughRecordedAt: committedThroughRecordedAt?.toUtc(),
    committedSnapshotHash: snapshotHash,
    migrationMode: RecordingCardSyncMigrationMode.normal,
    updatedAt: at.toUtc(),
  );
}

final class RecordingCardSyncCandidate {
  const RecordingCardSyncCandidate({required this.entry, required this.reason});

  final RecordingCardFileLedgerEntry entry;
  final RecordingCardSyncCandidateReason reason;
}

final class RecordingCardSyncPlan {
  const RecordingCardSyncPlan({
    required this.cardSnDigest,
    required this.snapshotHash,
    required this.directoryReadAt,
    required this.entries,
    required this.candidates,
    required this.maximumRecordedAt,
  });

  final String cardSnDigest;
  final String snapshotHash;
  final DateTime directoryReadAt;
  final List<RecordingCardFileLedgerEntry> entries;
  final List<RecordingCardSyncCandidate> candidates;
  final DateTime? maximumRecordedAt;

  bool get isEmpty => candidates.isEmpty;
  Set<String> get frozenSourceSignatures => Set<String>.unmodifiable(
    candidates.map((candidate) => candidate.entry.sourceSignature),
  );
}

final class RecordingCardSyncSessionState {
  const RecordingCardSyncSessionState({
    required this.status,
    this.waitingReason,
    this.cardSnDigest,
    this.planSnapshotHash,
    this.replanRequested = false,
    this.errorCode,
  });

  const RecordingCardSyncSessionState.waiting({
    required RecordingCardSyncWaitingReason reason,
    String? cardSnDigest,
  }) : this(
         status: RecordingCardSyncSessionStatus.waiting,
         waitingReason: reason,
         cardSnDigest: cardSnDigest,
       );

  final RecordingCardSyncSessionStatus status;
  final RecordingCardSyncWaitingReason? waitingReason;
  final String? cardSnDigest;
  final String? planSnapshotHash;
  final bool replanRequested;
  final String? errorCode;
}

bool _isSha256(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
