import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_sync_ledger_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_sync_ledger.dart';

void main() {
  final cardA = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;
  final cardB = RecordingCardFileIdentity.digestSerialNumber('CARD-000002')!;
  final now = DateTime.utc(2026, 9, 4, 9);

  test('ledger remains isolated by account and card digest', () {
    final database = AppDatabase();
    final accountA = RecordingCardSyncLedgerStore(
      database: database,
      accountScope: 'account-a',
    );
    final accountB = RecordingCardSyncLedgerStore(
      database: database,
      accountScope: 'account-b',
    );
    accountA.saveFileLedgerEntry(_queued(cardA, 'same', now));
    accountA.saveFileLedgerEntry(_queued(cardB, 'other-card', now));
    accountB.saveFileLedgerEntry(_queued(cardA, 'other-account', now));

    expect(accountA.loadFileLedger(cardA).single.deviceFileId, 'same');
    expect(accountA.loadFileLedger(cardB).single.deviceFileId, 'other-card');
    expect(accountB.loadFileLedger(cardA).single.deviceFileId, 'other-account');
    final stableDigestOrder = <String>[cardA, cardB]..sort();
    expect(accountA.loadKnownCardDigests(), stableDigestOrder);
    expect(accountA.latestKnownCardSnDigest(), stableDigestOrder.first);
  });

  test('latest known card uses maximum checkpoint or ledger activity', () {
    final store = RecordingCardSyncLedgerStore(
      database: AppDatabase(),
      accountScope: 'account-a',
    );
    store.saveFileLedgerEntry(
      _queued(cardA, 'recent-ledger', now.add(const Duration(minutes: 5))),
    );
    store.saveFileLedgerEntry(_queued(cardB, 'older-ledger', now));

    expect(store.latestKnownCardSnDigest(), cardA);

    store.saveSyncCheckpoint(
      RecordingCardSyncCheckpoint.empty(
        cardSnDigest: cardB,
        at: now.add(const Duration(minutes: 10)),
      ),
    );
    expect(store.latestKnownCardSnDigest(), cardB);

    store.saveSyncCheckpoint(
      RecordingCardSyncCheckpoint.empty(
        cardSnDigest: cardA,
        at: now.subtract(const Duration(minutes: 10)),
      ),
    );
    store.saveFileLedgerEntry(
      _queued(cardA, 'newest-ledger', now.add(const Duration(minutes: 15))),
    );
    expect(store.latestKnownCardSnDigest(), cardA);
  });

  test('Bluetooth recovery intent survives restart and clears on commit', () {
    final database = AppDatabase();
    var store = RecordingCardSyncLedgerStore(
      database: database,
      accountScope: 'account-a',
    );
    const planned = 'card-33333333333333333333333333333333';
    final syncing = _queued(cardA, 'recoverable', now)
        .beginSync(now)
        .planBluetoothDownload(
          at: now,
          plannedNativeFileId: planned,
          syncOrigin: RecordingCardSyncOrigin.automatic,
        );
    store.saveFileLedgerEntry(syncing);

    store = RecordingCardSyncLedgerStore(
      database: database,
      accountScope: 'account-a',
    );
    final restored = store.loadFileLedger(cardA).single;
    expect(restored.plannedNativeFileId, planned);
    expect(restored.syncOrigin, RecordingCardSyncOrigin.automatic);
    expect(restored.resumeRequested, isTrue);

    final completed = restored.markSynced(
      at: now.add(const Duration(minutes: 1)),
      localRecordingId: 'local-recoverable',
    );
    store.saveFileLedgerEntry(completed);
    final persisted = store.loadFileLedger(cardA).single;
    expect(persisted.plannedNativeFileId, isNull);
    expect(persisted.resumeRequested, isFalse);
  });

  test('user cancellation blocks automatic sync until manually queued', () {
    final cancelled = _queued(cardA, 'cancelled', now)
        .beginSync(now)
        .planBluetoothDownload(
          at: now,
          plannedNativeFileId: 'card-44444444444444444444444444444444',
          syncOrigin: RecordingCardSyncOrigin.user,
        )
        .recoverInterrupted(now)
        .clearBluetoothResumeRequest(now);

    expect(cancelled.resumeRequested, isFalse);
    expect(cancelled.blocksAutomaticSync, isTrue);
    final retried = cancelled.queue(at: now, manual: true).beginSync(now);
    expect(retried.resumeRequested, isTrue);
    expect(retried.syncOrigin, RecordingCardSyncOrigin.user);
  });

  test('local recording lookup returns every shared ledger association', () {
    final store = RecordingCardSyncLedgerStore(
      database: AppDatabase(),
      accountScope: 'account-a',
    );
    store.saveFileLedgerEntries(<RecordingCardFileLedgerEntry>[
      _synced(cardA, 'one', now, localRecordingId: 'local-duplicate'),
      _synced(cardB, 'two', now, localRecordingId: 'local-duplicate'),
    ]);

    final matches = store.findFileLedgerEntriesByLocalRecordingId(
      'local-duplicate',
    );

    expect(matches, hasLength(2));
    expect(
      matches.map((entry) => entry.deviceFileId),
      containsAll(<String>['one', 'two']),
    );

    final deleting = matches
        .map((entry) => entry.beginLocalDeletion(now))
        .toList(growable: false);
    store.saveFileLedgerEntries(deleting);
    expect(
      store
          .findFileLedgerEntriesByLocalRecordingId('local-duplicate')
          .every(
            (entry) => entry.localState == RecordingCardFileLocalState.deleting,
          ),
      isTrue,
    );

    store.saveFileLedgerEntries(
      deleting.map(
        (entry) =>
            entry.restoreLocalDeletion(now.add(const Duration(seconds: 1))),
      ),
    );
    expect(
      store
          .findFileLedgerEntriesByLocalRecordingId('local-duplicate')
          .every(
            (entry) => entry.localState == RecordingCardFileLocalState.synced,
          ),
      isTrue,
    );

    store.saveFileLedgerEntries(
      deleting.map(
        (entry) =>
            entry.finishLocalDeletion(now.add(const Duration(seconds: 2))),
      ),
    );
    expect(
      <RecordingCardFileLedgerEntry>[
        ...store.loadFileLedger(cardA),
        ...store.loadFileLedger(cardB),
      ].every(
        (entry) =>
            entry.localState == RecordingCardFileLocalState.localDeleted &&
            entry.localRecordingId == null,
      ),
      isTrue,
    );
  });

  test('restart recovers syncing and objectively settles deleting', () {
    final store = RecordingCardSyncLedgerStore(
      database: AppDatabase(),
      accountScope: 'account-a',
    );
    final syncing = _queued(cardA, 'syncing', now).beginSync(now);
    final deleting = _synced(
      cardA,
      'deleting',
      now,
      localRecordingId: 'local-deleting',
    ).beginLocalDeletion(now);
    final syncedWithoutLocalCopy = _queued(cardA, 'missing-synced-copy', now)
        .markSynced(
          at: now,
          localRecordingId: 'local-missing',
          contentHash: _hash('a'),
        );
    final deletedTombstone = _queued(cardA, 'deleted-tombstone', now)
        .markSynced(at: now, localRecordingId: 'local-deleted')
        .beginLocalDeletion(now)
        .finishLocalDeletion(now);
    store.saveFileLedgerEntries(<RecordingCardFileLedgerEntry>[
      syncing,
      deleting,
      syncedWithoutLocalCopy,
      deletedTombstone,
    ]);

    final recovered = store.recoverInterruptedEntries(
      cardSnDigest: cardA,
      at: now.add(const Duration(minutes: 1)),
      localFileExists: (entry) => false,
    );

    expect(
      recovered
          .singleWhere((entry) => entry.deviceFileId == 'syncing')
          .localState,
      RecordingCardFileLocalState.queued,
    );
    expect(
      recovered
          .singleWhere((entry) => entry.deviceFileId == 'deleting')
          .localState,
      RecordingCardFileLocalState.localDeleted,
    );
    final requeued = recovered.singleWhere(
      (entry) => entry.deviceFileId == 'missing-synced-copy',
    );
    expect(requeued.localState, RecordingCardFileLocalState.queued);
    expect(requeued.localRecordingId, isNull);
    expect(requeued.contentHash, _hash('a'));
    expect(
      recovered
          .singleWhere((entry) => entry.deviceFileId == 'deleted-tombstone')
          .localState,
      RecordingCardFileLocalState.localDeleted,
    );
  });

  test('manual resync is the only exit from localDeleted', () {
    final store = RecordingCardSyncLedgerStore(
      database: AppDatabase(),
      accountScope: 'account-a',
    );
    final deleted = _queued(cardA, 'deleted', now)
        .markSynced(
          at: now,
          localRecordingId: 'local-deleted',
          contentHash: 'old-verified-hash',
        )
        .beginLocalDeletion(now)
        .finishLocalDeletion(now);
    store.saveFileLedgerEntry(deleted);

    final queued = store.queueManualSync(
      cardSnDigest: cardA,
      sourceSignature: deleted.sourceSignature,
      at: now.add(const Duration(minutes: 1)),
    );

    expect(queued.localState, RecordingCardFileLocalState.queued);
    expect(queued.localDeletedAt, isNull);
    store.beginManualSync(
      cardSnDigest: cardA,
      sourceSignature: deleted.sourceSignature,
      at: now.add(const Duration(minutes: 2)),
    );
    final completed = store.completeManualSync(
      cardSnDigest: cardA,
      sourceSignature: deleted.sourceSignature,
      localRecordingId: 'local-resynced',
      at: now.add(const Duration(minutes: 3)),
    );

    expect(completed.localState, RecordingCardFileLocalState.synced);
    expect(completed.localRecordingId, 'local-resynced');
    expect(completed.contentHash, isNull);
    expect(
      store.loadSyncCheckpoint(cardA)?.lastTransferCompletedAt,
      now.add(const Duration(minutes: 3)),
    );
    expect(store.loadSyncCheckpoint(cardA)?.lastSuccessfulAutoSyncAt, isNull);
  });

  test('first manual sync atomically creates a scanned-file ledger row', () {
    final store = RecordingCardSyncLedgerStore(
      database: AppDatabase(),
      accountScope: 'account-a',
    );
    final file = _file('manual-first');

    final syncing = store.beginManualSyncForFile(
      cardSnDigest: cardA,
      file: file,
      at: now,
    );

    expect(syncing.localState, RecordingCardFileLocalState.syncing);
    expect(syncing.attemptCount, 1);
    expect(syncing.deviceFileId, file.deviceFileId);
    final persisted = store.loadFileLedger(cardA).single;
    expect(persisted.sourceSignature, syncing.sourceSignature);
    expect(persisted.localState, RecordingCardFileLocalState.syncing);

    final completed = store.completeManualSync(
      cardSnDigest: cardA,
      sourceSignature: syncing.sourceSignature,
      localRecordingId: 'local-manual-first',
      at: now.add(const Duration(seconds: 1)),
    );
    expect(completed.localState, RecordingCardFileLocalState.synced);
    expect(completed.localRecordingId, 'local-manual-first');
    expect(store.loadSyncCheckpoint(cardA)?.lastSuccessfulAutoSyncAt, isNull);
  });

  test('manual queue starts only on transfer and completion is idempotent', () {
    final store = RecordingCardSyncLedgerStore(
      database: AppDatabase(),
      accountScope: 'account-a',
    );
    final file = _file('manual-queued');
    final queued = store.queueManualSyncForFile(
      cardSnDigest: cardA,
      file: file,
      at: now,
    );

    expect(queued.localState, RecordingCardFileLocalState.queued);
    expect(queued.attemptCount, 0);

    final syncing = store.beginManualSync(
      cardSnDigest: cardA,
      sourceSignature: queued.sourceSignature,
      at: now.add(const Duration(seconds: 1)),
    );
    expect(syncing.localState, RecordingCardFileLocalState.syncing);
    expect(syncing.attemptCount, 1);

    final completed = store.completeManualSync(
      cardSnDigest: cardA,
      sourceSignature: queued.sourceSignature,
      localRecordingId: 'local-manual-queued',
      at: now.add(const Duration(seconds: 2)),
    );
    final replayed = store.completeManualSync(
      cardSnDigest: cardA,
      sourceSignature: queued.sourceSignature,
      localRecordingId: 'local-manual-queued',
      contentHash: _hash('a'),
      at: now.add(const Duration(seconds: 3)),
    );

    expect(completed.localState, RecordingCardFileLocalState.synced);
    expect(replayed.localState, RecordingCardFileLocalState.synced);
    expect(replayed.localRecordingId, completed.localRecordingId);
    expect(completed.contentHash, isNull);
    expect(replayed.contentHash, _hash('a'));
    expect(store.loadFileLedger(cardA).single.contentHash, _hash('a'));
    expect(
      () => store.completeManualSync(
        cardSnDigest: cardA,
        sourceSignature: queued.sourceSignature,
        localRecordingId: 'local-conflict',
        contentHash: _hash('a'),
        at: now.add(const Duration(seconds: 4)),
      ),
      throwsStateError,
    );
    expect(
      () => store.completeManualSync(
        cardSnDigest: cardA,
        sourceSignature: queued.sourceSignature,
        localRecordingId: 'local-manual-queued',
        contentHash: _hash('b'),
        at: now.add(const Duration(seconds: 5)),
      ),
      throwsStateError,
    );
  });

  test(
    'changed hash re-queues a reused source identity without stale local ownership',
    () {
      final store = RecordingCardSyncLedgerStore(
        database: AppDatabase(),
        accountScope: 'account-a',
      );
      final original = _file('hash-reused', contentHash: _hash('a'));
      final syncing = store.beginManualSyncForFile(
        cardSnDigest: cardA,
        file: original,
        at: now,
      );
      final completed = store.completeManualSync(
        cardSnDigest: cardA,
        sourceSignature: syncing.sourceSignature,
        localRecordingId: 'local-old-content',
        contentHash: _hash('a'),
        at: now.add(const Duration(seconds: 1)),
      );

      final replacement = store.queueManualSyncForFile(
        cardSnDigest: cardA,
        file: _file('hash-reused', contentHash: _hash('b')),
        at: now.add(const Duration(seconds: 2)),
      );

      expect(completed.localState, RecordingCardFileLocalState.synced);
      expect(replacement.sourceSignature, completed.sourceSignature);
      expect(replacement.localState, RecordingCardFileLocalState.queued);
      expect(replacement.localRecordingId, isNull);
      expect(replacement.contentHash, isNull);
      expect(replacement.lastSyncedAt, isNull);
      expect(store.loadFileLedger(cardA).single.localRecordingId, isNull);
    },
  );

  test('first-use confirmed card deletion creates a durable ledger fact', () {
    final store = RecordingCardSyncLedgerStore(
      database: AppDatabase(),
      accountScope: 'account-a',
    );

    final deleted = store.markCardDeletedForFile(
      cardSnDigest: cardA,
      file: _file('card-delete-first'),
      at: now,
    );

    expect(deleted.localState, RecordingCardFileLocalState.neverSynced);
    expect(deleted.cardState, RecordingCardFilePresenceState.deleted);
    final persisted = store.loadFileLedger(cardA).single;
    expect(persisted.sourceSignature, deleted.sourceSignature);
    expect(persisted.cardState, RecordingCardFilePresenceState.deleted);
  });

  test('manual sync of a current card row restores confirmed presence', () {
    final store = RecordingCardSyncLedgerStore(
      database: AppDatabase(),
      accountScope: 'account-a',
    );
    final file = _file('restored-on-card');
    final deleted = store.markCardDeletedForFile(
      cardSnDigest: cardA,
      file: file,
      at: now,
    );

    final syncing = store.beginManualSyncForFile(
      cardSnDigest: cardA,
      file: file,
      at: now.add(const Duration(minutes: 1)),
    );

    expect(deleted.cardState, RecordingCardFilePresenceState.deleted);
    expect(syncing.localState, RecordingCardFileLocalState.syncing);
    expect(syncing.cardState, RecordingCardFilePresenceState.present);
    expect(
      store.loadFileLedger(cardA).single.cardState,
      RecordingCardFilePresenceState.present,
    );
  });

  test('verified entries and checkpoint commit together', () {
    final database = AppDatabase();
    final store = RecordingCardSyncLedgerStore(
      database: database,
      accountScope: 'account-a',
    );
    final synced = _synced(
      cardA,
      'verified',
      now,
      localRecordingId: 'local-verified',
    );
    final checkpoint =
        RecordingCardSyncCheckpoint.empty(
          cardSnDigest: cardA,
          at: now,
        ).commitAutomaticSync(
          at: now,
          snapshotHash: RecordingCardFileIdentity.snapshotHash(<String>[
            synced.sourceSignature,
          ]),
          committedThroughRecordedAt: now,
          transferredFiles: true,
        );

    store.commitVerifiedSync(
      entries: <RecordingCardFileLedgerEntry>[synced],
      checkpoint: checkpoint,
    );

    expect(
      store.loadFileLedger(cardA).single.localState,
      RecordingCardFileLocalState.synced,
    );
    expect(store.loadSyncCheckpoint(cardA)?.lastSuccessfulAutoSyncAt, now);
  });

  test(
    'legacy seed preserves synced, deleted, unfinished and unknown facts',
    () {
      final database = AppDatabase();
      final store = RecordingCardSyncLedgerStore(
        database: database,
        accountScope: 'account-a',
      );
      final manual = store.beginManualSyncForFile(
        cardSnDigest: cardA,
        file: _file('manual-before-seed'),
        at: now.subtract(const Duration(minutes: 2)),
      );
      store.completeManualSync(
        cardSnDigest: cardA,
        sourceSignature: manual.sourceSignature,
        localRecordingId: 'local-manual-before-seed',
        at: now.subtract(const Duration(minutes: 1)),
      );
      database.upsertRecord(
        LocalTableName.recordingCardDownloadedManifest,
        'manifest-synced',
        <String, Object?>{
          'user_scope': 'account-a',
          'device_file_id': 'synced',
          'device_fingerprint': 'legacy-fingerprint',
          'device_filename': 'synced.wav',
          'local_file_id': 'local-synced',
          'app_private_uri': 'app-private://recording-card/synced.wav',
          'expected_size_bytes': 1024,
          'actual_size_bytes': 1024,
          'content_hash': _hash('a'),
          'downloaded_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
      );
      database.upsertRecord(
        LocalTableName.recordingCardDownloadedManifest,
        'manifest-deleted',
        <String, Object?>{
          'user_scope': 'account-a',
          'device_file_id': 'deleted',
          'device_fingerprint': 'legacy-fingerprint',
          'device_filename': 'deleted.wav',
          'local_file_id': 'local-deleted',
          'expected_size_bytes': 1024,
          'actual_size_bytes': 1024,
          'local_state': 'localDeleted',
          'local_deleted_at': now.toIso8601String(),
          'downloaded_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
      );
      database.upsertRecord(
        LocalTableName.localTransferRecords,
        'legacy-task',
        <String, Object?>{
          'user_scope': 'account-a',
          'transfer_id': 'legacy-task',
          'transfer_kind': 'recording_card_auto_sync',
          'batch_id': 'legacy-batch',
          'device_fingerprint': 'legacy-fingerprint',
          'device_file_id': 'unfinished',
          'device_filename': 'unfinished.wav',
          'local_file_key': 'key-unfinished',
          'expected_size_bytes': 1024,
          'stage': 'downloading',
          'attempt_count': 1,
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
      );
      final files = <RecordingCardScannedFile>[
        _verifiedFile(
          'synced',
          localRecordingId: 'local-synced',
          appPrivateUri: 'app-private://recording-card/synced.wav',
          contentHash: _hash('a'),
        ),
        _file('deleted'),
        _file('unfinished'),
        _file('unproven'),
        _file('manual-before-seed'),
      ];

      final result = store.seedLegacyData(
        cardSnDigest: cardA,
        legacyDeviceFingerprint: 'legacy-fingerprint',
        directoryFiles: files,
        at: now,
      );
      final byId = <String, RecordingCardFileLedgerEntry>{
        for (final entry in result.entries) entry.deviceFileId: entry,
      };

      expect(result.hadMatchingLegacyEvidence, isTrue);
      expect(byId['synced']?.localState, RecordingCardFileLocalState.synced);
      expect(
        byId['deleted']?.localState,
        RecordingCardFileLocalState.localDeleted,
      );
      expect(
        byId['unfinished']?.localState,
        RecordingCardFileLocalState.queued,
      );
      expect(
        byId['unproven']?.localState,
        RecordingCardFileLocalState.legacyUnknown,
      );
      expect(
        byId['manual-before-seed']?.localState,
        RecordingCardFileLocalState.synced,
      );
      expect(
        store.loadSyncCheckpoint(cardA)?.migrationMode,
        RecordingCardSyncMigrationMode.legacyData,
      );
      expect(
        store
            .seedLegacyData(
              cardSnDigest: cardA,
              legacyDeviceFingerprint: 'legacy-fingerprint',
              directoryFiles: files,
              at: now,
            )
            .alreadySeeded,
        isTrue,
      );
    },
  );

  test('legacy synced manifest requires verified matching local evidence', () {
    final database = AppDatabase();
    final store = RecordingCardSyncLedgerStore(
      database: database,
      accountScope: 'account-a',
    );
    void saveManifest(String id, {String hash = ''}) {
      database.upsertRecord(
        LocalTableName.recordingCardDownloadedManifest,
        'manifest-$id',
        <String, Object?>{
          'user_scope': 'account-a',
          'device_file_id': id,
          'device_fingerprint': 'legacy-fingerprint',
          'device_filename': '$id.wav',
          'local_file_id': 'local-$id',
          'app_private_uri': 'app-private://recording-card/$id.wav',
          'expected_size_bytes': 1024,
          'actual_size_bytes': 1024,
          if (hash.isNotEmpty) 'content_hash': hash,
          'downloaded_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
      );
    }

    saveManifest('verified', hash: _hash('a'));
    saveManifest('not-ready');
    saveManifest('uri-mismatch');
    saveManifest('size-mismatch');
    saveManifest('hash-mismatch', hash: _hash('b'));

    final result = store.seedLegacyData(
      cardSnDigest: cardA,
      legacyDeviceFingerprint: 'legacy-fingerprint',
      directoryFiles: <RecordingCardScannedFile>[
        _verifiedFile(
          'verified',
          localRecordingId: 'local-verified',
          appPrivateUri: 'app-private://recording-card/verified.wav',
          contentHash: _hash('a'),
        ),
        _file('not-ready'),
        _verifiedFile(
          'uri-mismatch',
          localRecordingId: 'local-uri-mismatch',
          appPrivateUri: 'app-private://recording-card/other.wav',
        ),
        _verifiedFile(
          'size-mismatch',
          localRecordingId: 'local-size-mismatch',
          appPrivateUri: 'app-private://recording-card/size-mismatch.wav',
          sizeBytes: 2048,
        ),
        _verifiedFile(
          'hash-mismatch',
          localRecordingId: 'local-hash-mismatch',
          appPrivateUri: 'app-private://recording-card/hash-mismatch.wav',
          contentHash: _hash('c'),
        ),
      ],
      at: now,
    );
    final byId = <String, RecordingCardFileLedgerEntry>{
      for (final entry in result.entries) entry.deviceFileId: entry,
    };

    expect(byId['verified']?.localState, RecordingCardFileLocalState.synced);
    for (final id in <String>[
      'not-ready',
      'uri-mismatch',
      'size-mismatch',
      'hash-mismatch',
    ]) {
      expect(
        byId[id]?.localState,
        RecordingCardFileLocalState.legacyUnknown,
        reason: id,
      );
    }
  });

  test(
    'card without matching legacy evidence remains eligible for full sync',
    () {
      final store = RecordingCardSyncLedgerStore(
        database: AppDatabase(),
        accountScope: 'new-account',
      );

      final result = store.seedLegacyData(
        cardSnDigest: cardA,
        legacyDeviceFingerprint: 'new-fingerprint',
        directoryFiles: <RecordingCardScannedFile>[_file('first')],
        at: now,
      );

      expect(result.isNewCard, isTrue);
      expect(store.loadFileLedger(cardA), isEmpty);
      expect(store.loadSyncCheckpoint(cardA), isNull);
    },
  );
}

RecordingCardScannedFile _file(String id, {String? contentHash}) =>
    RecordingCardScannedFile(
      deviceFileId: id,
      localFileKey: 'key-$id',
      deviceFilename: '$id.wav',
      sizeBytes: 1024,
      contentHash: contentHash,
      format: RecordingCardFileFormat.wav,
      mimeType: 'audio/wav',
    );

RecordingCardScannedFile _verifiedFile(
  String id, {
  required String localRecordingId,
  required String appPrivateUri,
  int sizeBytes = 1024,
  String? contentHash,
}) => RecordingCardScannedFile(
  deviceFileId: id,
  localFileKey: 'key-$id',
  deviceFilename: '$id.wav',
  sizeBytes: sizeBytes,
  contentHash: contentHash,
  sizeConfidence: RecordingCardFileSizeConfidence.trusted,
  format: RecordingCardFileFormat.wav,
  mimeType: 'audio/wav',
  syncState: RecordingCardFileSyncState.synced,
  localFileId: localRecordingId,
  appPrivateUri: appPrivateUri,
);

String _hash(String digit) => List<String>.filled(64, digit).join();

RecordingCardFileLedgerEntry _queued(
  String cardDigest,
  String id,
  DateTime now,
) => RecordingCardFileLedgerEntry.discovered(
  cardSnDigest: cardDigest,
  sourceSignature: RecordingCardFileIdentity.sourceSignatureFor(
    cardSnDigest: cardDigest,
    deviceFileId: id,
    deviceFilename: '$id.wav',
    sizeBytes: 1024,
  ),
  deviceFileId: id,
  deviceFilename: '$id.wav',
  seenAt: now,
  sizeBytes: 1024,
).queue(at: now, manual: false);

RecordingCardFileLedgerEntry _synced(
  String cardDigest,
  String id,
  DateTime now, {
  required String localRecordingId,
}) => _queued(
  cardDigest,
  id,
  now,
).markSynced(at: now, localRecordingId: localRecordingId);
