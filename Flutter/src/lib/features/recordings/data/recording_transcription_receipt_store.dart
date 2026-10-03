// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';
import '../domain/recording_transcription_receipt.dart';

final class RecordingTranscriptionReceiptStore extends ChangeNotifier
    implements RecordingTranscriptionReceiptStorePort {
  RecordingTranscriptionReceiptStore({
    required AppDatabase database,
    required String accountScope,
  }) : _database = database,
       _accountScope = _requiredText(accountScope, 'accountScope');

  final AppDatabase _database;
  final String _accountScope;
  int _revision = 0;
  int _publishedRevision = 0;
  bool _disposed = false;

  @override
  RecordingTranscriptionReceipt? findByFileIdentity(String fileIdentity) {
    final identity = _requiredText(fileIdentity, 'fileIdentity');
    return _find((receipt) => receipt.fileIdentity == identity);
  }

  @override
  RecordingTranscriptionReceipt? findByLocalRecordingId(
    String localRecordingId,
  ) {
    final id = _requiredText(localRecordingId, 'localRecordingId');
    return _find((receipt) => receipt.localRecordingId == id);
  }

  @override
  RecordingTranscriptionReceipt? findByRemoteRecordingId(
    String remoteRecordingId,
  ) {
    final id = _requiredText(remoteRecordingId, 'remoteRecordingId');
    return _find((receipt) => receipt.remoteRecordingId == id);
  }

  @override
  List<RecordingTranscriptionReceipt> listReceipts() {
    final receipts =
        _database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.recordingTranscriptionReceipts,
            )
            .where((record) => record['user_scope'] == _accountScope)
            .map(_fromRecord)
            .whereType<RecordingTranscriptionReceipt>()
            .toList(growable: false)
          ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List<RecordingTranscriptionReceipt>.unmodifiable(receipts);
  }

  @override
  void save(RecordingTranscriptionReceipt receipt) {
    if (receipt.userScope.trim() != _accountScope) {
      throw StateError('Transcription receipt account scope mismatch');
    }
    final normalized = _normalize(receipt);
    final existing = findByFileIdentity(normalized.fileIdentity);
    final merged = existing == null ? normalized : existing.merge(normalized);
    _database.upsertRecord(
      LocalTableName.recordingTranscriptionReceipts,
      _recordKey(merged.fileIdentity),
      <String, Object?>{
        'user_scope': _accountScope,
        'file_identity': merged.fileIdentity,
        if (merged.deviceFilename != null)
          'device_filename': merged.deviceFilename,
        if (merged.contentHash != null) 'content_hash': merged.contentHash,
        if (merged.localRecordingId != null)
          'local_recording_id': merged.localRecordingId,
        'remote_recording_id': merged.remoteRecordingId,
        if (merged.noteId != null) 'note_id': merged.noteId,
        'transcript_completed_at': merged.transcriptCompletedAt
            .toUtc()
            .toIso8601String(),
        if (merged.assetReadyAt != null)
          'asset_ready_at': merged.assetReadyAt!.toUtc().toIso8601String(),
        if (merged.outlineCompletedAt != null)
          'outline_completed_at': merged.outlineCompletedAt!
              .toUtc()
              .toIso8601String(),
        'updated_at': merged.updatedAt.toUtc().toIso8601String(),
      },
    );
    _revision += 1;
  }

  @override
  Future<bool> flush() async {
    final revision = _revision;
    try {
      await _database.flushPersistence();
      if (!_disposed && revision > _publishedRevision) {
        _publishedRevision = revision;
        notifyListeners();
      }
      return true;
    } on Object {
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  RecordingTranscriptionReceipt? _find(
    bool Function(RecordingTranscriptionReceipt receipt) test,
  ) {
    for (final receipt in listReceipts()) {
      if (test(receipt)) return receipt;
    }
    return null;
  }

  RecordingTranscriptionReceipt? _fromRecord(LocalDatabaseRecord record) {
    final fileIdentity = _optionalText(record['file_identity']);
    final remoteRecordingId = _optionalText(record['remote_recording_id']);
    final transcriptCompletedAt = _date(record['transcript_completed_at']);
    final updatedAt = _date(record['updated_at']);
    if (fileIdentity == null ||
        remoteRecordingId == null ||
        transcriptCompletedAt == null ||
        updatedAt == null) {
      return null;
    }
    return RecordingTranscriptionReceipt(
      userScope: _accountScope,
      fileIdentity: fileIdentity,
      deviceFilename: _optionalText(record['device_filename']),
      contentHash: _optionalText(record['content_hash']),
      localRecordingId: _optionalText(record['local_recording_id']),
      remoteRecordingId: remoteRecordingId,
      noteId: _optionalText(record['note_id']),
      transcriptCompletedAt: transcriptCompletedAt,
      assetReadyAt: _date(record['asset_ready_at']),
      outlineCompletedAt: _date(record['outline_completed_at']),
      updatedAt: updatedAt,
    );
  }

  RecordingTranscriptionReceipt _normalize(
    RecordingTranscriptionReceipt receipt,
  ) {
    return RecordingTranscriptionReceipt(
      userScope: _accountScope,
      fileIdentity: _requiredText(receipt.fileIdentity, 'fileIdentity'),
      deviceFilename: _boundedOptional(receipt.deviceFilename, 240),
      contentHash: _boundedOptional(receipt.contentHash, 160),
      localRecordingId: _boundedOptional(receipt.localRecordingId, 200),
      remoteRecordingId: _bounded(
        receipt.remoteRecordingId,
        512,
        'remoteRecordingId',
      ),
      noteId: _boundedOptional(receipt.noteId, 512),
      transcriptCompletedAt: receipt.transcriptCompletedAt.toUtc(),
      assetReadyAt: receipt.assetReadyAt?.toUtc(),
      outlineCompletedAt: receipt.outlineCompletedAt?.toUtc(),
      updatedAt: receipt.updatedAt.toUtc(),
    );
  }

  String _recordKey(String fileIdentity) {
    return sha256
        .convert(utf8.encode('$_accountScope\u0000$fileIdentity'))
        .toString();
  }
}

String _requiredText(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, name);
  return normalized;
}

String _bounded(String value, int maximum, String name) {
  final normalized = _requiredText(value, name);
  return normalized.length <= maximum
      ? normalized
      : normalized.substring(0, maximum);
}

String? _boundedOptional(String? value, int maximum) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return normalized.length <= maximum
      ? normalized
      : normalized.substring(0, maximum);
}

String? _optionalText(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

DateTime? _date(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}
