import 'dart:async';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  group('EndpointCatalog', () {
    test('all endpoint policies are internally consistent', () {
      final issues = EndpointCatalog.listDefinitions()
          .expand(assertEndpointPolicy)
          .toList(growable: false);

      expect(issues, isEmpty);
    });

    test('resolves fixed Docs workspace and HNote routes', () {
      expect(
        EndpointCatalog.resolve(
          'workspaceDetail',
          pathParams: const <String, Object>{'workspaceId': 'ws / 1'},
        ).path,
        '/api/v1/workspaces/ws%20%2F%201',
      );
      expect(
        EndpointCatalog.resolve(
          'workspaceNoteDetail',
          pathParams: const <String, Object>{
            'workspaceId': 'ws_1',
            'noteId': 'note_1',
          },
        ).path,
        '/api/v1/workspaces/ws_1/notes/note_1',
      );
      expect(
        EndpointCatalog.byId('updateWorkspaceNote').integrationStatus,
        BackendIntegrationStatus.deferred,
      );
      expect(EndpointCatalog.byId('home').method, HttpMethod.get);
      expect(EndpointCatalog.byId('home').pathTemplate, '/api/v1/home');
      expect(EndpointCatalog.byId('updateMeTimezone').method, HttpMethod.put);
      expect(
        EndpointCatalog.byId('updateMeTimezone').pathTemplate,
        '/api/v1/me/timezone',
      );
      expect(
        EndpointCatalog.byId('updateMeTimezone').idempotency,
        EndpointIdempotencyPolicy.required,
      );
      expect(
        EndpointCatalog.byId('updateMeTimezone').idempotencyHeaderName,
        'X-Idempotency-Key',
      );
      expect(
        EndpointCatalog.byId('updateMeTimezone').capability,
        BackendCapability.auth,
      );
      final currentProfile = EndpointCatalog.byId('currentWorkspaceProfile');
      expect(currentProfile.method, HttpMethod.get);
      expect(currentProfile.pathTemplate, '/api/v1/workspaces/current/profile');
      expect(currentProfile.auth, EndpointAuthPolicy.required);
      expect(currentProfile.idempotency, EndpointIdempotencyPolicy.forbidden);
      expect(currentProfile.capability, BackendCapability.profile);
      final viewed = EndpointCatalog.resolve(
        'markHotspotSuggestionViewed',
        pathParams: const <String, Object>{'suggestionId': 'suggestion / 1'},
      );
      expect(
        viewed.path,
        '/api/v1/home/hotspot-suggestions/suggestion%20%2F%201/viewed',
      );
      expect(viewed.idempotency, EndpointIdempotencyPolicy.required);
    });
  });

  test(
    'ApiClient sends the formal envelope request and parses a DTO',
    () async {
      final transport = _CapturingTransport(
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'traceId': 'trace_docs_fixture',
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'workspaceId': 'ws_1',
                  'displayName': 'Personal',
                  'state': 'ready',
                  'isDefault': true,
                  'etag': '"workspace-1"',
                },
              ],
            },
          },
        ),
      );
      final client = ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: '0.1.0',
          deviceId: 'desktop-1',
          platform: 'macos',
          locale: 'zh-CN',
          getAccessToken: () => 'access-token',
          traceIdFactory: () => 'trace_docs_fixture',
        ),
        transport: transport,
      );

      final result = await client.request<SharedWorkspacePage>(
        ApiRequestOptions<SharedWorkspacePage>(
          endpointId: 'workspaces',
          parseData: (value) {
            final json = asObjectMap(value);
            return json == null ? null : SharedWorkspacePage.fromJson(json);
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(result.data!.items.single.workspaceId, 'ws_1');
      expect(transport.requests.single.url.path, '/api/v1/workspaces');
      expect(
        transport.requests.single.headers['Authorization'],
        'Bearer access-token',
      );
      expect(
        transport.requests.single.headers['X-Request-Id'],
        'trace_docs_fixture',
      );
    },
  );

  test('business error details survive HTTP status handling', () async {
    final client = ApiClient(
      config: ApiClientConfig(
        baseUrl: Uri.parse('https://api.example.test'),
        clientVersion: '0.1.0',
        deviceId: 'desktop-1',
        platform: 'macos',
        locale: 'zh-CN',
        getAccessToken: () => 'access-token',
      ),
      transport: _CapturingTransport(
        const ApiTransportResponse(
          status: 409,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'RUNTIME_EVENT_GAP',
              'userMessage': 'event history has a gap',
              'retryable': false,
              'details': <String, Object?>{
                'oldestAvailableSequence': 5,
                'latestSequence': 12,
                'resumeAfterSequence': 4,
              },
            },
          },
        ),
      ),
    );

    final result = await client.request<ApiContractObject>(
      const ApiRequestOptions<ApiContractObject>(
        endpointId: 'workspaces',
        parseData: ApiContractObject.fromValue,
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.code, 'RUNTIME_EVENT_GAP');
    expect(result.error?.details, <String, Object?>{
      'oldestAvailableSequence': 5,
      'latestSequence': 12,
      'resumeAfterSequence': 4,
    });
    expect(result.error?.metadata, isNot(contains('resumeAfterSequence')));
    expect(
      () => result.error!.details['resumeAfterSequence'] = 9,
      throwsUnsupportedError,
    );
  });

  test(
    'formal HNote mutations use their documented idempotency header',
    () async {
      final transport = _CapturingTransport(
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{'success': true, 'data': <String, Object?>{}},
        ),
      );
      final client = ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: '0.1.0',
          deviceId: 'desktop-1',
          platform: 'macos',
          locale: 'zh-CN',
          getAccessToken: () => 'access-token',
        ),
        transport: transport,
      );

      await client.request<Map<String, Object?>>(
        ApiRequestOptions<Map<String, Object?>>(
          endpointId: 'createWorkspaceNote',
          pathParams: const <String, Object>{'workspaceId': 'ws-1'},
          body: const <String, Object?>{},
          idempotency: const IdempotencyRequestContext(explicitKey: 'idem-1'),
          parseData: asObjectMap,
        ),
      );

      expect(transport.requests.single.headers['X-Idempotency-Key'], 'idem-1');
      expect(
        transport.requests.single.headers,
        isNot(contains('Idempotency-Key')),
      );
      expect(
        EndpointCatalog.byId('authRefresh').idempotency,
        EndpointIdempotencyPolicy.forbidden,
      );
    },
  );

  test(
    'conditional requests expose HTTP 304 without parsing an empty body',
    () async {
      final transport = _CapturingTransport(
        const ApiTransportResponse(
          status: 304,
          headers: <String, String>{
            'etag': '"workspace-snapshot-1"',
            'x-trace-id': 'trace-conditional',
          },
          body: null,
        ),
      );
      final client = ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: '0.1.0',
          deviceId: 'desktop-1',
          platform: 'macos',
          locale: 'zh-CN',
          getAccessToken: () => 'access-token',
        ),
        transport: transport,
      );

      final conditional = await client.requestConditional<ApiContractObject>(
        ApiRequestOptions<ApiContractObject>(
          endpointId: 'workspaces',
          headers: const <String, String>{
            'If-None-Match': '"workspace-snapshot-1"',
          },
          parseData: (_) => throw StateError('A 304 body must not be parsed'),
        ),
      );

      expect(conditional.ok, isTrue);
      expect(conditional.isNotModified, isTrue);
      expect(conditional.notModified, isTrue);
      expect(conditional.status, 304);
      expect(conditional.data, isNull);
      expect(conditional.error, isNull);
      expect(conditional.apiResult, isNull);
      expect(conditional.etag, '"workspace-snapshot-1"');
      expect(conditional.traceId, 'trace-conditional');
      expect(
        transport.requests.single.headers['If-None-Match'],
        '"workspace-snapshot-1"',
      );

      final ordinary = await client.request<ApiContractObject>(
        const ApiRequestOptions<ApiContractObject>(
          endpointId: 'workspaces',
          parseData: ApiContractObject.fromValue,
        ),
      );
      expect(ordinary.ok, isFalse);
      expect(ordinary.status, 304);
      expect(ordinary.error?.code, 'API_HTTP_ERROR');
    },
  );

  test(
    'malformed DTO responses are contract failures, not network errors',
    () async {
      final client = ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: '0.1.0',
          deviceId: 'desktop-1',
          platform: 'macos',
          locale: 'zh-CN',
          getAccessToken: () => 'access-token',
        ),
        transport: _CapturingTransport(
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{'items': 'not-a-list'},
            },
          ),
        ),
      );

      final result = await client.request<SharedWorkspacePage>(
        ApiRequestOptions<SharedWorkspacePage>(
          endpointId: 'workspaces',
          parseData: (value) =>
              SharedWorkspacePage.fromJson(asObjectMap(value)!),
        ),
      );

      expect(result.error!.code, 'API_RESPONSE_INVALID');
      expect(result.error!.isRetryable, isFalse);
    },
  );

  test('equivalent concurrent GETs share one opaque in-flight key', () async {
    final transport = _ControlledTransport();
    var traceSequence = 0;
    final client = ApiClient(
      config: ApiClientConfig(
        baseUrl: Uri.parse('https://api.example.test'),
        clientVersion: '0.1.0',
        deviceId: 'desktop-1',
        platform: 'macos',
        locale: 'zh-CN',
        getAccessToken: () => 'secret-access-token',
        traceIdFactory: () => 'trace-${traceSequence += 1}',
      ),
      transport: transport,
    );
    const options = ApiRequestOptions<ApiContractObject>(
      endpointId: 'workspaces',
      query: <String, Object?>{'cursor': 'secret-query-value'},
      parseData: ApiContractObject.fromValue,
    );

    final first = client.request<ApiContractObject>(options);
    final second = client.request<ApiContractObject>(options);
    await _waitUntil(() => transport.requests.length == 1);

    expect(client.inFlightGetKeyDigests, hasLength(1));
    final digest = client.inFlightGetKeyDigests.single;
    expect(digest, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(digest, isNot(contains('secret-access-token')));
    expect(digest, isNot(contains('secret-query-value')));
    expect(
      transport.requests.single.headers['X-Request-Id'],
      anyOf('trace-1', 'trace-2'),
    );

    transport.complete(0, _successfulObjectResponse);
    final results = await Future.wait(<Future<ApiResult<ApiContractObject>>>[
      first,
      second,
    ]);

    expect(
      results,
      everyElement(
        predicate<ApiResult<ApiContractObject>>((result) => result.ok),
      ),
    );
    expect(transport.requests, hasLength(1));
    expect(client.inFlightGetKeyDigests, isEmpty);
  });

  test('joined GET consumers report the physical request trace', () async {
    final transport = _ControlledTransport();
    final client = _clientWithTransport(transport);

    final first = client.request<ApiContractObject>(
      const ApiRequestOptions<ApiContractObject>(
        endpointId: 'workspaces',
        accessTokenOverride: 'access-token',
        correlationId: 'trace-first-consumer',
        parseData: ApiContractObject.fromValue,
      ),
    );
    final second = client.request<ApiContractObject>(
      const ApiRequestOptions<ApiContractObject>(
        endpointId: 'workspaces',
        accessTokenOverride: 'access-token',
        correlationId: 'trace-second-consumer',
        parseData: ApiContractObject.fromValue,
      ),
    );
    await _waitUntil(() => transport.requests.length == 1);
    final physicalTrace = transport.requests.single.headers['X-Trace-Id'];

    transport.complete(0, _successfulObjectResponse);
    final results = await Future.wait(<Future<ApiResult<ApiContractObject>>>[
      first,
      second,
    ]);

    expect(physicalTrace, isNotNull);
    expect(results.map((result) => result.traceId), <String?>[
      physicalTrace,
      physicalTrace,
    ]);
  });

  test('GET single-flight isolates query values and access tokens', () async {
    final transport = _ControlledTransport();
    final client = _clientWithTransport(transport);
    ApiRequestOptions<ApiContractObject> options({
      required String cursor,
      required String token,
    }) {
      return ApiRequestOptions<ApiContractObject>(
        endpointId: 'workspaces',
        query: <String, Object?>{'cursor': cursor},
        accessTokenOverride: token,
        parseData: ApiContractObject.fromValue,
      );
    }

    final results = <Future<ApiResult<ApiContractObject>>>[
      client.request(options(cursor: 'cursor-a', token: 'token-a')),
      client.request(options(cursor: 'cursor-b', token: 'token-a')),
      client.request(options(cursor: 'cursor-a', token: 'token-b')),
    ];
    await _waitUntil(() => transport.requests.length == 3);

    expect(client.inFlightGetKeyDigests.toSet(), hasLength(3));
    for (var index = 0; index < 3; index += 1) {
      transport.complete(index, _successfulObjectResponse);
    }
    expect(await Future.wait(results), everyElement(_isSuccessfulApiResult));
    expect(transport.requests, hasLength(3));
  });

  test('cancelling one GET lease keeps its shared consumer active', () async {
    final transport = _ControlledTransport();
    final client = _clientWithTransport(transport);
    const options = ApiRequestOptions<ApiContractObject>(
      endpointId: 'workspaces',
      accessTokenOverride: 'access-token',
      parseData: ApiContractObject.fromValue,
    );

    final cancelledLease = client.leaseGet(options);
    final activeLease = client.leaseGet(options);
    await _waitUntil(() => transport.requests.length == 1);
    cancelledLease.cancel();

    final cancelled = await cancelledLease.result;
    expect(cancelled.ok, isFalse);
    expect(cancelled.error?.code, 'API_REQUEST_CANCELLED');

    transport.complete(0, _successfulObjectResponse);
    expect((await activeLease.result).ok, isTrue);
    expect(transport.requests, hasLength(1));
  });

  test('last GET lease cancellation aborts a cancellable transport', () async {
    final transport = _ControlledCancellableTransport();
    final client = _clientWithTransport(transport);
    const options = ApiRequestOptions<ApiContractObject>(
      endpointId: 'workspaces',
      accessTokenOverride: 'access-token',
      parseData: ApiContractObject.fromValue,
    );

    final first = client.leaseGet(options);
    final second = client.leaseGet(options);
    await _waitUntil(() => transport.requests.length == 1);

    first.cancel();
    expect(transport.cancelCalls, 0);
    second.cancel();

    expect((await first.result).error?.code, 'API_REQUEST_CANCELLED');
    expect((await second.result).error?.code, 'API_REQUEST_CANCELLED');
    expect(transport.cancelCalls, 1);
    expect(client.inFlightGetKeyDigests, isEmpty);
  });

  test(
    'last conditional GET lease cancellation aborts its transport',
    () async {
      final transport = _ControlledCancellableTransport();
      final client = _clientWithTransport(transport);
      const options = ApiRequestOptions<ApiContractObject>(
        endpointId: 'workspaces',
        accessTokenOverride: 'access-token',
        headers: <String, String>{'If-None-Match': '"workspace-1"'},
        parseData: ApiContractObject.fromValue,
      );

      final lease = client.leaseConditionalGet(options);
      await _waitUntil(() => transport.requests.length == 1);
      lease.cancel();

      final result = await lease.result;
      expect(result.ok, isFalse);
      expect(result.error?.code, 'API_REQUEST_CANCELLED');
      expect(transport.cancelCalls, 1);
      expect(client.inFlightGetKeyDigests, isEmpty);
    },
  );

  test('default HTTP cancellation stops a body after headers arrive', () async {
    final response = _SlowBodyHttpClientResponse();
    final client = _SlowBodyHttpClient(response);
    final transport = HttpApiTransport(client: client);
    addTearDown(response.close);

    final operation = transport.sendCancellable(
      ApiTransportRequest(
        url: Uri.parse('https://api.example.test/slow'),
        method: 'GET',
        headers: const <String, String>{},
      ),
    );
    final completion = expectLater(
      operation.response,
      throwsA(isA<Exception>()),
    );
    await response.listened.future;

    operation.cancel();

    await response.cancelled.future;
    await completion;
    expect(client.request.abortCalls, 1);
  });

  test('transport abort exceptions do not strand a cancelled lease', () async {
    final transport = _ControlledCancellableTransport()..throwOnCancel = true;
    final client = _clientWithTransport(transport);
    const options = ApiRequestOptions<ApiContractObject>(
      endpointId: 'workspaces',
      accessTokenOverride: 'access-token',
      parseData: ApiContractObject.fromValue,
    );

    final lease = client.leaseGet(options);
    await _waitUntil(() => transport.requests.length == 1);
    lease.cancel();

    expect((await lease.result).error?.code, 'API_REQUEST_CANCELLED');
    expect(transport.cancelCalls, 1);
    expect(client.inFlightGetKeyDigests, isEmpty);
    transport.complete(0, _successfulObjectResponse);
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'last lease cancellation drops a late 401 without auth replay',
    () async {
      final transport = _ControlledTransport();
      var refreshCalls = 0;
      final client = ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: '0.1.0',
          deviceId: 'desktop-1',
          platform: 'macos',
          locale: 'zh-CN',
          getAccessToken: () => 'expired-access-token',
          refreshAccessToken:
              ({required rejectedAccessToken, required failure}) {
                refreshCalls += 1;
                return AccessTokenRefreshDisposition.refreshed;
              },
        ),
        transport: transport,
      );

      const options = ApiRequestOptions<ApiContractObject>(
        endpointId: 'workspaces',
        parseData: ApiContractObject.fromValue,
      );
      final lease = client.leaseGet<ApiContractObject>(options);
      await _waitUntil(() => transport.requests.length == 1);
      lease.cancel();

      expect((await lease.result).error?.code, 'API_REQUEST_CANCELLED');
      expect(client.inFlightGetKeyDigests, isEmpty);

      final replacement = client.leaseGet<ApiContractObject>(options);
      await _waitUntil(() => transport.requests.length == 2);
      transport.complete(0, _unauthorizedResponse);
      transport.complete(1, _successfulObjectResponse);
      expect((await replacement.result).ok, isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(refreshCalls, 0);
      expect(transport.requests, hasLength(2));
    },
  );

  test('retry backoff is capped and accepts deterministic jitter', () {
    final midpoint = RetryBackoffPolicy(
      initialDelay: const Duration(seconds: 1),
      maximumDelay: const Duration(seconds: 5),
      randomDouble: () => 0.5,
    );

    expect(midpoint.delayForAttempt(0), const Duration(seconds: 1));
    expect(midpoint.delayForAttempt(1), const Duration(seconds: 2));
    expect(midpoint.delayForAttempt(2), const Duration(seconds: 4));
    expect(midpoint.delayForAttempt(3), const Duration(seconds: 5));
    expect(midpoint.delayForAttempt(100), const Duration(seconds: 5));

    final low = RetryBackoffPolicy(randomDouble: () => 0).delayForAttempt(0);
    final high = RetryBackoffPolicy(randomDouble: () => 1).delayForAttempt(0);
    expect(low, const Duration(milliseconds: 800));
    expect(high, const Duration(milliseconds: 1200));
    expect(low, isNot(high));
    expect(() => midpoint.delayForAttempt(-1), throwsRangeError);
  });
}

