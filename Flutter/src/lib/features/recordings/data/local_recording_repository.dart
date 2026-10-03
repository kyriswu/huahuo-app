import '../../../core/api/api_envelope.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/recording_dao.dart';
import '../../../core/native/native_file_port.dart';
import '../../../core/storage/file_storage_port.dart';
import '../../../core/storage/private_recording_path_resolver.dart';
import '../../../core/storage/upload_draft_store.dart';
import '../domain/recording_library.dart';

final class LocalRecordingResult<T> {
  const LocalRecordingResult._({required this.ok, this.value, this.error});

  factory LocalRecordingResult.success(T value) {
    return LocalRecordingResult<T>._(ok: true, value: value);
  }

  factory LocalRecordingResult.failure(AppFailure error) {
    return LocalRecordingResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

final class LocalRecordingPage {
  const LocalRecordingPage({
    required this.rows,
    required this.summary,
    this.emptyState,
  });

  final List<RecordingLibraryItem> rows;
  final RecordingLibrarySummary summary;
  final String? emptyState;
}

final class LocalRecordingImportBatch {
  const LocalRecordingImportBatch({required this.imported, this.error});

  final List<RecordingLibraryItem> imported;
  final AppFailure? error;

  bool get ok => error == null;
}

/// Account-scoped recording-card deletion facts supplied by the application
/// composition layer. Ordinary local recordings have no matching ledger row.
abstract interface class LocalRecordingDeletionLedgerPort {
  bool canStartUpload(String localRecordingId);

  Iterable<String> deletionInProgressLocalRecordingIds();

  /// Returns true when a matching card ledger entry was locked as `deleting`.
  bool beginLocalDeletion(String localRecordingId, DateTime at);

  void finishLocalDeletion(String localRecordingId, DateTime at);

  void restoreLocalDeletion(String localRecordingId, DateTime at);
}

final class VerifiedRecordingCardDownload {
  const VerifiedRecordingCardDownload({
    required this.deviceIds,
    required this.deviceFileId,
    required this.deviceFingerprint,
    required this.deviceFilename,
    required this.localRecordingId,
    required this.appPrivateUri,
    required this.actualSizeBytes,
    required this.durationSeconds,
    required this.contentHash,
  });

  final Set<String> deviceIds;
  final String deviceFileId;
  final String deviceFingerprint;
  final String deviceFilename;
  final String localRecordingId;
  final String appPrivateUri;
  final int actualSizeBytes;
  final int durationSeconds;
  final String? contentHash;
}

final class LocalRecordingRepository {
  LocalRecordingRepository({
    required AppDatabase database,
    required this.fileStorage,
    String? accountScope,
    bool requireAuthenticatedAccount = false,
    UploadDraftStore? uploadDraftStore,
    LocalRecordingDeletionLedgerPort? deletionLedger,
    this.recoveryPathResolver,
  }) : _accountScope = _normalizeRecordingAccountScope(accountScope),
       _requiresAuthenticatedAccount = requireAuthenticatedAccount,
       _dao = RecordingDao(
         database,
         userScope: _normalizeRecordingAccountScope(accountScope),
       ),
       _database = database,
       _deletionLedger = deletionLedger,
       _uploadDraftStore =
           uploadDraftStore ??
           UploadDraftStore(
             database: database,
             accountScope: _normalizeRecordingAccountScope(accountScope),
           );

  final String? _accountScope;
  final bool _requiresAuthenticatedAccount;
  final AppDatabase _database;
  final RecordingDao _dao;
  final FileStoragePort fileStorage;
  final PrivateRecordingPathResolver? recoveryPathResolver;
  final UploadDraftStore _uploadDraftStore;
  final LocalRecordingDeletionLedgerPort? _deletionLedger;
  final Map<String, _LocalRecordingOperation> _activeFileOperations =
      <String, _LocalRecordingOperation>{};

  bool get hasActiveAccount =>
      !_requiresAuthenticatedAccount || _accountScope != null;

  bool canStartUpload(String recordingId) {
    final normalized = recordingId.trim();
    if (normalized.isEmpty || _activeFileOperations.containsKey(normalized)) {
      return false;
    }
    return _deletionLedger?.canStartUpload(normalized) ?? true;
  }

  bool beginUploadOperation(String recordingId) {
    final normalized = recordingId.trim();
    if (normalized.isEmpty || !canStartUpload(normalized)) return false;
    _activeFileOperations[normalized] = _LocalRecordingOperation.upload;
    return true;
  }

  void finishUploadOperation(String recordingId) {
    final normalized = recordingId.trim();
    if (_activeFileOperations[normalized] == _LocalRecordingOperation.upload) {
      _activeFileOperations.remove(normalized);
    }
  }

  bool _beginSyncRegistrationOperation(String recordingId) {
    final normalized = recordingId.trim();
    if (normalized.isEmpty ||
        _activeFileOperations.containsKey(normalized) ||
        !(_deletionLedger?.canStartUpload(normalized) ?? true)) {
      return false;
    }
    _activeFileOperations[normalized] =
        _LocalRecordingOperation.syncRegistration;
    return true;
  }

  void _finishSyncRegistrationOperation(String recordingId) {
    final normalized = recordingId.trim();
    if (_activeFileOperations[normalized] ==
        _LocalRecordingOperation.syncRegistration) {
      _activeFileOperations.remove(normalized);
    }
  }

  RecordingLibraryItem? findById(String recordingId) {
    final normalized = recordingId.trim();
    if (!isSafeRecordingLibraryIdentifier(normalized)) return null;
    for (final item in _allItems()) {
      if (item.recordingId == normalized &&
          item.status != RecordingLibraryStatus.recycled) {
        return item;
      }
    }
    return null;
  }

  Future<LocalRecordingResult<RecordingLibraryItem>> ensureContentHash(
    RecordingLibraryItem item,
  ) async {
    if (!hasActiveAccount) return _loginRequired();
    final current = _find(item.recordingId) ?? item;
    final existingHash = safeContentHash(current.contentHash);
    if (existingHash != null) {
      return LocalRecordingResult<RecordingLibraryItem>.success(current);
    }
    final appPrivateUri = current.appPrivateUri;
    if (current.status == RecordingLibraryStatus.recycled ||
        current.localFileState != RecordingLocalFileState.ready ||
        appPrivateUri == null ||
        !isSafeAppPrivateUri(appPrivateUri)) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_UPLOAD_NOT_READY'),
      );
    }
    final hashed = await fileStorage.hashPrivateAudio(appPrivateUri);
    final contentHash = hashed.ok ? safeContentHash(hashed.value) : null;
    if (contentHash == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        hashed.error ?? recordingLibraryError('RECORDING_CONTENT_HASH_FAILED'),
      );
    }
    final updated = _recordingWithContentHash(
      current,
      contentHash,
      DateTime.now().toUtc(),
    );
    try {
      _upsert(updated);
    } catch (_) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_CONTENT_HASH_WRITE_FAILED'),
      );
    }
    return LocalRecordingResult<RecordingLibraryItem>.success(updated);
  }

  LocalRecordingPage list({
    RecordingLibraryQuery query = const RecordingLibraryQuery(),
  }) {
    final items = _allItems();
    final rows = filterRecordingLibrary(items, query);
    return LocalRecordingPage(
      rows: rows,
      summary: summarizeRecordings(items),
      emptyState: rows.isEmpty ? _emptyStateFor(query) : null,
    );
  }

  Future<LocalRecordingPage> verifiedList({
    RecordingLibraryQuery query = const RecordingLibraryQuery(),
  }) async {
    if (!hasActiveAccount) return list(query: query);
    await _recoverUnindexedPrivateRecordings();
    await _verifyLocalFileStates();
    return list(query: query);
  }

  Future<LocalRecordingResult<int>> recoverInterruptedLocalDeletions() async {
    if (!hasActiveAccount) return _loginRequired();
    final legacyDeletingManifests = _dao
        .listDownloadedManifests()
        .where((record) => record['local_state'] == 'deleting')
        .toList(growable: false);
    final recordingIds = <String>{
      ...?_deletionLedger?.deletionInProgressLocalRecordingIds(),
      for (final manifest in legacyDeletingManifests)
        if (manifest['local_file_id'] case final String id)
          if (_isSafeMetadataText(id)) id.trim(),
    };
    var settledCount = 0;
    for (final recordingId in recordingIds) {
      if (!isSafeRecordingLibraryIdentifier(recordingId) ||
          _activeFileOperations.containsKey(recordingId)) {
        continue;
      }
      _activeFileOperations[recordingId] = _LocalRecordingOperation.deletion;
      try {
        final current = _find(recordingId);
        final manifests = _dao.listDownloadedManifestsFor(recordingId);
        final candidateUris = <String>{
          if (current?.appPrivateUri case final String uri)
            if (isSafeAppPrivateUri(uri)) uri,
          for (final manifest in manifests)
            if (manifest['app_private_uri'] case final String uri)
              if (isSafeAppPrivateUri(uri)) uri,
        };
        if (candidateUris.length != 1) {
          return LocalRecordingResult<int>.failure(
            recordingLibraryError(
              'RECORDING_DELETE_RECOVERY_FILE_REFERENCE_UNAVAILABLE',
            ),
          );
        }
        final stat = await fileStorage.statPrivateAudio(candidateUris.single);
        if (!stat.ok || stat.value == null) {
          return LocalRecordingResult<int>.failure(
            stat.error ??
                recordingLibraryError('RECORDING_DELETE_RECOVERY_STAT_FAILED'),
          );
        }

        final settledAt = DateTime.now().toUtc();
        if (stat.value!.exists) {
          _deletionLedger?.restoreLocalDeletion(recordingId, settledAt);
          _dao.updateDownloadedManifestLocalState(
            localFileId: recordingId,
            localState: 'synced',
            updatedAt: settledAt.toIso8601String(),
          );
        } else {
          final drafts = _uploadDraftStore.listDraftsForLocalRecording(
            recordingId,
          );
          _dao.updateDownloadedManifestLocalState(
            localFileId: recordingId,
            localState: 'localDeleted',
            updatedAt: settledAt.toIso8601String(),
            localDeletedAt: settledAt.toIso8601String(),
          );
          if (current != null) {
            _dao.purgeRelatedMetadata(
              recordingId,
              preserveDeviceHistory: true,
              preserveUploadDrafts: drafts.any(_draftOwnsRemoteObservation),
            );
          }
          _deletionLedger?.finishLocalDeletion(recordingId, settledAt);
        }
        try {
          await _database.flushPersistence();
        } on Object {
          return LocalRecordingResult<int>.failure(
            recordingLibraryError('RECORDING_DELETE_RECOVERY_WRITE_FAILED'),
          );
        }
        settledCount += 1;
      } finally {
        if (_activeFileOperations[recordingId] ==
            _LocalRecordingOperation.deletion) {
          _activeFileOperations.remove(recordingId);
        }
      }
    }
    return LocalRecordingResult<int>.success(settledCount);
  }

  Future<List<VerifiedRecordingCardDownload>>
  verifiedRecordingCardDownloads() async {
    if (!hasActiveAccount) return const <VerifiedRecordingCardDownload>[];
    await _verifyLocalFileStates();
    final itemsById = <String, RecordingLibraryItem>{
      for (final item in _allItems())
        if (item.source == RecordingLibrarySource.device &&
            item.status != RecordingLibraryStatus.recycled &&
            item.localFileState == RecordingLocalFileState.ready &&
            item.appPrivateUri != null &&
            isSafeAppPrivateUri(item.appPrivateUri!))
          item.recordingId: item,
    };
    final mappedDeviceIds = <String, Set<String>>{};
    for (final record in _dao.listDeviceLocalMappings()) {
      final deviceId = record['device_id'];
      final deviceFileId = record['device_file_key'];
      final localRecordingId = record['local_recording_id'];
      if (deviceId is! String ||
          deviceFileId is! String ||
          localRecordingId is! String ||
          !_isSafeMetadataText(deviceId) ||
          !_isSafeMetadataText(deviceFileId) ||
          !_isSafeMetadataText(localRecordingId) ||
          record['sync_status'] != 'downloaded') {
        continue;
      }
      mappedDeviceIds
          .putIfAbsent(
            _recordingCardLinkKey(localRecordingId, deviceFileId),
            () => <String>{},
          )
          .add(deviceId);
    }

    final verified = <VerifiedRecordingCardDownload>[];
    final actualHashes = <String, String>{};
    for (final record in _dao.listDownloadedManifests()) {
      final deviceFileId = record['device_file_id'];
      final deviceFingerprint = record['device_fingerprint'];
      final deviceFilename = record['device_filename'];
      final localRecordingId = record['local_file_id'];
      final appPrivateUri = record['app_private_uri'];
      final actualSizeBytes = _positiveMetadataInt(record['actual_size_bytes']);
      final durationSeconds = _nonNegativeMetadataInt(
        record['duration_seconds'],
      );
      if (deviceFileId is! String ||
          deviceFingerprint is! String ||
          deviceFilename is! String ||
          localRecordingId is! String ||
          appPrivateUri is! String ||
          !_isSafeMetadataText(deviceFileId) ||
          !_isSafeMetadataText(deviceFingerprint) ||
          safeDisplayName(deviceFilename) == null ||
          !_isSafeMetadataText(localRecordingId) ||
          !isSafeAppPrivateUri(appPrivateUri) ||
          actualSizeBytes == null ||
          durationSeconds == null) {
        continue;
      }
      final item = itemsById[localRecordingId];
      if (item == null ||
          item.appPrivateUri != appPrivateUri ||
          item.sizeBytes != actualSizeBytes) {
        continue;
      }
      var actualHash = actualHashes[appPrivateUri];
      if (actualHash == null) {
        final hashed = await fileStorage.hashPrivateAudio(appPrivateUri);
        actualHash = hashed.ok ? safeContentHash(hashed.value) : null;
        if (actualHash == null) {
          throw StateError(
            hashed.error?.code ?? 'RECORDING_CARD_LOCAL_HASH_FAILED',
          );
        }
        actualHashes[appPrivateUri] = actualHash;
      }
      final rawManifestHash = record['content_hash'];
      final manifestHash = rawManifestHash == null
          ? null
          : safeContentHash(rawManifestHash is String ? rawManifestHash : '');
      final rawLocalHash = item.contentHash;
      final localHash = rawLocalHash == null
          ? null
          : safeContentHash(rawLocalHash);
      if ((rawManifestHash != null && manifestHash == null) ||
          (rawLocalHash != null && localHash == null)) {
        throw StateError('RECORDING_CARD_STORED_HASH_INVALID');
      }
      if (manifestHash != null &&
          localHash != null &&
          manifestHash != localHash) {
        throw StateError('RECORDING_CARD_HASH_LEDGER_CONFLICT');
      }
      final storedHash = manifestHash ?? localHash;
      if (storedHash != null && storedHash != actualHash) {
        _upsert(
          item.copyWith(
            localFileState: RecordingLocalFileState.missing,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        continue;
      }
      if (localHash == null || manifestHash == null) {
        final updatedAt = DateTime.now().toUtc();
        final updatedItem = _recordingWithContentHash(
          item,
          actualHash,
          updatedAt,
        );
        final updatedRecord = <String, Object?>{
          ...record,
          'content_hash': actualHash,
          'updated_at': updatedAt.toIso8601String(),
        };
        final persisted = _database.withTransaction((_) {
          _upsert(updatedItem);
          _dao.upsertDownloadedManifestRecord(updatedRecord);
          return true;
        });
        if (!persisted.ok) {
          throw StateError('RECORDING_CARD_HASH_BACKFILL_FAILED');
        }
        final flushed = await flushRecordingCardPersistence();
        if (!flushed.ok) {
          throw StateError('RECORDING_CARD_HASH_BACKFILL_FAILED');
        }
      }
      verified.add(
        VerifiedRecordingCardDownload(
          deviceIds: Set<String>.unmodifiable(
            mappedDeviceIds[_recordingCardLinkKey(
                  localRecordingId,
                  deviceFileId,
                )] ??
                const <String>{},
          ),
          deviceFileId: deviceFileId,
          deviceFingerprint: deviceFingerprint,
          deviceFilename: deviceFilename,
          localRecordingId: localRecordingId,
          appPrivateUri: appPrivateUri,
          actualSizeBytes: actualSizeBytes,
          durationSeconds: durationSeconds,
          contentHash: actualHash,
        ),
      );
    }
    return List<VerifiedRecordingCardDownload>.unmodifiable(verified);
  }

  Future<LocalRecordingResult<RecordingLibraryItem>> archivePrivateMediaAudio({
    required String sourceAppPrivateUri,
    required String displayName,
    required String mimeType,
    required int sizeBytes,
    required int durationSeconds,
    required String contentHash,
    required DateTime recordedAt,
  }) async {
    if (!hasActiveAccount) return _loginRequired();
    final copied = await fileStorage.copyPrivateMediaAudioToPrivateLibrary(
      sourceAppPrivateUri: sourceAppPrivateUri,
      displayName: displayName,
      mimeType: mimeType,
      expectedSizeBytes: sizeBytes,
      durationSeconds: durationSeconds,
      expectedContentHash: contentHash,
      recordedAt: recordedAt,
    );
    if (!copied.ok || copied.value == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        copied.error ??
            recordingLibraryError('RECORDING_CAPTURE_ARCHIVE_FAILED'),
      );
    }
    final alreadyIndexed = _allItems().any(
      (item) => item.appPrivateUri == copied.value!.appPrivateUri,
    );
    final registered = await registerNativeVoiceRecording(
      file: copied.value!,
      recordedAt: recordedAt,
      tagIds: const <String>[internalRecordingHistoryTagId],
    );
    if (!registered.ok && !alreadyIndexed) {
      await _discardImportedPrivateAudio(copied.value!.appPrivateUri);
    }
    return registered;
  }

  LocalRecordingResult<int> restoreHistoricalRecycledRecordings() {
    final recycled = _allItems()
        .where((item) => item.status == RecordingLibraryStatus.recycled)
        .toList(growable: false);
    if (recycled.isEmpty) return LocalRecordingResult<int>.success(0);

    final restored = _database.withTransaction((_) {
      for (final item in recycled) {
        _upsert(item.restored(item.updatedAt));
        _dao.deleteTrash(item.recordingId);
      }
      return recycled.length;
    });
    if (!restored.ok || restored.value == null) {
      return LocalRecordingResult<int>.failure(
        recordingLibraryError('RECORDING_RECYCLED_MIGRATION_FAILED'),
      );
    }
    return LocalRecordingResult<int>.success(restored.value!);
  }

  Future<LocalRecordingResult<RecordingLibraryItem>> importPickedRecording(
    PickedAudioFile picked, {
    DateTime? now,
  }) async {
    if (!hasActiveAccount) return _loginRequired();
    final displayName = safeDisplayName(picked.displayName);
    if (displayName == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        picked.displayName.trim().isEmpty
            ? recordingLibraryError('RECORDING_NAME_EMPTY')
            : recordingLibraryError('RECORDING_LOCAL_NAME_UNSAFE'),
      );
    }
    if (!_isSafePickerRef(picked.pickerRef)) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_LOCAL_FILE_UNSAFE'),
      );
    }
    final copied = await fileStorage.copyPickedAudioToPrivateLibrary(picked);
    if (!copied.ok || copied.value == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        copied.error ?? recordingLibraryError('RECORDING_IMPORT_COPY_FAILED'),
      );
    }
    final verifiedFile = await _withVerifiedPrivateMetadata(copied.value!);
    final itemOrError = _itemFromPrivateAudio(
      verifiedFile,
      now ?? DateTime.now(),
    );
    if (itemOrError is AppFailure) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(itemOrError);
    }
    final item = itemOrError as RecordingLibraryItem;
    final draft = _initialImportDraft(item);
    if (draft is AppFailure) {
      await _discardImportedPrivateAudio(item.appPrivateUri!);
      return LocalRecordingResult<RecordingLibraryItem>.failure(draft);
    }

    final persisted = _database.withTransaction((_) {
      _upsert(item);
      final saved = _uploadDraftStore.saveDraft(draft as UploadDraft);
      if (!saved.ok || saved.value == null) {
        throw StateError('UPLOAD_DRAFT_WRITE_FAILED');
      }
      return true;
    });
    if (!persisted.ok) {
      await _discardImportedPrivateAudio(item.appPrivateUri!);
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_UPLOAD_DRAFT_WRITE_FAILED'),
      );
    }
    return LocalRecordingResult<RecordingLibraryItem>.success(item);
  }

  Future<LocalRecordingImportBatch> importPickedRecordings(
    List<PickedAudioFile> picked, {
    DateTime? now,
  }) async {
    if (picked.isEmpty) {
      return LocalRecordingImportBatch(
        imported: const <RecordingLibraryItem>[],
        error: recordingLibraryError('RECORDING_PICKER_EMPTY'),
      );
    }
    final imported = <RecordingLibraryItem>[];
    for (final file in picked) {
      final result = await importPickedRecording(file, now: now);
      if (!result.ok || result.value == null) {
        return LocalRecordingImportBatch(
          imported: List<RecordingLibraryItem>.unmodifiable(imported),
          error:
              result.error ?? recordingLibraryError('RECORDING_IMPORT_FAILED'),
        );
      }
      imported.add(result.value!);
    }
    return LocalRecordingImportBatch(
      imported: List<RecordingLibraryItem>.unmodifiable(imported),
    );
  }

  Future<LocalRecordingResult<RecordingLibraryItem>>
  registerDownloadedRecording({
    required PrivateAudioFile file,
    required String deviceId,
    required String deviceFileId,
    required String deviceFingerprint,
    required String deviceFilename,
    DateTime? downloadedAt,
  }) async {
    if (!hasActiveAccount) return _loginRequired();
    final safeDeviceFilename = safeDisplayName(deviceFilename);
    if (safeDeviceFilename == null ||
        !_isSafeMetadataText(deviceId) ||
        !_isSafeMetadataText(deviceFileId) ||
        !_isSafeMetadataText(deviceFingerprint)) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_LOCAL_FILE_UNSAFE'),
      );
    }
    final expectedHash = safeContentHash(file.contentHash);
    if (!isSafeAppPrivateUri(file.appPrivateUri) ||
        file.sizeBytes <= 0 ||
        (file.contentHash != null && expectedHash == null)) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_PRIVATE_FILE_INVALID'),
      );
    }
    final adopted = await _adoptPrivateFileIfNeeded(file, recordingCard: true);
    if (!adopted.ok || adopted.value == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        adopted.error ??
            recordingLibraryError('RECORDING_ACCOUNT_FILE_ADOPTION_FAILED'),
      );
    }
    final effectiveFile = adopted.value!;
    final stat = await fileStorage.statPrivateAudio(
      effectiveFile.appPrivateUri,
    );
    if (!stat.ok || stat.value == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        stat.error ??
            recordingLibraryError('RECORDING_PRIVATE_FILE_STAT_FAILED'),
      );
    }
    final actualSizeBytes = stat.value!.sizeBytes;
    if (!stat.value!.exists ||
        actualSizeBytes == null ||
        actualSizeBytes <= 0) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_PRIVATE_FILE_MISSING'),
      );
    }
    if (actualSizeBytes != effectiveFile.sizeBytes) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_PRIVATE_FILE_SIZE_MISMATCH'),
      );
    }
    final hashed = await fileStorage.hashPrivateAudio(
      effectiveFile.appPrivateUri,
    );
    final actualHash = hashed.ok ? safeContentHash(hashed.value) : null;
    if (actualHash == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        hashed.error ??
            recordingLibraryError('RECORDING_PRIVATE_FILE_HASH_FAILED'),
      );
    }
    if (expectedHash != null && expectedHash != actualHash) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_PRIVATE_FILE_HASH_MISMATCH'),
      );
    }
    final resyncRecordingId = _manualResyncRecordingId(
      fileId: effectiveFile.fileId,
      deviceId: deviceId,
      deviceFileId: deviceFileId,
      deviceFingerprint: deviceFingerprint,
    );
    final reusable = resyncRecordingId == null
        ? await _findReusableDownloadedRecording(
            contentHash: actualHash,
            sizeBytes: actualSizeBytes,
          )
        : null;
    if (reusable != null &&
        _beginSyncRegistrationOperation(reusable.recordingId)) {
      try {
        final current = _find(reusable.recordingId);
        if (current != null &&
            await _isReusableDownloadedRecording(
              current,
              contentHash: actualHash,
              sizeBytes: actualSizeBytes,
            )) {
          final at = downloadedAt ?? DateTime.now();
          final persisted = _database.withTransaction((_) {
            _upsert(current);
            _persistDownloadedRecordingLinks(
              item: current,
              deviceId: deviceId,
              deviceFileId: deviceFileId,
              deviceFingerprint: deviceFingerprint,
              deviceFilename: safeDeviceFilename,
              expectedSizeBytes: effectiveFile.sizeBytes,
              downloadedAt: at,
              updatedAt: at,
            );
            return true;
          });
          if (!persisted.ok) {
            return LocalRecordingResult<RecordingLibraryItem>.failure(
              recordingLibraryError('RECORDING_DOWNLOAD_LEDGER_WRITE_FAILED'),
            );
          }
          final flushed = await flushRecordingCardPersistence();
          if (!flushed.ok) {
            return LocalRecordingResult<RecordingLibraryItem>.failure(
              recordingLibraryError('RECORDING_DOWNLOAD_LEDGER_WRITE_FAILED'),
            );
          }
          if (current.appPrivateUri != effectiveFile.appPrivateUri) {
            await _discardImportedPrivateAudio(effectiveFile.appPrivateUri);
          }
          return LocalRecordingResult<RecordingLibraryItem>.success(current);
        }
      } finally {
        _finishSyncRegistrationOperation(reusable.recordingId);
      }
    }
    return _registerVerifiedDownloadedRecording(
      file: PrivateAudioFile(
        fileId: effectiveFile.fileId,
        appPrivateUri: effectiveFile.appPrivateUri,
        displayName: effectiveFile.displayName,
        mimeType: effectiveFile.mimeType,
        sizeBytes: actualSizeBytes,
        durationSeconds:
            effectiveFile.durationSeconds ?? stat.value!.durationSeconds,
        contentHash: actualHash,
        recordedAt: effectiveFile.recordedAt,
      ),
      deviceId: deviceId,
      deviceFileId: deviceFileId,
      deviceFingerprint: deviceFingerprint,
      deviceFilename: safeDeviceFilename,
      downloadedAt: downloadedAt,
      recordingId: resyncRecordingId,
    );
  }

  Future<LocalRecordingResult<RecordingLibraryItem>>
  registerNativeVoiceRecording({
    required PrivateAudioFile file,
    DateTime? recordedAt,
    List<String> tagIds = const <String>[],
  }) async {
    if (!hasActiveAccount) return _loginRequired();
    if (!_isSafeMetadataText(file.fileId) ||
        !_isSafeRecordingLibraryUri(file.appPrivateUri) ||
        file.sizeBytes <= 0 ||
        (file.durationSeconds != null && file.durationSeconds! <= 0) ||
        (file.contentHash != null &&
            safeContentHash(file.contentHash) == null)) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_PRIVATE_FILE_INVALID'),
      );
    }
    final adopted = await _adoptPrivateFileIfNeeded(file, recordingCard: false);
    if (!adopted.ok || adopted.value == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        adopted.error ??
            recordingLibraryError('RECORDING_ACCOUNT_FILE_ADOPTION_FAILED'),
      );
    }
    final effectiveFile = adopted.value!;
    final stat = await fileStorage.statPrivateAudio(
      effectiveFile.appPrivateUri,
    );
    if (!stat.ok || stat.value == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        stat.error ??
            recordingLibraryError('RECORDING_PRIVATE_FILE_STAT_FAILED'),
      );
    }
    final actualSizeBytes = stat.value!.sizeBytes;
    if (!stat.value!.exists ||
        actualSizeBytes == null ||
        actualSizeBytes <= 0) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_PRIVATE_FILE_MISSING'),
      );
    }
    if (actualSizeBytes != effectiveFile.sizeBytes) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_PRIVATE_FILE_SIZE_MISMATCH'),
      );
    }
    final at = recordedAt ?? DateTime.now();
    final itemOrError = _itemFromPrivateAudio(
      PrivateAudioFile(
        fileId: effectiveFile.fileId,
        appPrivateUri: effectiveFile.appPrivateUri,
        displayName: effectiveFile.displayName,
        mimeType: effectiveFile.mimeType,
        sizeBytes: actualSizeBytes,
        durationSeconds:
            effectiveFile.durationSeconds ?? stat.value!.durationSeconds,
        contentHash: effectiveFile.contentHash,
        recordedAt: effectiveFile.recordedAt ?? at,
      ),
      at,
      source: RecordingLibrarySource.microphone,
    );
    if (itemOrError is AppFailure) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(itemOrError);
    }
    final taggedItem = updateRecordingTags(
      itemOrError as RecordingLibraryItem,
      tagIds,
      at,
    );
    if (taggedItem is AppFailure) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(taggedItem);
    }
    final item = taggedItem as RecordingLibraryItem;
    final persisted = _database.withTransaction((_) {
      _upsert(item);
      _persistTagLinks(item);
      return true;
    });
    if (!persisted.ok) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_NATIVE_RECORDING_WRITE_FAILED'),
      );
    }
    final flushed = await flushRecordingCardPersistence();
    if (!flushed.ok) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_NATIVE_RECORDING_WRITE_FAILED'),
      );
    }
    return LocalRecordingResult<RecordingLibraryItem>.success(item);
  }

  Future<LocalRecordingResult<RecordingLibraryItem>>
  _registerVerifiedDownloadedRecording({
    required PrivateAudioFile file,
    required String deviceId,
    required String deviceFileId,
    required String deviceFingerprint,
    required String deviceFilename,
    DateTime? downloadedAt,
    String? recordingId,
  }) async {
    final safeDeviceFilename = safeDisplayName(deviceFilename);
    if (safeDeviceFilename == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_LOCAL_FILE_UNSAFE'),
      );
    }
    final at = downloadedAt ?? DateTime.now();
    final itemOrError = _itemFromPrivateAudio(
      file,
      at,
      source: RecordingLibrarySource.device,
      deviceFilename: safeDeviceFilename,
      recordingId: recordingId,
    );
    if (itemOrError is AppFailure) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(itemOrError);
    }
    final item = itemOrError as RecordingLibraryItem;
    if (!_beginSyncRegistrationOperation(item.recordingId)) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_DOWNLOAD_LOCAL_OPERATION_IN_PROGRESS'),
      );
    }
    try {
      final persisted = _database.withTransaction((_) {
        _upsert(item);
        _persistDownloadedRecordingLinks(
          item: item,
          deviceId: deviceId,
          deviceFileId: deviceFileId,
          deviceFingerprint: deviceFingerprint,
          deviceFilename: safeDeviceFilename,
          expectedSizeBytes: file.sizeBytes,
          downloadedAt: at,
          updatedAt: item.updatedAt,
        );
        return true;
      });
      if (!persisted.ok) {
        return LocalRecordingResult<RecordingLibraryItem>.failure(
          recordingLibraryError('RECORDING_DOWNLOAD_LEDGER_WRITE_FAILED'),
        );
      }
      final flushed = await flushRecordingCardPersistence();
      if (!flushed.ok) {
        return LocalRecordingResult<RecordingLibraryItem>.failure(
          recordingLibraryError('RECORDING_DOWNLOAD_LEDGER_WRITE_FAILED'),
        );
      }
      return LocalRecordingResult<RecordingLibraryItem>.success(item);
    } finally {
      _finishSyncRegistrationOperation(item.recordingId);
    }
  }

  String? _manualResyncRecordingId({
    required String fileId,
    required String deviceId,
    required String deviceFileId,
    required String deviceFingerprint,
  }) {
    final acceptedDeviceIdentities = <String>{deviceId, deviceFingerprint};
    final tombstones = _dao
        .listDownloadedManifests()
        .where((record) {
          return record['device_file_id'] == deviceFileId &&
              acceptedDeviceIdentities.contains(record['device_fingerprint']) &&
              record['local_state'] == 'localDeleted';
        })
        .toList(growable: false);
    if (tombstones.isEmpty) return null;
    tombstones.sort(
      (left, right) => '${left['updated_at'] ?? ''}'.compareTo(
        '${right['updated_at'] ?? ''}',
      ),
    );
    final tombstone = tombstones.last;
    final previousLocalId = '${tombstone['local_file_id'] ?? ''}'.trim();
    final deletedAt =
        '${tombstone['local_deleted_at'] ?? tombstone['updated_at'] ?? ''}'
            .trim();
    final generationIdentity =
        '$deviceFingerprint\u0000$deviceFileId\u0000$fileId\u0000'
        '$previousLocalId\u0000$deletedAt';
    return 'local-resync-${stableRecordingHash(generationIdentity)}';
  }

  void _persistDownloadedRecordingLinks({
    required RecordingLibraryItem item,
    required String deviceId,
    required String deviceFileId,
    required String deviceFingerprint,
    required String deviceFilename,
    required int expectedSizeBytes,
    required DateTime downloadedAt,
    required DateTime updatedAt,
  }) {
    _dao.upsertDeviceLocalMapping(
      deviceId: deviceId,
      deviceFileKey: deviceFileId,
      localRecordingId: item.recordingId,
      syncStatus: 'downloaded',
      updatedAt: updatedAt.toIso8601String(),
    );
    _dao.upsertDownloadedManifest(
      deviceFileId: deviceFileId,
      deviceFingerprint: deviceFingerprint,
      deviceFilename: deviceFilename,
      localFileId: item.recordingId,
      appPrivateUri: item.appPrivateUri!,
      expectedSizeBytes: expectedSizeBytes < 0 ? 0 : expectedSizeBytes,
      actualSizeBytes: item.sizeBytes,
      durationSeconds: item.durationSeconds,
      contentHash: item.contentHash,
      downloadedAt: downloadedAt.toIso8601String(),
      updatedAt: updatedAt.toIso8601String(),
    );
  }

  Future<LocalRecordingResult<RecordingLibraryItem>> rename({
    required String recordingId,
    required String displayName,
    DateTime? updatedAt,
  }) async {
    final current = _find(recordingId);
    if (current == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_NOT_FOUND'),
      );
    }
    final renamed = renameRecording(
      current,
      displayName,
      updatedAt ?? DateTime.now(),
    );
    if (renamed is AppFailure) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(renamed);
    }
    final item = renamed as RecordingLibraryItem;
    if (current.appPrivateUri != null) {
      final stored = await fileStorage.updatePrivateAudioMetadata(
        appPrivateUri: current.appPrivateUri!,
        displayName: item.displayName,
      );
      if (!stored.ok) {
        return LocalRecordingResult<RecordingLibraryItem>.failure(
          stored.error ??
              recordingLibraryError('RECORDING_METADATA_WRITE_FAILED'),
        );
      }
    }
    _upsert(item);
    return LocalRecordingResult<RecordingLibraryItem>.success(item);
  }

  LocalRecordingResult<RecordingLibraryItem> updateTags({
    required String recordingId,
    required List<String> tagIds,
    DateTime? updatedAt,
  }) {
    final current = _find(recordingId);
    if (current == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_NOT_FOUND'),
      );
    }
    final updated = updateRecordingTags(
      current,
      tagIds,
      updatedAt ?? DateTime.now(),
    );
    if (updated is AppFailure) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(updated);
    }
    final item = updated as RecordingLibraryItem;
    _upsert(item);
    _persistTagLinks(item);
    return LocalRecordingResult<RecordingLibraryItem>.success(item);
  }

  void _persistTagLinks(RecordingLibraryItem item) {
    for (final tagId in item.tagIds) {
      _dao.upsertTag(tagId, <String, Object?>{
        'tag_id': tagId,
        'name': tagId,
        'created_at': item.updatedAt.toIso8601String(),
        'updated_at': item.updatedAt.toIso8601String(),
      });
    }
    _dao.replaceTagLinks(
      item.recordingId,
      item.tagIds,
      item.updatedAt.toIso8601String(),
    );
  }

  LocalRecordingResult<RecordingLibraryItem> setFavorite({
    required String recordingId,
    required bool isFavorite,
    DateTime? updatedAt,
  }) {
    final current = _find(recordingId);
    if (current == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_NOT_FOUND'),
      );
    }
    final item = current.copyWith(
      isFavorite: isFavorite,
      updatedAt: updatedAt ?? DateTime.now(),
    );
    _upsert(item);
    return LocalRecordingResult<RecordingLibraryItem>.success(item);
  }

  LocalRecordingResult<RecordingLibraryItem> linkRemoteRecording({
    required String localRecordingId,
    required String remoteRecordingId,
    String? contentLineId,
    DateTime? linkedAt,
  }) {
    if (!isSafeRecordingLibraryIdentifier(localRecordingId) ||
        !isSafeRecordingLibraryIdentifier(remoteRecordingId) ||
        (contentLineId != null &&
            !isSafeRecordingLibraryIdentifier(contentLineId))) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_REMOTE_LINK_INVALID'),
      );
    }
    final current = _find(localRecordingId);
    if (current == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_NOT_FOUND'),
      );
    }
    final linked = current.copyWith(
      remoteRecordingId: remoteRecordingId,
      contentLineId: contentLineId,
      updatedAt: linkedAt ?? DateTime.now().toUtc(),
    );
    _upsert(linked);
    return LocalRecordingResult<RecordingLibraryItem>.success(linked);
  }

  LocalRecordingResult<RecordingLibraryItem> moveToTrash({
    required String recordingId,
    DateTime? deletedAt,
  }) {
    final current = _find(recordingId);
    if (current == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_NOT_FOUND'),
      );
    }
    final at = deletedAt ?? DateTime.now();
    final item = current.copyWith(
      status: RecordingLibraryStatus.recycled,
      updatedAt: at,
      deletedAt: at,
    );
    _upsert(item);
    _dao.upsertTrash(
      recordingId: recordingId,
      deletedAt: at.toIso8601String(),
      retentionUntil: at.add(const Duration(days: 30)).toIso8601String(),
    );
    return LocalRecordingResult<RecordingLibraryItem>.success(item);
  }

  LocalRecordingResult<RecordingLibraryItem> restoreFromTrash({
    required String recordingId,
    DateTime? restoredAt,
  }) {
    final current = _find(recordingId);
    if (current == null) {
      return LocalRecordingResult<RecordingLibraryItem>.failure(
        recordingLibraryError('RECORDING_NOT_FOUND'),
      );
    }
    final item = current.restored(restoredAt ?? DateTime.now());
    _upsert(item);
    _dao.deleteTrash(recordingId);
    return LocalRecordingResult<RecordingLibraryItem>.success(item);
  }

  Future<LocalRecordingResult<bool>> deletePermanently(
    String recordingId,
  ) async {
    final normalizedRecordingId = recordingId.trim();
    final current = _find(normalizedRecordingId);
    if (current == null) {
      return LocalRecordingResult<bool>.failure(
        recordingLibraryError('RECORDING_NOT_FOUND'),
      );
    }
    final activeOperation = _activeFileOperations[normalizedRecordingId];
    if (activeOperation != null) {
      return LocalRecordingResult<bool>.failure(
        recordingLibraryError(
          activeOperation == _LocalRecordingOperation.deletion
              ? 'RECORDING_DELETE_IN_PROGRESS'
              : 'RECORDING_DELETE_UPLOAD_IN_PROGRESS',
        ),
      );
    }
    _activeFileOperations[normalizedRecordingId] =
        _LocalRecordingOperation.deletion;

    var ledgerLocked = false;
    var legacyManifestLocked = false;
    try {
      final drafts = _uploadDraftStore.listDraftsForLocalRecording(
        normalizedRecordingId,
      );
      if (drafts.any(_draftBlocksLocalDeletion)) {
        return LocalRecordingResult<bool>.failure(
          recordingLibraryError('RECORDING_DELETE_UPLOAD_IN_PROGRESS'),
        );
      }

      try {
        final lockedAt = DateTime.now().toUtc();
        if (current.source == RecordingLibrarySource.device) {
          legacyManifestLocked =
              _dao.updateDownloadedManifestLocalState(
                localFileId: normalizedRecordingId,
                localState: 'deleting',
                updatedAt: lockedAt.toIso8601String(),
              ) >
              0;
        }
        ledgerLocked =
            _deletionLedger?.beginLocalDeletion(
              normalizedRecordingId,
              lockedAt,
            ) ??
            false;
        if (ledgerLocked || legacyManifestLocked) {
          await _database.flushPersistence();
        }
      } on Object {
        if (ledgerLocked || legacyManifestLocked) {
          try {
            final restoredAt = DateTime.now().toUtc();
            if (ledgerLocked) {
              _deletionLedger?.restoreLocalDeletion(
                normalizedRecordingId,
                restoredAt,
              );
            }
            if (legacyManifestLocked) {
              _dao.updateDownloadedManifestLocalState(
                localFileId: normalizedRecordingId,
                localState: 'synced',
                updatedAt: restoredAt.toIso8601String(),
              );
            }
            await _database.flushPersistence();
          } on Object {
            // Recovery resolves a persisted `deleting` row from file existence.
          }
        }
        return LocalRecordingResult<bool>.failure(
          recordingLibraryError('RECORDING_DELETE_LEDGER_WRITE_FAILED'),
        );
      }

      if (current.appPrivateUri != null) {
        final deleted = await fileStorage.deletePrivateAudio(
          current.appPrivateUri!,
        );
        if (!deleted.ok) {
          if (ledgerLocked || legacyManifestLocked) {
            try {
              final restoredAt = DateTime.now().toUtc();
              if (ledgerLocked) {
                _deletionLedger?.restoreLocalDeletion(
                  normalizedRecordingId,
                  restoredAt,
                );
              }
              if (legacyManifestLocked) {
                _dao.updateDownloadedManifestLocalState(
                  localFileId: normalizedRecordingId,
                  localState: 'synced',
                  updatedAt: restoredAt.toIso8601String(),
                );
              }
              await _database.flushPersistence();
            } on Object {
              // The source file still exists, so restart recovery is safe.
            }
          }
          return LocalRecordingResult<bool>.failure(
            deleted.error ?? recordingLibraryError('RECORDING_DELETE_FAILED'),
          );
        }
      }

      final deletedAt = DateTime.now().toUtc();
      if (legacyManifestLocked) {
        _dao.updateDownloadedManifestLocalState(
          localFileId: normalizedRecordingId,
          localState: 'localDeleted',
          updatedAt: deletedAt.toIso8601String(),
          localDeletedAt: deletedAt.toIso8601String(),
        );
      }
      _dao.purgeRelatedMetadata(
        normalizedRecordingId,
        preserveDeviceHistory: current.source == RecordingLibrarySource.device,
        preserveUploadDrafts: drafts.any(_draftOwnsRemoteObservation),
      );
      if (ledgerLocked) {
        _deletionLedger?.finishLocalDeletion(normalizedRecordingId, deletedAt);
      }
      try {
        await _database.flushPersistence();
      } on Object {
        return LocalRecordingResult<bool>.failure(
          recordingLibraryError('RECORDING_DELETE_LEDGER_WRITE_FAILED'),
        );
      }
      return LocalRecordingResult<bool>.success(true);
    } finally {
      if (_activeFileOperations[normalizedRecordingId] ==
          _LocalRecordingOperation.deletion) {
        _activeFileOperations.remove(normalizedRecordingId);
      }
    }
  }

  Future<LocalRecordingResult<PreparedAudioExport>> prepareExport(
    String recordingId,
  ) async {
    final current = _find(recordingId);
    if (current == null) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_NOT_FOUND'),
      );
    }
    if (current.status == RecordingLibraryStatus.recycled) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_EXPORT_RECYCLED'),
      );
    }
    if (current.localFileState != RecordingLocalFileState.ready) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_EXPORT_NOT_READY'),
      );
    }
    final privateUri = current.appPrivateUri;
    if (privateUri == null || !isSafeAppPrivateUri(privateUri)) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_LOCAL_FILE_UNSAFE'),
      );
    }
    final exportFormat = resolveRecordingLibraryExportFormat(current);
    final exportDisplayName = recordingLibraryExportDisplayName(
      current.displayName,
      exportFormat,
    );
    final exportMimeType = recordingLibraryMimeTypeForFormat(exportFormat);
    if (exportDisplayName == null || exportMimeType == null) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_EXPORT_FORMAT_UNKNOWN'),
      );
    }
    final stat = await fileStorage.statPrivateAudio(privateUri);
    if (!stat.ok || stat.value == null) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        stat.error ?? recordingLibraryError('RECORDING_EXPORT_STAT_FAILED'),
      );
    }
    if (!stat.value!.exists) {
      _upsert(
        current.copyWith(localFileState: RecordingLocalFileState.missing),
      );
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_PRIVATE_FILE_MISSING'),
      );
    }
    final privateSize = stat.value!.sizeBytes;
    if (privateSize != null &&
        (privateSize <= 0 ||
            (current.sizeBytes > 0 && privateSize != current.sizeBytes))) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_EXPORT_SIZE_MISMATCH'),
      );
    }
    final prepared = await fileStorage.prepareAudioExport(
      appPrivateUri: privateUri,
      displayName: exportDisplayName,
    );
    if (!prepared.ok || prepared.value == null) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        prepared.error ?? recordingLibraryError('RECORDING_EXPORT_FAILED'),
      );
    }
    final value = prepared.value!;
    if (value.sizeBytes <= 0 ||
        (privateSize != null && value.sizeBytes != privateSize) ||
        (current.sizeBytes > 0 && value.sizeBytes != current.sizeBytes)) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_EXPORT_SIZE_MISMATCH'),
      );
    }
    final rawPreparedHash = value.contentHash;
    final preparedHash = safeContentHash(rawPreparedHash);
    if (rawPreparedHash != null && preparedHash == null) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_EXPORT_HASH_INVALID'),
      );
    }
    final expectedHash = safeContentHash(current.contentHash);
    if (expectedHash != null &&
        preparedHash != null &&
        expectedHash != preparedHash) {
      return LocalRecordingResult<PreparedAudioExport>.failure(
        recordingLibraryError('RECORDING_EXPORT_HASH_MISMATCH'),
      );
    }
    return LocalRecordingResult<PreparedAudioExport>.success(
      PreparedAudioExport(
        opaqueExportRef: value.opaqueExportRef,
        displayName: exportDisplayName,
        sizeBytes: value.sizeBytes,
        mimeType: exportMimeType,
        contentHash: preparedHash,
      ),
    );
  }

  List<Map<String, Object?>> uploadDraftsFor(String recordingId) {
    if (!hasActiveAccount) return const <Map<String, Object?>>[];
    return _dao.listUploadDraftsFor(recordingId);
  }

  List<Map<String, Object?>> downloadedManifestsFor(String recordingId) {
    if (!hasActiveAccount) return const <Map<String, Object?>>[];
    return _dao.listDownloadedManifestsFor(recordingId);
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
    required DateTime createdAt,
    required DateTime updatedAt,
    String? cardSnDigest,
    String? ledgerSourceSignature,
    String? batchErrorCode,
    String? errorCode,
    String? localRecordingId,
    String? fileFormat,
    String? mimeType,
    int? durationSeconds,
    DateTime? recordedAt,
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
    if (!hasActiveAccount) return;
    final hasStagedMetadata =
        stagedNativeFileId != null ||
        stagedFileFormat != null ||
        stagedSizeBytes != null ||
        stagedContentHash != null;
    final safeSourceContentHash = safeContentHash(contentHash);
    final safeStagedContentHash = safeContentHash(stagedContentHash);
    if (contentHash != null && safeSourceContentHash == null) {
      throw ArgumentError('Invalid recording-card source content hash');
    }
    if (hasStagedMetadata && safeStagedContentHash == null) {
      throw ArgumentError('Invalid recording-card staged metadata');
    }
    if (safeSourceContentHash != null &&
        safeStagedContentHash != null &&
        safeSourceContentHash != safeStagedContentHash) {
      throw ArgumentError('Recording-card source and staged hashes conflict');
    }
    _dao.upsertRecordingCardWifiBatchItem(
      transferId: transferId,
      batchId: batchId,
      deviceFingerprint: deviceFingerprint,
      deviceIdentity: deviceIdentity,
      cardSnDigest: cardSnDigest,
      batchErrorCode: batchErrorCode,
      deviceFileId: deviceFileId,
      deviceFilename: deviceFilename,
      localFileKey: localFileKey,
      itemOrder: itemOrder,
      expectedSizeBytes: expectedSizeBytes,
      attemptCount: attemptCount,
      batchStage: batchStage,
      stage: stage,
      idempotencyKey: idempotencyKey,
      createdAt: createdAt.toIso8601String(),
      updatedAt: updatedAt.toIso8601String(),
      errorCode: errorCode,
      localRecordingId: localRecordingId,
      fileFormat: fileFormat,
      mimeType: mimeType,
      durationSeconds: durationSeconds,
      recordedAt: recordedAt?.toIso8601String(),
      contentHash: safeSourceContentHash,
      ledgerSourceSignature: ledgerSourceSignature,
      sourceSizeConfidence: sourceSizeConfidence,
      plannedNativeFileId: plannedNativeFileId,
      attemptId: attemptId,
      stopRequested: stopRequested,
      stagedNativeFileId: stagedNativeFileId,
      stagedFileFormat: stagedFileFormat,
      stagedSizeBytes: stagedSizeBytes,
      stagedContentHash: safeStagedContentHash,
      checkpointOnly: checkpointOnly,
      allowLegacyIdentityUpgrade: allowLegacyIdentityUpgrade,
    );
  }

  LocalDatabaseResult<void> writeRecordingCardWifiBatchAtomically(
    void Function() action,
  ) {
    return _dao.writeRecordingCardWifiBatchAtomically(action);
  }

  Future<LocalDatabaseResult<bool>> flushRecordingCardPersistence() async {
    try {
      await _database.flushPersistence();
      return LocalDatabaseResult<bool>.success(true);
    } catch (_) {
      return LocalDatabaseResult<bool>.failure(
        recordingLibraryError('RECORDING_CARD_LEDGER_FLUSH_FAILED'),
      );
    }
  }

  List<LocalDatabaseRecord> recordingCardWifiBatchItems({String? batchId}) {
    if (!hasActiveAccount) return const <LocalDatabaseRecord>[];
    return _dao.listRecordingCardWifiBatchItems(batchId: batchId);
  }

  Future<LocalDatabaseResult<bool>> stopInvalidRecordingCardWifiBatch(
    String batchId,
  ) async {
    if (!hasActiveAccount) {
      return LocalDatabaseResult.failure(
        recordingLibraryError('RECORDING_CARD_ACCOUNT_REQUIRED'),
      );
    }
    final written = _dao.writeRecordingCardWifiBatchAtomically(
      () => _dao.stopInvalidRecordingCardWifiBatch(batchId),
    );
    if (!written.ok) return LocalDatabaseResult.failure(written.error!);
    return flushRecordingCardPersistence();
  }

  void deleteRecordingCardWifiBatch(String batchId) {
    if (!hasActiveAccount) return;
    _dao.deleteRecordingCardWifiBatch(batchId);
  }

  Future<RecordingLibraryItem?> _findReusableDownloadedRecording({
    required String? contentHash,
    required int sizeBytes,
  }) async {
    final hash = safeContentHash(contentHash);
    if (hash == null || sizeBytes <= 0) return null;
    for (final item in _allItems()) {
      if (item.source != RecordingLibrarySource.device ||
          item.status == RecordingLibraryStatus.recycled ||
          item.localFileState != RecordingLocalFileState.ready ||
          item.sizeBytes != sizeBytes ||
          safeContentHash(item.contentHash) != hash ||
          item.appPrivateUri == null ||
          !isSafeAppPrivateUri(item.appPrivateUri!)) {
        continue;
      }
      if (await _isReusableDownloadedRecording(
        item,
        contentHash: hash,
        sizeBytes: sizeBytes,
      )) {
        return item;
      }
    }
    return null;
  }

  Future<bool> _isReusableDownloadedRecording(
    RecordingLibraryItem item, {
    required String contentHash,
    required int sizeBytes,
  }) async {
    if (item.source != RecordingLibrarySource.device ||
        item.status == RecordingLibraryStatus.recycled ||
        item.localFileState != RecordingLocalFileState.ready ||
        item.sizeBytes != sizeBytes ||
        safeContentHash(item.contentHash) != contentHash ||
        item.appPrivateUri == null ||
        !isSafeAppPrivateUri(item.appPrivateUri!)) {
      return false;
    }
    final stat = await fileStorage.statPrivateAudio(item.appPrivateUri!);
    if (!stat.ok ||
        stat.value?.exists != true ||
        stat.value?.sizeBytes != sizeBytes) {
      return false;
    }
    final actualHash = await fileStorage.hashPrivateAudio(item.appPrivateUri!);
    return actualHash.ok && safeContentHash(actualHash.value) == contentHash;
  }

  List<RecordingLibraryItem> _allItems() {
    if (!hasActiveAccount) return const <RecordingLibraryItem>[];
    return _dao
        .listLocalRecordings()
        .map(RecordingLibraryItem.fromRecord)
        .whereType<RecordingLibraryItem>()
        .toList(growable: false);
  }

  Future<void> _verifyLocalFileStates() async {
    for (final item in _allItems()) {
      var current = item;
      var uri = current.appPrivateUri;
      if (uri == null ||
          current.localFileState == RecordingLocalFileState.part ||
          current.localFileState == RecordingLocalFileState.none) {
        continue;
      }
      final reference = PrivateRecordingPathResolver().parse(uri);
      if (reference?.kind == PrivateRecordingReferenceKind.legacyFlutter) {
        final migration = await fileStorage.migrateLegacyPrivateAudio(
          appPrivateUri: uri,
          recordingCard: current.source == RecordingLibrarySource.device,
        );
        if (migration.ok &&
            migration.value != null &&
            migration.value!.migrated) {
          final migrated = current.copyWith(
            appPrivateUri: migration.value!.effectiveUri,
            localFileState: RecordingLocalFileState.ready,
            updatedAt: DateTime.now().toUtc(),
          );
          final persisted = _database.withTransaction((_) {
            _upsert(migrated);
            _rewriteRelatedPrivateUris(
              recordingId: current.recordingId,
              appPrivateUri: migration.value!.effectiveUri,
            );
            return true;
          });
          if (persisted.ok) {
            current = migrated;
            uri = migrated.appPrivateUri;
          }
        }
      }
      final activeUri = uri;
      if (activeUri == null) continue;
      final stat = await fileStorage.statPrivateAudio(activeUri);
      if (!stat.ok || stat.value == null) {
        continue;
      }
      final exists = stat.value!.exists;
      final actualSize = stat.value!.sizeBytes;
      final deviceSizeMismatch =
          current.source == RecordingLibrarySource.device &&
          exists &&
          current.sizeBytes > 0 &&
          actualSize != null &&
          actualSize != current.sizeBytes;
      final preserveMissingDeviceState =
          current.source == RecordingLibrarySource.device &&
          current.localFileState == RecordingLocalFileState.missing;
      final nextState =
          exists && !deviceSizeMismatch && !preserveMissingDeviceState
          ? RecordingLocalFileState.ready
          : RecordingLocalFileState.missing;
      final actualDuration = stat.value!.durationSeconds;
      final canRepairMetadata =
          exists && current.source != RecordingLibrarySource.device;
      final repairedSize =
          canRepairMetadata && actualSize != null && actualSize > 0
          ? actualSize
          : current.sizeBytes;
      final repairedDuration =
          canRepairMetadata && actualDuration != null && actualDuration > 0
          ? actualDuration
          : current.durationSeconds;
      if (nextState != current.localFileState ||
          repairedSize != current.sizeBytes ||
          repairedDuration != current.durationSeconds) {
        final repaired = current.copyWith(
          localFileState: nextState,
          sizeBytes: repairedSize,
          durationSeconds: repairedDuration,
          updatedAt: DateTime.now().toUtc(),
        );
        _database.withTransaction((_) {
          _upsert(repaired);
          if (current.source != RecordingLibrarySource.device) {
            _rewriteRelatedPrivateMetadata(
              recordingId: repaired.recordingId,
              appPrivateUri: repaired.appPrivateUri!,
              sizeBytes: repaired.sizeBytes,
              durationSeconds: repaired.durationSeconds,
              updatedAt: repaired.updatedAt,
            );
          }
          return true;
        });
      }
    }
  }

  Future<void> _recoverUnindexedPrivateRecordings() async {
    final resolver = recoveryPathResolver;
    if (resolver == null) return;
    final currentItems = _allItems();
    final indexedUris = currentItems
        .map((item) => item.appPrivateUri)
        .whereType<String>()
        .toSet();
    final List<DiscoveredPrivateRecording> discovered;
    try {
      discovered = await resolver.discoverExistingRecordings();
    } catch (_) {
      return;
    }
    for (final file in discovered) {
      if (indexedUris.contains(file.appPrivateUri)) {
        continue;
      }
      final stat = await fileStorage.statPrivateAudio(file.appPrivateUri);
      final value = stat.value;
      if (!stat.ok ||
          value == null ||
          !value.exists ||
          value.sizeBytes == null ||
          value.sizeBytes! <= 0) {
        continue;
      }
      final source = file.kind == PrivateRecordingReferenceKind.recordingCard
          ? RecordingLibrarySource.device
          : RecordingLibrarySource.localImport;
      final itemOrError = _itemFromPrivateAudio(
        PrivateAudioFile(
          fileId: 'recovered-${stableRecordingHash(file.appPrivateUri)}',
          appPrivateUri: file.appPrivateUri,
          displayName: file.fileName,
          mimeType: _mimeTypeForRecoveredFile(file.fileName),
          sizeBytes: value.sizeBytes!,
          durationSeconds: value.durationSeconds,
          recordedAt: file.modifiedAt,
        ),
        file.modifiedAt,
        source: source,
        deviceFilename: source == RecordingLibrarySource.device
            ? file.fileName
            : null,
      );
      if (itemOrError is! RecordingLibraryItem ||
          itemOrError.format == RecordingLibraryFormat.unknown) {
        continue;
      }
      _upsert(itemOrError);
      indexedUris.add(file.appPrivateUri);
    }
  }

  void _rewriteRelatedPrivateUris({
    required String recordingId,
    required String appPrivateUri,
  }) {
    final current = _find(recordingId);
    _rewriteRelatedPrivateMetadata(
      recordingId: recordingId,
      appPrivateUri: appPrivateUri,
      sizeBytes: current?.sizeBytes,
      durationSeconds: current?.durationSeconds,
      updatedAt: current?.updatedAt ?? DateTime.now().toUtc(),
    );
  }

  void _rewriteRelatedPrivateMetadata({
    required String recordingId,
    required String appPrivateUri,
    required int? sizeBytes,
    required int? durationSeconds,
    required DateTime updatedAt,
  }) {
    for (final draft in _uploadDraftStore.listDraftsForLocalRecording(
      recordingId,
    )) {
      _uploadDraftStore.saveDraft(
        draft.copyWith(
          appPrivateUri: appPrivateUri,
          sizeBytes: sizeBytes,
          durationSeconds: durationSeconds,
          updatedAt: updatedAt,
        ),
      );
    }
    for (final record in _dao.listDownloadedManifestsFor(recordingId)) {
      _dao.upsertDownloadedManifestRecord(<String, Object?>{
        ...record,
        'app_private_uri': appPrivateUri,
        if (sizeBytes != null) 'actual_size_bytes': sizeBytes,
        if (durationSeconds != null) 'duration_seconds': durationSeconds,
        'updated_at': updatedAt.toIso8601String(),
      });
    }
  }

  Future<LocalRecordingResult<PrivateAudioFile>> _adoptPrivateFileIfNeeded(
    PrivateAudioFile file, {
    required bool recordingCard,
  }) async {
    // Legacy test/support repositories intentionally have no owner. They must
    // keep the original missing-file contract rather than probing global roots.
    if (_accountScope == null) {
      return LocalRecordingResult<PrivateAudioFile>.success(file);
    }
    final current = await fileStorage.statPrivateAudio(file.appPrivateUri);
    if (current.ok && current.value?.exists == true) {
      return LocalRecordingResult<PrivateAudioFile>.success(file);
    }
    final migration = await fileStorage.migrateLegacyPrivateAudio(
      appPrivateUri: file.appPrivateUri,
      recordingCard: recordingCard,
    );
    if (!migration.ok ||
        migration.value == null ||
        !migration.value!.migrated) {
      return LocalRecordingResult<PrivateAudioFile>.failure(
        migration.error ??
            recordingLibraryError('RECORDING_ACCOUNT_FILE_ADOPTION_FAILED'),
      );
    }
    return LocalRecordingResult<PrivateAudioFile>.success(
      PrivateAudioFile(
        fileId: migration.value!.fileId,
        appPrivateUri: migration.value!.effectiveUri,
        displayName: file.displayName,
        mimeType: file.mimeType,
        sizeBytes: file.sizeBytes,
        durationSeconds: file.durationSeconds,
        contentHash: file.contentHash,
        recordedAt: file.recordedAt,
      ),
    );
  }

  Future<PrivateAudioFile> _withVerifiedPrivateMetadata(
    PrivateAudioFile file,
  ) async {
    final stat = await fileStorage.statPrivateAudio(file.appPrivateUri);
    final value = stat.ok ? stat.value : null;
    return PrivateAudioFile(
      fileId: file.fileId,
      appPrivateUri: file.appPrivateUri,
      displayName: file.displayName,
      mimeType: file.mimeType,
      sizeBytes: value?.sizeBytes != null && value!.sizeBytes! > 0
          ? value.sizeBytes!
          : file.sizeBytes,
      durationSeconds: file.durationSeconds ?? value?.durationSeconds,
      contentHash: file.contentHash,
      recordedAt: file.recordedAt,
    );
  }

  RecordingLibraryItem? _find(String recordingId) {
    if (!hasActiveAccount) return null;
    final record = _dao.getLocalRecording(recordingId);
    return record == null ? null : RecordingLibraryItem.fromRecord(record);
  }

  void _upsert(RecordingLibraryItem item) {
    if (!hasActiveAccount) {
      throw StateError('RECORDING_LOGIN_REQUIRED');
    }
    if (item.localFileState == RecordingLocalFileState.part &&
        item.status != RecordingLibraryStatus.downloading) {
      throw StateError('Part recording cannot enter formal playable state');
    }
    _dao.upsertLocalRecording(item.recordingId, item.toRecord());
  }

  Object _initialImportDraft(RecordingLibraryItem item) {
    final appPrivateUri = item.appPrivateUri;
    final mimeType = _mimeTypeForUpload(item.format);
    if (appPrivateUri == null ||
        !isSafeAppPrivateUri(appPrivateUri) ||
        item.sizeBytes <= 0 ||
        mimeType == null) {
      return recordingLibraryError('RECORDING_UPLOAD_NOT_READY');
    }
    return createInitialUploadDraft(
      draftId: 'draft-${item.recordingId}',
      localRecordingId: item.recordingId,
      appPrivateUri: appPrivateUri,
      fileName: item.displayName,
      mimeType: mimeType,
      sizeBytes: item.sizeBytes,
      durationSeconds: item.durationSeconds,
      sourceScene: 'raw_material',
      recordingSource: 'local_upload',
      updatedAt: item.updatedAt,
      contentHash: item.contentHash,
      recordedAt: item.createdAt,
      title: item.displayName,
    );
  }

  Future<void> _discardImportedPrivateAudio(String appPrivateUri) async {
    try {
      await fileStorage.deletePrivateAudio(appPrivateUri);
    } catch (_) {
      // An import persistence failure must not become an unhandled cleanup error.
    }
  }
}

