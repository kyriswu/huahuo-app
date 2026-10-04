/// Coverage of persisted positioning data, never a generation percentage.
final class PositioningCoverage {
  const PositioningCoverage({
    required this.coldStartPercent,
    required this.completedPercent,
    required this.isStale,
  });

  final int coldStartPercent;
  final int completedPercent;
  final bool isStale;

  PositioningCoverage asStale() => PositioningCoverage(
    coldStartPercent: coldStartPercent,
    completedPercent: completedPercent,
    isStale: true,
  );
}

abstract interface class PositioningProgressRepository {
  PositioningCoverage? readCached();

  /// Returns null when this read loses ownership. Implementations must check
  /// [isCurrent] before persisting or accepting a response, including errors.
  Future<PositioningCoverage?> refresh({required bool Function() isCurrent});
}