const _successfulObjectResponse = ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{'value': 7},
  },
);

const _unauthorizedResponse = ApiTransportResponse(
  status: 401,
  body: <String, Object?>{
    'success': false,
    'error': <String, Object?>{
      'code': 'AUTH_UNAUTHORIZED',
      'message': 'Expired access token',
      'userMessageKey': 'auth.expired',
    },
  },
);

bool _isSuccessfulApiResult(ApiResult<ApiContractObject> result) => result.ok;

ApiClient _clientWithTransport(ApiTransport transport) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: '0.1.0',
      deviceId: 'desktop-1',
      platform: 'macos',
      locale: 'zh-CN',
      getAccessToken: () => 'access-token',
    ),
    transport: transport,
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Condition was not reached');
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

final class _ControlledTransport implements ApiTransport {
  final requests = <ApiTransportRequest>[];
  final _responses = <Completer<ApiTransportResponse>>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    requests.add(request);
    final response = Completer<ApiTransportResponse>();
    _responses.add(response);
    return response.future;
  }

  void complete(int index, ApiTransportResponse response) {
    _responses[index].complete(response);
  }
}

final class _ControlledCancellableTransport
    implements ApiTransport, CancellableApiTransport {
  final requests = <ApiTransportRequest>[];
  final _responses = <Completer<ApiTransportResponse>>[];
  int cancelCalls = 0;
  bool throwOnCancel = false;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) =>
      sendCancellable(request).response;

  @override
  ApiTransportOperation sendCancellable(ApiTransportRequest request) {
    requests.add(request);
    final response = Completer<ApiTransportResponse>();
    _responses.add(response);
    return ApiTransportOperation(
      response: response.future,
      cancel: () {
        cancelCalls += 1;
        if (throwOnCancel) throw StateError('abort-failed');
        if (!response.isCompleted) {
          response.completeError(StateError('transport-cancelled'));
        }
      },
    );
  }

  void complete(int index, ApiTransportResponse response) {
    if (!_responses[index].isCompleted) _responses[index].complete(response);
  }
}

final class _SlowBodyHttpClient implements HttpClient {
  _SlowBodyHttpClient(_SlowBodyHttpClientResponse response)
    : request = _SlowBodyHttpClientRequest(response);

  final _SlowBodyHttpClientRequest request;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => request;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _SlowBodyHttpClientRequest implements HttpClientRequest {
  _SlowBodyHttpClientRequest(this.response);

  final _SlowBodyHttpClientResponse response;
  @override
  final HttpHeaders headers = _TestHttpHeaders();
  int abortCalls = 0;

  @override
  void add(List<int> data) {}

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    abortCalls += 1;
  }

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _SlowBodyHttpClientResponse implements HttpClientResponse {
  _SlowBodyHttpClientResponse() {
    _controller.onListen = () => listened.complete();
    _controller.onCancel = () => cancelled.complete();
  }

  final _controller = StreamController<List<int>>();
  final Completer<void> listened = Completer<void>();
  final Completer<void> cancelled = Completer<void>();

  @override
  final HttpHeaders headers = _TestHttpHeaders();

  @override
  int get statusCode => HttpStatus.ok;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  Future<void> close() => _controller.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TestHttpHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name] = <String>[value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
