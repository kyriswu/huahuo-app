final class RecordingCardConnectionHistoryEntry {
  const RecordingCardConnectionHistoryEntry({
    required this.displayName,
    required this.safeDeviceFingerprint,
    required this.lastConnectedAt,
  });

  final String displayName;
  final String safeDeviceFingerprint;
  final DateTime lastConnectedAt;
}

abstract interface class RecordingCardConnectionHistoryPort {
  List<RecordingCardConnectionHistoryEntry> load();

  void remember(RecordingCardConnectionHistoryEntry entry);
}

final class InMemoryRecordingCardConnectionHistory
    implements RecordingCardConnectionHistoryPort {
  InMemoryRecordingCardConnectionHistory({
    List<RecordingCardConnectionHistoryEntry> initialEntries =
        const <RecordingCardConnectionHistoryEntry>[],
  }) : _entries = List<RecordingCardConnectionHistoryEntry>.of(initialEntries);

  final List<RecordingCardConnectionHistoryEntry> _entries;

  @override
  List<RecordingCardConnectionHistoryEntry> load() =>
      List<RecordingCardConnectionHistoryEntry>.unmodifiable(_entries);

  @override
  void remember(RecordingCardConnectionHistoryEntry entry) {
    _entries
      ..removeWhere(
        (existing) =>
            existing.safeDeviceFingerprint == entry.safeDeviceFingerprint,
      )
      ..insert(0, entry);
  }
}
