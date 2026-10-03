import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'app_database.dart';

final class RecordingDao {
  RecordingDao(this._database, {String? userScope})
    : _userScope = _normalizeOptionalUserScope(userScope);

  final AppDatabase _database;
  final String? _userScope;

  static const recordingCardWifiBatchKind = 'recording_card_wifi_batch';
  static final _canonicalRecordingCardSerialIdentity = RegExp(
    r'^serial:[A-Z0-9]{6,64}$',
  );

  String? get userScope => _userScope;

  bool get isUserScoped => _userScope != null;

  LocalDatabaseRecord _ownedRecord(LocalDatabaseRecord record) {
    final scope = _userScope;
    if (scope == null) return record;
    final owner = record['user_scope'];
    if (owner != null && owner != scope) {
      throw StateError('Recording metadata owner mismatch');
    }
    return <String, Object?>{...record, 'user_scope': scope};
  }

  void _upsert(
    LocalTableName table,
    String logicalKey,
    LocalDatabaseRecord record, {
    bool checkpointOnly = false,
  }) {
    final key = _storageKey(table, logicalKey);
    final owned = _ownedRecord(record);
    if (checkpointOnly) {
      _database.upsertCheckpointRecord(table, key, owned);
    } else {
      _database.upsertRecord(table, key, owned);
    }
  }

  LocalDatabaseRecord? _get(LocalTableName table, String logicalKey) {
    final record = _database.getRecord<LocalDatabaseRecord>(
      table,
      _storageKey(table, logicalKey),
    );
    return _isOwned(record) ? record : null;
  }

  List<LocalDatabaseRecord> _list(LocalTableName table) {
    return _database
        .listRecords<LocalDatabaseRecord>(table)
        .where(_isOwned)
        .toList(growable: false);
  }

  bool _isOwned(LocalDatabaseRecord? record) {
    if (record == null) return false;
    final scope = _userScope;
    return scope == null || record['user_scope'] == scope;
  }

  bool _delete(LocalTableName table, String logicalKey) {
    return _database.deleteRecord(table, _storageKey(table, logicalKey));
  }

  String _storageKey(LocalTableName table, String logicalKey) {
    final scope = _userScope;
    if (scope == null) return logicalKey;
    return 'recording:${_encode(scope)}:${table.dbName}:${_encode(logicalKey)}';
  }

  void upsertLocalRecording(String id, LocalDatabaseRecord record) {
    _upsert(LocalTableName.localRecordings, id, record);
  }

  LocalDatabaseRecord? getLocalRecording(String id) {
    return _get(LocalTableName.localRecordings, id);
  }

  List<LocalDatabaseRecord> listLocalRecordings() {
    return _list(LocalTableName.localRecordings);
  }

  void upsertTag(String id, LocalDatabaseRecord record) {
    _upsert(LocalTableName.localRecordingTags, id, record);
  }

  void replaceTagLinks(String recordingId, List<String> tagIds, String at) {
    _deleteWhere(LocalTableName.localRecordingTagLinks, (record) {
      return record['recording_id'] == recordingId;
    });
    for (final tagId in tagIds) {
      _upsert(
        LocalTableName.localRecordingTagLinks,
        '$recordingId:$tagId',
        <String, Object?>{
          'recording_id': recordingId,
          'tag_id': tagId,
          'created_at': at,
        },
      );
    }
  }

  void upsertTrash({
    required String recordingId,
    required String deletedAt,
    required String retentionUntil,
  }) {
    _upsert(LocalTableName.localRecordingTrash, recordingId, <String, Object?>{
      'recording_id': recordingId,
      'deleted_at': deletedAt,
      'retention_until': retentionUntil,
    });
  }

  void deleteTrash(String recordingId) {
    _delete(LocalTableName.localRecordingTrash, recordingId);
  }

  void upsertUploadDraft({
    required String draftId,
    required String localFileId,
    required String stage,
    required String updatedAt,
  }) {
    _upsert(
      LocalTableName.localRecordingUploadDrafts,
      draftId,
      <String, Object?>{
        'draft_id': draftId,
        'local_file_id': localFileId,
        'stage': stage,
        'updated_at': updatedAt,
      },
    );
  }

  void upsertUploadDraftRecord(String draftId, LocalDatabaseRecord record) {
    _upsert(LocalTableName.localRecordingUploadDrafts, draftId, record);
  }

