import '../../../core/database/recording_dao.dart';
import '../application/recording_playback_position_store.dart';

export '../application/recording_playback_position_store.dart';

final class LocalRecordingPlaybackPositionStore
    implements RecordingPlaybackPositionStore {
  LocalRecordingPlaybackPositionStore({required RecordingDao dao}) : _dao = dao;

  final RecordingDao _dao;

  @override
  void clear(String recordingId) {
    if (!_isSafeRecordingId(recordingId)) return;
    _dao.deletePlaybackPosition(recordingId);
  }

  @override
  Duration? read(String recordingId) {
    if (!_isSafeRecordingId(recordingId)) return null;
    final seconds = _dao.getPlaybackPositionSeconds(recordingId);
    return seconds == null ? null : Duration(seconds: seconds);
  }

  @override
  void save({required String recordingId, required Duration position}) {
    if (!_isSafeRecordingId(recordingId)) return;
    final seconds = position.isNegative ? 0 : position.inSeconds;
    _dao.upsertPlaybackPosition(
      recordingId: recordingId,
      positionSeconds: seconds,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }
}

bool _isSafeRecordingId(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value.trim());
}
