import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  group('ApiContractManifest', () {
    test('contains every unique Docs App operation', () {
      final operations = ApiContractManifest.operations;
      final keys = operations.map((operation) => operation.key).toSet();

      expect(operations, hasLength(215));
      expect(keys, hasLength(215));
      expect(
        operations.where(
          (operation) => operation.scope == ApiContractScope.formal,
        ),
        hasLength(123),
      );
      expect(
        operations.where(
          (operation) => operation.scope == ApiContractScope.retained,
        ),
        hasLength(92),
      );
      expect(ApiContractManifest.prohibitedOperations, hasLength(5));
      expect(
        operations.every((operation) => operation.authority.startsWith('API ')),
        isTrue,
      );
    });

    test('prohibited and retired routes cannot enter runtime catalog', () {
      final runtimePaths = EndpointCatalog.listDefinitions()
          .map((endpoint) => endpoint.pathTemplate)
          .toSet();

      for (final operation in ApiContractManifest.prohibitedOperations) {
        expect(runtimePaths, isNot(contains(operation.path)));
      }
      for (final path in ApiContractManifest.retiredClientPaths) {
        expect(runtimePaths, isNot(contains(path)));
      }
    });

    test('saved subscription Note assets are formal Mobile binary reads', () {
      final operation = ApiContractManifest.operations.singleWhere(
        (entry) => entry.path.endsWith('/notes/{noteId}/subscription-assets'),
      );
      expect(operation.scope, ApiContractScope.formal);
      expect(operation.authority, 'API 25');
      expect(operation.disposition, ApiOperationDisposition.wiredMobile);
      expect(operation.responseKind, ApiResponseKind.binary);
      expect(
        EndpointCatalog.byId('subscriptionNoteAsset').responseMode,
        EndpointResponseMode.binary,
      );
    });

    test('API 28 callbacks are server-only contract records', () {
      const callbackKeys = <String>{
        'POST /api/v1/billing/wechat/notify',
        'POST /api/v1/billing/alipay/notify',
        'POST /api/v1/billing/apple/notifications/v2',
      };
      final callbacks = ApiContractManifest.operations
          .where((operation) => callbackKeys.contains(operation.key))
          .toList(growable: false);

      expect(callbacks, hasLength(3));
      for (final operation in callbacks) {
        expect(operation.authority, 'API 28');
        expect(operation.disposition, ApiOperationDisposition.contractOnly);
        expect(operation.responseKind, ApiResponseKind.jsonEnvelope);
      }

      final runtimePaths = EndpointCatalog.listDefinitions()
          .map((definition) => definition.pathTemplate)
          .toSet();
      for (final callbackKey in callbackKeys) {
        expect(runtimePaths, isNot(contains(callbackKey.substring(5))));
      }

      for (final endpointId in <String>[
        'billingWechatNotify',
        'billingAlipayNotify',
        'billingAppleNotificationsV2',
      ]) {
        expect(() => EndpointCatalog.resolve(endpointId), throwsArgumentError);
      }
    });

    test('dispositions mirror production Mobile and Desktop consumers', () {
      final operations = <String, ApiContractOperation>{
        for (final operation in ApiContractManifest.operations)
          operation.key: operation,
      };
      ApiOperationDisposition disposition(String key) =>
          operations[key]!.disposition;

      expect(
        disposition('POST /api/v1/media/upload-token'),
        ApiOperationDisposition.wiredMobile,
      );
      expect(
        disposition(
          'POST /api/v1/workspaces/{workspaceId}/document-change-proposals',
        ),
        ApiOperationDisposition.wiredMobile,
      );
      expect(
        disposition(
          'POST /api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/rebase',
        ),
        ApiOperationDisposition.contractOnly,
      );
      expect(
        disposition('PUT /api/v1/me/timezone'),
        ApiOperationDisposition.wiredMobile,
      );
      expect(
        disposition('GET /api/v1/workspaces/current/profile'),
        ApiOperationDisposition.wiredMobile,
      );
      expect(
        disposition('GET /api/v1/workspaces/{workspaceId}/content-snapshot'),
        ApiOperationDisposition.wiredBoth,
      );
      expect(
        disposition('GET /api/v1/workspaces/{workspaceId}/content-changes'),
        ApiOperationDisposition.wiredBoth,
      );
      expect(
        disposition('GET /api/v1/recording-card/device-binding'),
        ApiOperationDisposition.wiredBoth,
      );
      for (final key in <String>{
        'POST /api/v1/recording-card/bind-challenge',
        'POST /api/v1/recording-card/bind',
        'POST /api/v1/recording-card/devices/{deviceId}/unbind',
      }) {
        expect(disposition(key), ApiOperationDisposition.wiredMobile);
      }
      expect(
        disposition('POST /api/v1/workspaces/{workspaceId}/search'),
        ApiOperationDisposition.wiredBoth,
      );
      expect(
        disposition('GET /api/v1/agent-profiles/{agentProfileId}/models'),
        ApiOperationDisposition.wiredBoth,
      );
      expect(
        disposition('GET /api/v1/workspaces/{workspaceId}/work'),
        ApiOperationDisposition.wiredBoth,
      );
      expect(
        disposition(
          'GET /api/v1/subscription/articles/{articleId}/revisions/{articleRevisionId}',
        ),
        ApiOperationDisposition.wiredMobile,
      );
      expect(
        disposition(
          'GET /api/v1/workspaces/{workspaceId}/content-navigation/{map}',
        ),
        ApiOperationDisposition.contractOnly,
      );
      expect(
        disposition('POST /api/v1/workspaces/{workspaceId}/book/import'),
        ApiOperationDisposition.contractOnly,
      );
      expect(
        disposition(
          'POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/relations',
        ),
        ApiOperationDisposition.contractOnly,
      );
    });

    test('prohibited operations are rejected before transport', () async {
      final transport = _CountingTransport();
      final client = _client(transport);

      for (final endpointId in ApiContractManifest.prohibitedEndpointIds) {
        final result = await client.request<ApiContractObject>(
          ApiRequestOptions<ApiContractObject>(
            endpointId: endpointId,
            parseData: ApiContractObject.fromValue,
          ),
        );
        expect(result.ok, isFalse, reason: endpointId);
        expect(result.error?.code, 'API_ENDPOINT_PROHIBITED');
      }

      expect(transport.calls, 0);
    });

    test('agent feature routes select only public Agent profiles', () {
      final featureIds = AgentFeatureRoutes.all
          .map((route) => route.featureId)
          .toSet();

      expect(featureIds, hasLength(AgentFeatureRoutes.all.length));
      for (final route in AgentFeatureRoutes.all) {
        expect(route.agentProfileId, isNot(contains('_agent')));
        expect(route.skillProfileIds, isEmpty);
      }
      expect(
        <String>{
          for (final route in AgentFeatureRoutes.all) route.agentProfileId,
        },
        containsAll(<String>{
          'book_writing',
          'positioning_lv1',
          'positioning_lv2',
          'faya_germination',
          'huoke_content',
          'self_media_creation_standard',
          'renshe_content',
          'self_media_creation',
          'video_analysis',
          'visual_chat',
        }),
      );
      expect(
        AgentFeatureRoutes.forFeature('book.writing')?.agentProfileId,
        'book_writing',
      );
      expect(
        AgentFeatureRoutes.forFeature('chat.general')?.agentProfileId,
        'self_media_creation_standard',
      );
      expect(
        AgentFeatureRoutes.forFeature('creation.free')?.agentProfileId,
        'self_media_creation',
      );
      expect(
        AgentFeatureRoutes.forFeature('positioning.initial')?.agentProfileId,
        'positioning_lv1',
      );
      expect(
        AgentFeatureRoutes.forFeature('deep_positioning')?.agentProfileId,
        'positioning_lv2',
      );
      expect(
        AgentFeatureRoutes.forFeature('canvas.risk_check')?.agentProfileId,
        'self_media_creation',
      );
      for (final route in AgentFeatureRoutes.all.where(
        (route) =>
            route.featureId.startsWith('canvas.') ||
            route.featureId.startsWith('creation.'),
      )) {
        expect(route.agentProfileId, 'self_media_creation');
      }
    });

    test('Agent feature availability uses the public profile catalog only', () {
      final route = AgentFeatureRoutes.forFeature('video_analysis')!;
      const profiles = AgentProfileCatalog(
        catalogVersion: 'catalog-v2',
        items: <AgentProfileCatalogItem>[
          AgentProfileCatalogItem(
            agentProfileId: 'video_analysis',
            displayName: 'Video analysis',
          ),
        ],
      );
      final available = AgentFeatureAvailabilityResolver.resolve(
        route: route,
        profiles: profiles,
      );
      expect(available.isAvailable, isTrue);
      expect(available.reasonCode, isNull);
      expect(available.skillProfileIds, isEmpty);
      expect(available.modelProfileId, isNull);

      final missingProfile = AgentFeatureAvailabilityResolver.resolve(
        route: route,
        profiles: const AgentProfileCatalog(
          catalogVersion: 'catalog-v2',
          items: <AgentProfileCatalogItem>[],
        ),
      );
      expect(
        missingProfile.status,
        AgentFeatureAvailabilityStatus.agentProfileUnavailable,
      );

      final unknown = AgentFeatureAvailabilityResolver.resolveFeature(
        featureId: 'unknown.feature',
        profiles: profiles,
      );
      expect(unknown.status, AgentFeatureAvailabilityStatus.featureUnknown);
    });

    test(
      'every runtime operation constructs and parses its response mode',
      () async {
        for (final endpoint in EndpointCatalog.listDefinitions()) {
          expect(endpoint.docsAuthority, isNotEmpty, reason: endpoint.id);
          expect(endpoint.responseType, isNotEmpty, reason: endpoint.id);
          expect(
            endpoint.isStreaming,
            endpoint.responseMode == EndpointResponseMode.sse,
            reason: endpoint.id,
          );
          if (endpoint.responseMode == EndpointResponseMode.sse) continue;
          final response = switch (endpoint.responseMode) {
            EndpointResponseMode.empty => const ApiTransportResponse(
              status: 204,
              body: null,
            ),
            EndpointResponseMode.binary => ApiTransportResponse(
              status: 200,
              body: Uint8List.fromList(<int>[1, 2, 3]),
            ),
            _ => const ApiTransportResponse(
              status: 200,
              body: <String, Object?>{
                'success': true,
                'data': <String, Object?>{'accepted': true},
              },
            ),
          };
          final transport = _CapturingTransport(response);
          final client = _client(transport);
          final result = await client.request<Object>(
            ApiRequestOptions<Object>(
              endpointId: endpoint.id,
              pathParams: _pathParams(endpoint.pathTemplate),
              body: endpoint.method == HttpMethod.get
                  ? null
                  : const <String, Object?>{},
              idempotency:
                  endpoint.idempotency == EndpointIdempotencyPolicy.forbidden
                  ? null
                  : const IdempotencyRequestContext(
                      explicitKey: 'manifest-operation-key',
                    ),
              parseData: (value) => switch (endpoint.responseMode) {
                EndpointResponseMode.empty => const <String, Object?>{
                  'empty': true,
                },
                EndpointResponseMode.binary when value is Uint8List => value,
                _ => asObjectMap(value),
              },
            ),
          );

          expect(result.ok, isTrue, reason: endpoint.id);
          final request = transport.requests.single;
          expect(request.method, endpoint.method.value, reason: endpoint.id);
          expect(request.url.path, isNot(contains('{')), reason: endpoint.id);
          expect(request.responseMode, endpoint.responseMode);
          if (endpoint.idempotency != EndpointIdempotencyPolicy.forbidden) {
            expect(
              request.headers[endpoint.idempotencyHeaderName],
              'manifest-operation-key',
              reason: endpoint.id,
            );
          }
        }
      },
    );

    test(
      'every JSON runtime operation rejects a damaged success response',
      () async {
        for (final endpoint in EndpointCatalog.listDefinitions().where(
          (endpoint) =>
              endpoint.responseMode == EndpointResponseMode.strictEnvelope ||
              endpoint.responseMode == EndpointResponseMode.legacyCompatible,
        )) {
          final transport = _CapturingTransport(
            const ApiTransportResponse(status: 200, body: 'damaged'),
          );
          final result = await _client(transport).request<ApiContractObject>(
            ApiRequestOptions<ApiContractObject>(
              endpointId: endpoint.id,
              pathParams: _pathParams(endpoint.pathTemplate),
              body: endpoint.method == HttpMethod.get
                  ? null
                  : const <String, Object?>{},
              idempotency:
                  endpoint.idempotency == EndpointIdempotencyPolicy.forbidden
                  ? null
                  : const IdempotencyRequestContext(
                      explicitKey: 'manifest-damaged-key',
                    ),
              parseData: ApiContractObject.fromValue,
            ),
          );

          expect(result.ok, isFalse, reason: endpoint.id);
          expect(
            result.error?.code,
            anyOf('API_MALFORMED_ENVELOPE', 'API_RESPONSE_INVALID'),
            reason: endpoint.id,
          );
        }
      },
    );

    test('SSE, conflict, precondition and retry metadata stay typed', () async {
      final streamTransport = _StreamingTransport();
      final streamResult = await _client(streamTransport)
          .openEventStream<ApiContractObject>(
            ApiStreamRequestOptions<ApiContractObject>(
              endpointId: 'agentRunEventStream',
              pathParams: const <String, Object>{'agentRunId': 'run-1'},
              parseData: ApiContractObject.fromValue,
            ),
          );
      final events = await streamResult.data!.toList();
      expect(events.single.event, 'run.updated');
      expect(events.single.data?.requireString('status'), 'running');

      for (final expectation in <(int, String, int?)>[
        (409, 'API_CONFLICT', null),
        (412, 'API_PRECONDITION_FAILED', null),
        (429, 'API_RATE_LIMITED', 7),
      ]) {
        final result =
            await _client(
              _CapturingTransport(
                ApiTransportResponse(
                  status: expectation.$1,
                  headers: expectation.$1 == 429
                      ? const <String, String>{'Retry-After': '7'}
                      : const <String, String>{},
                  body: const <String, Object?>{},
                ),
              ),
            ).request<ApiContractObject>(
              const ApiRequestOptions<ApiContractObject>(
                endpointId: 'workspaces',
                parseData: ApiContractObject.fromValue,
              ),
            );
        expect(result.error?.code, expectation.$2);
        expect(result.retryAfterSeconds, expectation.$3);
      }
    });

    test('authenticated SSE refreshes and reconnects once after 401', () async {
      var accessToken = 'expired-access';
      var refreshCalls = 0;
      final transport = _StreamingSequenceTransport(
        <ApiTransportStreamResponse>[
          const ApiTransportStreamResponse(
            status: 401,
            headers: <String, String>{},
            errorBody: <String, Object?>{
              'success': false,
              'error': <String, Object?>{'code': 'UNAUTHORIZED'},
            },
            events: Stream<ApiTransportStreamEvent>.empty(),
          ),
          ApiTransportStreamResponse(
            status: 200,
            headers: const <String, String>{},
            events: Stream<ApiTransportStreamEvent>.value(
              const ApiTransportStreamEvent(
                id: '1',
                event: 'run.updated',
                data: <String, Object?>{'status': 'completed'},
              ),
            ),
          ),
        ],
      );
      final client = _client(
        transport,
        getAccessToken: () => accessToken,
        refreshAccessToken: ({required rejectedAccessToken, required failure}) {
          expect(rejectedAccessToken, 'expired-access');
          refreshCalls += 1;
          accessToken = 'rotated-access';
          return AccessTokenRefreshDisposition.refreshed;
        },
      );

      final result = await client.openEventStream<ApiContractObject>(
        ApiStreamRequestOptions<ApiContractObject>(
          endpointId: 'agentRunEventStream',
          pathParams: const <String, Object>{'agentRunId': 'run-refresh'},
          correlationId: 'trace-sse-refresh',
          parseData: ApiContractObject.fromValue,
        ),
      );
      final events = await result.data!.toList();

      expect(result.ok, isTrue);
      expect(events.single.data?.requireString('status'), 'completed');
      expect(refreshCalls, 1);
      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.map((request) => request.headers['Authorization']),
        <String?>['Bearer expired-access', 'Bearer rotated-access'],
      );
      expect(
        transport.requests.map((request) => request.headers['X-Trace-Id']),
        everyElement('trace-sse-refresh'),
      );
    });
  });
}