  LocalDatabaseRecord? getUploadDraftRecord(String draftId) {
    return _get(LocalTableName.localRecordingUploadDrafts, draftId);
  }

  List<LocalDatabaseRecord> listUploadDraftRecords() {
    return _list(LocalTableName.localRecordingUploadDrafts);
  }

  bool deleteUploadDraftRecord(String draftId) {
    return _delete(LocalTableName.localRecordingUploadDrafts, draftId);
  }

  void upsertDeviceLocalMapping({
    required String deviceId,
    required String deviceFileKey,
    required String localRecordingId,
    required String syncStatus,
    required String updatedAt,
  }) {
    _upsert(
      LocalTableName.deviceLocalRecordingMappings,
      '$deviceId:$deviceFileKey',
      <String, Object?>{
        'device_id': deviceId,
        'device_file_key': deviceFileKey,
        'local_recording_id': localRecordingId,
        'sync_status': syncStatus,
        'updated_at': updatedAt,
      },
    );
  }

  void upsertDownloadedManifest({
    required String deviceFileId,
    required String deviceFingerprint,
    required String deviceFilename,
    required String localFileId,
    required String appPrivateUri,
    required int expectedSizeBytes,
    required int actualSizeBytes,
    required int durationSeconds,
    required String? contentHash,
    required String downloadedAt,
    required String updatedAt,
  }) {
    _upsert(
      LocalTableName.recordingCardDownloadedManifest,
      _recordingCardManifestKey(deviceFingerprint, deviceFileId),
      <String, Object?>{
        'device_file_id': deviceFileId,
        'device_fingerprint': deviceFingerprint,
        'device_filename': deviceFilename,
        'local_file_id': localFileId,
        'app_private_uri': appPrivateUri,
        'expected_size_bytes': expectedSizeBytes,
        'actual_size_bytes': actualSizeBytes,
        'duration_seconds': durationSeconds,
        if (contentHash != null) 'content_hash': contentHash,
        'downloaded_at': downloadedAt,
        'local_state': 'synced',
        'updated_at': updatedAt,
      },
    );
  }

  void upsertDownloadedManifestRecord(LocalDatabaseRecord record) {
    final logicalKey = _downloadedManifestRecordKey(record);
    if (logicalKey == null) {
      throw ArgumentError.value(
        record,
        'record',
        'missing downloaded manifest id',
      );
    }
    _upsert(LocalTableName.recordingCardDownloadedManifest, logicalKey, record);
  }

  List<LocalDatabaseRecord> listUploadDraftsFor(String localFileId) {
    return _list(LocalTableName.localRecordingUploadDrafts)
        .where((record) => record['local_file_id'] == localFileId)
        .toList(growable: false);
  }

  List<LocalDatabaseRecord> listDownloadedManifestsFor(String localFileId) {
    return _list(LocalTableName.recordingCardDownloadedManifest)
        .where((record) => record['local_file_id'] == localFileId)
        .toList(growable: false);
  }

  List<LocalDatabaseRecord> listDeviceLocalMappings() {
    return _list(LocalTableName.deviceLocalRecordingMappings);
  }

  List<LocalDatabaseRecord> listDownloadedManifests() {
    return _list(LocalTableName.recordingCardDownloadedManifest);
  }

  int updateDownloadedManifestLocalState({
    required String localFileId,
    required String localState,
    required String updatedAt,
    String? localDeletedAt,
  }) {
    if (!const <String>{
      'synced',
      'deleting',
      'localDeleted',
    }.contains(localState)) {
      throw ArgumentError.value(localState, 'localState');
    }
    final records = listDownloadedManifestsFor(localFileId);
    for (final record in records) {
      upsertDownloadedManifestRecord(<String, Object?>{
        ...record,
        'local_state': localState,
        'local_deleted_at': localState == 'localDeleted'
            ? localDeletedAt ?? updatedAt
            : null,
        'updated_at': updatedAt,
      });
    }
    return records.length;
  }

