import '../../../core/native/recording_card_native_port.dart';
import '../domain/recording_card_sync_ledger.dart';

final class RecordingCardSyncPlanner {
  const RecordingCardSyncPlanner();

  RecordingCardSyncPlan planAutomatic({
    required String cardSnDigest,
    required List<RecordingCardScannedFile> directoryFiles,
    required List<RecordingCardFileLedgerEntry> ledger,
    required DateTime directoryReadAt,
    bool resetTransientAttempts = true,
  }) {
    return _plan(
      cardSnDigest: cardSnDigest,
      directoryFiles: directoryFiles,
      ledger: ledger,
      directoryReadAt: directoryReadAt,
      manualSourceSignatures: const <String>{},
      resetTransientAttempts: resetTransientAttempts,
      selectCandidates: true,
    );
  }

  RecordingCardSyncPlan observeDirectory({
    required String cardSnDigest,
    required List<RecordingCardScannedFile> directoryFiles,
    required List<RecordingCardFileLedgerEntry> ledger,
    required DateTime directoryReadAt,
  }) => _plan(
    cardSnDigest: cardSnDigest,
    directoryFiles: directoryFiles,
    ledger: ledger,
    directoryReadAt: directoryReadAt,
    manualSourceSignatures: const <String>{},
    resetTransientAttempts: false,
    selectCandidates: false,
  );

  RecordingCardSyncPlan planManual({
    required String cardSnDigest,
    required List<RecordingCardScannedFile> directoryFiles,
    required List<RecordingCardFileLedgerEntry> ledger,
    required Set<String> sourceSignatures,
    required DateTime directoryReadAt,
  }) {
    if (sourceSignatures.isEmpty) {
      throw ArgumentError.value(sourceSignatures, 'sourceSignatures');
    }
    return _plan(
      cardSnDigest: cardSnDigest,
      directoryFiles: directoryFiles,
      ledger: ledger,
      directoryReadAt: directoryReadAt,
      manualSourceSignatures: sourceSignatures,
      resetTransientAttempts: true,
      selectCandidates: true,
    );
  }

