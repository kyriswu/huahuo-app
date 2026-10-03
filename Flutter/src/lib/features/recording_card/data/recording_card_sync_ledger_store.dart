import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_database.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../domain/recording_card_sync_ledger.dart';

abstract interface class RecordingCardSyncLedgerPersistencePort {
  String get accountScope;

  Future<void> flushSyncPersistence();

  List<String> loadKnownCardDigests();

  String? latestKnownCardSnDigest();

  List<RecordingCardFileLedgerEntry> loadFileLedger(String cardSnDigest);

  RecordingCardFileLedgerEntry? findFileLedgerEntry({
    required String cardSnDigest,
    required String sourceSignature,
  });

  RecordingCardFileLedgerEntry? findFileLedgerEntryByLocalRecordingId(
    String localRecordingId,
  );

  List<RecordingCardFileLedgerEntry> findFileLedgerEntriesByLocalRecordingId(
    String localRecordingId,
  );

  void saveFileLedgerEntry(RecordingCardFileLedgerEntry entry);

  void saveFileLedgerEntries(Iterable<RecordingCardFileLedgerEntry> entries);

  RecordingCardSyncCheckpoint? loadSyncCheckpoint(String cardSnDigest);

  void saveSyncCheckpoint(RecordingCardSyncCheckpoint checkpoint);

  void commitVerifiedSync({
    required Iterable<RecordingCardFileLedgerEntry> entries,
    required RecordingCardSyncCheckpoint checkpoint,
  });

  List<RecordingCardFileLedgerEntry> recoverInterruptedEntries({
    required String cardSnDigest,
    required DateTime at,
    required bool Function(RecordingCardFileLedgerEntry entry) localFileExists,
  });

  RecordingCardLegacySeedResult seedLegacyData({
    required String cardSnDigest,
    required String legacyDeviceFingerprint,
    required List<RecordingCardScannedFile> directoryFiles,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry queueManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry beginManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry beginManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry queueManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry completeManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required String localRecordingId,
    required DateTime at,
    String? contentHash,
  });