  void upsertRecordingCardWifiBatchItem({
    required String transferId,
    required String batchId,
    required String deviceFingerprint,
    required String deviceIdentity,
    required String deviceFileId,
    required String deviceFilename,
    required String localFileKey,
    required int itemOrder,
    required int expectedSizeBytes,
    required int attemptCount,
    required String batchStage,
    required String stage,
    required String idempotencyKey,
    required String createdAt,
    required String updatedAt,
    String? cardSnDigest,
    String? ledgerSourceSignature,
    String? batchErrorCode,
    String? errorCode,
    String? localRecordingId,
    String? fileFormat,
    String? mimeType,
    int? durationSeconds,
    String? recordedAt,
    String? contentHash,
    String? stagedNativeFileId,
    String? sourceSizeConfidence,
    String? plannedNativeFileId,
    String? attemptId,
    bool stopRequested = false,
    String? stagedFileFormat,
    int? stagedSizeBytes,
    String? stagedContentHash,
    bool checkpointOnly = false,
    bool allowLegacyIdentityUpgrade = false,
  }) {
    if (plannedNativeFileId != null &&
        !RegExp(r'^card-[a-f0-9]{32}$').hasMatch(plannedNativeFileId)) {
      throw ArgumentError('Invalid Wi-Fi download intent');
    }
    if (attemptId != null &&
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(attemptId)) {
      throw ArgumentError('Invalid Wi-Fi attempt identity');
    }
    final hasStagedMetadata =
        stagedNativeFileId != null ||
        stagedFileFormat != null ||
        stagedSizeBytes != null ||
        stagedContentHash != null;
    if (contentHash != null && !_sha256Hash.hasMatch(contentHash)) {
      throw ArgumentError('Invalid recording-card source content hash');
    }
    if (cardSnDigest != null && !_sha256Hash.hasMatch(cardSnDigest)) {
      throw ArgumentError('Invalid recording-card card digest');
    }
    if (ledgerSourceSignature != null &&
        !_sha256Hash.hasMatch(ledgerSourceSignature)) {
      throw ArgumentError('Invalid recording-card ledger source signature');
    }
    if (hasStagedMetadata &&
        (stagedNativeFileId == null ||
            !_recordingCardStagedFileId.hasMatch(stagedNativeFileId) ||
            stagedFileFormat == null ||
            !_recordingCardStagedFormats.contains(stagedFileFormat) ||
            stagedSizeBytes == null ||
            stagedSizeBytes <= 0 ||
            stagedContentHash == null ||
            !_sha256Hash.hasMatch(stagedContentHash))) {
      throw ArgumentError('Invalid recording-card staged metadata');
    }
    if (contentHash != null &&
        stagedContentHash != null &&
        contentHash != stagedContentHash) {
      throw ArgumentError('Recording-card source and staged hashes conflict');
    }
    final existing = _get(LocalTableName.localTransferRecords, transferId);
    if (existing != null) {
      final legacyIdentityUpgrade = _isLegacyWifiIdentityUpgrade(
        existing: existing,
        allowUpgrade: allowLegacyIdentityUpgrade,
        batchId: batchId,
        deviceFingerprint: deviceFingerprint,
        deviceIdentity: deviceIdentity,
        cardSnDigest: cardSnDigest,
        deviceFileId: deviceFileId,
        idempotencyKey: idempotencyKey,
        ledgerSourceSignature: ledgerSourceSignature,
      );
      final legacyBlankDigestUpgrade = _isLegacyBlankWifiDigestUpgrade(
        existing: existing,
        allowUpgrade: allowLegacyIdentityUpgrade,
        batchId: batchId,
        deviceFingerprint: deviceFingerprint,
        deviceIdentity: deviceIdentity,
        cardSnDigest: cardSnDigest,
        deviceFileId: deviceFileId,
      );
      final immutableIdentity = <String, Object?>{
        'transfer_kind': recordingCardWifiBatchKind,
        'batch_id': batchId,
        'device_fingerprint': deviceFingerprint,
        'device_identity': deviceIdentity,
        if (cardSnDigest != null) 'card_sn_digest': cardSnDigest,
        'device_file_id': deviceFileId,
        'device_filename': deviceFilename,
        'local_file_key': localFileKey,
        'item_order': itemOrder < 0 ? 0 : itemOrder,
        'idempotency_key': idempotencyKey,
        'file_format': fileFormat,
        'content_hash': contentHash,
        if (ledgerSourceSignature != null)
          'ledger_source_signature': ledgerSourceSignature,
      };
      final verifiedFormatUpgrade =
          existing['file_format'] == 'unknown' &&
          _recordingCardStagedFormats.contains(fileFormat) &&
          existing['staged_file_format'] == fileFormat &&
          existing['staged_size_bytes'] == expectedSizeBytes &&
          existing['staged_content_hash'] != null &&
          existing['staged_content_hash'] == contentHash &&
          stage == 'completed' &&
          localRecordingId != null &&
          localRecordingId.trim().isNotEmpty;
      for (final entry in immutableIdentity.entries) {
        final previous = existing[entry.key];
        if (previous != null && previous != entry.value) {
          if (entry.key == 'file_format' && verifiedFormatUpgrade) {
            continue;
          }
          if (legacyIdentityUpgrade &&
              (entry.key == 'device_identity' ||
                  entry.key == 'idempotency_key')) {
            continue;
          }
          if (legacyBlankDigestUpgrade && entry.key == 'card_sn_digest') {
            continue;
          }
          throw StateError('Recording-card transfer identity conflict');
        }
      }
    }
    final record = <String, Object?>{
      'transfer_id': transferId,
      'transfer_kind': recordingCardWifiBatchKind,
      'batch_id': batchId,
      'device_fingerprint': deviceFingerprint,
      'device_identity': deviceIdentity,
      if (cardSnDigest != null) 'card_sn_digest': cardSnDigest,
      'device_file_id': deviceFileId,
      'device_filename': deviceFilename,
      'local_file_key': localFileKey,
      'item_order': itemOrder < 0 ? 0 : itemOrder,
      'expected_size_bytes': expectedSizeBytes < 0 ? 0 : expectedSizeBytes,
      'attempt_count': attemptCount < 0 ? 0 : attemptCount,
      'batch_stage': batchStage,
      if (sourceSizeConfidence == 'trusted' ||
          sourceSizeConfidence == 'suspect')
        'source_size_confidence': sourceSizeConfidence,
      if (plannedNativeFileId != null)
        'planned_native_file_id': plannedNativeFileId,
      if (attemptId != null) 'attempt_id': attemptId,
      'stop_requested': stopRequested || existing?['stop_requested'] == true,
      'stage': stage,
      if (batchErrorCode != null) 'batch_error_code': batchErrorCode,
      if (errorCode != null) 'error_code': errorCode,
      if (localRecordingId != null) 'local_recording_id': localRecordingId,
      if (fileFormat != null) 'file_format': fileFormat,
      if (mimeType != null) 'mime_type': mimeType,
      if (durationSeconds != null)
        'duration_seconds': durationSeconds < 0 ? 0 : durationSeconds,
      if (recordedAt != null) 'recorded_at': recordedAt,
      if (contentHash != null) 'content_hash': contentHash,
      if (ledgerSourceSignature != null)
        'ledger_source_signature': ledgerSourceSignature,
      if (hasStagedMetadata) 'staged_native_file_id': stagedNativeFileId,
      if (hasStagedMetadata) 'staged_file_format': stagedFileFormat,
      if (hasStagedMetadata) 'staged_size_bytes': stagedSizeBytes,
      if (hasStagedMetadata) 'staged_content_hash': stagedContentHash,
      'idempotency_key': idempotencyKey,
      'created_at': existing?['created_at'] ?? createdAt,
      'updated_at': updatedAt,
    };
    if (checkpointOnly) {
      _upsert(
        LocalTableName.localTransferRecords,
        transferId,
        record,
        checkpointOnly: true,
      );
    } else {
      _upsert(LocalTableName.localTransferRecords, transferId, record);
    }
  }