  RecordingCardSyncPlan _plan({
    required String cardSnDigest,
    required List<RecordingCardScannedFile> directoryFiles,
    required List<RecordingCardFileLedgerEntry> ledger,
    required DateTime directoryReadAt,
    required Set<String> manualSourceSignatures,
    required bool resetTransientAttempts,
    required bool selectCandidates,
  }) {
    final now = directoryReadAt.toUtc();
    final bySignature = <String, RecordingCardFileLedgerEntry>{
      for (final entry in ledger)
        if (entry.cardSnDigest == cardSnDigest) entry.sourceSignature: entry,
    };
    final byContentHash = _uniqueEntriesByContentHash(
      ledger.where((entry) => entry.cardSnDigest == cardSnDigest),
    );
    final seen = <String>{};
    final directorySignatures = <String>{};
    final candidates = <RecordingCardSyncCandidate>[];

    for (final file in directoryFiles) {
      final computedSignature = RecordingCardFileIdentity.sourceSignatureFor(
        cardSnDigest: cardSnDigest,
        deviceFileId: file.deviceFileId,
        deviceFilename: file.deviceFilename,
        sizeBytes: file.sizeBytes,
        recordedAt: file.recordedAt,
      );
      final contentHash = file.contentHash?.trim().toLowerCase();
      final exactEntry = bySignature[computedSignature];
      final exactHashConflict =
          exactEntry != null &&
          _contentHashesConflict(contentHash, exactEntry.contentHash);
      var entry = exactHashConflict ? null : exactEntry;
      if (entry == null &&
          !exactHashConflict &&
          contentHash != null &&
          contentHash.isNotEmpty) {
        entry = byContentHash[contentHash];
      }
      final wasNew = entry == null;
      entry = entry == null
          ? RecordingCardFileLedgerEntry.discovered(
              cardSnDigest: cardSnDigest,
              sourceSignature: computedSignature,
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
              seenAt: now,
              recordedAt: file.recordedAt,
              sizeBytes: file.sizeBytes,
              durationSeconds: file.durationSeconds,
            )
          : entry.seen(
              at: now,
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
              recordedAt: file.recordedAt,
              sizeBytes: file.sizeBytes,
              durationSeconds: file.durationSeconds,
            );
      directorySignatures.add(entry.sourceSignature);
      final firstObservation = seen.add(entry.sourceSignature);

      final manual =
          manualSourceSignatures.contains(entry.sourceSignature) ||
          manualSourceSignatures.contains(computedSignature);
      if (selectCandidates && firstObservation) {
        final reason = _candidateReason(
          entry,
          wasNew: wasNew,
          manual: manual,
          now: now,
        );
        if (reason != null) {
          entry = entry.queue(
            at: now,
            manual: manual,
            resetAttemptCount:
                (reason == RecordingCardSyncCandidateReason.transientRetry &&
                    resetTransientAttempts) ||
                reason == RecordingCardSyncCandidateReason.manual,
          );
          candidates.add(
            RecordingCardSyncCandidate(entry: entry, reason: reason),
          );
        }
      }
      bySignature[entry.sourceSignature] = entry;
    }

    for (final entry in ledger) {
      if (entry.cardSnDigest != cardSnDigest ||
          seen.contains(entry.sourceSignature)) {
        continue;
      }
      bySignature[entry.sourceSignature] =
          entry.cardState == RecordingCardFilePresenceState.deleted
          ? entry
          : entry.markCardUnknown(now);
    }

    candidates.sort(_compareCandidates);
    final orderedEntries = bySignature.values.toList(growable: false)
      ..sort(
        (left, right) => left.sourceSignature.compareTo(right.sourceSignature),
      );
    DateTime? maximumRecordedAt;
    for (final file in directoryFiles) {
      final recordedAt = file.recordedAt?.toUtc();
      if (recordedAt != null &&
          (maximumRecordedAt == null ||
              recordedAt.isAfter(maximumRecordedAt))) {
        maximumRecordedAt = recordedAt;
      }
    }
    return RecordingCardSyncPlan(
      cardSnDigest: cardSnDigest,
      snapshotHash: RecordingCardFileIdentity.snapshotHash(directorySignatures),
      directoryReadAt: now,
      entries: List<RecordingCardFileLedgerEntry>.unmodifiable(orderedEntries),
      candidates: List<RecordingCardSyncCandidate>.unmodifiable(candidates),
      maximumRecordedAt: maximumRecordedAt,
    );
  }

  RecordingCardSyncVerification verify({
    required RecordingCardSyncPlan plan,
    required List<RecordingCardScannedFile> verifiedDirectory,
    required List<RecordingCardFileLedgerEntry> ledger,
  }) {
    final bySignature = <String, RecordingCardFileLedgerEntry>{
      for (final entry in ledger)
        if (entry.cardSnDigest == plan.cardSnDigest)
          entry.sourceSignature: entry,
    };
    final byContentHash = _uniqueEntriesByContentHash(bySignature.values);
    final verifiedSignatures = <String>{};
    final verifiedFilesBySignature = <String, List<RecordingCardScannedFile>>{};
    for (final file in verifiedDirectory) {
      final signature = _canonicalSourceSignature(
        cardSnDigest: plan.cardSnDigest,
        file: file,
        bySignature: bySignature,
        byContentHash: byContentHash,
      );
      verifiedSignatures.add(signature);
      (verifiedFilesBySignature[signature] ??= <RecordingCardScannedFile>[])
          .add(file);
    }
    final incomplete = <String>{
      for (final sourceSignature in plan.frozenSourceSignatures)
        if (!_isVerifiedSourceComplete(
          entry: bySignature[sourceSignature],
          verifiedFiles: verifiedFilesBySignature[sourceSignature],
        ))
          sourceSignature,
    };
    final plannedDirectorySignatures = <String>{
      for (final entry in plan.entries) entry.sourceSignature,
    };
    final newSourceSignatures = verifiedSignatures.difference(
      plannedDirectorySignatures,
    );
    return RecordingCardSyncVerification(
      allCandidatesSynced: incomplete.isEmpty,
      incompleteSourceSignatures: Set<String>.unmodifiable(incomplete),
      newSourceSignatures: Set<String>.unmodifiable(newSourceSignatures),
      verifiedSnapshotHash: RecordingCardFileIdentity.snapshotHash(
        verifiedSignatures,
      ),
    );
  }

