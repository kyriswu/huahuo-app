enum RecordingCardFileCatalogPhase {
  disconnected,
  reading,
  verifying,
  ready,
  failed,
}

final class RecordingCardFileCatalogState {
  const RecordingCardFileCatalogState({
    required this.phase,
    required this.connectionRevision,
    this.deviceIdentity,
    this.errorCode,
  });

  const RecordingCardFileCatalogState.disconnected({
    this.connectionRevision = 0,
  }) : phase = RecordingCardFileCatalogPhase.disconnected,
       deviceIdentity = null,
       errorCode = null;

  final RecordingCardFileCatalogPhase phase;
  final int connectionRevision;
  final String? deviceIdentity;
  final String? errorCode;

  bool get isReady => phase == RecordingCardFileCatalogPhase.ready;

  bool owns({
    required int connectionRevision,
    required String? deviceIdentity,
  }) {
    return this.connectionRevision == connectionRevision &&
        this.deviceIdentity == deviceIdentity;
  }

  RecordingCardFileCatalogState transition(
    RecordingCardFileCatalogPhase next, {
    String? errorCode,
  }) {
    assert(next != RecordingCardFileCatalogPhase.disconnected);
    return RecordingCardFileCatalogState(
      phase: next,
      connectionRevision: connectionRevision,
      deviceIdentity: deviceIdentity,
      errorCode: next == RecordingCardFileCatalogPhase.failed
          ? errorCode
          : null,
    );
  }
}