  RecordingCardFileLedgerEntry failManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required String errorCode,
    required RecordingCardSyncRetryability retryability,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry beginLocalDeletion({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry finishLocalDeletion({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry restoreLocalDeletion({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry markCardDeleted({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  });

  RecordingCardFileLedgerEntry markCardDeletedForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  });
}

final class RecordingCardLegacySeedResult {
  const RecordingCardLegacySeedResult({
    required this.entries,
    required this.hadMatchingLegacyEvidence,
    required this.alreadySeeded,
  });

  final List<RecordingCardFileLedgerEntry> entries;
  final bool hadMatchingLegacyEvidence;
  final bool alreadySeeded;

  bool get isNewCard => !alreadySeeded && !hadMatchingLegacyEvidence;
}

final class RecordingCardSyncLedgerStore
    implements RecordingCardSyncLedgerPersistencePort {
  RecordingCardSyncLedgerStore({
    required this._database,
    required String accountScope,
  }) : _accountScope = accountScope.trim(),
       _scopeHash = sha256
           .convert(utf8.encode(accountScope.trim()))
           .toString() {
    if (accountScope.trim().isEmpty) {
      throw ArgumentError.value(
        accountScope,
        'accountScope',
        'must not be empty',
      );
    }
  }

  final AppDatabase _database;
  final String _accountScope;
  final String _scopeHash;

  @override
  String get accountScope => _accountScope;

  @override
  List<String> loadKnownCardDigests() {
    final latestByDigest = <String, DateTime>{};
    for (final record in _database.listRecords<LocalDatabaseRecord>(
      LocalTableName.recordingCardFileLedger,
    )) {
      if (record['user_scope'] != _accountScope) continue;
      final digest = _string(record['card_sn_digest']);
      final activityAt = _latestDate(
        _date(record['last_seen_at']),
        _date(record['updated_at']),
      );
      if (digest == null || activityAt == null) continue;
      final previous = latestByDigest[digest];
      if (previous == null || activityAt.isAfter(previous)) {
        latestByDigest[digest] = activityAt;
      }
    }
    for (final record in _database.listRecords<LocalDatabaseRecord>(
      LocalTableName.recordingCardSyncCheckpoints,
    )) {
      if (record['user_scope'] != _accountScope) continue;
      final digest = _string(record['card_sn_digest']);
      final updatedAt = _date(record['updated_at']);
      if (digest == null || updatedAt == null) continue;
      final previous = latestByDigest[digest];
      if (previous == null || updatedAt.isAfter(previous)) {
        latestByDigest[digest] = updatedAt;
      }
    }
    final values = latestByDigest.entries.toList(growable: false)
      ..sort((left, right) {
        final recency = right.value.compareTo(left.value);
        return recency != 0 ? recency : left.key.compareTo(right.key);
      });
    return List<String>.unmodifiable(values.map((entry) => entry.key));
  }

  @override
  String? latestKnownCardSnDigest() => loadKnownCardDigests().firstOrNull;

  @override
  Future<void> flushSyncPersistence() => _database.flushPersistence();

  @override
  List<RecordingCardFileLedgerEntry> loadFileLedger(String cardSnDigest) {
    final digest = _validatedDigest(cardSnDigest);
    final entries =
        _database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.recordingCardFileLedger,
            )
            .where(
              (record) =>
                  record['user_scope'] == _accountScope &&
                  record['card_sn_digest'] == digest,
            )
            .map(_entryFromRecord)
            .whereType<RecordingCardFileLedgerEntry>()
            .toList(growable: false)
          ..sort((left, right) {
            final recorded = _compareNullableDateDescending(
              left.recordedAt,
              right.recordedAt,
            );
            return recorded != 0
                ? recorded
                : left.sourceSignature.compareTo(right.sourceSignature);
          });
    return List<RecordingCardFileLedgerEntry>.unmodifiable(entries);
  }

  @override
  RecordingCardFileLedgerEntry? findFileLedgerEntry({
    required String cardSnDigest,
    required String sourceSignature,
  }) {
    final digest = _validatedDigest(cardSnDigest);
    final signature = _validatedDigest(sourceSignature);
    final record = _database.getRecord<LocalDatabaseRecord>(
      LocalTableName.recordingCardFileLedger,
      _entryKey(digest, signature),
    );
    if (record == null ||
        record['user_scope'] != _accountScope ||
        record['card_sn_digest'] != digest) {
      return null;
    }
    return _entryFromRecord(record);
  }

  @override
  RecordingCardFileLedgerEntry? findFileLedgerEntryByLocalRecordingId(
    String localRecordingId,
  ) {
    final matches = findFileLedgerEntriesByLocalRecordingId(localRecordingId);
    if (matches.length > 1) {
      throw StateError(
        'Multiple recording-card ledger rows reference local recording '
        '${localRecordingId.trim()}',
      );
    }
    return matches.firstOrNull;
  }

  @override
  List<RecordingCardFileLedgerEntry> findFileLedgerEntriesByLocalRecordingId(
    String localRecordingId,
  ) {
    final id = localRecordingId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(localRecordingId, 'localRecordingId');
    }
    final matches =
        _database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.recordingCardFileLedger,
            )
            .where(
              (record) =>
                  record['user_scope'] == _accountScope &&
                  record['local_recording_id'] == id,
            )
            .map(_entryFromRecord)
            .whereType<RecordingCardFileLedgerEntry>()
            .toList(growable: false)
          ..sort((left, right) {
            final card = left.cardSnDigest.compareTo(right.cardSnDigest);
            return card != 0
                ? card
                : left.sourceSignature.compareTo(right.sourceSignature);
          });
    return List<RecordingCardFileLedgerEntry>.unmodifiable(matches);
  }

  @override
  void saveFileLedgerEntry(RecordingCardFileLedgerEntry entry) {
    final record = _entryToRecord(entry);
    _database.upsertRecord(
      LocalTableName.recordingCardFileLedger,
      _entryKey(entry.cardSnDigest, entry.sourceSignature),
      record,
    );
  }

  @override
  void saveFileLedgerEntries(Iterable<RecordingCardFileLedgerEntry> entries) {
    final frozen = entries.toList(growable: false);
    if (frozen.isEmpty) return;
    final result = _database.withTransaction<void>((database) {
      for (final entry in frozen) {
        database.upsertRecord(
          LocalTableName.recordingCardFileLedger,
          _entryKey(entry.cardSnDigest, entry.sourceSignature),
          _entryToRecord(entry),
        );
      }
    });
    _requireTransaction(result, 'save recording-card file ledger');
  }

  @override
  RecordingCardSyncCheckpoint? loadSyncCheckpoint(String cardSnDigest) {
    final digest = _validatedDigest(cardSnDigest);
    final record = _database.getRecord<LocalDatabaseRecord>(
      LocalTableName.recordingCardSyncCheckpoints,
      _checkpointKey(digest),
    );
    if (record == null ||
        record['user_scope'] != _accountScope ||
        record['card_sn_digest'] != digest) {
      return null;
    }
    return _checkpointFromRecord(record);
  }

  @override
  void saveSyncCheckpoint(RecordingCardSyncCheckpoint checkpoint) {
    _database.upsertCheckpointRecord(
      LocalTableName.recordingCardSyncCheckpoints,
      _checkpointKey(checkpoint.cardSnDigest),
      _checkpointToRecord(checkpoint),
    );
  }

  @override
  void commitVerifiedSync({
    required Iterable<RecordingCardFileLedgerEntry> entries,
    required RecordingCardSyncCheckpoint checkpoint,
  }) {
    final digest = _validatedDigest(checkpoint.cardSnDigest);
    final frozen = entries.toList(growable: false);
    if (frozen.any((entry) => entry.cardSnDigest != digest)) {
      throw ArgumentError('Every committed entry must belong to $digest');
    }
    final result = _database.withTransaction<void>((database) {
      for (final entry in frozen) {
        database.upsertRecord(
          LocalTableName.recordingCardFileLedger,
          _entryKey(digest, entry.sourceSignature),
          _entryToRecord(entry),
        );
      }
      database.upsertCheckpointRecord(
        LocalTableName.recordingCardSyncCheckpoints,
        _checkpointKey(digest),
        _checkpointToRecord(checkpoint),
      );
    });
    _requireTransaction(result, 'commit recording-card sync checkpoint');
  }

  @override
  List<RecordingCardFileLedgerEntry> recoverInterruptedEntries({
    required String cardSnDigest,
    required DateTime at,
    required bool Function(RecordingCardFileLedgerEntry entry) localFileExists,
  }) {
    final recovered = <RecordingCardFileLedgerEntry>[];
    for (final entry in loadFileLedger(cardSnDigest)) {
      final next = switch (entry.localState) {
        RecordingCardFileLocalState.syncing => entry.recoverInterrupted(at),
        RecordingCardFileLocalState.synced when !localFileExists(entry) =>
          entry.requeueAfterLocalVerificationFailure(at),
        RecordingCardFileLocalState.deleting => entry.recoverDeleting(
          at: at,
          localFileExists: localFileExists(entry),
        ),
        _ => entry,
      };
      recovered.add(next);
    }
    saveFileLedgerEntries(recovered);
    return List<RecordingCardFileLedgerEntry>.unmodifiable(recovered);
  }

  @override
  RecordingCardLegacySeedResult seedLegacyData({
    required String cardSnDigest,
    required String legacyDeviceFingerprint,
    required List<RecordingCardScannedFile> directoryFiles,
    required DateTime at,
  }) {
    final digest = _validatedDigest(cardSnDigest);
    final existing = loadFileLedger(digest);
    final existingCheckpoint = loadSyncCheckpoint(digest);
    final seedAlreadyCompleted =
        existingCheckpoint != null &&
        (existingCheckpoint.migrationMode !=
                RecordingCardSyncMigrationMode.newDevice ||
            existingCheckpoint.lastDirectoryReadAt != null);
    if (seedAlreadyCompleted) {
      return RecordingCardLegacySeedResult(
        entries: existing,
        hadMatchingLegacyEvidence: false,
        alreadySeeded: true,
      );
    }
    final fingerprint = legacyDeviceFingerprint.trim();
    if (fingerprint.isEmpty) {
      throw ArgumentError.value(
        legacyDeviceFingerprint,
        'legacyDeviceFingerprint',
      );
    }
    final manifests = _database
        .listRecords<LocalDatabaseRecord>(
          LocalTableName.recordingCardDownloadedManifest,
        )
        .where(
          (record) =>
              record['user_scope'] == _accountScope &&
              record['device_fingerprint'] == fingerprint,
        )
        .toList(growable: false);
    final legacyTasks = _database
        .listRecords<LocalDatabaseRecord>(LocalTableName.localTransferRecords)
        .where(
          (record) =>
              record['user_scope'] == _accountScope &&
              record['transfer_kind'] == 'recording_card_auto_sync' &&
              record['device_fingerprint'] == fingerprint,
        )
        .toList(growable: false);
    final hadEvidence = manifests.isNotEmpty || legacyTasks.isNotEmpty;
    if (!hadEvidence) {
      return RecordingCardLegacySeedResult(
        entries: existing,
        hadMatchingLegacyEvidence: false,
        alreadySeeded: false,
      );
    }

    final now = at.toUtc();
    final entriesBySignature = <String, RecordingCardFileLedgerEntry>{
      for (final entry in existing) entry.sourceSignature: entry,
    };
    for (final file in directoryFiles) {
      final signature = RecordingCardFileIdentity.sourceSignatureFor(
        cardSnDigest: digest,
        deviceFileId: file.deviceFileId,
        deviceFilename: file.deviceFilename,
        sizeBytes: file.sizeBytes,
        recordedAt: file.recordedAt,
      );
      final retained = entriesBySignature[signature];
      if (retained != null) {
        entriesBySignature[signature] = retained.seen(
          at: now,
          deviceFileId: file.deviceFileId,
          deviceFilename: file.deviceFilename,
          recordedAt: file.recordedAt,
          sizeBytes: file.sizeBytes,
          durationSeconds: file.durationSeconds,
        );
        continue;
      }
      final manifest = manifests
          .where((record) => _legacyRecordMatchesFile(record, file))
          .firstOrNull;
      final task = legacyTasks
          .where((record) => _legacyRecordMatchesFile(record, file))
          .firstOrNull;
      if (manifest != null) {
        var entry = RecordingCardFileLedgerEntry.discovered(
          cardSnDigest: digest,
          sourceSignature: signature,
          deviceFileId: file.deviceFileId,
          deviceFilename: file.deviceFilename,
          seenAt: now,
          recordedAt: file.recordedAt,
          sizeBytes: file.sizeBytes,
          durationSeconds: file.durationSeconds,
        ).queue(at: now, manual: false);
        final localRecordingId = _string(manifest['local_file_id']);
        final legacyLocalState = _string(manifest['local_state']);
        final isConfirmedLocalDeletion =
            legacyLocalState == RecordingCardFileLocalState.localDeleted.name ||
            (legacyLocalState == RecordingCardFileLocalState.deleting.name &&
                file.syncState != RecordingCardFileSyncState.synced);
        if (localRecordingId != null && isConfirmedLocalDeletion) {
          entry = entry.markSynced(
            at: _date(manifest['downloaded_at']) ?? now,
            localRecordingId: localRecordingId,
            contentHash: _string(manifest['content_hash']),
          );
          entry = entry
              .beginLocalDeletion(_date(manifest['local_deleted_at']) ?? now)
              .finishLocalDeletion(_date(manifest['local_deleted_at']) ?? now);
          entriesBySignature[signature] = entry;
          continue;
        }
        final verifiedLocalRecordingId =
            _verifiedLegacyManifestLocalRecordingId(manifest, file);
        if (verifiedLocalRecordingId != null) {
          entriesBySignature[signature] = entry.markSynced(
            at: _date(manifest['downloaded_at']) ?? now,
            localRecordingId: verifiedLocalRecordingId,
            contentHash: _string(manifest['content_hash']),
          );
          continue;
        }
        entriesBySignature[signature] =
            RecordingCardFileLedgerEntry.legacyUnknown(
              cardSnDigest: digest,
              sourceSignature: signature,
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
              seenAt: now,
              recordedAt: file.recordedAt,
              sizeBytes: file.sizeBytes,
              durationSeconds: file.durationSeconds,
            );
        continue;
      }
      if (task != null) {
        final seeded = _entryFromLegacyTask(
          cardSnDigest: digest,
          sourceSignature: signature,
          file: file,
          task: task,
          at: now,
        );
        entriesBySignature[signature] = seeded;
        continue;
      }
      entriesBySignature[signature] =
          RecordingCardFileLedgerEntry.legacyUnknown(
            cardSnDigest: digest,
            sourceSignature: signature,
            deviceFileId: file.deviceFileId,
            deviceFilename: file.deviceFilename,
            seenAt: now,
            recordedAt: file.recordedAt,
            sizeBytes: file.sizeBytes,
            durationSeconds: file.durationSeconds,
          );
    }
    final entries = entriesBySignature.values.toList(growable: false);

    final latestLegacyTransfer = manifests
        .map((record) => _date(record['downloaded_at']))
        .whereType<DateTime>()
        .fold<DateTime?>(
          null,
          (latest, value) =>
              latest == null || value.isAfter(latest) ? value : latest,
        );
    final latestTransfer = _latestDate(
      existingCheckpoint?.lastTransferCompletedAt,
      latestLegacyTransfer,
    );
    final checkpoint = RecordingCardSyncCheckpoint(
      cardSnDigest: digest,
      lastSuccessfulAutoSyncAt: existingCheckpoint?.lastSuccessfulAutoSyncAt,
      lastTransferCompletedAt: latestTransfer,
      lastDirectoryReadAt: now,
      migrationMode: RecordingCardSyncMigrationMode.legacyData,
      updatedAt: now,
    );
    final result = _database.withTransaction<void>((database) {
      for (final entry in entries) {
        database.upsertRecord(
          LocalTableName.recordingCardFileLedger,
          _entryKey(digest, entry.sourceSignature),
          _entryToRecord(entry),
        );
      }
      database.upsertCheckpointRecord(
        LocalTableName.recordingCardSyncCheckpoints,
        _checkpointKey(digest),
        _checkpointToRecord(checkpoint),
      );
    });
    _requireTransaction(result, 'seed legacy recording-card data');
    return RecordingCardLegacySeedResult(
      entries: List<RecordingCardFileLedgerEntry>.unmodifiable(entries),
      hadMatchingLegacyEvidence: true,
      alreadySeeded: false,
    );
  }

  @override
  RecordingCardFileLedgerEntry queueManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) {
    final current = _requiredEntry(cardSnDigest, sourceSignature);
    final queued = current.queue(at: at, manual: true);
    saveFileLedgerEntry(queued);
    return queued;
  }

