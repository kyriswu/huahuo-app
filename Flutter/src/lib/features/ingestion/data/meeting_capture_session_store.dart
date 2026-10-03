import '../../../core/database/app_database.dart';
import '../../../core/native/voice_recorder_port.dart';

final class MeetingCaptureCheckpoint {
  const MeetingCaptureCheckpoint({
    required this.correlationId,
    required this.distillToDigitalTwin,
    this.draft,
    this.localRecordingId,
  });

  final String correlationId;
  final bool distillToDigitalTwin;
  final VoiceRecordingDraft? draft;
  final String? localRecordingId;

  MeetingCaptureCheckpoint copyWith({
    VoiceRecordingDraft? draft,
    String? localRecordingId,
  }) => MeetingCaptureCheckpoint(
    correlationId: correlationId,
    distillToDigitalTwin: distillToDigitalTwin,
    draft: draft ?? this.draft,
    localRecordingId: localRecordingId ?? this.localRecordingId,
  );

  Map<String, Object?> toJson() => {
    'correlationId': correlationId,
    'distillToDigitalTwin': distillToDigitalTwin,
    'localRecordingId': localRecordingId,
    if (draft case final media?)
      'draft': {
        'recordingId': media.recordingId,
        'appPrivateUri': media.appPrivateUri,
        'fileName': media.fileName,
        'mimeType': media.mimeType,
        'sizeBytes': media.sizeBytes,
        'durationSeconds': media.durationSeconds,
        'sha256': media.sha256,
        'recordedAt': media.recordedAt?.toUtc().toIso8601String(),
        'scene': media.scene?.name,
        'sampleRateHz': media.sampleRateHz,
        'bitDepth': media.bitDepth,
        'channelCount': media.channelCount,
      },
  };

  factory MeetingCaptureCheckpoint.fromJson(Map<String, Object?> value) {
    final media = value['draft'] as Map?;
    return MeetingCaptureCheckpoint(
      correlationId: value['correlationId']! as String,
      distillToDigitalTwin: value['distillToDigitalTwin'] == true,
      localRecordingId: value['localRecordingId'] as String?,
      draft: media == null
          ? null
          : VoiceRecordingDraft(
              recordingId: media['recordingId']! as String,
              appPrivateUri: media['appPrivateUri']! as String,
              fileName: media['fileName']! as String,
              mimeType: media['mimeType']! as String,
              sizeBytes: media['sizeBytes']! as int,
              durationSeconds: media['durationSeconds']! as int,
              sha256: media['sha256']! as String,
              recordedAt: media['recordedAt'] == null
                  ? null
                  : DateTime.parse(media['recordedAt']! as String),
              scene: media['scene'] == null
                  ? null
                  : VoiceRecordingScene.values.byName(
                      media['scene']! as String,
                    ),
              sampleRateHz: media['sampleRateHz'] as int?,
              bitDepth: media['bitDepth'] as int?,
              channelCount: media['channelCount'] as int?,
            ),
    );
  }
}

final class MeetingCaptureSessionStore {
  MeetingCaptureSessionStore({
    required AppDatabase database,
    required String scope,
  }) : _database = database,
       _scope = scope;

  final AppDatabase _database;
  final String _scope;
  String get _key => 'meeting-capture:$_scope';

  MeetingCaptureCheckpoint? read() {
    final record = _database.getRecord<LocalDatabaseRecord>(
      LocalTableName.localRecordingRecoveryCheckpoints,
      _key,
    );
    if (record == null) return null;
    if (record['owner_scope'] != _scope)
      throw const FormatException('MEETING_CHECKPOINT_SCOPE_MISMATCH');
    return MeetingCaptureCheckpoint.fromJson(
      Map<String, Object?>.from(record['checkpoint']! as Map),
    );
  }

  Future<void> save(MeetingCaptureCheckpoint checkpoint) async {
    _database.upsertCheckpointRecord(
      LocalTableName.localRecordingRecoveryCheckpoints,
      _key,
      {
        'checkpoint_id': _key,
        'owner_scope': _scope,
        'checkpoint': checkpoint.toJson(),
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
}