  RecordingCardSyncCheckpoint buildCommittedCheckpoint({
    required RecordingCardSyncPlan plan,
    required RecordingCardSyncVerification verification,
    required RecordingCardSyncCheckpoint? previous,
    required DateTime committedAt,
  }) {
    if (!verification.canCommit) {
      throw StateError('Cannot commit an incomplete recording-card sync plan');
    }
    final base =
        previous ??
        RecordingCardSyncCheckpoint.empty(
          cardSnDigest: plan.cardSnDigest,
          at: committedAt,
        );
    if (base.cardSnDigest != plan.cardSnDigest) {
      throw StateError('Checkpoint belongs to a different recording card');
    }
    final previousWatermark = base.committedThroughRecordedAt;
    final currentWatermark = plan.maximumRecordedAt;
    final committedWatermark =
        currentWatermark == null ||
            (previousWatermark != null &&
                previousWatermark.isAfter(currentWatermark))
        ? previousWatermark
        : currentWatermark;
    return base.commitAutomaticSync(
      at: committedAt,
      snapshotHash: verification.verifiedSnapshotHash,
      committedThroughRecordedAt: committedWatermark,
      transferredFiles: plan.candidates.isNotEmpty,
    );
  }

  RecordingCardSyncCandidateReason? _candidateReason(
    RecordingCardFileLedgerEntry entry, {
    required bool wasNew,
    required bool manual,
    required DateTime now,
  }) {
    if (manual) return RecordingCardSyncCandidateReason.manual;
    if (entry.blocksAutomaticSync) return null;
    if (entry.cardState == RecordingCardFilePresenceState.deleted) return null;
    return switch (entry.localState) {
      RecordingCardFileLocalState.neverSynced =>
        wasNew
            ? RecordingCardSyncCandidateReason.newlyDiscovered
            : RecordingCardSyncCandidateReason.neverSynced,
      RecordingCardFileLocalState.queued =>
        RecordingCardSyncCandidateReason.interrupted,
      RecordingCardFileLocalState.syncing =>
        RecordingCardSyncCandidateReason.interrupted,
      RecordingCardFileLocalState.failed =>
        entry.retryability == RecordingCardSyncRetryability.transient &&
                (entry.nextRetryAt == null || !entry.nextRetryAt!.isAfter(now))
            ? RecordingCardSyncCandidateReason.transientRetry
            : null,
      RecordingCardFileLocalState.synced ||
      RecordingCardFileLocalState.localDeleted ||
      RecordingCardFileLocalState.legacyUnknown ||
      RecordingCardFileLocalState.deleting => null,
    };
  }
}

final class RecordingCardSyncVerification {
  const RecordingCardSyncVerification({
    required this.allCandidatesSynced,
    required this.incompleteSourceSignatures,
    required this.newSourceSignatures,
    required this.verifiedSnapshotHash,
  });

  final bool allCandidatesSynced;
  final Set<String> incompleteSourceSignatures;
  final Set<String> newSourceSignatures;
  final String verifiedSnapshotHash;

  bool get canCommit => allCandidatesSynced && newSourceSignatures.isEmpty;
  bool get needsReplan => newSourceSignatures.isNotEmpty;
}

final class RecordingCardSyncRetryPolicy {
  const RecordingCardSyncRetryPolicy({
    this.maximumAttemptsPerRun = 3,
    this.baseDelay = const Duration(milliseconds: 300),
    this.maximumDelay = const Duration(seconds: 3),
  }) : assert(maximumAttemptsPerRun > 0);

  final int maximumAttemptsPerRun;
  final Duration baseDelay;
  final Duration maximumDelay;

