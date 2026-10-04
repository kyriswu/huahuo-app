import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/app_cache_policy.dart';

void main() {
  group('AppCachePolicy', () {
    test('starts from the documented 300-second fallback', () {
      final policy = AppCachePolicy();

      expect(policy.cacheTtl, const Duration(seconds: 300));
      expect(policy.isRefreshDue, isTrue);
    });

    test(
      'adopts a valid public App-config TTL without retaining its payload',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _configResponse(45),
        ]);
        final policy = AppCachePolicy(apiClient: _client(transport));

        expect(await policy.refresh(), isTrue);
        expect(policy.cacheTtl, const Duration(seconds: 45));
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single.url.path, '/api/v1/app/config');
      },
    );

    test('coalesces concurrent configuration reads', () async {
      final response = Completer<ApiTransportResponse>();
      final transport = _DeferredTransport(response);
      final policy = AppCachePolicy(apiClient: _client(transport));

      final first = policy.refresh();
      final second = policy.refresh(force: true);
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(1));

      response.complete(_configResponse(90));
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(policy.cacheTtl, const Duration(seconds: 90));
    });

    test(
      'uses the active TTL to defer then retry configuration reads',
      () async {
        var now = DateTime.utc(2026, 8, 13, 10);
        final transport = _QueueTransport(<ApiTransportResponse>[
          _configResponse(30),
          _configResponse(60),
        ]);
        final policy = AppCachePolicy(
          apiClient: _client(transport),
          now: () => now,
        );

        expect(await policy.refresh(), isTrue);
        now = now.add(const Duration(seconds: 29));
        expect(await policy.refresh(), isFalse);
        expect(transport.requests, hasLength(1));

        now = now.add(const Duration(seconds: 1));
        expect(await policy.refresh(), isTrue);
        expect(policy.cacheTtl, const Duration(seconds: 60));
        expect(transport.requests, hasLength(2));
      },
    );

    test(
      'rejects malformed public TTL values and preserves the fallback',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _configResponse(0),
          _configResponse(60.5),
          _configResponse(86401),
        ]);
        final policy = AppCachePolicy(apiClient: _client(transport));

        expect(await policy.refresh(), isFalse);
        expect(await policy.refresh(force: true), isFalse);
        expect(await policy.refresh(force: true), isFalse);
        expect(policy.cacheTtl, AppCachePolicy.fallbackCacheTtl);
      },
    );
  });
}

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '0.1.0',
    deviceId: 'device-1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
    traceIdFactory: () => 'trace-cache-policy',
  ),
  transport: transport,
);

ApiTransportResponse _configResponse(num cacheTtlSeconds) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{
        'success': true,
        'data': <String, Object?>{'cacheTtlSeconds': cacheTtlSeconds},
      },
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

final class _DeferredTransport implements ApiTransport {
  _DeferredTransport(this._response);

  final Completer<ApiTransportResponse> _response;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    requests.add(request);
    return _response.future;
  }
}
