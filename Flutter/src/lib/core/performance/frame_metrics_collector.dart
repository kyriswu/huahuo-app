import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'performance_snapshot.dart';

final class FrameMetricSample {
  const FrameMetricSample({
    required this.build,
    required this.raster,
    required this.total,
  });

  final Duration build;
  final Duration raster;
  final Duration total;

  Map<String, Object?> toJson() => <String, Object?>{
    'buildMs': build.inMicroseconds / 1000,
    'rasterMs': raster.inMicroseconds / 1000,
    'totalMs': total.inMicroseconds / 1000,
  };
}

final class FrameMetricsSummary {
  const FrameMetricsSummary({
    required this.sampleCount,
    required this.retainedSampleCount,
    required this.build,
    required this.raster,
    required this.total,
    required this.jankCount,
    required this.jankRate,
    required this.jankThreshold,
    required this.recentFrames,
  });

  final int sampleCount;
  final int retainedSampleCount;
  final MetricPercentiles build;
  final MetricPercentiles raster;
  final MetricPercentiles total;
  final int jankCount;
  final double jankRate;
  final Duration jankThreshold;
  final List<FrameMetricSample> recentFrames;

  Map<String, Object?> toJson() => <String, Object?>{
    'sampleCount': sampleCount,
    'retainedSampleCount': retainedSampleCount,
    'build': build.toJson(),
    'raster': raster.toJson(),
    'total': total.toJson(),
    'jankCount': jankCount,
    'jankRate': jankRate,
    'jankThresholdMs': jankThreshold.inMicroseconds / 1000,
    'recentFrames': recentFrames
        .map((sample) => sample.toJson())
        .toList(growable: false),
  };
}

final class FrameMetricsCollector extends ChangeNotifier {
  static const recentFrameWindowSize = 60;

  FrameMetricsCollector({
    int capacity = 600,
    this.jankThreshold = const Duration(milliseconds: 32),
    this.notificationBatchSize = 30,
  }) : _samples = BoundedMetricBuffer<FrameMetricSample>(capacity: capacity) {
    if (notificationBatchSize < 1) {
      throw ArgumentError.value(
        notificationBatchSize,
        'notificationBatchSize',
        'must be positive',
      );
    }
    _callback = _recordTimings;
  }

  final Duration jankThreshold;
  final int notificationBatchSize;
  final BoundedMetricBuffer<FrameMetricSample> _samples;
  late final TimingsCallback _callback;
  bool _running = false;
  bool _disposed = false;
  int _samplesSinceNotification = 0;
  int _recordedSampleCount = 0;
  MetricPercentiles? _totalPercentiles;

  bool get isRunning => _running;
  int get retainedSampleCount => _samples.length;
  MetricPercentiles get totalPercentiles =>
      _totalPercentiles ??= MetricPercentiles.fromDurations(
        _samples.values.map((sample) => sample.total),
      );

  void start() {
    if (_running || _disposed) return;
    SchedulerBinding.instance.addTimingsCallback(_callback);
    _running = true;
  }

  void stop() {
    if (!_running) return;
    SchedulerBinding.instance.removeTimingsCallback(_callback);
    _running = false;
  }

  @override
  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    super.dispose();
  }

  void reset() {
    if (_samples.isEmpty) return;
    _samples.clear();
    _totalPercentiles = null;
    _samplesSinceNotification = 0;
    _recordedSampleCount = 0;
    notifyListeners();
  }

  void recordFrame({
    required Duration build,
    required Duration raster,
    required Duration total,
  }) {
    if (_disposed) return;
    _samples.add(
      FrameMetricSample(
        build: _nonNegative(build),
        raster: _nonNegative(raster),
        total: _nonNegative(total),
      ),
    );
    _totalPercentiles = null;
    _recordedSampleCount++;
    _samplesSinceNotification++;
    if (_samplesSinceNotification >= notificationBatchSize) {
      _samplesSinceNotification = 0;
      notifyListeners();
    }
  }

  FrameMetricsSummary snapshot() {
    final samples = _samples.values;
    final recentStart = samples.length > recentFrameWindowSize
        ? samples.length - recentFrameWindowSize
        : 0;
    final jankCount = samples
        .where((sample) => sample.total > jankThreshold)
        .length;
    return FrameMetricsSummary(
      sampleCount: _recordedSampleCount,
      retainedSampleCount: samples.length,
      build: MetricPercentiles.fromDurations(
        samples.map((sample) => sample.build),
      ),
      raster: MetricPercentiles.fromDurations(
        samples.map((sample) => sample.raster),
      ),
      total: totalPercentiles,
      jankCount: jankCount,
      jankRate: samples.isEmpty ? 0 : jankCount / samples.length,
      jankThreshold: jankThreshold,
      recentFrames: List<FrameMetricSample>.unmodifiable(
        samples.skip(recentStart),
      ),
    );
  }

  void _recordTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      recordFrame(
        build: timing.buildDuration,
        raster: timing.rasterDuration,
        total: timing.totalSpan,
      );
    }
  }
}

Duration _nonNegative(Duration value) =>
    value.isNegative ? Duration.zero : value;
