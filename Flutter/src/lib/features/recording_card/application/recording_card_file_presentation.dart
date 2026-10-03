import '../../../core/native/recording_card_native_port.dart';
import '../../recordings/domain/recording_library.dart';
import '../../recordings/domain/recording_transcription_receipt.dart';
import '../domain/recording_card_sync_ledger.dart';
import 'recording_card_controller.dart';

enum RecordingCardFileDisplayStatus {
  notSynced('未同步'),
  queued('等待同步'),
  transferring('同步中'),
  verifying('正在校验'),
  registering('正在入库'),
  paused('同步已暂停'),
  recoveryRequired('同步待恢复'),
  synced('已同步'),
  deleting('正在删除本地'),
  locallyDeleted('本地已删除'),
  locallyMissing('本地文件缺失'),
  unverified('本地待核验'),
  unknown('同步状态待确认'),
  failed('同步失败');

  const RecordingCardFileDisplayStatus(this.label);
  final String label;

  bool get hasActiveTransfer => switch (this) {
    transferring || verifying || registering => true,
    _ => false,
  };

  bool get isAutomaticCandidate => switch (this) {
    notSynced || queued || recoveryRequired || locallyMissing || failed => true,
    _ => false,
  };
}

final class RecordingCardFilePresentation {
  const RecordingCardFilePresentation({
    required this.file,
    required this.status,
    required this.transcribed,
    this.localRecording,
    this.lastSyncedAt,
  });

  final RecordingCardScannedFile file;
  final RecordingCardFileDisplayStatus status;
  final RecordingLibraryItem? localRecording;
  final bool transcribed;
  final DateTime? lastSyncedAt;
}

bool recordingCardWifiBatchMatchesCard({
  required RecordingCardWifiBatchSnapshot? batch,
  required String? cardSnDigest,
  required String? deviceFingerprint,
}) {
  if (batch == null) return false;
  final persistedDigest = _text(batch.cardSnDigest);
  if (persistedDigest != null) {
    return _text(cardSnDigest) == persistedDigest;
  }
  final fingerprint = _text(deviceFingerprint);
  return fingerprint != null && batch.deviceFingerprint == fingerprint;
}

List<RecordingCardFilePresentation> buildRecordingCardFilePresentations({
  required List<RecordingCardScannedFile>? directory,
  required List<RecordingCardFileLedgerEntry> ledger,
  required String? cardSnDigest,
  required RecordingCardControllerState card,
  required RecordingLibraryItem? Function(String) localRecordingLookup,
  required bool localInventoryLoaded,
  Iterable<RecordingTranscriptionReceipt> receipts =
      const <RecordingTranscriptionReceipt>[],
}) {
  final entries = ledger
      .where((entry) => entry.cardSnDigest == cardSnDigest)
      .toList(growable: false);
  final files =
      directory ??
      entries
          .where(
            (entry) =>
                entry.cardState == RecordingCardFilePresenceState.present,
          )
          .map(_cachedFile)
          .toList(growable: false);
  final result = <RecordingCardFilePresentation>[];
  for (final file in files) {
    final entry = _matchingEntry(file, entries, cardSnDigest);
    if (entry?.cardState == RecordingCardFilePresenceState.deleted) continue;
    final localId = _text(entry?.localRecordingId) ?? _text(file.localFileId);
    final candidate = localId == null ? null : localRecordingLookup(localId);
    final local = _verifiedLocal(file, entry, candidate);
    final status = _displayStatus(
      file,
      entry,
      local,
      localInventoryLoaded,
      card,
      cardSnDigest,
    );
    final isSynced = status == RecordingCardFileDisplayStatus.synced;
    final syncState = isSynced
        ? RecordingCardFileSyncState.synced
        : status.hasActiveTransfer
        ? RecordingCardFileSyncState.downloading
        : switch (status) {
            RecordingCardFileDisplayStatus.locallyDeleted ||
            RecordingCardFileDisplayStatus.locallyMissing =>
              RecordingCardFileSyncState.localMissing,
            RecordingCardFileDisplayStatus.failed =>
              RecordingCardFileSyncState.failed,
            _ => RecordingCardFileSyncState.deviceOnly,
          };
    result.add(
      RecordingCardFilePresentation(
        file: RecordingCardScannedFile(
          deviceFileId: file.deviceFileId,
          localFileKey: file.localFileKey,
          deviceFilename: file.deviceFilename,
          sizeBytes: file.sizeBytes,
          durationSeconds: file.durationSeconds,
          recordedAt: file.recordedAt,
          contentHash: file.contentHash,
          sizeConfidence: file.sizeConfidence,
          format: file.format,
          mimeType: file.mimeType,
          syncState: syncState,
          localFileId: isSynced ? local?.recordingId ?? file.localFileId : null,
          appPrivateUri: isSynced
              ? local?.appPrivateUri ?? file.appPrivateUri
              : null,
        ),
        status: status,
        localRecording: isSynced ? local : null,
        transcribed: _hasReceipt(file, entry, local, receipts),
        lastSyncedAt: entry?.lastSyncedAt,
      ),
    );
  }
  return List<RecordingCardFilePresentation>.unmodifiable(result);
}

