import 'api_client.dart';

/// Platform-neutral values used to configure an [ApiClient].
///
/// Each application shell remains responsible for deriving these values and
/// for choosing its token, refresh, and lifecycle policies.
final class ApiClientRuntime {
  const ApiClientRuntime({
    required this.clientVersion,
    required this.deviceId,
    required this.platform,
    required this.locale,
    required this.timeZone,
  });

  final String clientVersion;
  final String deviceId;
  final String platform;
  final String locale;
  final String timeZone;
}

/// Builds [ApiClient] instances without making platform or storage decisions.
final class ApiClientFactory {
  const ApiClientFactory._();

  static ApiClient create({
    required Uri baseUrl,
    required ApiClientRuntime runtime,
    required ApiTransport transport,
    AccessTokenProvider? getAccessToken,
    AccessTokenRefreshHandler? refreshAccessToken,
    TraceIdFactory? traceIdFactory,
    AuthExpiredHandler? onAuthExpired,
    Duration requestTimeout = const Duration(seconds: 15),
  }) {
    return ApiClient(
      config: ApiClientConfig(
        baseUrl: baseUrl,
        clientVersion: runtime.clientVersion,
        deviceId: runtime.deviceId,
        platform: runtime.platform,
        locale: runtime.locale,
        timeZone: runtime.timeZone,
        getAccessToken: getAccessToken,
        refreshAccessToken: refreshAccessToken,
        traceIdFactory: traceIdFactory,
        onAuthExpired: onAuthExpired,
        requestTimeout: requestTimeout,
      ),
      transport: transport,
    );
  }
}