Map<String, Object> _pathParams(String pathTemplate) => <String, Object>{
  for (final match in RegExp(r'\{([A-Za-z0-9_]+)\}').allMatches(pathTemplate))
    match.group(1)!: '${match.group(1)}-test',
};

ApiClient _client(
  ApiTransport transport, {
  AccessTokenProvider? getAccessToken,
  AccessTokenRefreshHandler? refreshAccessToken,
}) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'test-device',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: getAccessToken ?? () => 'token',
    refreshAccessToken: refreshAccessToken,
  ),
  transport: transport,
);

final class _CountingTransport implements ApiTransport {
  var calls = 0;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    calls += 1;
    return const ApiTransportResponse(status: 500, body: <String, Object?>{});
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

final class _StreamingTransport implements ApiTransport, ApiStreamingTransport {
  @override
  Future<ApiTransportStreamResponse> open(ApiTransportRequest request) async {
    return ApiTransportStreamResponse(
      status: 200,
      headers: const <String, String>{},
      events: Stream<ApiTransportStreamEvent>.value(
        const ApiTransportStreamEvent(
          id: '1',
          event: 'run.updated',
          data: <String, Object?>{'status': 'running'},
        ),
      ),
    );
  }

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async =>
      throw StateError('SSE must use open');
}

final class _StreamingSequenceTransport
    implements ApiTransport, ApiStreamingTransport {
  _StreamingSequenceTransport(List<ApiTransportStreamResponse> responses)
    : _responses = List<ApiTransportStreamResponse>.from(responses);

  final List<ApiTransportStreamResponse> _responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportStreamResponse> open(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async =>
      throw StateError('SSE must use open');
}
