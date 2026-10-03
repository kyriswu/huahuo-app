import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test('runtime factory snapshots all four platform configurations', () {
    const snapshots =
        <({String platform, String deviceId, String locale, String timeZone})>[
          (
            platform: 'ios',
            deviceId: 'ios-device-1',
            locale: 'zh-CN',
            timeZone: 'Asia/Shanghai',
          ),
          (
            platform: 'android',
            deviceId: 'android-device-1',
            locale: 'zh-CN',
            timeZone: 'Asia/Shanghai',
          ),
          (
            platform: 'windows',
            deviceId: 'desktop-workstation',
            locale: 'en-US',
            timeZone: 'America/Los_Angeles',
          ),
          (
            platform: 'macos',
            deviceId: 'desktop-studio',
            locale: 'zh-TW',
            timeZone: 'Asia/Taipei',
          ),
        ];

    for (final snapshot in snapshots) {
      final client = ApiClientFactory.create(
        baseUrl: Uri.parse('https://api.example.test'),
        runtime: ApiClientRuntime(
          clientVersion: '0.1.0+1',
          deviceId: snapshot.deviceId,
          platform: snapshot.platform,
          locale: snapshot.locale,
          timeZone: snapshot.timeZone,
        ),
        transport: _DiscardingTransport(),
      );

      expect(
        <String, Object?>{
          'baseUrl': client.config.baseUrl.toString(),
          'clientVersion': client.config.clientVersion,
          'deviceId': client.config.deviceId,
          'platform': client.config.platform,
          'locale': client.config.locale,
          'timeZone': client.config.timeZone,
        },
        <String, Object?>{
          'baseUrl': 'https://api.example.test',
          'clientVersion': '0.1.0+1',
          'deviceId': snapshot.deviceId,
          'platform': snapshot.platform,
          'locale': snapshot.locale,
          'timeZone': snapshot.timeZone,
        },
        reason: snapshot.platform,
      );
    }
  });

  test(
    'runtime factory preserves injected client configuration and callbacks',
    () async {
      final transport = _CapturingTransport(
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{'ready': true},
          },
        ),
      );
      String? getAccessToken() => 'access-token';

      AccessTokenRefreshDisposition refreshAccessToken({
        required String rejectedAccessToken,
        required AppFailure failure,
      }) => AccessTokenRefreshDisposition.refreshed;

      String traceIdFactory() => 'trace-runtime-1';

      void onAuthExpired(AppFailure failure) {}

      final client = ApiClientFactory.create(
        baseUrl: Uri.parse('https://api.example.test'),
        runtime: const ApiClientRuntime(
          clientVersion: '1.2.3+4',
          deviceId: 'device-1',
          platform: 'ios',
          locale: 'zh-CN',
          timeZone: 'Asia/Shanghai',
        ),
        transport: transport,
        getAccessToken: getAccessToken,
        refreshAccessToken: refreshAccessToken,
        traceIdFactory: traceIdFactory,
        onAuthExpired: onAuthExpired,
        requestTimeout: const Duration(seconds: 21),
      );

      expect(client.config.baseUrl, Uri.parse('https://api.example.test'));
      expect(client.config.clientVersion, '1.2.3+4');
      expect(client.config.deviceId, 'device-1');
      expect(client.config.platform, 'ios');
      expect(client.config.locale, 'zh-CN');
      expect(client.config.timeZone, 'Asia/Shanghai');
      expect(client.config.requestTimeout, const Duration(seconds: 21));
      expect(identical(client.config.getAccessToken, getAccessToken), isTrue);
      expect(
        identical(client.config.refreshAccessToken, refreshAccessToken),
        isTrue,
      );
      expect(identical(client.config.traceIdFactory, traceIdFactory), isTrue);
      expect(identical(client.config.onAuthExpired, onAuthExpired), isTrue);

      final result = await client.request<Map<String, Object?>>(
        const ApiRequestOptions<Map<String, Object?>>(
          endpointId: 'meStatus',
          parseData: asObjectMap,
        ),
      );

      expect(result.ok, isTrue);
      expect(result.data?['ready'], isTrue);
      expect(
        transport.requests.single.headers['Authorization'],
        'Bearer access-token',
      );
      expect(
        transport.requests.single.headers['X-Request-Id'],
        'trace-runtime-1',
      );
    },
  );
}

final class _DiscardingTransport implements ApiTransport {
  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    throw UnsupportedError('No request should be made by a configuration test');
  }
}

final class _CapturingTransport implements ApiTransport {
  _CapturingTransport(this.response);

  final ApiTransportResponse response;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return response;
  }
}
