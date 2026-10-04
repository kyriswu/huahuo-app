import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/chat/data/remote_project_assistant_runtime.dart';
import 'package:huahuoai_app/features/chat/domain/assistant_runtime.dart';

void main() {
  test('maps project progress wire data to provider-neutral events', () async {
    final runtime = RemoteProjectAssistantRuntime(
      _client(
        _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'threadId': 'thread-1',
                'nextSequence': 4,
                'events': <Object?>[
                  <String, Object?>{
                    'sequence': 3,
                    'eventType': 'draft_delta',
                    'runId': 'run-1',
                    'deltaText': '你好',
                    'replace': false,
                  },
                  <String, Object?>{
                    'sequence': 4,
                    'eventType': 'status',
                    'runId': 'run-1',
                  },
                ],
              },
            },
          ),
        ]),
      ),
    );

    final result = await runtime.readProgress(
      conversationId: 'thread-1',
      afterSequence: 2,
    );

    expect(result.ok, isTrue);
    expect(result.data?.conversationId, 'thread-1');
    expect(result.data?.nextSequence, 4);
    expect(result.data?.events, hasLength(2));
    expect(
      result.data?.events.first.type,
      AssistantProgressEventType.draftDelta,
    );
    expect(result.data?.events.first.runHandle, 'run-1');
    expect(result.data?.events.first.deltaText, '你好');
  });

  test('rejects invalid progress identifiers before transport', () async {
    final transport = _QueueTransport(const <ApiTransportResponse>[]);
    final runtime = RemoteProjectAssistantRuntime(_client(transport));

    final result = await runtime.readProgress(
      conversationId: 'file:///private/thread',
      afterSequence: 0,
    );

    expect(result.ok, isFalse);
    expect(result.errorCode, 'ASSISTANT_PROGRESS_QUERY_INVALID');
    expect(transport.requests, isEmpty);
  });

  test('rejects project-invalid run handles before transport', () async {
    final transport = _QueueTransport(const <ApiTransportResponse>[]);
    final runtime = RemoteProjectAssistantRuntime(_client(transport));

    final result = await runtime.readRun(
      handle: const AssistantRunHandle('provider-run-without-project-prefix'),
    );

    expect(result.ok, isFalse);
    expect(result.errorCode, 'ASSISTANT_RUN_HANDLE_INVALID');
    expect(transport.requests, isEmpty);
  });

  test(
    'rejects malformed provider progress fields at the adapter boundary',
    () async {
      final runtime = RemoteProjectAssistantRuntime(
        _client(
          _QueueTransport(<ApiTransportResponse>[
            const ApiTransportResponse(
              status: 200,
              body: <String, Object?>{
                'success': true,
                'data': <String, Object?>{
                  'threadId': 'thread-1',
                  'nextSequence': 2,
                  'events': <Object?>[
                    <String, Object?>{
                      'sequence': 1,
                      'eventType': 'draft_delta',
                      'runId': 'run-1',
                      'messageId': 42,
                      'deltaText': 'ignored',
                    },
                  ],
                },
              },
            ),
          ]),
        ),
      );

      final result = await runtime.readProgress(
        conversationId: 'thread-1',
        afterSequence: 0,
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'API_RESPONSE_INVALID');
    },
  );
}

ApiClient _client(_QueueTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '0.1.0',
    deviceId: 'device-1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
    traceIdFactory: () => 'trace-assistant-runtime',
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
