import 'dart:convert';
import 'dart:math' as math;

import 'package:huahuo_api/huahuo_api.dart';
import 'performance_snapshot.dart';

final class InstrumentedApiTransport
    implements ApiTransport, CancellableApiTransport, ApiStreamingTransport {
  InstrumentedApiTransport({
    required ApiTransport delegate,
    required NetworkMetrics metrics,
  }) : // Public parameter names intentionally omit private field prefixes.
       // ignore: prefer_initializing_formals
       _delegate = delegate,
       // ignore: prefer_initializing_formals
       _metrics = metrics;

  final ApiTransport _delegate;
  final NetworkMetrics _metrics;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    final stopwatch = Stopwatch()..start();
    _metrics.recordStarted();
    try {
      final response = await _delegate.send(request);
      _metrics.recordCompleted(
        method: request.method,
        endpoint: request.url.toString(),
        duration: stopwatch.elapsed,
        statusCode: response.status,
        bytesSent: _requestBytes(request),
        bytesReceived: _contentLength(response.headers),
        success: response.ok,
      );
      return response;
    } catch (_) {
      _metrics.recordCompleted(
        method: request.method,
        endpoint: request.url.toString(),
        duration: stopwatch.elapsed,
        bytesSent: _requestBytes(request),
        success: false,
      );
      rethrow;
    }
  }

  @override
  ApiTransportOperation sendCancellable(ApiTransportRequest request) {
    final stopwatch = Stopwatch()..start();
    _metrics.recordStarted();
    try {
      final delegate = _delegate;
      final operation = delegate is CancellableApiTransport
          ? (delegate as CancellableApiTransport).sendCancellable(request)
          : ApiTransportOperation(
              response: delegate.send(request),
              cancel: _noTransportCancellation,
            );
      return ApiTransportOperation(
        response: _completeUnary(request, operation.response, stopwatch),
        cancel: operation.cancel,
      );
    } catch (_) {
      _recordUnaryFailure(request, stopwatch);
      rethrow;
    }
  }

  Future<ApiTransportResponse> _completeUnary(
    ApiTransportRequest request,
    Future<ApiTransportResponse> operation,
    Stopwatch stopwatch,
  ) async {
    try {
      final response = await operation;
      _metrics.recordCompleted(
        method: request.method,
        endpoint: request.url.toString(),
        duration: stopwatch.elapsed,
        statusCode: response.status,
        bytesSent: _requestBytes(request),
        bytesReceived: _contentLength(response.headers),
        success: response.ok,
      );
      return response;
    } catch (_) {
      _recordUnaryFailure(request, stopwatch);
      rethrow;
    }
  }

  void _recordUnaryFailure(ApiTransportRequest request, Stopwatch stopwatch) {
    _metrics.recordCompleted(
      method: request.method,
      endpoint: request.url.toString(),
      duration: stopwatch.elapsed,
      bytesSent: _requestBytes(request),
      success: false,
    );
  }

  @override
  Future<ApiTransportStreamResponse> open(ApiTransportRequest request) async {
    final delegate = _delegate;
    if (delegate is! ApiStreamingTransport) {
      throw StateError('API_STREAM_TRANSPORT_UNAVAILABLE');
    }
    final streamingDelegate = delegate as ApiStreamingTransport;
    final stopwatch = Stopwatch()..start();
    _metrics.recordStarted();
    try {
      final response = await streamingDelegate.open(request);
      _metrics.recordCompleted(
        method: request.method,
        endpoint: request.url.toString(),
        duration: stopwatch.elapsed,
        statusCode: response.status,
        bytesSent: _requestBytes(request),
        bytesReceived: _contentLength(response.headers),
        success: response.ok,
      );
      return response;
    } catch (_) {
      _metrics.recordCompleted(
        method: request.method,
        endpoint: request.url.toString(),
        duration: stopwatch.elapsed,
        bytesSent: _requestBytes(request),
        success: false,
      );
      rethrow;
    }
  }
}

void _noTransportCancellation() {}

final class NetworkMetricSample {
  const NetworkMetricSample({
    required this.method,
    required this.endpoint,
    required this.statusClass,
    required this.duration,
    required this.bytesSent,
    required this.bytesReceived,
    required this.success,
  });

  final String method;
  final String endpoint;
  final String statusClass;
  final Duration duration;
  final int bytesSent;
  final int bytesReceived;
  final bool success;
}

final class NetworkMetricsSummary {
  const NetworkMetricsSummary({
    required this.started,
    required this.completed,
    required this.failures,
    required this.retries,
    required this.active,
    required this.peakActive,
    required this.bytesSent,
    required this.bytesReceived,
    required this.duration,
    required this.retainedSampleCount,
    required this.byMethod,
    required this.byStatusClass,
    required this.byEndpoint,
  });

