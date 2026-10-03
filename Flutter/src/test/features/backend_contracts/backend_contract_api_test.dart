import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/endpoint_catalog.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/backend_contracts/data/backend_contract_api.dart';
import 'package:huahuoai_app/features/backend_contracts/domain/backend_contract_models.dart';

void main() {
  test('adapter runtime inventory contains only active catalog endpoints', () {
    expect(
      BackendContractApi.contractReadyEndpointIds.every(
        EndpointCatalog.definitions.containsKey,
      ),
      isTrue,
    );
    expect(
      BackendContractApi.contractReadyEndpointIds,
      isNot(
        containsAll(<String>{
          'updateMyProfile',
          'contentLines',
          'memoryNoteAppends',
          'workAiMaterialCandidates',
          'taskEvents',
          'feedDepositSummary',
          'retryFeedDeposit',
        }),
      ),
    );
  });

  test(
    'retired and prohibited compatibility calls never reach transport',
    () async {
      final transport = _CountingTransport();
      final api = _api(transport);

      final contentLines = await api.listContentLines(cursor: 'cursor-1');
      final profile = await api.updateMyProfile(
        const ProfileUpdateContract(displayName: '新的昵称'),
        idempotency: const IdempotencyRequestContext(explicitKey: 'idem-1'),
      );
      final work = await api.listWorkAiMaterialCandidates(purpose: 'topic');
      final feed = await api.getFeedDepositSummary('message-1');
      final retryFeed = await api.retryFeedDeposit(
        'message-1',
        idempotency: const IdempotencyRequestContext(explicitKey: 'idem-2'),
      );

      expect(contentLines.error?.code, 'API_ENDPOINT_RETIRED');
      expect(profile.error?.code, 'API_ENDPOINT_RETIRED');
      expect(work.error?.code, 'API_ENDPOINT_PROHIBITED');
      expect(feed.error?.code, 'API_ENDPOINT_PROHIBITED');
      expect(retryFeed.error?.code, 'API_ENDPOINT_PROHIBITED');
      expect(transport.calls, 0);
    },
  );

  test('active analytics call keeps the documented transport path', () async {
    final transport = _CountingTransport(
      response: const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{'status': 'accepted'},
        },
      ),
    );
    final result = await _api(transport).sendAnalyticsEvent(
      AnalyticsEventContract(eventId: 'event-1', name: 'app_opened'),
    );

    expect(result.ok, isTrue);
    expect(transport.calls, 1);
    expect(transport.requests.single.url.path, '/api/v1/analytics/events');
  });

  test('workspace retry creates through the documented command', () async {
    final transport = _CountingTransport(
      response: const ApiTransportResponse(
        status: 202,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{'status': 'accepted'},
        },
      ),
    );

    final result = await _api(transport).retryWorkspaceCreate(
      idempotency: const IdempotencyRequestContext(
        explicitKey: 'workspace-retry-1',
      ),
    );

    expect(result.ok, isTrue);
    expect(
      transport.requests.single.url.path,
      '/api/v1/workspace/retry-create',
    );
    expect(
      transport.requests.single.headers['X-Idempotency-Key'],
      'workspace-retry-1',
    );
    expect(transport.requests.single.body, '{}');
  });

  test('recording-card writes require an active ownership fence', () async {
    final transport = _CountingTransport(
      response: const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{'status': 'accepted'},
        },
      ),
    );
    final api = _api(transport);
    final invalid = await api.syncRecordingCardFiles(
      bindingId: 'binding-1',
      bindingGeneration: 0,
      idempotency: const IdempotencyRequestContext(explicitKey: 'sync-bad'),
    );
    expect(invalid.error?.code, 'BACKEND_RECORDING_CARD_BINDING_FENCE_INVALID');
    expect(transport.calls, 0);

    await api.syncRecordingCardFiles(
      bindingId: 'binding-1',
      bindingGeneration: 4,
      idempotency: const IdempotencyRequestContext(explicitKey: 'sync-good'),
    );
    await api.linkRecordingCardUpload(
      cardFileId: 'card-file-1',
      uploadId: 'upload-1',
      resourceId: 'resource-1',
      bindingId: 'binding-1',
      bindingGeneration: 4,
      idempotency: const IdempotencyRequestContext(explicitKey: 'link-good'),
    );

    expect(jsonDecode(transport.requests[0].body!), <String, Object?>{
      'bindingId': 'binding-1',
      'bindingGeneration': 4,
    });
    expect(jsonDecode(transport.requests[1].body!), <String, Object?>{
      'uploadId': 'upload-1',
      'resourceId': 'resource-1',
      'bindingId': 'binding-1',
      'bindingGeneration': 4,
    });
  });

  test('recordings prefer transcript status and accept limit 100', () async {
    final transport = _CountingTransport(
      response: const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'recordingId': 'recording-1',
                'title': '已完成录音',
                'transcriptStatus': 'final_transcript_generated',
                'status': 'failed',
              },
              <String, Object?>{'id': 'recording-2', 'status': 'transcribed'},
            ],
          },
        },
      ),
    );

    final result = await _api(transport).listRecordings(limit: 100);

    expect(result.ok, isTrue);
    expect(transport.requests.single.url.queryParameters['limit'], '100');
    expect(
      result.data?.items[0].transcriptStatus,
      'final_transcript_generated',
    );
    expect(result.data?.items[0].status, 'final_transcript_generated');
    expect(result.data?.items[1].transcriptStatus, 'transcribed');
  });

  test('recordings reject limits above 100 before transport', () async {
    final transport = _CountingTransport();

    final result = await _api(transport).listRecordings(limit: 101);

    expect(result.error?.code, 'BACKEND_RECORDING_LIMIT_INVALID');
    expect(transport.calls, 0);
  });
}

BackendContractApi _api(ApiTransport transport) => BackendContractApi(
  apiClient: ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: () => 'access-token',
    ),
    transport: transport,
  ),
);

final class _CountingTransport implements ApiTransport {
  _CountingTransport({this.response});

  final ApiTransportResponse? response;
  final requests = <ApiTransportRequest>[];
  var calls = 0;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    calls += 1;
    requests.add(request);
    return response ??
        (throw StateError('Retired/prohibited call reached transport'));
  }
}
