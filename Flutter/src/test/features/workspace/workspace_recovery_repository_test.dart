import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/workspace/data/workspace_recovery_repository.dart';

void main() {
  test(
    'workspace retry uses the documented command and idempotency key',
    () async {
      final transport = _CountingTransport(
        response: const ApiTransportResponse(
          status: 202,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{'status': 'accepted'},
          },
        ),
      );
      final result = await _repository(transport).retryCreate(
        idempotency: const IdempotencyRequestContext(
          explicitKey: 'workspace-retry-1',
          operation: 'workspace-retry-create',
          scene: 'workspace-recovery',
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
      expect(result.data?.status, 'accepted');
    },
  );

  test(
    'malformed acknowledgement fails closed before the repository exposes data',
    () async {
      final transport = _CountingTransport(
        response: const ApiTransportResponse(
          status: 202,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{'status': ''},
          },
        ),
      );
      final result = await _repository(transport).retryCreate(
        idempotency: const IdempotencyRequestContext(
          explicitKey: 'workspace-retry-2',
        ),
      );

      expect(result.ok, isFalse);
      expect(result.data, isNull);
      expect(transport.calls, 1);
    },
  );
}

WorkspaceRecoveryRepository _repository(ApiTransport transport) =>
    WorkspaceRecoveryRepository(
      apiClient: ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'device-1',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () async => 'access-token',
        ),
        transport: transport,
      ),
    );

final class _CountingTransport implements ApiTransport {
  _CountingTransport({required this.response});

  final ApiTransportResponse response;
  final requests = <ApiTransportRequest>[];
  var calls = 0;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    calls += 1;
    requests.add(request);
    return response;
  }
}