RecordingCardFileDisplayStatus _displayStatus(
  RecordingCardScannedFile file,
  RecordingCardFileLedgerEntry? entry,
  RecordingLibraryItem? local,
  bool localInventoryLoaded,
  RecordingCardControllerState card,
  String? cardSnDigest,
) {
  final active = _activeFileStatus(file, card, cardSnDigest);
  if (active != null) return active;
  final localState = entry?.localState;
  switch (localState) {
    case RecordingCardFileLocalState.localDeleted:
      return RecordingCardFileDisplayStatus.locallyDeleted;
    case RecordingCardFileLocalState.deleting:
      return RecordingCardFileDisplayStatus.deleting;
    case RecordingCardFileLocalState.queued:
      return RecordingCardFileDisplayStatus.queued;
    case RecordingCardFileLocalState.syncing:
      return RecordingCardFileDisplayStatus.recoveryRequired;
    case RecordingCardFileLocalState.failed:
      return RecordingCardFileDisplayStatus.failed;
    default:
      break;
  }
  final expectsLocal =
      localState == RecordingCardFileLocalState.synced ||
      (entry == null && file.syncState == RecordingCardFileSyncState.synced);
  if (expectsLocal) {
    if (local != null && localInventoryLoaded) {
      return RecordingCardFileDisplayStatus.synced;
    }
    final nativeVerified =
        card.fileCatalog.isReady &&
        file.syncState == RecordingCardFileSyncState.synced &&
        _text(file.localFileId) != null &&
        isSafeAppPrivateUri(file.appPrivateUri ?? '');
    if (!localInventoryLoaded && nativeVerified) {
      return RecordingCardFileDisplayStatus.synced;
    }
    return localInventoryLoaded
        ? RecordingCardFileDisplayStatus.locallyMissing
        : RecordingCardFileDisplayStatus.unverified;
  }
  if (localState == RecordingCardFileLocalState.legacyUnknown) {
    return RecordingCardFileDisplayStatus.unknown;
  }
  return switch (file.syncState) {
    RecordingCardFileSyncState.downloading =>
      RecordingCardFileDisplayStatus.recoveryRequired,
    RecordingCardFileSyncState.localMissing =>
      RecordingCardFileDisplayStatus.locallyMissing,
    RecordingCardFileSyncState.failed => RecordingCardFileDisplayStatus.failed,
    _ => RecordingCardFileDisplayStatus.notSynced,
  };
}

RecordingCardFileDisplayStatus? _activeFileStatus(
  RecordingCardScannedFile file,
  RecordingCardControllerState card,
  String? cardSnDigest,
) {
  final batch = card.wifiBatch;
  final batchMatchesCard = recordingCardWifiBatchMatchesCard(
    batch: batch,
    cardSnDigest: cardSnDigest,
    deviceFingerprint: card.snapshot.deviceState.safeDeviceFingerprint,
  );
  if (batch != null && batchMatchesCard && !batch.isTerminal) {
    final item = batch.items
        .where(
          (item) =>
              (item.file.localFileKey == file.localFileKey ||
                  item.ledgerSourceSignature == file.localFileKey) &&
              item.file.deviceFileId == file.deviceFileId &&
              item.file.deviceFilename == file.deviceFilename &&
              _compatibleHash(item.file.contentHash, file.contentHash),
        )
        .firstOrNull;
    if (item != null && !item.isCompleted) {
      if (batch.state == RecordingCardWifiBatchState.paused) {
        return RecordingCardFileDisplayStatus.paused;
      }
      if (card.operation.isActive &&
          card.operation.kind == RecordingCardOperationKind.wifiTransfer) {
        return switch (item.state) {
          RecordingCardWifiBatchItemState.transferring =>
            RecordingCardFileDisplayStatus.transferring,
          RecordingCardWifiBatchItemState.verifying =>
            RecordingCardFileDisplayStatus.verifying,
          RecordingCardWifiBatchItemState.registering =>
            RecordingCardFileDisplayStatus.registering,
          RecordingCardWifiBatchItemState.failed =>
            RecordingCardFileDisplayStatus.failed,
          _ => RecordingCardFileDisplayStatus.queued,
        };
      }
    }
  }
  if (!card.operation.isActive ||
      card.operation.kind != RecordingCardOperationKind.bluetoothTransfer ||
      card.operation.connectionRevision !=
          card.fileCatalog.connectionRevision ||
      !card.snapshot.deviceState.isOperationallyConnected ||
      card.activeFileKey != file.localFileKey) {
    return null;
  }
  final progress = card.snapshot.transferProgress;
  if (progress?.localFileKey != file.localFileKey ||
      progress?.transport == RecordingCardTransferTransport.wifi) {
    return RecordingCardFileDisplayStatus.transferring;
  }
  return switch (progress?.phase) {
    RecordingCardTransferPhase.queued => RecordingCardFileDisplayStatus.queued,
    RecordingCardTransferPhase.verifying =>
      RecordingCardFileDisplayStatus.verifying,
    RecordingCardTransferPhase.registering ||
    RecordingCardTransferPhase.completed =>
      RecordingCardFileDisplayStatus.registering,
    RecordingCardTransferPhase.failed => RecordingCardFileDisplayStatus.failed,
    RecordingCardTransferPhase.cancelled ||
    RecordingCardTransferPhase.paused => RecordingCardFileDisplayStatus.paused,
    _ => RecordingCardFileDisplayStatus.transferring,
  };
}

