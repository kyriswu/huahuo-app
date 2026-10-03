// ignore_for_file: prefer_initializing_formals

import '../domain/recording_library.dart';
import '../domain/recording_transcription_receipt.dart';
import 'recording_processing_tracker.dart';

typedef RecordingTranscriptionLocalItemLookup =
    RecordingLibraryItem? Function(String localRecordingId);

/// Converts tracker-owned backend facts into durable local completion proof.
///
/// The projector is deliberately independent from batch state so the existing
/// one-file flow and every retained batch write the same receipt contract.
final class RecordingTranscriptionReceiptProjector {
  RecordingTranscriptionReceiptProjector({
    required RecordingTranscriptionReceiptStorePort store,
    required String accountScope,
    RecordingTranscriptionLocalItemLookup? localItemLookup,
    DateTime Function()? now,
  }) : _store = store,
       _accountScope = _requiredText(accountScope, 'accountScope'),
       _localItemLookup = localItemLookup,
       _now = now ?? DateTime.now;

  final RecordingTranscriptionReceiptStorePort _store;
  final String _accountScope;
  final RecordingTranscriptionLocalItemLookup? _localItemLookup;
  final DateTime Function() _now;

  Future<int> applyProcessingState(RecordingProcessingState processing) async {
    var persisted = 0;
    for (final task in processing.tasks) {
      if (await applyProcessingTask(task)) persisted += 1;
    }
    return persisted;
  }

  /// Returns true only when a new or stronger receipt was durably projected.
  Future<bool> applyProcessingTask(RecordingProcessingTask task) async {
    final detail = task.detail;
    if (detail == null || !detail.hasFinalTranscriptFact) return false;

    final draftRemoteId = _text(task.draft.recordingId);
    final detailRemoteId = _text(detail.recording.recordingId);
    final localRecordingId = _text(task.draft.localRecordingId);
    if (draftRemoteId == null ||
        detailRemoteId == null ||
        draftRemoteId != detailRemoteId ||
        localRecordingId == null) {
      return false;
    }

    RecordingLibraryItem? localItem;
    try {
      final candidate = _localItemLookup?.call(localRecordingId);
      if (candidate?.recordingId == localRecordingId) localItem = candidate;
    } on Object {
      // The durable upload draft still carries enough identity for projection.
    }

    final contentHash = safeContentHash(
      localItem?.contentHash ?? task.draft.contentHash,
    );
    final existingByRemote = _store.findByRemoteRecordingId(detailRemoteId);
    if (!_hashesCompatible(existingByRemote?.contentHash, contentHash)) {
      return false;
    }
    var existing = existingByRemote;
    final existingByLocal = _store.findByLocalRecordingId(localRecordingId);
    if (existing == null &&
        _hashesCompatible(existingByLocal?.contentHash, contentHash)) {
      existing = existingByLocal;
    }
    final defaultIdentity = contentHash ?? 'local:$localRecordingId';
    final existingByIdentity = _store.findByFileIdentity(defaultIdentity);
    if (existing == null &&
        _hashesCompatible(existingByIdentity?.contentHash, contentHash)) {
      existing = existingByIdentity;
    }

    final observedAt = task.updatedAt.toUtc();
    final projected = RecordingTranscriptionReceipt(
      userScope: _accountScope,
      fileIdentity: existing?.fileIdentity ?? defaultIdentity,
      deviceFilename: _firstText(
        localItem?.deviceFilename,
        localItem?.originalFilename,
        task.draft.fileName,
      ),
      contentHash: contentHash ?? existing?.contentHash,
      localRecordingId: localRecordingId,
      remoteRecordingId: detailRemoteId,
      noteId: detail.canonicalNoteId ?? existing?.noteId,
      transcriptCompletedAt: existing?.transcriptCompletedAt ?? observedAt,
      assetReadyAt: detail.hasCloudAsset
          ? existing?.assetReadyAt ?? observedAt
          : existing?.assetReadyAt,
      outlineCompletedAt: detail.hasCloudOutline
          ? existing?.outlineCompletedAt ?? observedAt
          : existing?.outlineCompletedAt,
      updatedAt: observedAt,
    );
    if (_covers(existing, projected)) return false;
    try {
      _store.save(projected);
      return await _store.flush();
    } on Object {
      return false;
    }
  }

