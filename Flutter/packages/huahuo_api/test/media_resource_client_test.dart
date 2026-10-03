import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'deletes a Workspace Resource with the required idempotency key',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success('deleted'),
      ]);
      final result = await MediaResourceClient(_client(transport)).delete(
        workspaceId: 'workspace-1',
        resourceId: 'resource-1',
        idempotencyKey: 'delete-resource-1',
      );

      expect(result.ok, isTrue);
      expect(result.data?.status, 'deleted');
      final request = transport.requests.single;
      expect(request.method, 'DELETE');
      expect(
        request.url.path,
        '/api/v1/workspaces/workspace-1/media/resources/resource-1',
      );
      expect(request.body, isNull);
      expect(request.headers['X-Idempotency-Key'], 'delete-resource-1');
    },
  );

  test(
    'accepts a delete_pending receipt because the Resource is unusable',
    () async {
      final result =
          await MediaResourceClient(
            _client(
              _QueueTransport(<ApiTransportResponse>[
                _success('delete_pending'),
              ]),
            ),
          ).delete(
            workspaceId: 'workspace-1',
            resourceId: 'resource-1',
            idempotencyKey: 'delete-resource-1',
          );

      expect(result.ok, isTrue);
      expect(result.data?.blocksFurtherUse, isTrue);
      expect(result.data?.status, 'delete_pending');
    },
  );

  test('rejects a receipt that changes identity or lifecycle', () async {
    final invalid = ApiTransportResponse(
      status: 200,
      body: <String, Object?>{
        'success': true,
        'data': <String, Object?>{
          'workspaceId': 'workspace-1',
          'resourceId': 'resource-other',
          'status': 'processing',
        },
      },
    );
    final result =
        await MediaResourceClient(
          _client(_QueueTransport(<ApiTransportResponse>[invalid])),
        ).delete(
          workspaceId: 'workspace-1',
          resourceId: 'resource-1',
          idempotencyKey: 'delete-resource-1',
        );

    expect(result.ok, isFalse);
  });
}

ApiClient _client(_QueueTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-test',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
  ),
  transport: transport,
);

ApiTransportResponse _success(String status) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'workspaceId': 'workspace-1',
      'resourceId': 'resource-1',
      'status': status,
    },
  },
);

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this.responses);

  final List<ApiTransportResponse> responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}