RecordingCardFileLedgerEntry? _matchingEntry(
  RecordingCardScannedFile file,
  List<RecordingCardFileLedgerEntry> entries,
  String? digest,
) {
  if (digest == null) return null;
  final signature = RecordingCardFileIdentity.sourceSignatureFor(
    cardSnDigest: digest,
    deviceFileId: file.deviceFileId,
    deviceFilename: file.deviceFilename,
    sizeBytes: file.sizeBytes,
    recordedAt: file.recordedAt,
  );
  final exact = entries
      .where(
        (entry) =>
            entry.sourceSignature == signature ||
            entry.sourceSignature == file.localFileKey,
      )
      .firstOrNull;
  if (exact != null) {
    return _compatibleHash(file.contentHash, exact.contentHash) ? exact : null;
  }
  final hash = _text(file.contentHash);
  if (hash == null) return null;
  final matching = entries
      .where(
        (entry) =>
            entry.cardState == RecordingCardFilePresenceState.present &&
            _text(entry.contentHash) == hash,
      )
      .toList();
  return matching.length == 1 ? matching.single : null;
}

RecordingLibraryItem? _verifiedLocal(
  RecordingCardScannedFile file,
  RecordingCardFileLedgerEntry? entry,
  RecordingLibraryItem? item,
) {
  if (item == null ||
      item.status == RecordingLibraryStatus.recycled ||
      item.localFileState != RecordingLocalFileState.ready ||
      !isSafeAppPrivateUri(item.appPrivateUri ?? '') ||
      !_compatibleHash(item.contentHash, entry?.contentHash) ||
      !_compatibleHash(item.contentHash, file.contentHash)) {
    return null;
  }
  if (entry == null && _text(file.appPrivateUri) != _text(item.appPrivateUri)) {
    return null;
  }
  return item;
}

bool _hasReceipt(
  RecordingCardScannedFile file,
  RecordingCardFileLedgerEntry? entry,
  RecordingLibraryItem? local,
  Iterable<RecordingTranscriptionReceipt> receipts,
) {
  final hash =
      _text(file.contentHash) ??
      _text(entry?.contentHash) ??
      _text(local?.contentHash);
  final localId = _text(entry?.localRecordingId) ?? _text(local?.recordingId);
  return receipts.any(
    (receipt) =>
        _compatibleHash(hash, receipt.contentHash) &&
        ((hash != null &&
                (hash == _text(receipt.contentHash) ||
                    hash == receipt.fileIdentity)) ||
            (entry != null && entry.sourceSignature == receipt.fileIdentity) ||
            (localId != null && localId == receipt.localRecordingId)),
  );
}

RecordingCardScannedFile _cachedFile(RecordingCardFileLedgerEntry entry) {
  final extension = entry.deviceFilename.split('.').last.toLowerCase();
  final format =
      RecordingCardFileFormat.values
          .where((value) => value.name == extension)
          .firstOrNull ??
      RecordingCardFileFormat.unknown;
  return RecordingCardScannedFile(
    deviceFileId: entry.deviceFileId,
    localFileKey: entry.sourceSignature,
    deviceFilename: entry.deviceFilename,
    recordedAt: entry.recordedAt,
    sizeBytes: entry.sizeBytes,
    durationSeconds: entry.durationSeconds,
    contentHash: entry.contentHash,
    format: format,
    mimeType: switch (format) {
      RecordingCardFileFormat.mp3 => 'audio/mpeg',
      RecordingCardFileFormat.opus => 'audio/opus',
      RecordingCardFileFormat.m4a => 'audio/mp4',
      RecordingCardFileFormat.wav => 'audio/wav',
      RecordingCardFileFormat.unknown => null,
    },
  );
}

bool _compatibleHash(String? left, String? right) =>
    _text(left) == null || _text(right) == null || _text(left) == _text(right);

String? _text(String? value) =>
    value?.trim().isEmpty != false ? null : value!.trim();
