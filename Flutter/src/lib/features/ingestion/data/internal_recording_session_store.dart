import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_database.dart';
import '../domain/material_ingestion.dart';

enum InternalRecordingCheckpointStage {
  awaitingConsent,
  importingMedia,
  recording,
  stopping,
  extractingAudio,
  registeringLocal,
  handingOff,
  completed,
  cancelled,
}

final class InternalRecordingCheckpoint {
  const InternalRecordingCheckpoint({
    required this.sessionId,
    required this.startedAt,
    this.media,
    this.localRecordingId,
    this.jobId,
    this.handedOff = false,
    this.discardRequested = false,
    this.distillToDigitalTwin = false,
    this.stage = InternalRecordingCheckpointStage.awaitingConsent,
  });

  final String sessionId;
  final DateTime startedAt;
  final CapturedMediaInput? media;
  final String? localRecordingId;
  final String? jobId;
  final bool handedOff;
  final bool discardRequested;
  final bool distillToDigitalTwin;
  final InternalRecordingCheckpointStage stage;

  InternalRecordingCheckpoint copyWith({
    CapturedMediaInput? media,
    String? localRecordingId,
    String? jobId,
    bool? handedOff,
    bool? discardRequested,
    InternalRecordingCheckpointStage? stage,
  }) => InternalRecordingCheckpoint(
    sessionId: sessionId,
    startedAt: startedAt,
    media: media ?? this.media,
    localRecordingId: localRecordingId ?? this.localRecordingId,
    jobId: jobId ?? this.jobId,
    handedOff: handedOff ?? this.handedOff,
    discardRequested: discardRequested ?? this.discardRequested,
    distillToDigitalTwin: distillToDigitalTwin,
    stage: stage ?? this.stage,
  );
}

final class InternalRecordingSessionStore {
  InternalRecordingSessionStore({
    required this._database,
    required String ownerScope,
  }) : _ownerScope = ownerScope.trim().isEmpty
           ? throw ArgumentError('Internal capture requires an account scope')
           : sha256.convert(utf8.encode(ownerScope)).toString();

  final AppDatabase _database;
  final String _ownerScope;
  String get _key => 'internal-capture:$_ownerScope';

  InternalRecordingCheckpoint? read() {
    final record = _database.getRecord<LocalDatabaseRecord>(
      LocalTableName.localRecordingRecoveryCheckpoints,
      _key,
    );
    if (record == null) return null;
    if (record['owner_scope'] != _ownerScope || record['version'] != 1) {
      throw const FormatException('INTERNAL_RECORDING_CHECKPOINT_INVALID');
    }
    final sessionId = record['session_id'];
    final startedAt = DateTime.tryParse('${record['started_at']}');
    if (sessionId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(sessionId) ||
        startedAt == null) {
      throw const FormatException('INTERNAL_RECORDING_CHECKPOINT_INVALID');
    }
    final raw = record['media'];
    CapturedMediaInput? media;
    if (raw != null) {
      if (raw is! Map ||
          raw['mime_type'] != 'video/mp4' ||
          raw['size_bytes'] is! int ||
          (raw['size_bytes'] as int) <= 0 ||
          (raw['size_bytes'] as int) > 500 * 1024 * 1024 ||
          raw['duration_seconds'] is! int ||
          (raw['duration_seconds'] as int) <= 0 ||
          (raw['duration_seconds'] as int) > 1800 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch('${raw['sha256']}') ||
          !RegExp(
            r'^[A-Za-z0-9][A-Za-z0-9._-]*\.mp4$',
          ).hasMatch('${raw['file_name']}') ||
          raw['uri'] !=
              'app-private-media://screen-capture/${raw['file_name']}' ||
          DateTime.tryParse('${raw['recorded_at']}') == null) {
        throw const FormatException('INTERNAL_RECORDING_CHECKPOINT_INVALID');
      }
      media = CapturedMediaInput(
        appPrivateUri: raw['uri'] as String,
        fileName: raw['file_name'] as String,
        mimeType: 'video/mp4',
        sizeBytes: raw['size_bytes'] as int,
        durationSeconds: raw['duration_seconds'] as int,
        sha256: raw['sha256'] as String,
        recordedAt: DateTime.parse(raw['recorded_at'] as String),
      );
    }
    final rawStage = record['stage'];
    final stage = rawStage == null
        ? record['handed_off'] == true
              ? InternalRecordingCheckpointStage.completed
              : record['local_recording_id'] != null
              ? InternalRecordingCheckpointStage.handingOff
              : media != null
              ? InternalRecordingCheckpointStage.extractingAudio
              : InternalRecordingCheckpointStage.awaitingConsent
        : InternalRecordingCheckpointStage.values
              .where((candidate) => candidate.name == rawStage)
              .firstOrNull;
    if (stage == null) {
      throw const FormatException('INTERNAL_RECORDING_CHECKPOINT_INVALID');
    }
    return InternalRecordingCheckpoint(
      sessionId: sessionId,
      startedAt: startedAt,
      media: media,
      localRecordingId: record['local_recording_id'] as String?,
      jobId: record['job_id'] as String?,
      handedOff: record['handed_off'] == true,
      discardRequested: record['discard_requested'] == true,
      distillToDigitalTwin: record['distill_to_digital_twin'] == true,
      stage: stage,
    );
  }

  Future<void> save(InternalRecordingCheckpoint checkpoint) async {
    final media = checkpoint.media;
    _database.upsertCheckpointRecord(
      LocalTableName.localRecordingRecoveryCheckpoints,
      _key,
      <String, Object?>{
        'version': 1,
        'checkpoint_id': _key,
        'owner_scope': _ownerScope,
        'session_id': checkpoint.sessionId,
        'started_at': checkpoint.startedAt.toUtc().toIso8601String(),
        'stage': checkpoint.stage.name,
        'local_recording_id': checkpoint.localRecordingId,
        'job_id': checkpoint.jobId,
        'handed_off': checkpoint.handedOff,
        'distill_to_digital_twin': checkpoint.distillToDigitalTwin,
        'discard_requested': checkpoint.discardRequested,
        if (media != null)
          'media': <String, Object?>{
            'uri': media.appPrivateUri,
            'file_name': media.fileName,
            'mime_type': media.mimeType,
            'size_bytes': media.sizeBytes,
            'duration_seconds': media.durationSeconds,
            'sha256': media.sha256,
            'recorded_at': media.recordedAt.toUtc().toIso8601String(),
          },
      },
    );
    await _database.flushPersistence();
  }

  Future<void> clear() async {
    _database.deleteRecord(
      LocalTableName.localRecordingRecoveryCheckpoints,
      _key,
    );
    await _database.flushPersistence();
  }

  Future<void> quarantine() async {
    final record = _database.getRecord<LocalDatabaseRecord>(
      LocalTableName.localRecordingRecoveryCheckpoints,
      _key,
    );
    if (record != null) {
      final quarantineKey =
          '$_key:quarantine:${DateTime.now().microsecondsSinceEpoch}';
      _database.upsertCheckpointRecord(
        LocalTableName.localRecordingRecoveryCheckpoints,
        quarantineKey,
        <String, Object?>{
          ...record,
          'checkpoint_id': quarantineKey,
          'quarantined_at': DateTime.now().toUtc().toIso8601String(),
        },
      );
      await _database.flushPersistence();
    }
    await clear();
  }
}