enum _LocalRecordingOperation { upload, syncRegistration, deletion }

LocalRecordingResult<T> _loginRequired<T>() {
  return LocalRecordingResult<T>.failure(
    recordingLibraryError('RECORDING_LOGIN_REQUIRED'),
  );
}

String? _normalizeRecordingAccountScope(String? value) {
  if (value == null) return null;
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  if (normalized.length > 256 || normalized.contains('\u0000')) {
    throw ArgumentError.value(value, 'accountScope', 'is unsafe');
  }
  return normalized;
}

String? _mimeTypeForUpload(RecordingLibraryFormat format) {
  return switch (format) {
    RecordingLibraryFormat.mp3 => 'audio/mpeg',
    RecordingLibraryFormat.opus => 'audio/opus',
    RecordingLibraryFormat.m4a => 'audio/mp4',
    RecordingLibraryFormat.wav => 'audio/wav',
    RecordingLibraryFormat.unknown => null,
  };
}

String _mimeTypeForRecoveredFile(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.opus')) return 'audio/opus';
  if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) return 'audio/mp4';
  if (lower.endsWith('.wav')) return 'audio/wav';
  return 'application/octet-stream';
}

Object _itemFromPrivateAudio(
  PrivateAudioFile file,
  DateTime now, {
  RecordingLibrarySource source = RecordingLibrarySource.localImport,
  String? deviceFilename,
  String? recordingId,
}) {
  final displayName = safeDisplayName(file.displayName);
  if (displayName == null) {
    return file.displayName.trim().isEmpty
        ? recordingLibraryError('RECORDING_NAME_EMPTY')
        : recordingLibraryError('RECORDING_LOCAL_NAME_UNSAFE');
  }
  if (!isSafeAppPrivateUri(file.appPrivateUri)) {
    return recordingLibraryError('RECORDING_LOCAL_FILE_UNSAFE');
  }
  return RecordingLibraryItem(
    recordingId: recordingId ?? 'local-${stableRecordingHash(file.fileId)}',
    source: source,
    displayName: displayName,
    originalFilename: displayName,
    deviceFilename: safeDisplayName(deviceFilename),
    appPrivateUri: file.appPrivateUri,
    format: formatFromMetadata(file.mimeType, displayName),
    localFileState: RecordingLocalFileState.ready,
    status: RecordingLibraryStatus.localOnly,
    durationSeconds: file.durationSeconds == null || file.durationSeconds! < 0
        ? 0
        : file.durationSeconds!,
    sizeBytes: file.sizeBytes < 0 ? 0 : file.sizeBytes,
    contentHash: safeContentHash(file.contentHash),
    isFavorite: false,
    tagIds: const <String>[],
    createdAt: file.recordedAt ?? now,
    updatedAt: now,
  );
}