  bool canAttempt(int attemptsThisRun) =>
      attemptsThisRun < maximumAttemptsPerRun;

  Duration delayBeforeAttempt(int attemptNumber, {int jitterSeed = 0}) {
    if (attemptNumber <= 1) return Duration.zero;
    final multiplier = 1 << (attemptNumber - 2).clamp(0, 8);
    final rawMilliseconds = baseDelay.inMilliseconds * multiplier;
    final capped = rawMilliseconds.clamp(0, maximumDelay.inMilliseconds);
    final jitterWindow = (capped * 0.2).round();
    final jitter = jitterWindow == 0
        ? 0
        : (jitterSeed.abs() % (jitterWindow * 2 + 1)) - jitterWindow;
    return Duration(milliseconds: (capped + jitter).clamp(0, 1 << 31));
  }
}

final class RecordingCardSyncSessionMachine {
  RecordingCardSyncSessionMachine({RecordingCardSyncSessionState? initial})
    : _state =
          initial ??
          const RecordingCardSyncSessionState(
            status: RecordingCardSyncSessionStatus.idle,
          );

  RecordingCardSyncSessionState _state;

  RecordingCardSyncSessionState get state => _state;

  bool start({
    required RecordingCardSyncTrigger trigger,
    required String cardSnDigest,
  }) {
    if (_state.status == RecordingCardSyncSessionStatus.pausing) return false;
    if (_state.status == RecordingCardSyncSessionStatus.disabled &&
        trigger != RecordingCardSyncTrigger.autoSyncEnabled) {
      return false;
    }
    if (_state.status == RecordingCardSyncSessionStatus.paused &&
        trigger != RecordingCardSyncTrigger.explicitContinue &&
        trigger != RecordingCardSyncTrigger.explicitRetry &&
        trigger != RecordingCardSyncTrigger.autoSyncEnabled) {
      return false;
    }
    _state = RecordingCardSyncSessionState(
      status: RecordingCardSyncSessionStatus.scanning,
      cardSnDigest: cardSnDigest,
    );
    return true;
  }

  void disable() {
    _state = RecordingCardSyncSessionState(
      status: RecordingCardSyncSessionStatus.disabled,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: _state.planSnapshotHash,
    );
  }

  void requestPause() {
    if (_state.status == RecordingCardSyncSessionStatus.disabled) return;
    _state = RecordingCardSyncSessionState(
      status: RecordingCardSyncSessionStatus.pausing,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: _state.planSnapshotHash,
    );
  }

  void waitFor(RecordingCardSyncWaitingReason reason, {String? cardSnDigest}) {
    _state = RecordingCardSyncSessionState.waiting(
      reason: reason,
      cardSnDigest: cardSnDigest ?? _state.cardSnDigest,
    );
  }

  void directoryScanned(String snapshotHash) {
    _require(RecordingCardSyncSessionStatus.scanning);
    _state = RecordingCardSyncSessionState(
      status: RecordingCardSyncSessionStatus.planning,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: snapshotHash,
    );
  }

  void planPersisted({required bool hasCandidates}) {
    _require(RecordingCardSyncSessionStatus.planning);
    _state = RecordingCardSyncSessionState(
      status: hasCandidates
          ? RecordingCardSyncSessionStatus.transferring
          : RecordingCardSyncSessionStatus.completed,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: _state.planSnapshotHash,
    );
  }

  void transfersSettled() {
    _require(RecordingCardSyncSessionStatus.transferring);
    _state = RecordingCardSyncSessionState(
      status: RecordingCardSyncSessionStatus.verifying,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: _state.planSnapshotHash,
      replanRequested: _state.replanRequested,
    );
  }

  void verificationAccepted() {
    _require(RecordingCardSyncSessionStatus.verifying);
    _state = RecordingCardSyncSessionState(
      status: RecordingCardSyncSessionStatus.committing,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: _state.planSnapshotHash,
    );
  }

  void committed() {
    _require(RecordingCardSyncSessionStatus.committing);
    _state = RecordingCardSyncSessionState(
      status: RecordingCardSyncSessionStatus.completed,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: _state.planSnapshotHash,
    );
  }