  @override
  RecordingCardFileLedgerEntry beginManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) {
    final current = _requiredEntry(cardSnDigest, sourceSignature);
    final queued = current.localState == RecordingCardFileLocalState.queued
        ? current
        : current.queue(at: at, manual: true, resetAttemptCount: true);
    final syncing = queued.beginSync(at);
    saveFileLedgerEntry(syncing);
    return syncing;
  }

  @override
  RecordingCardFileLedgerEntry queueManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  }) => _prepareManualSyncForFile(
    cardSnDigest: cardSnDigest,
    file: file,
    at: at,
    begin: false,
  );

  @override
  RecordingCardFileLedgerEntry beginManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  }) => _prepareManualSyncForFile(
    cardSnDigest: cardSnDigest,
    file: file,
    at: at,
    begin: true,
  );

  RecordingCardFileLedgerEntry _prepareManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
    required bool begin,
  }) {
    final digest = _validatedDigest(cardSnDigest);
    final now = at.toUtc();
    final computedSignature = RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: digest,
      deviceFileId: file.deviceFileId,
      deviceFilename: file.deviceFilename,
      sizeBytes: file.sizeBytes,
      recordedAt: file.recordedAt,
    );
    var existing = findFileLedgerEntry(
      cardSnDigest: digest,
      sourceSignature: computedSignature,
    );
    final contentHash = file.contentHash?.trim().toLowerCase();
    final existingHash = existing?.contentHash?.trim().toLowerCase();
    if (existing != null &&
        contentHash != null &&
        contentHash.isNotEmpty &&
        existingHash != null &&
        existingHash.isNotEmpty &&
        contentHash != existingHash) {
      existing = null;
    }
    if (existing == null && contentHash != null && contentHash.isNotEmpty) {
      final matches = loadFileLedger(digest)
          .where(
            (entry) => entry.contentHash?.trim().toLowerCase() == contentHash,
          )
          .toList(growable: false);
      if (matches.length == 1) existing = matches.single;
    }
    final sourceSignature = existing?.sourceSignature ?? computedSignature;
    final observed =
        (existing ??
                RecordingCardFileLedgerEntry.discovered(
                  cardSnDigest: digest,
                  sourceSignature: sourceSignature,
                  deviceFileId: file.deviceFileId,
                  deviceFilename: file.deviceFilename,
                  seenAt: now,
                  recordedAt: file.recordedAt,
                  sizeBytes: file.sizeBytes,
                  durationSeconds: file.durationSeconds,
                ))
            .seen(
              at: now,
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
              recordedAt: file.recordedAt,
              sizeBytes: file.sizeBytes,
              durationSeconds: file.durationSeconds,
            )
            .confirmCardPresent(now);
    final queued = observed.localState == RecordingCardFileLocalState.queued
        ? observed
        : observed.queue(at: now, manual: true, resetAttemptCount: true);
    final next = begin ? queued.beginSync(now) : queued;
    final result = _database.withTransaction<void>((database) {
      database.upsertRecord(
        LocalTableName.recordingCardFileLedger,
        _entryKey(digest, sourceSignature),
        _entryToRecord(next),
      );
    });
    _requireTransaction(
      result,
      begin
          ? 'begin manual recording-card sync'
          : 'queue manual recording-card sync',
    );
    return next;
  }

  @override
  RecordingCardFileLedgerEntry completeManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required String localRecordingId,
    required DateTime at,
    String? contentHash,
  }) {
    final current = _requiredEntry(cardSnDigest, sourceSignature);
    final normalizedLocalId = localRecordingId.trim();
    final normalizedHash = contentHash == null
        ? null
        : _validatedDigest(contentHash);
    late final RecordingCardFileLedgerEntry synced;
    if (current.localState == RecordingCardFileLocalState.synced) {
      final currentLocalId = current.localRecordingId?.trim();
      final currentHash = current.contentHash?.trim().toLowerCase();
      if (currentLocalId != normalizedLocalId ||
          (currentHash != null &&
              currentHash.isNotEmpty &&
              normalizedHash != null &&
              currentHash != normalizedHash)) {
        throw StateError('Conflicting replay of completed manual sync');
      }
      synced =
          (currentHash == null || currentHash.isEmpty) && normalizedHash != null
          ? current.backfillVerifiedContentHash(
              at: at,
              contentHash: normalizedHash,
            )
          : current;
    } else {
      synced = current.markSynced(
        at: at,
        localRecordingId: normalizedLocalId,
        contentHash: normalizedHash,
        clearContentHashWhenMissing: true,
      );
    }
    final checkpoint =
        (loadSyncCheckpoint(cardSnDigest) ??
                RecordingCardSyncCheckpoint.empty(
                  cardSnDigest: cardSnDigest,
                  at: at,
                ))
            .noteManualTransfer(at);
    commitVerifiedSync(
      entries: <RecordingCardFileLedgerEntry>[synced],
      checkpoint: checkpoint,
    );
    return synced;
  }

  @override
  RecordingCardFileLedgerEntry failManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required String errorCode,
    required RecordingCardSyncRetryability retryability,
    required DateTime at,
  }) {
    final current = _requiredEntry(cardSnDigest, sourceSignature);
    final failed = current.markFailed(
      at: at,
      errorCode: errorCode,
      retryability: retryability,
    );
    saveFileLedgerEntry(failed);
    return failed;
  }

  @override
  RecordingCardFileLedgerEntry beginLocalDeletion({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) {
    final next = _requiredEntry(
      cardSnDigest,
      sourceSignature,
    ).beginLocalDeletion(at);
    saveFileLedgerEntry(next);
    return next;
  }

  @override
  RecordingCardFileLedgerEntry finishLocalDeletion({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) {
    final next = _requiredEntry(
      cardSnDigest,
      sourceSignature,
    ).finishLocalDeletion(at);
    saveFileLedgerEntry(next);
    return next;
  }

  @override
  RecordingCardFileLedgerEntry restoreLocalDeletion({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) {
    final next = _requiredEntry(
      cardSnDigest,
      sourceSignature,
    ).restoreLocalDeletion(at);
    saveFileLedgerEntry(next);
    return next;
  }

  @override
  RecordingCardFileLedgerEntry markCardDeleted({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) {
    final next = _requiredEntry(
      cardSnDigest,
      sourceSignature,
    ).markCardDeleted(at);
    saveFileLedgerEntry(next);
    return next;
  }

  @override
  RecordingCardFileLedgerEntry markCardDeletedForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  }) {
    final digest = _validatedDigest(cardSnDigest);
    final now = at.toUtc();
    final computedSignature = RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: digest,
      deviceFileId: file.deviceFileId,
      deviceFilename: file.deviceFilename,
      sizeBytes: file.sizeBytes,
      recordedAt: file.recordedAt,
    );
    var existing = findFileLedgerEntry(
      cardSnDigest: digest,
      sourceSignature: computedSignature,
    );
    final contentHash = file.contentHash?.trim().toLowerCase();
    if (existing == null && contentHash != null && contentHash.isNotEmpty) {
      final matches = loadFileLedger(digest)
          .where(
            (entry) => entry.contentHash?.trim().toLowerCase() == contentHash,
          )
          .toList(growable: false);
      if (matches.length == 1) existing = matches.single;
    }
    final sourceSignature = existing?.sourceSignature ?? computedSignature;
    final deleted =
        (existing ??
                RecordingCardFileLedgerEntry.discovered(
                  cardSnDigest: digest,
                  sourceSignature: sourceSignature,
                  deviceFileId: file.deviceFileId,
                  deviceFilename: file.deviceFilename,
                  seenAt: now,
                  recordedAt: file.recordedAt,
                  sizeBytes: file.sizeBytes,
                  durationSeconds: file.durationSeconds,
                ))
            .seen(
              at: now,
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
              recordedAt: file.recordedAt,
              sizeBytes: file.sizeBytes,
              durationSeconds: file.durationSeconds,
            )
            .markCardDeleted(now);
    final result = _database.withTransaction<void>((database) {
      database.upsertRecord(
        LocalTableName.recordingCardFileLedger,
        _entryKey(digest, sourceSignature),
        _entryToRecord(deleted),
      );
    });
    _requireTransaction(result, 'mark recording-card source deleted');
    return deleted;
  }

  RecordingCardFileLedgerEntry _requiredEntry(
    String cardSnDigest,
    String sourceSignature,
  ) {
    final entry = findFileLedgerEntry(
      cardSnDigest: cardSnDigest,
      sourceSignature: sourceSignature,
    );
    if (entry == null) {
      throw StateError('Recording-card file ledger entry does not exist');
    }
    return entry;
  }

  RecordingCardFileLedgerEntry _entryFromLegacyTask({
    required String cardSnDigest,
    required String sourceSignature,
    required RecordingCardScannedFile file,
    required LocalDatabaseRecord task,
    required DateTime at,
  }) {
    var entry = RecordingCardFileLedgerEntry.discovered(
      cardSnDigest: cardSnDigest,
      sourceSignature: sourceSignature,
      deviceFileId: file.deviceFileId,
      deviceFilename: file.deviceFilename,
      seenAt: at,
      recordedAt: file.recordedAt,
      sizeBytes: file.sizeBytes,
      durationSeconds: file.durationSeconds,
    ).queue(at: at, manual: false);
    final stage = _string(task['stage']);
    final localRecordingId = _string(task['local_recording_id']);
    if (localRecordingId != null &&
        const <String>{
          'downloaded',
          'transcribing',
          'completed',
        }.contains(stage)) {
      return entry.markSynced(
        at: _date(task['updated_at']) ?? at,
        localRecordingId: localRecordingId,
        contentHash: _string(task['content_hash']),
      );
    }
    if (stage == 'failed') {
      final errorCode =
          _string(task['error_code']) ?? 'RECORDING_CARD_LEGACY_SYNC_FAILED';
      final retryability = _legacyRetryability(errorCode);
      entry = entry.markFailed(
        at: _date(task['updated_at']) ?? at,
        errorCode: errorCode,
        retryability: retryability,
        nextRetryAt: retryability == RecordingCardSyncRetryability.transient
            ? at
            : null,
      );
    }
    return entry;
  }

  String _entryKey(String cardSnDigest, String sourceSignature) =>
      '$_scopeHash:${_validatedDigest(cardSnDigest)}:${_validatedDigest(sourceSignature)}';

  String _checkpointKey(String cardSnDigest) =>
      '$_scopeHash:${_validatedDigest(cardSnDigest)}';

  LocalDatabaseRecord _entryToRecord(RecordingCardFileLedgerEntry entry) {
    final cardDigest = _validatedDigest(entry.cardSnDigest);
    final sourceSignature = _validatedDigest(entry.sourceSignature);
    return <String, Object?>{
      'user_scope': _accountScope,
      'card_sn_digest': cardDigest,
      'source_signature': sourceSignature,
      'device_file_id': _bounded(entry.deviceFileId, 200),
      'device_filename': _bounded(entry.deviceFilename, 240),
      if (entry.recordedAt != null)
        'recorded_at': entry.recordedAt!.toUtc().toIso8601String(),
      if (entry.sizeBytes != null) 'size_bytes': entry.sizeBytes,
      if (entry.durationSeconds != null)
        'duration_seconds': entry.durationSeconds,
      if (entry.contentHash != null)
        'content_hash': _bounded(entry.contentHash!, 160),
      if (entry.localRecordingId != null)
        'local_recording_id': _bounded(entry.localRecordingId!, 200),
      'local_state': entry.localState.name,
      'card_state': entry.cardState.name,
      if (entry.lastSyncedAt != null)
        'last_synced_at': entry.lastSyncedAt!.toUtc().toIso8601String(),
      if (entry.localDeletedAt != null)
        'local_deleted_at': entry.localDeletedAt!.toUtc().toIso8601String(),
      'last_seen_at': entry.lastSeenAt.toUtc().toIso8601String(),
      if (entry.errorCode != null)
        'error_code': _bounded(entry.errorCode!, 160),
      if (entry.retryability != null) 'retryability': entry.retryability!.name,
      'attempt_count': entry.attemptCount < 0 ? 0 : entry.attemptCount,
      if (entry.nextRetryAt != null)
        'next_retry_at': entry.nextRetryAt!.toUtc().toIso8601String(),
      if (entry.plannedNativeFileId != null)
        'planned_native_file_id': entry.plannedNativeFileId,
      if (entry.syncOrigin != null) 'sync_origin': entry.syncOrigin!.name,
      'resume_requested': entry.resumeRequested,
      'updated_at': entry.updatedAt.toUtc().toIso8601String(),
    };
  }

  RecordingCardFileLedgerEntry? _entryFromRecord(LocalDatabaseRecord record) {
    final cardDigest = record['card_sn_digest'];
    final sourceSignature = record['source_signature'];
    final deviceFileId = record['device_file_id'];
    final filename = record['device_filename'];
    final localState = _enumByName(
      RecordingCardFileLocalState.values,
      record['local_state'],
    );
    final cardState = _enumByName(
      RecordingCardFilePresenceState.values,
      record['card_state'],
    );
    final lastSeenAt = _date(record['last_seen_at']);
    final updatedAt = _date(record['updated_at']);
    if (cardDigest is! String ||
        sourceSignature is! String ||
        deviceFileId is! String ||
        filename is! String ||
        localState == null ||
        cardState == null ||
        lastSeenAt == null ||
        updatedAt == null) {
      return null;
    }
    return RecordingCardFileLedgerEntry(
      cardSnDigest: cardDigest,
      sourceSignature: sourceSignature,
      deviceFileId: deviceFileId,
      deviceFilename: filename,
      recordedAt: _date(record['recorded_at']),
      sizeBytes: _int(record['size_bytes']),
      durationSeconds: _int(record['duration_seconds']),
      contentHash: _string(record['content_hash']),
      localRecordingId: _string(record['local_recording_id']),
      localState: localState,
      cardState: cardState,
      lastSyncedAt: _date(record['last_synced_at']),
      localDeletedAt: _date(record['local_deleted_at']),
      lastSeenAt: lastSeenAt,
      errorCode: _string(record['error_code']),
      retryability: _enumByName(
        RecordingCardSyncRetryability.values,
        record['retryability'],
      ),
      attemptCount: _int(record['attempt_count']) ?? 0,
      nextRetryAt: _date(record['next_retry_at']),
      plannedNativeFileId: _plannedNativeFileId(
        record['planned_native_file_id'],
      ),
      syncOrigin: _enumByName(
        RecordingCardSyncOrigin.values,
        record['sync_origin'],
      ),
      resumeRequested:
          _bool(record['resume_requested']) ??
          (localState == RecordingCardFileLocalState.queued ||
              localState == RecordingCardFileLocalState.syncing),
      updatedAt: updatedAt,
    );
  }

  LocalDatabaseRecord _checkpointToRecord(
    RecordingCardSyncCheckpoint checkpoint,
  ) => <String, Object?>{
    'user_scope': _accountScope,
    'card_sn_digest': _validatedDigest(checkpoint.cardSnDigest),
    if (checkpoint.lastSuccessfulAutoSyncAt != null)
      'last_successful_auto_sync_at': checkpoint.lastSuccessfulAutoSyncAt!
          .toUtc()
          .toIso8601String(),
    if (checkpoint.lastTransferCompletedAt != null)
      'last_transfer_completed_at': checkpoint.lastTransferCompletedAt!
          .toUtc()
          .toIso8601String(),
    if (checkpoint.lastDirectoryReadAt != null)
      'last_directory_read_at': checkpoint.lastDirectoryReadAt!
          .toUtc()
          .toIso8601String(),
    if (checkpoint.committedThroughRecordedAt != null)
      'committed_through_recorded_at': checkpoint.committedThroughRecordedAt!
          .toUtc()
          .toIso8601String(),
    if (checkpoint.committedSnapshotHash != null)
      'committed_snapshot_hash': _validatedDigest(
        checkpoint.committedSnapshotHash!,
      ),
    'migration_mode': checkpoint.migrationMode.name,
    'updated_at': checkpoint.updatedAt.toUtc().toIso8601String(),
  };

  RecordingCardSyncCheckpoint? _checkpointFromRecord(
    LocalDatabaseRecord record,
  ) {
    final cardDigest = record['card_sn_digest'];
    final migrationMode = _enumByName(
      RecordingCardSyncMigrationMode.values,
      record['migration_mode'],
    );
    final updatedAt = _date(record['updated_at']);
    if (cardDigest is! String || migrationMode == null || updatedAt == null) {
      return null;
    }
    return RecordingCardSyncCheckpoint(
      cardSnDigest: cardDigest,
      lastSuccessfulAutoSyncAt: _date(record['last_successful_auto_sync_at']),
      lastTransferCompletedAt: _date(record['last_transfer_completed_at']),
      lastDirectoryReadAt: _date(record['last_directory_read_at']),
      committedThroughRecordedAt: _date(
        record['committed_through_recorded_at'],
      ),
      committedSnapshotHash: _string(record['committed_snapshot_hash']),
      migrationMode: migrationMode,
      updatedAt: updatedAt,
    );
  }
}