  /// Enriches existing transcript proof after Chat/Outline settles.
  ///
  /// At least one public identity is required. When both are supplied, the
  /// Recording ID is authoritative and a conflicting Note ID fails closed.
  Future<int> applyOutlineCompleted({
    String? remoteRecordingId,
    String? noteId,
    DateTime? completedAt,
  }) async {
    final remoteId = _text(remoteRecordingId);
    final normalizedNoteId = _text(noteId);
    if (remoteId == null && normalizedNoteId == null) {
      throw ArgumentError('remoteRecordingId or noteId is required');
    }
    final settledAt = (completedAt ?? _now()).toUtc();
    final matches = <RecordingTranscriptionReceipt>[
      for (final receipt in _store.listReceipts())
        if (_matchesOutlineTarget(
          receipt,
          remoteRecordingId: remoteId,
          noteId: normalizedNoteId,
        ))
          receipt,
    ];
    var changed = 0;
    for (final receipt in matches) {
      if (receipt.isOutlineReady &&
          (normalizedNoteId == null || receipt.noteId == normalizedNoteId)) {
        continue;
      }
      try {
        _store.save(
          RecordingTranscriptionReceipt(
            userScope: receipt.userScope,
            fileIdentity: receipt.fileIdentity,
            deviceFilename: receipt.deviceFilename,
            contentHash: receipt.contentHash,
            localRecordingId: receipt.localRecordingId,
            remoteRecordingId: receipt.remoteRecordingId,
            noteId: normalizedNoteId ?? receipt.noteId,
            transcriptCompletedAt: receipt.transcriptCompletedAt,
            assetReadyAt: receipt.assetReadyAt,
            outlineCompletedAt: receipt.outlineCompletedAt ?? settledAt,
            updatedAt: settledAt,
          ),
        );
        changed += 1;
      } on Object {
        // One corrupt/conflicting legacy row must not block unrelated receipts.
      }
    }
    if (changed == 0) return 0;
    return await _store.flush() ? changed : 0;
  }
}

bool _matchesOutlineTarget(
  RecordingTranscriptionReceipt receipt, {
  required String? remoteRecordingId,
  required String? noteId,
}) {
  if (remoteRecordingId != null &&
      receipt.remoteRecordingId != remoteRecordingId) {
    return false;
  }
  final receiptNoteId = _text(receipt.noteId);
  if (remoteRecordingId != null && noteId != null) {
    return receiptNoteId == null || receiptNoteId == noteId;
  }
  return noteId == null || receiptNoteId == noteId;
}

bool _covers(
  RecordingTranscriptionReceipt? existing,
  RecordingTranscriptionReceipt projected,
) {
  if (existing == null ||
      existing.remoteRecordingId != projected.remoteRecordingId) {
    return false;
  }
  return _containsText(existing.deviceFilename, projected.deviceFilename) &&
      _containsText(existing.contentHash, projected.contentHash) &&
      _containsText(existing.localRecordingId, projected.localRecordingId) &&
      _containsText(existing.noteId, projected.noteId) &&
      (projected.assetReadyAt == null || existing.assetReadyAt != null) &&
      (projected.outlineCompletedAt == null ||
          existing.outlineCompletedAt != null);
}

bool _containsText(String? existing, String? projected) =>
    projected == null || existing == projected;

bool _hashesCompatible(String? existing, String? proposed) {
  final current = safeContentHash(existing);
  return current == null || proposed == null || current == proposed;
}

String _requiredText(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, name);
  return normalized;
}

String? _text(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _firstText(String? first, String? second, String? third) =>
    _text(first) ?? _text(second) ?? _text(third);