  void requestReplan() {
    _state = RecordingCardSyncSessionState(
      status: _state.status,
      waitingReason: _state.waitingReason,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: _state.planSnapshotHash,
      replanRequested: true,
      errorCode: _state.errorCode,
    );
  }

  void pause() {
    _require(RecordingCardSyncSessionStatus.pausing);
    _state = RecordingCardSyncSessionState(
      status: RecordingCardSyncSessionStatus.paused,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: _state.planSnapshotHash,
    );
  }

  void fail(String errorCode) {
    if (errorCode.trim().isEmpty) throw ArgumentError.value(errorCode);
    _state = RecordingCardSyncSessionState(
      status: RecordingCardSyncSessionStatus.failed,
      cardSnDigest: _state.cardSnDigest,
      planSnapshotHash: _state.planSnapshotHash,
      errorCode: errorCode.trim(),
    );
  }

  void _require(RecordingCardSyncSessionStatus expected) {
    if (_state.status != expected) {
      throw StateError(
        'Illegal sync-session transition from ${_state.status}; '
        'expected $expected',
      );
    }
  }
}

final class RecordingCardSyncTriggerObservation {
  const RecordingCardSyncTriggerObservation({
    required this.autoSyncEnabled,
    required this.isConnected,
    required this.isRecording,
    required this.hasConflictingTransfer,
    this.cardSnDigest,
    this.directorySnapshotHash,
  });

  final bool autoSyncEnabled;
  final bool isConnected;
  final bool isRecording;
  final bool hasConflictingTransfer;
  final String? cardSnDigest;
  final String? directorySnapshotHash;
}

final class RecordingCardSyncTriggerGate {
  RecordingCardSyncTriggerObservation? _previous;
  final Set<RecordingCardSyncTrigger> _pending = <RecordingCardSyncTrigger>{};
  bool _running = false;

  bool get replanRequested => _running && _pending.isNotEmpty;
  bool get hasPending => _pending.isNotEmpty;

  void observe(
    RecordingCardSyncTriggerObservation next, {
    bool includeDirectoryChanges = true,
    bool includeRecordingChanges = true,
    bool includeTransferChanges = true,
  }) {
    final previous = _previous;
    _previous = next;
    if (!next.autoSyncEnabled) {
      _pending.clear();
      return;
    }
    if (next.isConnected &&
        next.cardSnDigest != null &&
        (previous == null ||
            !previous.isConnected ||
            previous.cardSnDigest != next.cardSnDigest)) {
      _pending.add(RecordingCardSyncTrigger.deviceConnected);
    }
    if (includeRecordingChanges &&
        previous != null &&
        previous.isRecording &&
        !next.isRecording) {
      _pending.add(RecordingCardSyncTrigger.recordingBecameIdle);
    }
    if (includeTransferChanges &&
        previous != null &&
        previous.hasConflictingTransfer &&
        !next.hasConflictingTransfer) {
      _pending.add(RecordingCardSyncTrigger.conflictingTransferEnded);
    }
    if (previous != null && !previous.autoSyncEnabled && next.autoSyncEnabled) {
      _pending.add(RecordingCardSyncTrigger.autoSyncEnabled);
    }
    if (includeDirectoryChanges &&
        previous != null &&
        next.isConnected &&
        next.cardSnDigest == previous.cardSnDigest &&
        next.directorySnapshotHash != previous.directorySnapshotHash) {
      _pending.add(RecordingCardSyncTrigger.directoryRefreshed);
    }
  }

  void signal(RecordingCardSyncTrigger trigger) {
    _pending.add(trigger);
  }

  Set<RecordingCardSyncTrigger> beginRun() {
    if (_running) return const <RecordingCardSyncTrigger>{};
    final drained = Set<RecordingCardSyncTrigger>.unmodifiable(_pending);
    _pending.clear();
    _running = true;
    return drained;
  }

  Set<RecordingCardSyncTrigger> finishRun() {
    _running = false;
    final drained = Set<RecordingCardSyncTrigger>.unmodifiable(_pending);
    _pending.clear();
    return drained;
  }
}

