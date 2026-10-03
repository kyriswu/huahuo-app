import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

final class BoundedMetricBuffer<T> {
  BoundedMetricBuffer({required this.capacity}) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
  }

  final int capacity;
  final ListQueue<T> _values = ListQueue<T>();

  int get length => _values.length;
  bool get isEmpty => _values.isEmpty;
  List<T> get values => List<T>.unmodifiable(_values);

  void add(T value) {
    if (_values.length == capacity) _values.removeFirst();
    _values.addLast(value);
  }

  void clear() => _values.clear();
}

final class MetricPercentiles {
  const MetricPercentiles({this.p50Ms, this.p95Ms, this.p99Ms});

  factory MetricPercentiles.fromDurations(Iterable<Duration> durations) {
    final values =
        durations
            .map((duration) => math.max(0, duration.inMicroseconds) / 1000)
            .toList(growable: false)
          ..sort();
    if (values.isEmpty) return const MetricPercentiles();
    return MetricPercentiles(
      p50Ms: _nearestRank(values, 0.50),
      p95Ms: _nearestRank(values, 0.95),
      p99Ms: _nearestRank(values, 0.99),
    );
  }

  final double? p50Ms;
  final double? p95Ms;
  final double? p99Ms;

  Map<String, Object?> toJson() => <String, Object?>{
    'p50Ms': p50Ms,
    'p95Ms': p95Ms,
    'p99Ms': p99Ms,
  };
}

double _nearestRank(List<double> sorted, double percentile) {
  final rank = (percentile * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

String sanitizeMetricLabel(
  String value, {
  String fallback = 'unknown',
  int maxLength = 96,
}) {
  var normalized = value.trim();
  if (normalized.isEmpty) return fallback;
  normalized = normalized.split('?').first.split('#').first;
  normalized = normalized.replaceAll(RegExp(r'[^A-Za-z0-9._:/-]+'), '_');
  normalized = normalized.replaceAll(RegExp('_+'), '_');
  if (normalized.isEmpty) return fallback;
  return normalized.length <= maxLength
      ? normalized
      : normalized.substring(0, maxLength);
}

String sanitizeMetricRoute(String value) {
  final trimmed = value.trim();
  final parsed = Uri.tryParse(trimmed);
  final rawPath = parsed != null && parsed.hasScheme
      ? parsed.path
      : trimmed.split('?').first.split('#').first;
  final segments = rawPath
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .map(_sanitizeRouteSegment)
      .toList(growable: false);
  return segments.isEmpty ? '/' : '/${segments.join('/')}';
}

String _sanitizeRouteSegment(String segment) {
  final decoded = Uri.decodeComponent(segment);
  if (_looksLikeIdentifier(decoded)) return ':id';
  return sanitizeMetricLabel(decoded, fallback: 'unknown', maxLength: 32);
}

bool _looksLikeIdentifier(String value) {
  if (RegExp(r'^\d+$').hasMatch(value)) return true;
  if (RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(value)) {
    return true;
  }
  if (RegExp(r'^[0-9a-fA-F]{16,}$').hasMatch(value)) return true;
  return value.length >= 24 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
}

final class PerformanceSnapshot {
  PerformanceSnapshot({
    required DateTime capturedAt,
    required Map<String, Object?> frame,
    required Map<String, Object?> runtime,
    required Map<String, Object?> tasks,
    required Map<String, Object?> database,
    required Map<String, Object?> network,
    Map<String, Object?> imageCaches = const <String, Object?>{},
    Map<String, Object?> memoryPressure = const <String, Object?>{},
    Map<String, Object?> thermal = const <String, Object?>{},
  }) : capturedAt = capturedAt.toUtc(),
       frame = _safeSection(frame),
       runtime = _safeSection(runtime),
       tasks = _safeSection(tasks),
       database = _safeSection(database),
       network = _safeSection(network),
       imageCaches = _safeSection(imageCaches),
       memoryPressure = _safeSection(memoryPressure),
       thermal = _safeSection(thermal);

  static const schemaVersion = 1;

  final DateTime capturedAt;
  final Map<String, Object?> frame;
  final Map<String, Object?> runtime;
  final Map<String, Object?> tasks;
  final Map<String, Object?> database;
  final Map<String, Object?> network;
  final Map<String, Object?> imageCaches;
  final Map<String, Object?> memoryPressure;
  final Map<String, Object?> thermal;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'capturedAt': capturedAt.toIso8601String(),
    'frame': frame,
    'runtime': runtime,
    'tasks': tasks,
    'database': database,
    'network': network,
    'imageCaches': imageCaches,
    'memoryPressure': memoryPressure,
    'thermal': thermal,
  };

  String toJsonString() => jsonEncode(toJson());
}

Map<String, Object?> _safeSection(Map<String, Object?> source) {
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    for (final entry in source.entries)
      sanitizeMetricLabel(entry.key, maxLength: 64): _safeValue(
        entry.key,
        entry.value,
      ),
  });
}

Object? _safeValue(String key, Object? value) {
  if (_isSensitiveMetricKey(key)) return '[REDACTED]';
  return switch (value) {
    null => null,
    bool() || num() => value,
    DateTime() => value.toUtc().toIso8601String(),
    Duration() => value.inMicroseconds / 1000,
    String() => sanitizeMetricLabel(value),
    Map() => _safeSection(<String, Object?>{
      for (final entry in value.entries) '${entry.key}': entry.value,
    }),
    Iterable() => List<Object?>.unmodifiable(
      value.take(64).map((item) => _safeValue('item', item)),
    ),
    _ => sanitizeMetricLabel(value.runtimeType.toString()),
  };
}

bool _isSensitiveMetricKey(String key) {
  final normalized = key.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toLowerCase();
  const sensitive = <String>{
    'authorization',
    'cookie',
    'headers',
    'password',
    'secret',
    'token',
    'apikey',
    'requestbody',
    'responsebody',
    'body',
    'content',
    'message',
    'prompt',
    'transcript',
    'payload',
    'sqltext',
    'querystring',
    'url',
    'uri',
    'path',
    'filepath',
    'filename',
    'audiopath',
  };
  return sensitive.contains(normalized) ||
      normalized.endsWith('token') ||
      normalized.endsWith('secret') ||
      normalized.endsWith('password');
}
