import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiClient', () {
    test(
      'auth-required endpoint without token does not call transport',
      () async {
        final expiredFailures = <AppFailure>[];
        final transport = _CapturingTransport(
          response: const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{},
          ),
        );
        final client = _client(
          transport,
          token: null,
          onAuthExpired: expiredFailures.add,
        );

        final result = await client.request<int>(
          ApiRequestOptions<int>(endpointId: 'meStatus', parseData: (_) => 1),
        );

        expect(result.ok, isFalse);
        expect(result.authExpired, isTrue);
        expect(result.error?.code, 'AUTH_SESSION_EXPIRED');
        expect(transport.requests, isEmpty);
        expect(expiredFailures, isEmpty);
      },
    );

    test('required idempotency endpoint without context is rejected', () async {
      final transport = _CapturingTransport(
        response: const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{},
        ),
      );
      final client = _client(transport, token: 'access-token');

      final result = await client.request<int>(
        ApiRequestOptions<int>(
          endpointId: 'createRecording',
          parseData: (_) => 1,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'IDEMPOTENCY_KEY_REQUIRED');
      expect(transport.requests, isEmpty);
    });

    test(
      'per-request access token override wins over configured provider',
      () async {
        final transport = _CapturingTransport(
          response: const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{'count': 1},
            },
          ),
        );
        final client = _client(transport, token: 'provider-token');

        final result = await client.request<int>(
          ApiRequestOptions<int>(
            endpointId: 'meStatus',
            accessTokenOverride: 'restored-token',
            parseData: (value) => asObjectMap(value)?['count'] as int?,
          ),
        );

        expect(result.ok, isTrue);
        expect(
          transport.requests.single.headers['Authorization'],
          'Bearer restored-token',
        );
      },
    );

    test('authRefresh refreshToken body is allowed for restore flow', () async {
      final transport = _CapturingTransport(
        response: const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{'ok': true},
          },
        ),
      );
      final client = _client(transport, token: null);

      final result = await client.request<bool>(
        ApiRequestOptions<bool>(
          endpointId: 'authRefresh',
          body: <String, Object?>{'refreshToken': 'refresh-token-1'},
          parseData: (value) => asObjectMap(value)?['ok'] as bool?,
        ),
      );

      expect(result.ok, isTrue);
      expect(transport.requests.single.method, 'POST');
    });

    test('token-like request body outside allowlist is rejected', () async {
      final transport = _CapturingTransport(
        response: const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{},
        ),
      );
      final client = _client(transport, token: 'access-token');

      final result = await client.request<int>(
        ApiRequestOptions<int>(
          endpointId: 'createRecording',
          body: <String, Object?>{'accessToken': 'access-token-1'},
          idempotency: const IdempotencyRequestContext(
            operation: 'create-recording',
            localDraftId: 'draft-1',
          ),
          parseData: (_) => 1,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'API_SENSITIVE_REQUEST_REJECTED');
      expect(transport.requests, isEmpty);
    });

    test('transport timeout maps to network failure', () async {
      final transport = _PendingTransport();
      final client = _client(
        transport,
        token: 'access-token',
        requestTimeout: const Duration(milliseconds: 1),
      );

      final result = await client.request<int>(
        ApiRequestOptions<int>(endpointId: 'meStatus', parseData: (_) => 1),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'NETWORK_REQUEST_FAILED');
      expect(transport.requests, hasLength(1));
    });

    test('generic 401 response does not set authExpired', () async {
      final transport = _CapturingTransport(
        response: const ApiTransportResponse(
          status: 401,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{'code': 'UNAUTHORIZED'},
          },
        ),
      );
      final client = _client(transport, token: 'access-token');

      final result = await client.request<int>(
        ApiRequestOptions<int>(endpointId: 'meStatus', parseData: (_) => 1),
      );

      expect(result.ok, isFalse);
      expect(result.authExpired, isFalse);
      expect(result.error?.category, AppFailureCategory.auth);
    });

    test(
      '401 refreshes the token and replays once with stable request identity',
      () async {
        var accessToken = 'expired-access';
        var refreshCalls = 0;
        final transport = _SequenceTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 401,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{'code': 'UNAUTHORIZED'},
            },
          ),
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{'count': 1},
            },
          ),
        ]);
        final client = _client(
          transport,
          getAccessToken: () => accessToken,
          refreshAccessToken:
              ({required rejectedAccessToken, required failure}) {
                expect(rejectedAccessToken, 'expired-access');
                expect(failure.code, 'UNAUTHORIZED');
                refreshCalls += 1;
                accessToken = 'rotated-access';
                return AccessTokenRefreshDisposition.refreshed;
              },
        );

        final result = await client.request<int>(
          ApiRequestOptions<int>(
            endpointId: 'createRecording',
            idempotency: const IdempotencyRequestContext(
              operation: 'create-recording',
              localDraftId: 'draft-refresh',
            ),
            parseData: (value) => asObjectMap(value)?['count'] as int?,
          ),
        );

        expect(result.ok, isTrue);
        expect(result.data, 1);
        expect(refreshCalls, 1);
        expect(transport.requests, hasLength(2));
        expect(
          transport.requests.map((request) => request.headers['Authorization']),
          <String?>['Bearer expired-access', 'Bearer rotated-access'],
        );
        expect(
          transport.requests.map((request) => request.headers['X-Trace-Id']),
          everyElement('trace_123456'),
        );
        expect(
          transport.requests.map(
            (request) => request.headers['X-Idempotency-Key'],
          ),
          everyElement(transport.requests.first.headers['X-Idempotency-Key']),
        );
      },
    );

    test('transient refresh failure preserves the session for retry', () async {
      final expiredFailures = <AppFailure>[];
      var refreshCalls = 0;
      final transport = _CapturingTransport(
        response: const ApiTransportResponse(
          status: 401,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{'code': 'UNAUTHORIZED'},
          },
        ),
      );
      final client = _client(
        transport,
        token: 'expired-access',
        refreshAccessToken: ({required rejectedAccessToken, required failure}) {
          refreshCalls += 1;
          return AccessTokenRefreshDisposition.unavailable;
        },
        onAuthExpired: expiredFailures.add,
      );

      final result = await client.request<int>(
        ApiRequestOptions<int>(endpointId: 'meStatus', parseData: (_) => 1),
      );

      expect(result.ok, isFalse);
      expect(refreshCalls, 1);
      expect(transport.requests, hasLength(1));
      expect(expiredFailures, isEmpty);
    });

    test('second 401 after refresh expires the main session once', () async {
      final expiredFailures = <AppFailure>[];
      var accessToken = 'expired-access';
      var refreshCalls = 0;
      final transport = _SequenceTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 401,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{'code': 'UNAUTHORIZED'},
          },
        ),
        const ApiTransportResponse(
          status: 401,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{'code': 'UNAUTHORIZED'},
          },
        ),
      ]);
      final client = _client(
        transport,
        getAccessToken: () => accessToken,
        refreshAccessToken: ({required rejectedAccessToken, required failure}) {
          refreshCalls += 1;
          accessToken = 'rotated-access';
          return AccessTokenRefreshDisposition.refreshed;
        },
        onAuthExpired: expiredFailures.add,
      );

      final result = await client.request<int>(
        ApiRequestOptions<int>(endpointId: 'meStatus', parseData: (_) => 1),
      );

      expect(result.ok, isFalse);
      expect(refreshCalls, 1);
      expect(transport.requests, hasLength(2));
      expect(expiredFailures, hasLength(1));
      expect(expiredFailures.single.code, 'UNAUTHORIZED');
    });

    test('explicit bearer override never enters automatic refresh', () async {
      var refreshCalls = 0;
      final expiredFailures = <AppFailure>[];
      final transport = _CapturingTransport(
        response: const ApiTransportResponse(
          status: 401,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{'code': 'UNAUTHORIZED'},
          },
        ),
      );
      final client = _client(
        transport,
        token: 'provider-access',
        refreshAccessToken: ({required rejectedAccessToken, required failure}) {
          refreshCalls += 1;
          return AccessTokenRefreshDisposition.refreshed;
        },
        onAuthExpired: expiredFailures.add,
      );

      await client.request<int>(
        ApiRequestOptions<int>(
          endpointId: 'meStatus',
          accessTokenOverride: 'explicit-access',
          parseData: (_) => 1,
        ),
      );

      expect(refreshCalls, 0);
      expect(transport.requests, hasLength(1));
      expect(expiredFailures, isEmpty);
    });

    test('malformed 401 response cannot synthesize session expiry', () async {
      final transport = _CapturingTransport(
        response: const ApiTransportResponse(
          status: 401,
          body: 'upstream gateway rejected the request',
        ),
      );
      final client = _client(transport, token: 'access-token');

      final result = await client.request<int>(
        ApiRequestOptions<int>(endpointId: 'meStatus', parseData: (_) => 1),
      );

      expect(result.ok, isFalse);
      expect(result.authExpired, isFalse);
      expect(result.error?.code, 'AUTH_UNAUTHORIZED');
    });

    test(
      'explicit session expiry notifies configured auth-expired handler',
      () async {
        final expiredFailures = <AppFailure>[];
        final transport = _CapturingTransport(
          response: const ApiTransportResponse(
            status: 401,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{'code': 'AUTH_SESSION_EXPIRED'},
            },
          ),
        );
        final client = _client(
          transport,
          token: 'access-token',
          onAuthExpired: expiredFailures.add,
        );

        final result = await client.request<int>(
          ApiRequestOptions<int>(endpointId: 'meStatus', parseData: (_) => 1),
        );

        expect(result.ok, isFalse);
        expect(result.authExpired, isTrue);
        expect(expiredFailures.single.code, 'AUTH_SESSION_EXPIRED');
      },
    );

    test('auth-expired handler failure does not mask API result', () async {
      final transport = _CapturingTransport(
        response: const ApiTransportResponse(
          status: 401,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{'code': 'TOKEN_EXPIRED'},
          },
        ),
      );
      final client = _client(
        transport,
        token: 'access-token',
        onAuthExpired: (_) => throw StateError('cleanup failed'),
      );

      final result = await client.request<int>(
        ApiRequestOptions<int>(endpointId: 'meStatus', parseData: (_) => 1),
      );

      expect(result.ok, isFalse);
      expect(result.authExpired, isTrue);
      expect(result.error?.code, 'TOKEN_EXPIRED');
    });

    test('parses success envelope and sends common headers', () async {
      final transport = _CapturingTransport(
        response: const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'traceId': 'trace_123456',
            'data': <String, Object?>{'count': 3},
          },
        ),
      );
      final client = _client(transport, token: 'access-token');

      final result = await client.request<int>(
        ApiRequestOptions<int>(
          endpointId: 'createRecording',
          parseData: (value) => asObjectMap(value)?['count'] as int?,
          idempotency: const IdempotencyRequestContext(
            operation: 'create-recording',
            localDraftId: 'draft-1',
          ),
        ),
      );

      expect(result.ok, isTrue);
      expect(result.data, 3);
      expect(
        transport.requests.single.headers['Authorization'],
        'Bearer access-token',
      );
      expect(
        transport.requests.single.headers['X-Idempotency-Key'],
        isNotEmpty,
      );
      expect(transport.requests.single.headers['X-Device-Id'], 'device-1');
      expect(transport.requests.single.headers['X-Time-Zone'], 'UTC');
      expect(
        transport.requests.single.headers['Content-Type'],
        'application/json; charset=utf-8',
      );
    });

    test(
      'strict endpoint rejects a direct object without success envelope',
      () async {
        final transport = _CapturingTransport(
          response: const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{'count': 3},
          ),
        );
        final client = _client(transport, token: 'access-token');

        final result = await client.request<int>(
          ApiRequestOptions<int>(
            endpointId: 'meStatus',
            parseData: (value) => asObjectMap(value)?['count'] as int?,
          ),
        );

        expect(result.ok, isFalse);
        expect(result.error?.code, 'API_MALFORMED_ENVELOPE');
      },
    );

    test('Dart IO transport sends non-Latin JSON as UTF-8', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        final requestReceived = server.first;
        final responseFuture = HttpApiTransport().send(
          ApiTransportRequest(
            url: Uri(
              scheme: 'http',
              host: server.address.host,
              port: server.port,
              path: '/speaker-labels',
            ),
            method: 'POST',
            headers: const <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: jsonEncode(<String, Object?>{'speakerName': '王工'}),
          ),
        );

        final request = await requestReceived;
        final requestBody = await utf8.decoder.bind(request).join();
        expect(request.headers.contentType?.charset, 'utf-8');
        expect(jsonDecode(requestBody), <String, Object?>{'speakerName': '王工'});
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"success":true,"data":{}}');
        await request.response.close();

        final response = await responseFuture;
        expect(response.status, HttpStatus.ok);
      } finally {
        await server.close(force: true);
      }
    });
  });
}

ApiClient _client(
  ApiTransport transport, {
  String? token,
  AccessTokenProvider? getAccessToken,
  AccessTokenRefreshHandler? refreshAccessToken,
  AuthExpiredHandler? onAuthExpired,
  Duration requestTimeout = const Duration(seconds: 15),
}) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: '0.1.0',
      deviceId: 'device-1',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: getAccessToken ?? () => token,
      refreshAccessToken: refreshAccessToken,
      traceIdFactory: () => 'trace_123456',
      onAuthExpired: onAuthExpired,
      requestTimeout: requestTimeout,
    ),
    transport: transport,
  );
}

final class _CapturingTransport implements ApiTransport {
  _CapturingTransport({required this.response});

  final ApiTransportResponse response;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return response;
  }
}

final class _SequenceTransport implements ApiTransport {
  _SequenceTransport(List<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.from(responses);

  final List<ApiTransportResponse> _responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}

final class _PendingTransport implements ApiTransport {
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    requests.add(request);
    return Completer<ApiTransportResponse>().future;
  }
}
