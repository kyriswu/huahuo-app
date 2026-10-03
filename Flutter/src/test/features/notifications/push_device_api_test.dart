import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/notifications/data/push_device_api.dart';
import 'package:huahuoai_app/features/notifications/domain/push_registration.dart';

void main() {
  group('PushDeviceApi', () {
    test(
      'registers through the fixed endpoint with an idempotency key',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'deviceId': 'device-1',
                'status': 'active',
                'updatedAt': '2026-08-07T10:00:00Z',
              },
            },
          ),
        ]);
        final api = PushDeviceApi(apiClient: _client(transport));

        final result = await api.registerDevice(
          registration: _registration,
          idempotency: const IdempotencyRequestContext(
            explicitKey: 'idem-push-registration-1',
          ),
        );

        expect(result.ok, isTrue);
        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/notification-devices');
        expect(
          request.headers['X-Idempotency-Key'],
          'idem-push-registration-1',
        );
        final payload = jsonDecode(request.body!);
        expect(payload, _registration.toJson());
        expect(payload['pushProvider'], 'jpush');
        expect(payload['notificationPermission'], 'authorized');
      },
    );

    for (final permission in <String>['denied', 'not_determined']) {
      test('$permission registration makes zero Transport calls', () async {
        final transport = _QueueTransport(const <ApiTransportResponse>[]);

        final result = await PushDeviceApi(apiClient: _client(transport))
            .registerDevice(
              registration: PushDeviceRegistration(
                deviceId: 'device-1',
                platform: 'android',
                pushProvider: 'jpush',
                pushToken: 'registration-token-123',
                notificationPermission: permission,
                appVersion: '1.2.3',
              ),
              idempotency: IdempotencyRequestContext(
                explicitKey: 'idem-push-$permission',
              ),
            );

        expect(result.error?.code, 'PUSH_DEVICE_REGISTRATION_INVALID');
        expect(transport.requests, isEmpty);
      });
    }

    test('unregisters using the stable device identifier', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'deviceId': 'device-1',
              'status': 'revoked',
              'updatedAt': '2026-08-07T10:00:00Z',
            },
          },
        ),
      ]);

      final result = await PushDeviceApi(apiClient: _client(transport))
          .unregisterDevice(
            deviceId: 'device-1',
            idempotency: const IdempotencyRequestContext(
              explicitKey: 'idem-push-unregister-1',
            ),
          );

      expect(result.ok, isTrue);
      expect(transport.requests.single.method, 'DELETE');
      expect(
        transport.requests.single.url.path,
        '/api/v1/notification-devices/device-1',
      );
    });

    test(
      'fails closed for unsafe registration and empty acknowledgements',
      () async {
        final invalidTransport = _QueueTransport(
          const <ApiTransportResponse>[],
        );
        final invalid =
            await PushDeviceApi(
              apiClient: _client(invalidTransport),
            ).registerDevice(
              registration: const PushDeviceRegistration(
                deviceId: '../private',
                platform: 'android',
                pushProvider: 'jpush',
                pushToken: 'registration-token-123',
                notificationPermission: 'authorized',
                appVersion: '1.0.0',
              ),
              idempotency: const IdempotencyRequestContext(
                explicitKey: 'idem-invalid-registration',
              ),
            );
        expect(invalid.ok, isFalse);
        expect(invalid.error?.code, 'PUSH_DEVICE_REGISTRATION_INVALID');
        expect(invalidTransport.requests, isEmpty);

        final malformedTransport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{'success': true, 'data': null},
          ),
        ]);
        final malformed =
            await PushDeviceApi(
              apiClient: _client(malformedTransport),
            ).registerDevice(
              registration: _registration,
              idempotency: const IdempotencyRequestContext(
                explicitKey: 'idem-malformed-registration',
              ),
            );
        expect(malformed.ok, isFalse);
        expect(malformed.error?.code, 'API_MALFORMED_ENVELOPE');
      },
    );

    test('rejects wrong-device wrong-status and malformed receipts', () async {
      for (final data in <Map<String, Object?>>[
        <String, Object?>{
          'deviceId': 'other-device',
          'status': 'active',
          'updatedAt': '2026-08-07T10:00:00Z',
        },
        <String, Object?>{
          'deviceId': 'device-1',
          'status': 'revoked',
          'updatedAt': '2026-08-07T10:00:00Z',
        },
        <String, Object?>{
          'deviceId': 'device-1',
          'status': 'active',
          'updatedAt': 'not-a-time',
        },
        <String, Object?>{
          'deviceId': 'device-1',
          'status': 'active',
          'updatedAt': '2026-08-07T10:00:00',
        },
        <String, Object?>{
          'deviceId': 'device-1',
          'status': 'active',
          'updatedAt': '2026-08-07T10:00:00Z',
          'pushToken': 'must-not-be-echoed',
        },
      ]) {
        final transport = _QueueTransport(<ApiTransportResponse>[
          ApiTransportResponse(
            status: 200,
            body: <String, Object?>{'success': true, 'data': data},
          ),
        ]);
        final result = await PushDeviceApi(apiClient: _client(transport))
            .registerDevice(
              registration: _registration,
              idempotency: const IdempotencyRequestContext(
                explicitKey: 'idem-invalid-receipt',
              ),
            );

        expect(result.ok, isFalse);
        expect(result.error?.code, 'API_RESPONSE_INVALID');
      }
    });

    test('accepts a valid timestamp with an explicit offset', () {
      final receipt =
          PushDeviceMutationReceipt.fromJson(const <String, Object?>{
            'deviceId': 'device-1',
            'status': 'active',
            'updatedAt': '2026-08-07T18:00:00+08:00',
          });

      expect(receipt.updatedAt, '2026-08-07T18:00:00+08:00');
    });
  });
}

const _registration = PushDeviceRegistration(
  deviceId: 'device-1',
  platform: 'android',
  pushProvider: 'jpush',
  pushToken: 'registration-token-123',
  notificationPermission: 'authorized',
  appVersion: '1.2.3',
);

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-1',
    platform: 'android',
    locale: 'zh-CN',
    getAccessToken: () async => 'access-token',
  ),
  transport: transport,
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