int _compareCandidates(
  RecordingCardSyncCandidate left,
  RecordingCardSyncCandidate right,
) {
  final reason = _reasonPriority(
    left.reason,
  ).compareTo(_reasonPriority(right.reason));
  if (reason != 0) return reason;
  final leftAt = left.entry.recordedAt;
  final rightAt = right.entry.recordedAt;
  if (leftAt != null && rightAt != null) {
    final recorded = leftAt.compareTo(rightAt);
    if (recorded != 0) return recorded;
  } else if (leftAt == null && rightAt != null) {
    return 1;
  } else if (leftAt != null && rightAt == null) {
    return -1;
  }
  final filename = left.entry.deviceFilename.compareTo(
    right.entry.deviceFilename,
  );
  return filename != 0
      ? filename
      : left.entry.sourceSignature.compareTo(right.entry.sourceSignature);
}

int _reasonPriority(RecordingCardSyncCandidateReason reason) =>
    switch (reason) {
      RecordingCardSyncCandidateReason.interrupted => 0,
      RecordingCardSyncCandidateReason.transientRetry => 1,
      RecordingCardSyncCandidateReason.neverSynced => 2,
      RecordingCardSyncCandidateReason.newlyDiscovered => 3,
      RecordingCardSyncCandidateReason.manual => 4,
    };

Map<String, RecordingCardFileLedgerEntry> _uniqueEntriesByContentHash(
  Iterable<RecordingCardFileLedgerEntry> entries,
) {
  final unique = <String, RecordingCardFileLedgerEntry>{};
  final ambiguous = <String>{};
  for (final entry in entries) {
    final hash = entry.contentHash?.trim().toLowerCase();
    if (hash == null || hash.isEmpty || ambiguous.contains(hash)) continue;
    if (unique.containsKey(hash)) {
      unique.remove(hash);
      ambiguous.add(hash);
    } else {
      unique[hash] = entry;
    }
  }
  return unique;
}

String _canonicalSourceSignature({
  required String cardSnDigest,
  required RecordingCardScannedFile file,
  required Map<String, RecordingCardFileLedgerEntry> bySignature,
  required Map<String, RecordingCardFileLedgerEntry> byContentHash,
}) {
  final computed = RecordingCardFileIdentity.sourceSignatureFor(
    cardSnDigest: cardSnDigest,
    deviceFileId: file.deviceFileId,
    deviceFilename: file.deviceFilename,
    sizeBytes: file.sizeBytes,
    recordedAt: file.recordedAt,
  );
  final direct = bySignature[computed];
  final hash = file.contentHash?.trim().toLowerCase();
  if (direct != null) {
    return _contentHashesConflict(hash, direct.contentHash)
        ? computed
        : direct.sourceSignature;
  }
  return hash == null || hash.isEmpty
      ? computed
      : byContentHash[hash]?.sourceSignature ?? computed;
}

bool _isVerifiedSourceComplete({
  required RecordingCardFileLedgerEntry? entry,
  required List<RecordingCardScannedFile>? verifiedFiles,
}) {
  if (entry?.hasValidLocalRecording != true || verifiedFiles == null) {
    return false;
  }
  final localRecordingId = entry!.localRecordingId!.trim();
  final matchingLocalFiles = verifiedFiles
      .where(
        (file) =>
            file.syncState == RecordingCardFileSyncState.synced &&
            file.localFileId?.trim() == localRecordingId,
      )
      .toList(growable: false);
  return matchingLocalFiles.isNotEmpty &&
      matchingLocalFiles.every(
        (file) => !_contentHashesConflict(file.contentHash, entry.contentHash),
      );
}

bool _contentHashesConflict(String? current, String? persisted) {
  final currentHash = current?.trim().toLowerCase();
  final persistedHash = persisted?.trim().toLowerCase();
  return currentHash != null &&
      currentHash.isNotEmpty &&
      persistedHash != null &&
      persistedHash.isNotEmpty &&
      currentHash != persistedHash;
}