RecordingLibraryItem _recordingWithContentHash(
  RecordingLibraryItem item,
  String contentHash,
  DateTime updatedAt,
) {
  return RecordingLibraryItem(
    recordingId: item.recordingId,
    source: item.source,
    displayName: item.displayName,
    format: item.format,
    localFileState: item.localFileState,
    status: item.status,
    durationSeconds: item.durationSeconds,
    sizeBytes: item.sizeBytes,
    contentHash: contentHash,
    isFavorite: item.isFavorite,
    tagIds: item.tagIds,
    createdAt: item.createdAt,
    updatedAt: updatedAt,
    originalFilename: item.originalFilename,
    deviceFilename: item.deviceFilename,
    appPrivateUri: item.appPrivateUri,
    remoteRecordingId: item.remoteRecordingId,
    contentLineId: item.contentLineId,
    deletedAt: item.deletedAt,
  );
}

bool _isSafePickerRef(String value) {
  return value.isNotEmpty &&
      !value.endsWith('.part') &&
      !unsafeLocalLibraryText(value);
}

bool _isSafeMetadataText(String value) {
  return value.trim().isNotEmpty &&
      value.length <= 128 &&
      !value.endsWith('.part') &&
      !unsafeLocalLibraryText(value);
}

String _recordingCardLinkKey(String localRecordingId, String deviceFileId) {
  return '${localRecordingId.length}:$localRecordingId$deviceFileId';
}