void _requireTransaction(LocalDatabaseResult<void> result, String operation) {
  if (result.ok) return;
  throw StateError('$operation failed: ${result.error?.code ?? 'unknown'}');
}

T? _enumByName<T extends Enum>(Iterable<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return null;
}

DateTime? _date(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

int? _int(Object? raw) => switch (raw) {
  int value => value,
  num value => value.toInt(),
  String value => int.tryParse(value),
  _ => null,
};

String? _string(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

bool? _bool(Object? raw) => switch (raw) {
  bool value => value,
  int value when value == 0 || value == 1 => value == 1,
  String value when value.toLowerCase() == 'true' => true,
  String value when value.toLowerCase() == 'false' => false,
  _ => null,
};

String? _plannedNativeFileId(Object? raw) {
  final normalized = _string(raw)?.toLowerCase();
  return normalized != null &&
          RegExp(r'^card-[a-f0-9]{32}$').hasMatch(normalized)
      ? normalized
      : null;
}

String _validatedDigest(String value) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'digest');
  }
  return normalized;
}

String _bounded(String value, int maximum) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, 'value');
  return normalized.length <= maximum
      ? normalized
      : normalized.substring(0, maximum);
}

int _compareNullableDateDescending(DateTime? left, DateTime? right) {
  if (left == null && right == null) return 0;
  if (left == null) return 1;
  if (right == null) return -1;
  return right.compareTo(left);
}