  bool _isLegacyWifiIdentityUpgrade({
    required LocalDatabaseRecord existing,
    required bool allowUpgrade,
    required String batchId,
    required String deviceFingerprint,
    required String deviceIdentity,
    required String? cardSnDigest,
    required String deviceFileId,
    required String idempotencyKey,
    required String? ledgerSourceSignature,
  }) {
    if (!allowUpgrade ||
        existing['batch_id'] != batchId ||
        existing['device_fingerprint'] != deviceFingerprint ||
        existing['device_identity'] != deviceFingerprint ||
        existing['card_sn_digest'] != null ||
        existing['ledger_source_signature'] != null ||
        existing['device_file_id'] != deviceFileId ||
        !_canonicalRecordingCardSerialIdentity.hasMatch(deviceIdentity) ||
        cardSnDigest == null ||
        ledgerSourceSignature == null) {
      return false;
    }
    final serialNumber = deviceIdentity.substring('serial:'.length);
    if (serialNumber.isEmpty ||
        sha256.convert(utf8.encode(serialNumber)).toString() != cardSnDigest) {
      return false;
    }
    final previousIdempotency = sha256
        .convert(utf8.encode('$deviceFingerprint:$deviceFileId:$batchId'))
        .toString();
    final upgradedIdempotency = sha256
        .convert(utf8.encode('$deviceIdentity:$deviceFileId:$batchId'))
        .toString();
    return existing['idempotency_key'] == previousIdempotency &&
        idempotencyKey == upgradedIdempotency;
  }

