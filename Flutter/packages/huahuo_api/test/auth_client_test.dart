import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'AuthClient preserves platform request bodies and Auth endpoint policy',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(<String, Object?>{
          'smsRequestId': 'sms-1',
          'cooldownSeconds': 60,
        }),
        _success(<String, Object?>{'session': 'desktop-compatible'}),
        _success(<String, Object?>{'accessToken': 'access-2'}),
        _success(<String, Object?>{
          'user': <String, Object?>{'userId': 'u-1'},
        }),
        _success(<String, Object?>{'timeZone': 'Asia/Shanghai'}),
      ]);
      final client = AuthClient(_client(transport));
      const loginBody = <String, Object?>{
        'phone': '13812348000',
        'smsRequestId': 'sms-1',
        'smsCode': '123456',
        'deviceId': 'mobile-device-1',
        'agreementAccepted': true,
        'agreementVersion': 'v0.1',
        'privacyVersion': 'v0.1',
        'clientVersion': '0.1.0+1',
        'timeZone': 'Asia/Shanghai',
      };

      final sms = await client.requestSmsCode<Map<String, Object?>>(
        phone: '13812348000',
        parseData: asObjectMap,
        correlationId: 'trace-sms-1',
        idempotency: const IdempotencyRequestContext(
          operation: 'mobile.auth.sms-code',
          scene: 'login',
        ),
      );
      final login = await client.login<Map<String, Object?>>(
        body: loginBody,
        parseData: asObjectMap,
        correlationId: 'trace-login-1',
        idempotency: const IdempotencyRequestContext(
          operation: 'mobile.auth.login',
          localDraftId: 'sms-1',
        ),
      );
      final refresh = await client.refresh<Map<String, Object?>>(
        refreshToken: 'refresh-1',
        parseData: asObjectMap,
        correlationId: 'trace-refresh-1',
      );
      final status = await client.getUserStatus<Map<String, Object?>>(
        accessToken: 'restored-access',
        parseData: asObjectMap,
        correlationId: 'trace-status-1',
      );
      final timeZone = await client.updateUserTimeZone<Map<String, Object?>>(
        timeZone: 'Asia/Shanghai',
        accessToken: 'restored-access',
        parseData: asObjectMap,
        correlationId: 'trace-timezone-1',
        idempotency: const IdempotencyRequestContext(
          operation: 'mobile.auth.timezone',
          businessEntityId: 'u-1',
        ),
      );

      expect(sms.ok, isTrue);
      expect(login.ok, isTrue);
      expect(refresh.ok, isTrue);
      expect(status.ok, isTrue);
      expect(timeZone.ok, isTrue);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/auth/sms-code',
        '/api/v1/auth/login',
        '/api/v1/auth/refresh',
        '/api/v1/me/status',
        '/api/v1/me/timezone',
      ]);
      expect(_body(transport.requests[0]), <String, Object?>{
        'phone': '13812348000',
        'scene': 'login',
      });
      expect(_body(transport.requests[1]), loginBody);
      expect(_body(transport.requests[2]), <String, Object?>{
        'refreshToken': 'refresh-1',
      });
      expect(_body(transport.requests[4]), <String, Object?>{
        'timeZone': 'Asia/Shanghai',
      });
      expect(transport.requests[0].headers['X-Request-Id'], 'trace-sms-1');
      expect(transport.requests[1].headers['X-Request-Id'], 'trace-login-1');
      expect(
        transport.requests[3].headers['Authorization'],
        'Bearer restored-access',
      );
      expect(
        transport.requests[4].headers['Authorization'],
        'Bearer restored-access',
      );
      expect(transport.requests[0].headers['X-Idempotency-Key'], isNotEmpty);
      expect(transport.requests[1].headers['X-Idempotency-Key'], isNotEmpty);
      expect(transport.requests[4].headers['X-Idempotency-Key'], isNotEmpty);
      expect(transport.requests[2].headers, isNot(contains('Authorization')));
      expect(
        transport.requests[2].headers,
        isNot(contains('X-Idempotency-Key')),
      );
    },
  );
}

ApiClient _client(ApiTransport transport) => ApiClientFactory.create(
  baseUrl: Uri.parse('https://api.example.test'),
  runtime: const ApiClientRuntime(
    clientVersion: 'test',
    deviceId: 'device-1',
    platform: 'ios',
    locale: 'zh-CN',
    timeZone: 'Asia/Shanghai',
  ),
  transport: transport,
  getAccessToken: () => 'global-access',
);

ApiTransportResponse _success(Object data) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{'success': true, 'data': data},
);

Map<String, Object?> _body(ApiTransportRequest request) {
  final decoded = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this._responses);

  final List<ApiTransportResponse> _responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}
