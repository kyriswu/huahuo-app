import 'api_client.dart';

/// Runtime-only freshness policy sourced from the public App configuration.
///
/// It deliberately retains no account content or transport credentials. A
/// failed configuration request leaves the documented fallback in place.
final class AppCachePolicy {
  AppCachePolicy({
    ApiClient? apiClient,
    Duration fallbackTtl = fallbackCacheTtl,
    DateTime Function()? now,
  }) : // Retains the public DI parameter name while keeping storage private.
       // ignore: prefer_initializing_formals
       _apiClient = apiClient,
       _cacheTtl = _validatedFallback(fallbackTtl),
       _now = now ?? DateTime.now;

  static const Duration fallbackCacheTtl = Duration(seconds: 300);
  static const Duration _maximumCacheTtl = Duration(days: 1);

  final ApiClient? _apiClient;
  final DateTime Function() _now;
  Duration _cacheTtl;
  DateTime? _lastRefreshAttemptAt;
  Future<bool>? _refreshing;

  Duration get cacheTtl => _cacheTtl;

  DateTime? get lastRefreshAttemptAt => _lastRefreshAttemptAt;

  bool get isRefreshDue {
    final lastAttempt = _lastRefreshAttemptAt;
    if (lastAttempt == null) return true;
    return _now().toUtc().difference(lastAttempt) >= _cacheTtl;
  }

  /// Refreshes only when due unless an account/lifecycle caller explicitly
  /// requests a forced read. Concurrent callers share one public request.
  Future<bool> refresh({bool force = false}) {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    if (!force && !isRefreshDue) return Future<bool>.value(false);
    final apiClient = _apiClient;
    if (apiClient == null) {
      _lastRefreshAttemptAt = _now().toUtc();
      return Future<bool>.value(false);
    }
    return _refreshing = _refresh(apiClient);
  }

  Future<bool> _refresh(ApiClient apiClient) async {
    try {
      final result = await apiClient.request<Duration>(
        const ApiRequestOptions<Duration>(
          endpointId: 'appConfig',
          parseData: _parseCacheTtl,
        ),
      );
      final ttl = result.data;
      if (!result.ok || ttl == null) return false;
      _cacheTtl = ttl;
      return true;
    } catch (_) {
      // App configuration is an optimization. The active fallback remains
      // authoritative for local cache freshness when the request is unavailable.
      return false;
    } finally {
      _lastRefreshAttemptAt = _now().toUtc();
      _refreshing = null;
    }
  }

  static Duration _parseCacheTtl(Object? value) {
    if (value is! Map) throw const FormatException('APP_CONFIG_INVALID');
    final raw = value['cacheTtlSeconds'];
    if (raw is! num || !raw.isFinite) {
      throw const FormatException('APP_CONFIG_CACHE_TTL_INVALID');
    }
    final seconds = raw.toInt();
    if (raw != seconds || seconds < 1 || seconds > _maximumCacheTtl.inSeconds) {
      throw const FormatException('APP_CONFIG_CACHE_TTL_INVALID');
    }
    return Duration(seconds: seconds);
  }

  static Duration _validatedFallback(Duration value) {
    if (value <= Duration.zero || value > _maximumCacheTtl) {
      return fallbackCacheTtl;
    }
    return value;
  }
}
