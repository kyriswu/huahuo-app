// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_database.dart';
import '../domain/recording_batch_transcription.dart';

const recordingBatchTranscriptionTransferKind = 'recording_batch_transcription';

final class RecordingBatchTranscriptionStore
    implements RecordingBatchTranscriptionStorePort {
  RecordingBatchTranscriptionStore({
    required AppDatabase database,
    required String accountScope,
    required String workspaceScope,
  }) : _database = database,
       _accountScope = _required(accountScope, 'accountScope'),
       _workspaceScope = _required(workspaceScope, 'workspaceScope');

  static const _payloadSchema = 1;

  final AppDatabase _database;
  final String _accountScope;
  final String _workspaceScope;

  @override
  List<RecordingBatchTranscriptionSnapshot> loadBatches() {
    final groups = <String, List<LocalDatabaseRecord>>{};
    for (final row in _rows()) {
      final batchId = _text(row['batch_id']);
      if (batchId == null) continue;
      groups.putIfAbsent(batchId, () => <LocalDatabaseRecord>[]).add(row);
    }

    final batches = <RecordingBatchTranscriptionSnapshot>[];
    for (final entry in groups.entries) {
      final rows = entry.value
        ..sort(
          (left, right) => _integer(
            left['item_order'],
          ).compareTo(_integer(right['item_order'])),
        );
      final items = rows
          .map(_itemFromRow)
          .whereType<RecordingBatchTranscriptionItem>()
          .toList(growable: false);
      if (items.length < 2) continue;
      final first = rows.first;
      final primaryItemId = _text(first['primary_item_id']);
      final createdAt = _date(first['created_at']);
      final updatedAt = items.fold<DateTime>(
        items.first.updatedAt,
        (latest, item) =>
            item.updatedAt.isAfter(latest) ? item.updatedAt : latest,
      );
      if (primaryItemId == null ||
          createdAt == null ||
          !items.any((item) => item.itemId == primaryItemId)) {
        continue;
      }
      batches.add(
        RecordingBatchTranscriptionSnapshot(
          batchId: entry.key,
          accountScope: _accountScope,
          workspaceScope: _workspaceScope,
          primaryItemId: primaryItemId,
          items: items,
          createdAt: createdAt,
          updatedAt: updatedAt,
        ),
      );
    }
    batches.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return List<RecordingBatchTranscriptionSnapshot>.unmodifiable(batches);
  }

  @override
  void saveBatch(RecordingBatchTranscriptionSnapshot batch) {
    if (batch.accountScope != _accountScope ||
        batch.workspaceScope != _workspaceScope) {
      throw StateError('Recording batch scope mismatch');
    }
    final desiredIds = <String>{
      for (final item in batch.items) _transferId(batch.batchId, item.itemId),
    };
    final result = _database.withTransaction<void>((database) {
      for (var index = 0; index < batch.items.length; index += 1) {
        final item = batch.items[index];
        final transferId = _transferId(batch.batchId, item.itemId);
        database.upsertRecord(
          LocalTableName.localTransferRecords,
          transferId,
          _itemRecord(batch, item, index, transferId),
        );
      }
      for (final row in _rows()) {
        if (row['batch_id'] != batch.batchId) continue;
        final transferId = _text(row['transfer_id']);
        if (transferId != null && !desiredIds.contains(transferId)) {
          database.deleteRecord(
            LocalTableName.localTransferRecords,
            transferId,
          );
        }
      }
    });
    if (!result.ok) {
      throw StateError(
        result.error?.code ?? 'RECORDING_BATCH_PERSISTENCE_FAILED',
      );
    }
  }

  @override
  void deleteBatch(String batchId) {
    final normalized = _required(batchId, 'batchId');
    final result = _database.withTransaction<void>((database) {
      for (final row in _rows()) {
        if (row['batch_id'] != normalized) continue;
        final transferId = _text(row['transfer_id']);
        if (transferId != null) {
          database.deleteRecord(
            LocalTableName.localTransferRecords,
            transferId,
          );
        }
      }
    });
    if (!result.ok) {
      throw StateError(result.error?.code ?? 'RECORDING_BATCH_DELETE_FAILED');
    }
  }

  @override
  Future<bool> flush() async {
    try {
      await _database.flushPersistence();
      return true;
    } on Object {
      return false;
    }
  }

  Iterable<LocalDatabaseRecord> _rows() => _database
      .listRecords<LocalDatabaseRecord>(LocalTableName.localTransferRecords)
      .where(
        (row) =>
            row['transfer_kind'] == recordingBatchTranscriptionTransferKind &&
            row['user_scope'] == _accountScope &&
            row['workspace_scope'] == _workspaceScope,
      );

  LocalDatabaseRecord _itemRecord(
    RecordingBatchTranscriptionSnapshot batch,
    RecordingBatchTranscriptionItem item,
    int itemOrder,
    String transferId,
  ) {
    return <String, Object?>{
      'user_scope': _accountScope,
      'workspace_scope': _workspaceScope,
      'transfer_id': transferId,
      'transfer_kind': recordingBatchTranscriptionTransferKind,
      'batch_id': batch.batchId,
      'primary_item_id': batch.primaryItemId,
      'job_id': item.jobId,
      if (item.remoteRecordingId != null)
        'recording_id': item.remoteRecordingId,
      if (item.noteId != null) 'note_id': item.noteId,
      if (item.deviceFilename != null) 'device_filename': item.deviceFilename,
      'local_file_key': item.fileIdentity,
      'item_order': itemOrder,
      'attempt_count': item.attemptCount,
      'batch_stage': batch.status.name,
      'stage': item.status.name,
      if (item.phase != null) 'last_phase': item.phase!.name,
      if (item.errorCode != null) 'error_code': item.errorCode,
      if (item.waitingReason != null)
        'waiting_reason': item.waitingReason!.name,
      'local_recording_id': item.localRecordingId,
      if (item.contentHash != null) 'content_hash': item.contentHash,
      'idempotency_key': item.jobId,
      if (item.observationStartedAt != null)
        'observation_started_at': _iso(item.observationStartedAt!),
      if (item.lastAuthoritativeProgressAt != null)
        'last_authoritative_progress_at': _iso(
          item.lastAuthoritativeProgressAt!,
        ),
      if (item.observationDeadlineAt != null)
        'observation_deadline_at': _iso(item.observationDeadlineAt!),
      'item_payload_json': jsonEncode(<String, Object?>{
        'schema': _payloadSchema,
        'itemId': item.itemId,
        'title': item.title,
        'outlineStatus': item.outlineStatus.name,
        if (item.outlineErrorCode != null)
          'outlineErrorCode': item.outlineErrorCode,
        if (item.outlineTaskId != null) 'outlineTaskId': item.outlineTaskId,
        if (item.supersededOutlineTaskId != null)
          'supersededOutlineTaskId': item.supersededOutlineTaskId,
        'retryable': item.retryable,
        if (item.progress != null) 'progress': item.progress,
        if (item.failureCategory != null)
          'failureCategory': item.failureCategory!.name,
        if (item.transcriptCompletedAt != null)
          'transcriptCompletedAt': _iso(item.transcriptCompletedAt!),
        if (item.assetReadyAt != null) 'assetReadyAt': _iso(item.assetReadyAt!),
      }),
      'created_at': _iso(batch.createdAt),
      'updated_at': _iso(item.updatedAt),
    };
  }

  RecordingBatchTranscriptionItem? _itemFromRow(LocalDatabaseRecord row) {
    final payload = _payload(row['item_payload_json']);
    final itemId = _text(payload?['itemId']);
    final title = _text(payload?['title']);
    final fileIdentity = _text(row['local_file_key']);
    final localRecordingId = _text(row['local_recording_id']);
    final jobId = _text(row['job_id'] ?? row['idempotency_key']);
    final rawStatus = _enumValue(
      RecordingBatchTranscriptionItemStatus.values,
      row['stage'],
    );
    final createdAt = _date(row['created_at']);
    final updatedAt = _date(row['updated_at']);
    if (itemId == null ||
        title == null ||
        fileIdentity == null ||
        localRecordingId == null ||
        jobId == null ||
        rawStatus == null ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }
    final status = rawStatus == RecordingBatchTranscriptionItemStatus.submitting
        ? RecordingBatchTranscriptionItemStatus.pending
        : rawStatus;
    return RecordingBatchTranscriptionItem(
      itemId: itemId,
      title: title,
      fileIdentity: fileIdentity,
      localRecordingId: localRecordingId,
      jobId: jobId,
      deviceFilename: _text(row['device_filename']),
      contentHash: _text(row['content_hash']),
      remoteRecordingId: _text(row['recording_id']),
      noteId: _text(row['note_id']),
      status: status,
      phase: _enumValue(
        RecordingBatchTranscriptionPhase.values,
        row['last_phase'],
      ),
      outlineStatus:
          _enumValue(
            RecordingBatchOutlineStatus.values,
            payload?['outlineStatus'],
          ) ??
          RecordingBatchOutlineStatus.notStarted,
      progress: _nullableInteger(payload?['progress']),
      retryable: payload?['retryable'] == true,
      attemptCount: _integer(row['attempt_count']),
      errorCode: _text(row['error_code']),
      outlineErrorCode: _safeOutlineErrorCode(payload?['outlineErrorCode']),
      outlineTaskId: _safeTaskId(payload?['outlineTaskId']),
      supersededOutlineTaskId: _safeTaskId(payload?['supersededOutlineTaskId']),
      failureCategory: _enumValue(
        RecordingBatchFailureCategory.values,
        payload?['failureCategory'],
      ),
      waitingReason: _enumValue(
        RecordingBatchWaitingReason.values,
        row['waiting_reason'],
      ),
      observationStartedAt: _date(row['observation_started_at']),
      lastAuthoritativeProgressAt: _date(row['last_authoritative_progress_at']),
      observationDeadlineAt: _date(row['observation_deadline_at']),
      transcriptCompletedAt: _date(payload?['transcriptCompletedAt']),
      assetReadyAt: _date(payload?['assetReadyAt']),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  String _transferId(String batchId, String itemId) {
    final digest = sha256
        .convert(
          utf8.encode(
            '$_accountScope\u0000$_workspaceScope\u0000$batchId\u0000$itemId',
          ),
        )
        .toString();
    return 'recording-batch-$digest';
  }
}

Map<String, Object?>? _payload(Object? raw) {
  if (raw is! String) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return <String, Object?>{
      for (final entry in decoded.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  } on Object {
    return null;
  }
}

T? _enumValue<T extends Enum>(Iterable<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return null;
}

String _required(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, name);
  return normalized;
}

String? _text(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String? _safeOutlineErrorCode(Object? value) {
  final code = _text(value);
  if (code == null || !RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(code)) {
    return null;
  }
  return code;
}

String? _safeTaskId(Object? value) {
  final id = _text(value);
  if (id == null ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(id)) {
    return null;
  }
  return id;
}

int _integer(Object? value) => switch (value) {
  int result => result < 0 ? 0 : result,
  num result => result < 0 ? 0 : result.floor(),
  String result => int.tryParse(result) ?? 0,
  _ => 0,
};

int? _nullableInteger(Object? value) => switch (value) {
  int result => result,
  num result => result.floor(),
  String result => int.tryParse(result),
  _ => null,
};

DateTime? _date(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String _iso(DateTime value) => value.toUtc().toIso8601String();