  final int started;
  final int completed;
  final int failures;
  final int retries;
  final int active;
  final int peakActive;
  final int bytesSent;
  final int bytesReceived;
  final MetricPercentiles duration;
  final int retainedSampleCount;
  final Map<String, int> byMethod;
  final Map<String, int> byStatusClass;
  final Map<String, int> byEndpoint;

  Map<String, Object?> toJson() => <String, Object?>{
    'started': started,
    'completed': completed,
    'failures': failures,
    'retries': retries,
    'active': active,
    'peakActive': peakActive,
    'bytesSent': bytesSent,
    'bytesReceived': bytesReceived,
    'duration': duration.toJson(),
    'retainedSampleCount': retainedSampleCount,
    'byMethod': byMethod,
    'byStatusClass': byStatusClass,
    'byEndpoint': byEndpoint,
  };
}

final class NetworkMetrics {
  NetworkMetrics({int capacity = 200, this.maxEndpoints = 32})
    : _samples = BoundedMetricBuffer<NetworkMetricSample>(capacity: capacity) {
    if (maxEndpoints < 1) {
      throw ArgumentError.value(
        maxEndpoints,
        'maxEndpoints',
        'must be positive',
      );
    }
  }

  final int maxEndpoints;
  final BoundedMetricBuffer<NetworkMetricSample> _samples;
  final Map<String, int> _byMethod = <String, int>{};
  final Map<String, int> _byStatusClass = <String, int>{};
  final Map<String, int> _byEndpoint = <String, int>{};
  var _started = 0;
  var _completed = 0;
  var _failures = 0;
  var _retries = 0;
  var _active = 0;
  var _peakActive = 0;
  var _bytesSent = 0;
  var _bytesReceived = 0;

  void recordStarted() {
    _started += 1;
    _active += 1;
    _peakActive = math.max(_peakActive, _active);
  }

  void recordRetry() => _retries += 1;

  void recordCompleted({
    required String method,
    required String endpoint,
    required Duration duration,
    int? statusCode,
    int bytesSent = 0,
    int bytesReceived = 0,
    bool success = true,
  }) {
    final safeMethod = sanitizeMetricLabel(method.toUpperCase(), maxLength: 12);
    final safeEndpoint = _boundedEndpoint(sanitizeMetricRoute(endpoint));
    final statusClass = _statusClass(statusCode);
    final sample = NetworkMetricSample(
      method: safeMethod,
      endpoint: safeEndpoint,
      statusClass: statusClass,
      duration: duration.isNegative ? Duration.zero : duration,
      bytesSent: math.max(0, bytesSent),
      bytesReceived: math.max(0, bytesReceived),
      success: success,
    );
    _samples.add(sample);
    if (_active > 0) _active -= 1;
    _completed += 1;
    if (!success) _failures += 1;
    _bytesSent += sample.bytesSent;
    _bytesReceived += sample.bytesReceived;
    _increment(_byMethod, safeMethod);
    _increment(_byStatusClass, statusClass);
  }

  NetworkMetricsSummary snapshot() => NetworkMetricsSummary(
    started: _started,
    completed: _completed,
    failures: _failures,
    retries: _retries,
    active: _active,
    peakActive: _peakActive,
    bytesSent: _bytesSent,
    bytesReceived: _bytesReceived,
    duration: MetricPercentiles.fromDurations(
      _samples.values.map((sample) => sample.duration),
    ),
    retainedSampleCount: _samples.length,
    byMethod: Map<String, int>.unmodifiable(_byMethod),
    byStatusClass: Map<String, int>.unmodifiable(_byStatusClass),
    byEndpoint: Map<String, int>.unmodifiable(_byEndpoint),
  );

  String _boundedEndpoint(String endpoint) {
    final key =
        _byEndpoint.containsKey(endpoint) || _byEndpoint.length < maxEndpoints
        ? endpoint
        : '/other';
    _increment(_byEndpoint, key);
    return key;
  }
}

String _statusClass(int? statusCode) {
  if (statusCode == null || statusCode < 100 || statusCode > 599) {
    return 'unknown';
  }
  return '${statusCode ~/ 100}xx';
}

void _increment(Map<String, int> counts, String key) {
  counts.update(key, (value) => value + 1, ifAbsent: () => 1);
}

int _requestBytes(ApiTransportRequest request) {
  final body = request.body;
  return body == null ? 0 : utf8.encode(body).length;
}

int _contentLength(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() != 'content-length') continue;
    return int.tryParse(entry.value.trim()) ?? 0;
  }
  return 0;
}