  bool _isLegacyBlankWifiDigestUpgrade({
    required LocalDatabaseRecord existing,
    required bool allowUpgrade,
    required String batchId,
    required String deviceFingerprint,
    required String deviceIdentity,
    required String? cardSnDigest,
    required String deviceFileId,
  }) {
    final previousDigest = existing['card_sn_digest'];
    if (!allowUpgrade ||
        existing['transfer_kind'] != recordingCardWifiBatchKind ||
        existing['batch_id'] != batchId ||
        existing['device_fingerprint'] != deviceFingerprint ||
        existing['device_identity'] != deviceIdentity ||
        existing['device_file_id'] != deviceFileId ||
        previousDigest is! String ||
        previousDigest.trim().isNotEmpty ||
        !_canonicalRecordingCardSerialIdentity.hasMatch(deviceIdentity) ||
        cardSnDigest == null) {
      return false;
    }
    final serialNumber = deviceIdentity.substring('serial:'.length);
    return sha256.convert(utf8.encode(serialNumber)).toString() == cardSnDigest;
  }

  LocalDatabaseResult<void> writeRecordingCardWifiBatchAtomically(
    void Function() action,
  ) {
    return _database.withTransaction<void>((_) => action());
  }

  List<LocalDatabaseRecord> listRecordingCardWifiBatchItems({String? batchId}) {
    final rows =
        _list(LocalTableName.localTransferRecords)
            .where(
              (record) =>
                  record['transfer_kind'] == recordingCardWifiBatchKind &&
                  (batchId == null || record['batch_id'] == batchId),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final batchOrder = '${left['batch_id']}'.compareTo(
              '${right['batch_id']}',
            );
            if (batchOrder != 0) return batchOrder;
            return _recordInt(
              left['item_order'],
            ).compareTo(_recordInt(right['item_order']));
          });
    return List<LocalDatabaseRecord>.unmodifiable(rows);
  }

  void stopInvalidRecordingCardWifiBatch(String batchId) {
    for (final record in listRecordingCardWifiBatchItems(batchId: batchId)) {
      final transferId = record['transfer_id'];
      if (transferId is! String) continue;
      _upsert(LocalTableName.localTransferRecords, transferId, {
        ...record,
        'stop_requested': true,
        'batch_stage': 'cancelled',
      });
    }
  }

  void deleteRecordingCardWifiBatch(String batchId) {
    _deleteWhere(LocalTableName.localTransferRecords, (record) {
      return record['transfer_kind'] == recordingCardWifiBatchKind &&
          record['batch_id'] == batchId;
    });
  }

  void deleteRecordingCardWifiBatchItem(String transferId) {
    final record = _get(LocalTableName.localTransferRecords, transferId);
    if (record?['transfer_kind'] == recordingCardWifiBatchKind) {
      _delete(LocalTableName.localTransferRecords, transferId);
    }
  }

  void upsertPlaybackPosition({
    required String recordingId,
    required int positionSeconds,
    required String updatedAt,
  }) {
    _upsert(
      LocalTableName.localRecordingPlayback,
      recordingId,
      <String, Object?>{
        'recording_id': recordingId,
        'position_seconds': positionSeconds < 0 ? 0 : positionSeconds,
        'updated_at': updatedAt,
      },
    );
  }

  int? getPlaybackPositionSeconds(String recordingId) {
    final record = _get(LocalTableName.localRecordingPlayback, recordingId);
    final value = record?['position_seconds'];
    if (value is int) return value < 0 ? 0 : value;
    if (value is num) return value < 0 ? 0 : value.floor();
    if (value is String) {
      final parsed = int.tryParse(value);
      return parsed == null || parsed < 0 ? null : parsed;
    }
    return null;
  }

  void deletePlaybackPosition(String recordingId) {
    _delete(LocalTableName.localRecordingPlayback, recordingId);
  }

  void purgeRelatedMetadata(
    String recordingId, {
    bool preserveDeviceHistory = false,
    bool preserveUploadDrafts = false,
  }) {
    final linkedTagIds = _list(LocalTableName.localRecordingTagLinks)
        .where((record) => record['recording_id'] == recordingId)
        .map((record) => record['tag_id']?.toString())
        .whereType<String>()
        .toSet();
    _delete(LocalTableName.localRecordings, recordingId);
    _delete(LocalTableName.localRecordingTrash, recordingId);
    _deleteWhere(LocalTableName.localRecordingTagLinks, (record) {
      return record['recording_id'] == recordingId;
    });
    _deleteOrphanTags(linkedTagIds);
    _deleteWhere(LocalTableName.localRecordingPlayback, (record) {
      return record['recording_id'] == recordingId;
    });
    if (!preserveDeviceHistory) {
      _deleteWhere(LocalTableName.deviceLocalRecordingMappings, (record) {
        return record['local_recording_id'] == recordingId;
      });
      _deleteWhere(LocalTableName.recordingCardDownloadedManifest, (record) {
        return record['local_file_id'] == recordingId;
      });
    }
    if (!preserveUploadDrafts) {
      _deleteWhere(LocalTableName.localRecordingUploadDrafts, (record) {
        return record['local_file_id'] == recordingId;
      });
    }
    _deleteWhere(LocalTableName.localRecordingRecoveryCheckpoints, (record) {
      return record['local_file_id'] == recordingId;
    });
    _deleteWhere(LocalTableName.localTransferRecords, (record) {
      return record['recording_id'] == recordingId ||
          record['local_file_id'] == recordingId;
    });
  }

  void _deleteOrphanTags(Set<String> tagIds) {
    for (final tagId in tagIds) {
      final hasRemainingLink = _list(
        LocalTableName.localRecordingTagLinks,
      ).any((record) => record['tag_id'] == tagId);
      if (!hasRemainingLink) {
        _delete(LocalTableName.localRecordingTags, tagId);
      }
    }
  }

  void _deleteWhere(
    LocalTableName table,
    bool Function(LocalDatabaseRecord record) test,
  ) {
    for (final record in _list(table).where(test)) {
      final key = _logicalKeyFor(table, record);
      if (key != null) {
        _delete(table, key);
      }
    }
  }

  String? _logicalKeyFor(LocalTableName table, LocalDatabaseRecord record) {
    return switch (table) {
      LocalTableName.localRecordings => record['recording_id']?.toString(),
      LocalTableName.localRecordingTags => record['tag_id']?.toString(),
      LocalTableName.localRecordingTagLinks =>
        '${record['recording_id']}:${record['tag_id']}',
      LocalTableName.localRecordingTrash => record['recording_id']?.toString(),
      LocalTableName.localRecordingPlayback =>
        record['recording_id']?.toString(),
      LocalTableName.deviceLocalRecordingMappings =>
        '${record['device_id']}:${record['device_file_key']}',
      LocalTableName.recordingCardDownloadedManifest =>
        _downloadedManifestRecordKey(record),
      LocalTableName.localRecordingUploadDrafts =>
        record['draft_id']?.toString(),
      LocalTableName.localRecordingRecoveryCheckpoints =>
        record['checkpoint_id']?.toString(),
      LocalTableName.localTransferRecords => record['transfer_id']?.toString(),
      _ => null,
    };
  }
}

String? _downloadedManifestRecordKey(LocalDatabaseRecord record) {
  final deviceFileId = record['device_file_id']?.toString();
  if (deviceFileId == null || deviceFileId.isEmpty) return null;
  final fingerprint = record['device_fingerprint']?.toString();
  if (fingerprint == null || fingerprint.isEmpty) return deviceFileId;
  return _recordingCardManifestKey(fingerprint, deviceFileId);
}

String _recordingCardManifestKey(String fingerprint, String deviceFileId) {
  return '${fingerprint.length}:$fingerprint:$deviceFileId';
}

String? _normalizeOptionalUserScope(String? value) {
  if (value == null) return null;
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  if (normalized.length > 256 || normalized.contains('\u0000')) {
    throw ArgumentError.value(value, 'userScope', 'is unsafe');
  }
  return normalized;
}

String _encode(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

int _recordInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.floor();
  return int.tryParse('$value') ?? 0;
}

final _recordingCardStagedFileId = RegExp(r'^card-[a-f0-9]{32}$');
final _sha256Hash = RegExp(r'^[a-f0-9]{64}$');
const _recordingCardStagedFormats = <String>{'mp3', 'opus', 'm4a', 'wav'};