DateTime? _latestDate(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return left.isAfter(right) ? left : right;
}

bool _legacyRecordMatchesFile(
  LocalDatabaseRecord record,
  RecordingCardScannedFile file,
) {
  if (record['device_file_id'] != file.deviceFileId) return false;
  final filename = _string(record['device_filename']);
  if (filename != null && filename != file.deviceFilename) return false;
  final recordedSize = _int(
    record['expected_size_bytes'] ?? record['actual_size_bytes'],
  );
  return recordedSize == null ||
      recordedSize <= 0 ||
      file.sizeBytes == null ||
      recordedSize == file.sizeBytes;
}

String? _verifiedLegacyManifestLocalRecordingId(
  LocalDatabaseRecord manifest,
  RecordingCardScannedFile file,
) {
  final localRecordingId = _string(manifest['local_file_id']);
  final manifestUri = _string(manifest['app_private_uri']);
  final fileUri = _string(file.appPrivateUri);
  final actualSizeBytes = _int(manifest['actual_size_bytes']);
  if (file.syncState != RecordingCardFileSyncState.synced ||
      localRecordingId == null ||
      file.localFileId != localRecordingId ||
      manifestUri == null ||
      fileUri != manifestUri ||
      actualSizeBytes == null ||
      actualSizeBytes <= 0 ||
      file.sizeBytes != actualSizeBytes) {
    return null;
  }

  final rawManifestHash = manifest['content_hash'];
  final rawFileHash = file.contentHash;
  final manifestHash = _legacyContentHash(rawManifestHash);
  final fileHash = _legacyContentHash(rawFileHash);
  if ((rawManifestHash != null && manifestHash == null) ||
      (rawFileHash != null && fileHash == null) ||
      (manifestHash != null && fileHash != null && manifestHash != fileHash)) {
    return null;
  }
  return localRecordingId;
}

String? _legacyContentHash(Object? raw) {
  if (raw is! String) return null;
  final normalized = raw.trim().toLowerCase();
  return RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized) ? normalized : null;
}

RecordingCardSyncRetryability _legacyRetryability(String errorCode) {
  final normalized = errorCode.toUpperCase();
  const transientMarkers = <String>[
    'BUSY',
    'TIMEOUT',
    'NETWORK',
    'DISCONNECT',
    'UNAVAILABLE',
    'CANCEL',
  ];
  return transientMarkers.any(normalized.contains)
      ? RecordingCardSyncRetryability.transient
      : RecordingCardSyncRetryability.permanent;
}
