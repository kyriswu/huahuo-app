import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_account_binding_repository.dart';

void main() {
  test(
    'secure SN cache avoids plaintext and isolates account scopes',
    () async {
      final driver = _MemorySecureTokenDriver();
      final firstAccount = SecureRecordingCardSnAuthorizationCache(
        driver: driver,
        accountScope: 'user-1',
      );
      final secondAccount = SecureRecordingCardSnAuthorizationCache(
        driver: driver,
        accountScope: 'user-2',
      );

      expect(await firstAccount.matches('SP63A00001'), isFalse);
      await firstAccount.remember(' sp63-a00001 ');

      expect(await firstAccount.matches('SP63A00001'), isTrue);
      expect(await firstAccount.matches('SP63A00002'), isFalse);
      expect(await secondAccount.matches('SP63A00001'), isFalse);
      expect(driver.credentials, hasLength(1));
      expect(driver.credentials.values.single.password, hasLength(64));
      expect(
        driver.credentials.values.single.password,
        isNot(contains('SP63')),
      );

      await firstAccount.clear();
      expect(await firstAccount.matches('SP63A00001'), isFalse);
      expect(driver.credentials, isEmpty);
    },
  );

  test(
    'secure SN cache treats malformed and unreadable data as misses',
    () async {
      final driver = _MemorySecureTokenDriver();
      final cache = SecureRecordingCardSnAuthorizationCache(
        driver: driver,
        accountScope: 'user-1',
      );
      driver.credentials['huahuo.ai.recording-card.sn.${_scopeHash('user-1')}'] =
          const SecureTokenCredential(
            username: 'recording-card-sn-authorization-v1',
            password: 'not-a-digest', // secret-scan: allow
          );

      expect(await cache.matches('SP63A00001'), isFalse);
      driver.throwOnRead = true;
      expect(await cache.matches('SP63A00001'), isFalse);
    },
  );

  test('secure SN cache fails closed on write and clear rejection', () async {
    final driver = _MemorySecureTokenDriver()..writeResult = false;
    final cache = SecureRecordingCardSnAuthorizationCache(
      driver: driver,
      accountScope: 'user-1',
    );

    await cache.remember('SP63A00001');
    expect(await cache.matches('SP63A00001'), isFalse);

    driver.writeResult = true;
    final freshCache = SecureRecordingCardSnAuthorizationCache(
      driver: driver,
      accountScope: 'user-1',
    );
    await freshCache.remember('SP63A00001');
    driver.clearResult = false;
    await freshCache.clear();

    expect(await freshCache.matches('SP63A00001'), isFalse);
    expect(
      driver.credentials.values.single.username,
      'recording-card-sn-authorization-invalidated-v1',
    );
    final restartedCache = SecureRecordingCardSnAuthorizationCache(
      driver: driver,
      accountScope: 'user-1',
    );
    expect(await restartedCache.matches('SP63A00001'), isFalse);
  });

  test('remote repository owns read direct SN bind and unbind', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _response(<String, Object?>{'binding': null}),
      _response(<String, Object?>{
        'binding': _bindingJson(),
        'idempotent': false,
      }),
      _response(<String, Object?>{
        'bindingId': 'binding_1',
        'deviceId': 'device_1',
        'status': 'revoked',
        'bindingGeneration': 3,
        'resetRequired': false,
        'idempotent': false,
      }),
    ]);
    final repository = RemoteRecordingCardCloudBindingRepository(
      _client(transport),
    );

    expect((await repository.currentBinding()).value, isNull);
    final bound = await repository.bind(
      serialNumber: 'SP63A00001',
      idempotencyKey: 'recording-card-bind-repository-test',
      displayName: '我的录音卡',
    );
    expect(bound.value?.serialNumberMasked, '****1234');
    expect(bound.value?.bindingGeneration, 2);

    final removed = await repository.unbind(
      binding: bound.value!,
      idempotencyKey: 'recording-card-unbind-repository-test',
    );
    expect(removed.value, isTrue);
    expect(transport.requests, hasLength(3));
    expect(transport.requests[1].url.path, '/api/v1/recording-card/bind');
    expect(
      transport.requests[1].headers['X-Idempotency-Key'],
      'recording-card-bind-repository-test',
    );
    expect(jsonDecode(transport.requests[1].body!), <String, Object?>{
      'serialNumber': 'SP63A00001',
      'displayName': '我的录音卡',
    });
  });

  test('remote failures are not replaced by local success', () async {
    final repository = RemoteRecordingCardCloudBindingRepository(
      _client(
        _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 404,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{
                'code': 'RECORDING_CARD_NOT_REGISTERED',
                'userMessage': 'not registered',
                'retryable': false,
              },
            },
          ),
        ]),
      ),
    );

    final result = await repository.bind(
      serialNumber: 'SP63A99999',
      idempotencyKey: 'recording-card-bind-not-registered',
    );
    expect(result.ok, isFalse);
    expect(result.errorCode, 'RECORDING_CARD_NOT_REGISTERED');
  });
}

String _scopeHash(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 24);

Map<String, Object?> _bindingJson() => <String, Object?>{
  'bindingId': 'binding_1',
  'deviceId': 'device_1',
  'serialNumberMasked': '****1234',
  'displayName': '我的录音卡',
  'status': 'active',
  'bindingGeneration': 2,
  'boundAt': '2026-08-21T08:01:00Z',
};

ApiTransportResponse _response(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-test',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'token',
  ),
  transport: transport,
);

final class _QueueTransport implements ApiTransport {
  _QueueTransport(List<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.of(responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('unexpected API request');
    return _responses.removeAt(0);
  }
}

final class _MemorySecureTokenDriver implements SecureTokenDriver {
  final Map<String, SecureTokenCredential> credentials =
      <String, SecureTokenCredential>{};
  bool throwOnRead = false;
  bool writeResult = true;
  bool clearResult = true;

  @override
  Future<SecureTokenCredential?> read({required String service}) async {
    if (throwOnRead) throw StateError('read failed');
    return credentials[service];
  }

  @override
  Future<bool> write({
    required String service,
    required String username,
    required String password,
  }) async {
    if (!writeResult) return false;
    credentials[service] = SecureTokenCredential(
      username: username,
      password: password,
    );
    return true;
  }

  @override
  Future<bool> clear({required String service}) async {
    if (!clearResult) return false;
    credentials.remove(service);
    return true;
  }
}
