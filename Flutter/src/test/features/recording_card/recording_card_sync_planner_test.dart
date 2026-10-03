import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_sync_planner.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_sync_ledger.dart';

void main() {
  final cardDigest = RecordingCardFileIdentity.digestSerialNumber(
    'CARD-000001',
  )!;
  final now = DateTime.utc(2026, 9, 4, 8);

  test('first sync freezes every discovered source in deterministic order', () {
    const planner = RecordingCardSyncPlanner();
    final newer = _file('newer', recordedAt: now.add(const Duration(hours: 1)));
    final older = _file('older', recordedAt: now);

    final plan = planner.planAutomatic(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[newer, older],
      ledger: const <RecordingCardFileLedgerEntry>[],
      directoryReadAt: now,
    );

    expect(plan.candidates, hasLength(2));
    expect(
      plan.candidates.map((candidate) => candidate.entry.deviceFileId),
      <String>['older', 'newer'],
    );
    expect(
      plan.entries.every(
        (entry) => entry.localState == RecordingCardFileLocalState.queued,
      ),
      isTrue,
    );
  });

  test(
    'unseen source is planned even when its device time moved backwards',
    () {
      const planner = RecordingCardSyncPlanner();
      final existingFile = _file('existing', recordedAt: now);
      final existing = _syncedEntry(cardDigest, existingFile, now);
      final clockRollback = _file(
        'clock-rollback',
        recordedAt: now.subtract(const Duration(days: 40)),
      );

      final plan = planner.planAutomatic(
        cardSnDigest: cardDigest,
        directoryFiles: <RecordingCardScannedFile>[existingFile, clockRollback],
        ledger: <RecordingCardFileLedgerEntry>[existing],
        directoryReadAt: now.add(const Duration(days: 1)),
      );

      expect(plan.candidates, hasLength(1));
      expect(plan.candidates.single.entry.deviceFileId, 'clock-rollback');
    },
  );

  test(
    'local deletion and legacy unknown remain excluded from automatic sync',
    () {
      const planner = RecordingCardSyncPlanner();
      final deletedFile = _file('deleted', recordedAt: now);
      final deleted = _syncedEntry(
        cardDigest,
        deletedFile,
        now,
      ).beginLocalDeletion(now).finishLocalDeletion(now);
      final unknownFile = _file('legacy', recordedAt: now);
      final unknown = RecordingCardFileLedgerEntry.legacyUnknown(
        cardSnDigest: cardDigest,
        sourceSignature: _signature(cardDigest, unknownFile),
        deviceFileId: unknownFile.deviceFileId,
        deviceFilename: unknownFile.deviceFilename,
        seenAt: now,
        recordedAt: unknownFile.recordedAt,
        sizeBytes: unknownFile.sizeBytes,
      );

      final automatic = planner.planAutomatic(
        cardSnDigest: cardDigest,
        directoryFiles: <RecordingCardScannedFile>[deletedFile, unknownFile],
        ledger: <RecordingCardFileLedgerEntry>[deleted, unknown],
        directoryReadAt: now.add(const Duration(minutes: 1)),
      );
      final manual = planner.planManual(
        cardSnDigest: cardDigest,
        directoryFiles: <RecordingCardScannedFile>[deletedFile, unknownFile],
        ledger: automatic.entries,
        sourceSignatures: <String>{deleted.sourceSignature},
        directoryReadAt: now.add(const Duration(minutes: 2)),
      );

      expect(automatic.candidates, isEmpty);
      expect(manual.candidates, hasLength(1));
      expect(
        manual.candidates.single.reason,
        RecordingCardSyncCandidateReason.manual,
      );
    },
  );

  test('confirmed card deletion blocks stale automatic projection', () {
    const planner = RecordingCardSyncPlanner();
    final file = _file('card-deleted', recordedAt: now);
    final deleted = RecordingCardFileLedgerEntry.discovered(
      cardSnDigest: cardDigest,
      sourceSignature: _signature(cardDigest, file),
      deviceFileId: file.deviceFileId,
      deviceFilename: file.deviceFilename,
      seenAt: now,
      recordedAt: file.recordedAt,
      sizeBytes: file.sizeBytes,
    ).markCardDeleted(now);

    final automatic = planner.planAutomatic(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[file],
      ledger: <RecordingCardFileLedgerEntry>[deleted],
      directoryReadAt: now.add(const Duration(minutes: 1)),
    );
    final manual = planner.planManual(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[file],
      ledger: automatic.entries,
      sourceSignatures: <String>{deleted.sourceSignature},
      directoryReadAt: now.add(const Duration(minutes: 2)),
    );

    expect(automatic.candidates, isEmpty);
    expect(
      automatic.entries.single.cardState,
      RecordingCardFilePresenceState.deleted,
    );
    expect(
      manual.candidates.single.reason,
      RecordingCardSyncCandidateReason.manual,
    );
  });

  test('user-cancelled queued work requires a new manual selection', () {
    const planner = RecordingCardSyncPlanner();
    final file = _file('user-cancelled', recordedAt: now);
    final cancelled =
        RecordingCardFileLedgerEntry.discovered(
              cardSnDigest: cardDigest,
              sourceSignature: _signature(cardDigest, file),
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
              seenAt: now,
              recordedAt: file.recordedAt,
              sizeBytes: file.sizeBytes,
            )
            .queue(at: now, manual: true)
            .clearBluetoothResumeRequest(now.add(const Duration(seconds: 1)));

    final automatic = planner.planAutomatic(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[file],
      ledger: <RecordingCardFileLedgerEntry>[cancelled],
      directoryReadAt: now.add(const Duration(minutes: 1)),
    );
    final manual = planner.planManual(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[file],
      ledger: automatic.entries,
      sourceSignatures: <String>{cancelled.sourceSignature},
      directoryReadAt: now.add(const Duration(minutes: 2)),
    );

    expect(cancelled.blocksAutomaticSync, isTrue);
    expect(automatic.candidates, isEmpty);
    expect(
      manual.candidates.single.reason,
      RecordingCardSyncCandidateReason.manual,
    );
    expect(
      manual.candidates.single.entry.syncOrigin,
      RecordingCardSyncOrigin.user,
    );
    expect(manual.candidates.single.entry.resumeRequested, isTrue);
  });

  test(
    'transient retry observes deadline while permanent failure is locked',
    () {
      const planner = RecordingCardSyncPlanner();
      final retryFile = _file('retry', recordedAt: now);
      final permanentFile = _file('permanent', recordedAt: now);
      final futureRetry = _queuedEntry(cardDigest, retryFile, now).markFailed(
        at: now,
        errorCode: 'NETWORK_UNAVAILABLE',
        retryability: RecordingCardSyncRetryability.transient,
        nextRetryAt: now.add(const Duration(minutes: 5)),
      );
      final permanent = _queuedEntry(cardDigest, permanentFile, now).markFailed(
        at: now,
        errorCode: 'FORMAT_UNSUPPORTED',
        retryability: RecordingCardSyncRetryability.permanent,
      );

      final early = planner.planAutomatic(
        cardSnDigest: cardDigest,
        directoryFiles: <RecordingCardScannedFile>[retryFile, permanentFile],
        ledger: <RecordingCardFileLedgerEntry>[futureRetry, permanent],
        directoryReadAt: now.add(const Duration(minutes: 1)),
      );
      final eligible = planner.planAutomatic(
        cardSnDigest: cardDigest,
        directoryFiles: <RecordingCardScannedFile>[retryFile, permanentFile],
        ledger: <RecordingCardFileLedgerEntry>[futureRetry, permanent],
        directoryReadAt: now.add(const Duration(minutes: 6)),
      );

      expect(early.candidates, isEmpty);
      expect(eligible.candidates, hasLength(1));
      expect(
        eligible.candidates.single.reason,
        RecordingCardSyncCandidateReason.transientRetry,
      );
      expect(eligible.candidates.single.entry.attemptCount, 0);
    },
  );

  test('trusted content hash canonicalizes changed source metadata', () {
    const planner = RecordingCardSyncPlanner();
    final original = RecordingCardScannedFile(
      deviceFileId: 'original-id',
      localFileKey: 'key-original',
      deviceFilename: 'original.wav',
      sizeBytes: 1024,
      recordedAt: now,
      contentHash: 'content-hash-one',
      format: RecordingCardFileFormat.wav,
      mimeType: 'audio/wav',
    );
    final existing = _queuedEntry(cardDigest, original, now).markSynced(
      at: now,
      localRecordingId: 'local-original',
      contentHash: original.contentHash,
    );
    final renamed = RecordingCardScannedFile(
      deviceFileId: 'replacement-id',
      localFileKey: 'key-replacement',
      deviceFilename: 'renamed.wav',
      sizeBytes: 2048,
      recordedAt: now.add(const Duration(minutes: 1)),
      contentHash: original.contentHash,
      format: RecordingCardFileFormat.wav,
      mimeType: 'audio/wav',
    );

    final plan = planner.planAutomatic(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[renamed],
      ledger: <RecordingCardFileLedgerEntry>[existing],
      directoryReadAt: now.add(const Duration(minutes: 2)),
    );
    final verification = planner.verify(
      plan: plan,
      verifiedDirectory: <RecordingCardScannedFile>[renamed],
      ledger: plan.entries,
    );

    expect(plan.candidates, isEmpty);
    expect(plan.entries.single.sourceSignature, existing.sourceSignature);
    expect(plan.entries.single.deviceFileId, renamed.deviceFileId);
    expect(verification.newSourceSignatures, isEmpty);
    expect(verification.canCommit, isTrue);
  });

  test(
    'exact source signature with conflicting hashes is planned as unsynced',
    () {
      const planner = RecordingCardSyncPlanner();
      final original = _file(
        'reused-source',
        recordedAt: now,
        contentHash: 'a' * 64,
      );
      final staleSynced = _queuedEntry(cardDigest, original, now).markSynced(
        at: now,
        localRecordingId: 'local-stale',
        contentHash: original.contentHash,
      );
      final replacement = _file(
        'reused-source',
        recordedAt: now,
        contentHash: 'b' * 64,
      );

      final plan = planner.planAutomatic(
        cardSnDigest: cardDigest,
        directoryFiles: <RecordingCardScannedFile>[replacement],
        ledger: <RecordingCardFileLedgerEntry>[staleSynced],
        directoryReadAt: now.add(const Duration(minutes: 1)),
      );
      final verification = planner.verify(
        plan: plan,
        verifiedDirectory: <RecordingCardScannedFile>[replacement],
        ledger: <RecordingCardFileLedgerEntry>[staleSynced],
      );

      expect(plan.candidates, hasLength(1));
      expect(
        plan.candidates.single.reason,
        RecordingCardSyncCandidateReason.newlyDiscovered,
      );
      expect(
        plan.candidates.single.entry.localState,
        RecordingCardFileLocalState.queued,
      );
      expect(plan.candidates.single.entry.localRecordingId, isNull);
      expect(verification.allCandidatesSynced, isFalse);
      expect(verification.canCommit, isFalse);
      expect(verification.incompleteSourceSignatures, <String>{
        staleSynced.sourceSignature,
      });
    },
  );

  test('verification blocks checkpoint when a frozen item failed', () {
    const planner = RecordingCardSyncPlanner();
    final file = _file('one', recordedAt: now);
    final plan = planner.planAutomatic(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[file],
      ledger: const <RecordingCardFileLedgerEntry>[],
      directoryReadAt: now,
    );
    final failed = plan.candidates.single.entry.markFailed(
      at: now,
      errorCode: 'TRANSFER_FAILED',
      retryability: RecordingCardSyncRetryability.permanent,
    );

    final verification = planner.verify(
      plan: plan,
      verifiedDirectory: <RecordingCardScannedFile>[file],
      ledger: <RecordingCardFileLedgerEntry>[failed],
    );

    expect(verification.canCommit, isFalse);
    expect(verification.incompleteSourceSignatures, <String>{
      failed.sourceSignature,
    });
    expect(
      () => planner.buildCommittedCheckpoint(
        plan: plan,
        verification: verification,
        previous: null,
        committedAt: now,
      ),
      throwsStateError,
    );
  });

  test('verification requires the matching physically synced local link', () {
    const planner = RecordingCardSyncPlanner();
    final file = _file('verified-link', recordedAt: now);
    final plan = planner.planAutomatic(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[file],
      ledger: const <RecordingCardFileLedgerEntry>[],
      directoryReadAt: now,
    );
    final synced = plan.candidates.single.entry.markSynced(
      at: now,
      localRecordingId: 'local-verified-link',
    );

    RecordingCardSyncVerification verify(RecordingCardScannedFile evidence) {
      return planner.verify(
        plan: plan,
        verifiedDirectory: <RecordingCardScannedFile>[evidence],
        ledger: <RecordingCardFileLedgerEntry>[synced],
      );
    }

    expect(verify(file).canCommit, isFalse);
    expect(
      verify(
        file.copyWith(
          syncState: RecordingCardFileSyncState.synced,
          localFileId: 'local-other',
        ),
      ).canCommit,
      isFalse,
    );
    expect(
      verify(
        file.copyWith(
          syncState: RecordingCardFileSyncState.synced,
          localFileId: 'local-verified-link',
        ),
      ).canCommit,
      isTrue,
    );
  });

  test('verification requests another plan when a new source appears', () {
    const planner = RecordingCardSyncPlanner();
    final first = _file('first', recordedAt: now);
    final late = _file('late', recordedAt: now.add(const Duration(minutes: 1)));
    final plan = planner.planAutomatic(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[first],
      ledger: const <RecordingCardFileLedgerEntry>[],
      directoryReadAt: now,
    );
    final synced = plan.candidates.single.entry.markSynced(
      at: now,
      localRecordingId: 'local-first',
    );

    final verification = planner.verify(
      plan: plan,
      verifiedDirectory: <RecordingCardScannedFile>[
        first.copyWith(
          syncState: RecordingCardFileSyncState.synced,
          localFileId: 'local-first',
        ),
        late,
      ],
      ledger: <RecordingCardFileLedgerEntry>[synced],
    );

    expect(verification.allCandidatesSynced, isTrue);
    expect(verification.needsReplan, isTrue);
    expect(verification.canCommit, isFalse);
  });

  test('committed time watermark never regresses or clears', () {
    const planner = RecordingCardSyncPlanner();
    final previous =
        RecordingCardSyncCheckpoint.empty(
          cardSnDigest: cardDigest,
          at: now,
        ).commitAutomaticSync(
          at: now,
          snapshotHash: 'previous-snapshot',
          committedThroughRecordedAt: now,
          transferredFiles: true,
        );

    RecordingCardSyncCheckpoint commitFor(RecordingCardScannedFile file) {
      final plan = planner.planAutomatic(
        cardSnDigest: cardDigest,
        directoryFiles: <RecordingCardScannedFile>[file],
        ledger: const <RecordingCardFileLedgerEntry>[],
        directoryReadAt: now.add(const Duration(hours: 1)),
      );
      final synced = plan.candidates.single.entry.markSynced(
        at: now,
        localRecordingId: 'local-${file.deviceFileId}',
      );
      final verification = planner.verify(
        plan: plan,
        verifiedDirectory: <RecordingCardScannedFile>[
          file.copyWith(
            syncState: RecordingCardFileSyncState.synced,
            localFileId: 'local-${file.deviceFileId}',
          ),
        ],
        ledger: <RecordingCardFileLedgerEntry>[synced],
      );
      return planner.buildCommittedCheckpoint(
        plan: plan,
        verification: verification,
        previous: previous,
        committedAt: now.add(const Duration(hours: 1)),
      );
    }

    expect(
      commitFor(
        _file(
          'clock-rollback',
          recordedAt: now.subtract(const Duration(days: 1)),
        ),
      ).committedThroughRecordedAt,
      now,
    );
    expect(commitFor(_file('missing-time')).committedThroughRecordedAt, now);
  });

  test('session policy requires explicit enable and acknowledged pause', () {
    final machine = RecordingCardSyncSessionMachine();
    bool start(RecordingCardSyncTrigger trigger) =>
        machine.start(trigger: trigger, cardSnDigest: cardDigest);
    expect(machine.state.status, RecordingCardSyncSessionStatus.idle);
    machine.disable();
    expect(start(RecordingCardSyncTrigger.deviceConnected), isFalse);
    expect(start(RecordingCardSyncTrigger.explicitRetry), isFalse);
    expect(start(RecordingCardSyncTrigger.autoSyncEnabled), isTrue);
    machine.directoryScanned('snapshot');
    machine.planPersisted(hasCandidates: true);
    machine.requestPause();
    expect(machine.state.status, RecordingCardSyncSessionStatus.pausing);
    expect(start(RecordingCardSyncTrigger.explicitContinue), isFalse);
    machine.pause();
    expect(machine.state.status, RecordingCardSyncSessionStatus.paused);
    expect(machine.committed, throwsStateError);
    expect(start(RecordingCardSyncTrigger.deviceConnected), isFalse);
    expect(start(RecordingCardSyncTrigger.explicitContinue), isTrue);
    expect(machine.state.status, RecordingCardSyncSessionStatus.scanning);
  });

  test('session machine rejects an ambiguous commit transition', () {
    final machine = RecordingCardSyncSessionMachine();
    machine.start(
      trigger: RecordingCardSyncTrigger.deviceConnected,
      cardSnDigest: cardDigest,
    );
    machine.directoryScanned('snapshot');
    machine.planPersisted(hasCandidates: true);
    machine.transfersSettled();

    expect(machine.state.status, RecordingCardSyncSessionStatus.verifying);
    expect(machine.committed, throwsStateError);
    machine.verificationAccepted();
    machine.committed();
    expect(machine.state.status, RecordingCardSyncSessionStatus.completed);
  });

  test('trigger gate coalesces repeats and latches replan during a run', () {
    final gate = RecordingCardSyncTriggerGate();
    final connected = RecordingCardSyncTriggerObservation(
      autoSyncEnabled: true,
      isConnected: true,
      isRecording: false,
      hasConflictingTransfer: false,
      cardSnDigest: cardDigest,
      directorySnapshotHash: 'first',
    );
    gate.observe(connected);
    gate.observe(connected);

    expect(gate.beginRun(), <RecordingCardSyncTrigger>{
      RecordingCardSyncTrigger.deviceConnected,
    });
    gate.observe(
      RecordingCardSyncTriggerObservation(
        autoSyncEnabled: true,
        isConnected: true,
        isRecording: false,
        hasConflictingTransfer: false,
        cardSnDigest: cardDigest,
        directorySnapshotHash: 'second',
      ),
    );
    expect(gate.replanRequested, isTrue);
    expect(gate.finishRun(), <RecordingCardSyncTrigger>{
      RecordingCardSyncTrigger.directoryRefreshed,
    });
  });

  test('trigger gate suppresses an owned transfer completion edge', () {
    final gate = RecordingCardSyncTriggerGate();
    RecordingCardSyncTriggerObservation observation(bool transfer) =>
        RecordingCardSyncTriggerObservation(
          autoSyncEnabled: true,
          isConnected: true,
          isRecording: false,
          hasConflictingTransfer: transfer,
          cardSnDigest: cardDigest,
          directorySnapshotHash: 'stable',
        );

    gate.observe(observation(false));
    expect(gate.beginRun(), <RecordingCardSyncTrigger>{
      RecordingCardSyncTrigger.deviceConnected,
    });
    gate.observe(observation(true), includeTransferChanges: false);
    gate.observe(observation(false), includeTransferChanges: false);

    expect(gate.finishRun(), isEmpty);

    gate.observe(observation(true));
    gate.observe(observation(false));
    expect(gate.beginRun(), <RecordingCardSyncTrigger>{
      RecordingCardSyncTrigger.conflictingTransferEnded,
    });
  });

  test(
    'trigger gate can delegate recording settlement without leaking an edge',
    () {
      final gate = RecordingCardSyncTriggerGate();
      RecordingCardSyncTriggerObservation observation(bool recording) =>
          RecordingCardSyncTriggerObservation(
            autoSyncEnabled: true,
            isConnected: true,
            isRecording: recording,
            hasConflictingTransfer: false,
            cardSnDigest: cardDigest,
            directorySnapshotHash: 'stable',
          );

      gate.observe(observation(false));
      expect(gate.beginRun(), <RecordingCardSyncTrigger>{
        RecordingCardSyncTrigger.deviceConnected,
      });
      gate.observe(observation(true), includeRecordingChanges: false);
      gate.observe(observation(false), includeRecordingChanges: false);
      expect(gate.finishRun(), isEmpty);

      gate.observe(observation(true));
      gate.observe(observation(false));
      expect(gate.beginRun(), <RecordingCardSyncTrigger>{
        RecordingCardSyncTrigger.recordingBecameIdle,
      });
    },
  );

  test('directory observation hashes only the current successful read', () {
    const planner = RecordingCardSyncPlanner();
    final historical = RecordingCardFileLedgerEntry.discovered(
      cardSnDigest: cardDigest,
      sourceSignature: RecordingCardFileIdentity.sourceSignatureFor(
        cardSnDigest: cardDigest,
        deviceFileId: 'historical',
        deviceFilename: 'historical.wav',
        sizeBytes: 512,
      ),
      deviceFileId: 'historical',
      deviceFilename: 'historical.wav',
      seenAt: now,
      sizeBytes: 512,
    );
    final current = _file('current');
    final currentSignature = RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: cardDigest,
      deviceFileId: current.deviceFileId,
      deviceFilename: current.deviceFilename,
      sizeBytes: current.sizeBytes,
      recordedAt: current.recordedAt,
    );

    final observation = planner.observeDirectory(
      cardSnDigest: cardDigest,
      directoryFiles: <RecordingCardScannedFile>[current],
      ledger: <RecordingCardFileLedgerEntry>[historical],
      directoryReadAt: now.add(const Duration(minutes: 1)),
    );

    expect(observation.candidates, isEmpty);
    expect(
      observation.entries
          .singleWhere((entry) => entry.sourceSignature == currentSignature)
          .localState,
      RecordingCardFileLocalState.neverSynced,
    );
    expect(
      observation.entries
          .singleWhere(
            (entry) => entry.sourceSignature == historical.sourceSignature,
          )
          .cardState,
      RecordingCardFilePresenceState.unknown,
    );
    expect(
      observation.snapshotHash,
      RecordingCardFileIdentity.snapshotHash(<String>[currentSignature]),
    );
  });
}

