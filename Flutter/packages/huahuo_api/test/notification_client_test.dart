import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'NotificationClient preserves inbox list and read-receipt transport',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{'notificationId': 'notice-1'},
          ],
          'nextCursor': 'cursor-2',
        }),
        _success(<String, Object?>{
          'notificationId': 'notice-1',
          'status': 'read',
        }),
      ]);
      final client = NotificationClient(_client(transport));

      final listed = await client.list<Map<String, Object?>>(
        cursor: 'cursor-1',
        limit: 20,
        parseData: asObjectMap,
      );
      final read = await client.markRead<Map<String, Object?>>(
        notificationId: 'notice-1',
        idempotency: const IdempotencyRequestContext(
          explicitKey: 'desktop-notification-read-notice-1',
        ),
        parseData: asObjectMap,
      );

      expect(listed.ok, isTrue);
      expect(read.ok, isTrue);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/notifications',
        '/api/v1/notifications/notice-1/read',
      ]);
      expect(transport.requests.first.url.queryParameters, <String, String>{
        'cursor': 'cursor-1',
        'limit': '20',
      });
      expect(transport.requests.last.body, jsonEncode(<String, Object?>{}));
      expect(transport.requests.last.headers['Authorization'], 'Bearer access');
      expect(
        transport.requests.last.headers['X-Idempotency-Key'],
        'desktop-notification-read-notice-1',
      );
    },
  );
}

ApiClient _client(ApiTransport transport) => ApiClientFactory.create(
  baseUrl: Uri.parse('https://api.example.test'),
  runtime: const ApiClientRuntime(
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'macos',
    locale: 'zh-CN',
    timeZone: 'Asia/Shanghai',
  ),
  transport: transport,
  getAccessToken: () => 'access',
);

ApiTransportResponse _success(Object data) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{'success': true, 'data': data},
);

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
