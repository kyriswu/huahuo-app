import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/work_ai/data/work_ai_api.dart';

void main() {
  test(
    'all Work AI compatibility operations are prohibited without transport',
    () async {
      final transport = _CountingTransport();
      final api = WorkAiApi(apiClient: _apiClient(transport));

      final options = await api.getTopicOptions(contentLineId: 'line-1');
      final created = await api.createTopicGeneration(
        const CreateWorkAiTopicInput(
          contentLineId: 'line-1',
          materialScope: WorkAiMaterialScope.recent(recentDays: 7),
          idempotency: IdempotencyRequestContext(explicitKey: 'work-ai-key'),
        ),
      );

      expect(options.error?.code, 'API_ENDPOINT_PROHIBITED');
      expect(created.error?.code, 'API_ENDPOINT_PROHIBITED');
      expect(transport.calls, 0);
    },
  );

  test('production unavailable port returns the same explicit state', () async {
    const api = UnavailableWorkAiApi();

    final result = await api.getTopicOptions();

    expect(result.ok, isFalse);
    expect(result.error?.code, 'API_ENDPOINT_PROHIBITED');
  });
}

ApiClient _apiClient(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-1',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
  ),
  transport: transport,
);

final class _CountingTransport implements ApiTransport {
  var calls = 0;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    calls += 1;
    throw StateError('Work AI must not invoke transport');
  }
}