RecordingCardScannedFile _file(
  String id, {
  DateTime? recordedAt,
  String? contentHash,
}) => RecordingCardScannedFile(
  deviceFileId: id,
  localFileKey: 'key-$id',
  deviceFilename: '$id.wav',
  sizeBytes: 1024,
  recordedAt: recordedAt,
  contentHash: contentHash,
  format: RecordingCardFileFormat.wav,
  mimeType: 'audio/wav',
);

String _signature(String cardDigest, RecordingCardScannedFile file) =>
    RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: cardDigest,
      deviceFileId: file.deviceFileId,
      deviceFilename: file.deviceFilename,
      sizeBytes: file.sizeBytes,
      recordedAt: file.recordedAt,
    );

RecordingCardFileLedgerEntry _queuedEntry(
  String cardDigest,
  RecordingCardScannedFile file,
  DateTime now,
) => RecordingCardFileLedgerEntry.discovered(
  cardSnDigest: cardDigest,
  sourceSignature: _signature(cardDigest, file),
  deviceFileId: file.deviceFileId,
  deviceFilename: file.deviceFilename,
  seenAt: now,
  recordedAt: file.recordedAt,
  sizeBytes: file.sizeBytes,
).queue(at: now, manual: false);

RecordingCardFileLedgerEntry _syncedEntry(
  String cardDigest,
  RecordingCardScannedFile file,
  DateTime now,
) => _queuedEntry(
  cardDigest,
  file,
  now,
).markSynced(at: now, localRecordingId: 'local-${file.deviceFileId}');
