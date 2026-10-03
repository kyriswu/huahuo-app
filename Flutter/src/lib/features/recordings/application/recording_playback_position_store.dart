abstract interface class RecordingPlaybackPositionStore {
  Duration? read(String recordingId);

  void save({required String recordingId, required Duration position});

  void clear(String recordingId);
}

final class InMemoryRecordingPlaybackPositionStore
    implements RecordingPlaybackPositionStore {
  final Map<String, Duration> _positions = <String, Duration>{};

  @override
  void clear(String recordingId) {
    _positions.remove(recordingId);
  }

  @override
  Duration? read(String recordingId) => _positions[recordingId];

  @override
  void save({required String recordingId, required Duration position}) {
    _positions[recordingId] = position.isNegative ? Duration.zero : position;
  }
}
