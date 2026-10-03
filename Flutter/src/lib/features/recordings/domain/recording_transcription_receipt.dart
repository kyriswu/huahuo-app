abstract interface class RecordingTranscriptionReceiptStorePort {
  RecordingTranscriptionReceipt? findByFileIdentity(String fileIdentity);

  RecordingTranscriptionReceipt? findByLocalRecordingId(
    String localRecordingId,
  );

  RecordingTranscriptionReceipt? findByRemoteRecordingId(
    String remoteRecordingId,
  );

  List<RecordingTranscriptionReceipt> listReceipts();

  void save(RecordingTranscriptionReceipt receipt);

  Future<bool> flush();
}

/// Durable proof derived from authoritative recording facts.
///
/// A receipt cannot represent upload acceptance or ASR queueing. Its required
/// transcript timestamp means every stored row is sufficient for the visible
/// `transcribed` badge; asset and Outline settlement remain independent facts.
final class RecordingTranscriptionReceipt {
  const RecordingTranscriptionReceipt({
    required this.userScope,
    required this.fileIdentity,
    required this.remoteRecordingId,
    required this.transcriptCompletedAt,
    required this.updatedAt,
    this.deviceFilename,
    this.contentHash,
    this.localRecordingId,
    this.noteId,
    this.assetReadyAt,
    this.outlineCompletedAt,
  }) : assert(userScope != ''),
       assert(fileIdentity != ''),
       assert(remoteRecordingId != ''),
       assert(noteId != ''),
       assert(contentHash != '');

  final String userScope;
  final String fileIdentity;
  final String? deviceFilename;
  final String? contentHash;
  final String? localRecordingId;
  final String remoteRecordingId;
  final String? noteId;
  final DateTime transcriptCompletedAt;
  final DateTime? assetReadyAt;
  final DateTime? outlineCompletedAt;
  final DateTime updatedAt;

  bool get isTranscribed => true;

  bool get isAssetReady =>
      noteId?.trim().isNotEmpty == true && assetReadyAt != null;

  bool get isOutlineReady => outlineCompletedAt != null;

  RecordingTranscriptionReceipt merge(RecordingTranscriptionReceipt newer) {
    if (userScope != newer.userScope || fileIdentity != newer.fileIdentity) {
      throw ArgumentError('Transcription receipt identity conflict');
    }
    final currentHash = contentHash?.trim();
    final newerHash = newer.contentHash?.trim();
    if (currentHash != null &&
        currentHash.isNotEmpty &&
        newerHash != null &&
        newerHash.isNotEmpty &&
        currentHash != newerHash) {
      throw ArgumentError('Transcription receipt content hash conflict');
    }
    return RecordingTranscriptionReceipt(
      userScope: userScope,
      fileIdentity: fileIdentity,
      deviceFilename: _preferText(newer.deviceFilename, deviceFilename),
      contentHash: _preferText(newer.contentHash, contentHash),
      localRecordingId: _preferText(newer.localRecordingId, localRecordingId),
      remoteRecordingId: newer.remoteRecordingId,
      noteId: _preferText(newer.noteId, noteId),
      transcriptCompletedAt:
          transcriptCompletedAt.isBefore(newer.transcriptCompletedAt)
          ? transcriptCompletedAt
          : newer.transcriptCompletedAt,
      assetReadyAt: _earliest(assetReadyAt, newer.assetReadyAt),
      outlineCompletedAt: _earliest(
        outlineCompletedAt,
        newer.outlineCompletedAt,
      ),
      updatedAt: updatedAt.isAfter(newer.updatedAt)
          ? updatedAt
          : newer.updatedAt,
    );
  }

  RecordingTranscriptionReceipt withAsset({
    required String noteId,
    required DateTime readyAt,
    required DateTime updatedAt,
  }) {
    return RecordingTranscriptionReceipt(
      userScope: userScope,
      fileIdentity: fileIdentity,
      deviceFilename: deviceFilename,
      contentHash: contentHash,
      localRecordingId: localRecordingId,
      remoteRecordingId: remoteRecordingId,
      noteId: noteId,
      transcriptCompletedAt: transcriptCompletedAt,
      assetReadyAt: readyAt,
      outlineCompletedAt: outlineCompletedAt,
      updatedAt: updatedAt,
    );
  }

  RecordingTranscriptionReceipt withOutline({
    required DateTime completedAt,
    required DateTime updatedAt,
  }) {
    return RecordingTranscriptionReceipt(
      userScope: userScope,
      fileIdentity: fileIdentity,
      deviceFilename: deviceFilename,
      contentHash: contentHash,
      localRecordingId: localRecordingId,
      remoteRecordingId: remoteRecordingId,
      noteId: noteId,
      transcriptCompletedAt: transcriptCompletedAt,
      assetReadyAt: assetReadyAt,
      outlineCompletedAt: completedAt,
      updatedAt: updatedAt,
    );
  }
}

String? _preferText(String? preferred, String? fallback) {
  final normalized = preferred?.trim();
  if (normalized != null && normalized.isNotEmpty) return normalized;
  final old = fallback?.trim();
  return old == null || old.isEmpty ? null : old;
}

DateTime? _earliest(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return left.isBefore(right) ? left : right;
}