int? _positiveMetadataInt(Object? value) {
  final parsed = switch (value) {
    int value => value,
    num value => value.floor(),
    String value => int.tryParse(value),
    _ => null,
  };
  return parsed != null && parsed > 0 ? parsed : null;
}

int? _nonNegativeMetadataInt(Object? value) {
  final parsed = switch (value) {
    int value => value,
    num value => value.floor(),
    String value => int.tryParse(value),
    _ => null,
  };
  return parsed != null && parsed >= 0 ? parsed : null;
}

bool _isSafeRecordingLibraryUri(String value) {
  return isSafeAppPrivateRecordingUri(value);
}

String _emptyStateFor(RecordingLibraryQuery query) {
  if (query.view == RecordingLibraryView.recycleBin) return 'recycleBinEmpty';
  return query.searchText?.trim().isNotEmpty == true
      ? 'noSearchResults'
      : 'noLocalRecordings';
}

bool _draftBlocksLocalDeletion(UploadDraft draft) {
  return switch (draft.stage) {
    UploadDraftStage.uploadTokenRequesting ||
    UploadDraftStage.uploadTokenReady ||
    UploadDraftStage.objectUploading ||
    UploadDraftStage.objectUploaded ||
    UploadDraftStage.completing ||
    UploadDraftStage.completed ||
    UploadDraftStage.creatingRecording ||
    UploadDraftStage.persistingLocalLink => true,
    UploadDraftStage.localReady ||
    UploadDraftStage.asrQueued ||
    UploadDraftStage.uploaded ||
    UploadDraftStage.asrCompleted ||
    UploadDraftStage.asrFailed ||
    UploadDraftStage.tokenFailed ||
    UploadDraftStage.objectUploadFailed ||
    UploadDraftStage.completeFailed ||
    UploadDraftStage.createRecordingFailed ||
    UploadDraftStage.localLinkFailed ||
    UploadDraftStage.cancelled => false,
  };
}

bool _draftOwnsRemoteObservation(UploadDraft draft) {
  return draft.recordingId?.trim().isNotEmpty == true ||
      draft.stage == UploadDraftStage.asrQueued ||
      draft.stage == UploadDraftStage.uploaded ||
      draft.stage == UploadDraftStage.asrCompleted ||
      draft.stage == UploadDraftStage.asrFailed;
}
