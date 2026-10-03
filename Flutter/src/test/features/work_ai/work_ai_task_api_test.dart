import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/work_ai/data/work_ai_task_api.dart';

void main() {
  group('WorkAiTaskApi', () {
    test(
      'loads a task result and submits retry/regenerate with idempotency',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _response(_taskDetailData()),
          _response(<String, Object?>{
            'retryTask': _task(taskId: 'task-2', status: 'queued'),
          }),
          _response(<String, Object?>{
            'regenerateTask': _task(taskId: 'task-3', status: 'queued'),
          }),
        ]);
        final api = WorkAiTaskApi(apiClient: _apiClient(transport));

        final detail = await api.getTask('task-1');
        final retry = await api.retryTask(
          taskId: 'task-1',
          stage: 'model_generation',
          idempotency: const IdempotencyRequestContext(
            operation: 'work_ai.retry_task',
            businessEntityId: 'task-1',
            scene: 'work_ai',
            generateKey: _retryKey,
          ),
        );
        final regenerated = await api.regenerateTask(
          taskId: 'task-2',
          supplement: 'Focus on customer objections',
          idempotency: const IdempotencyRequestContext(
            operation: 'work_ai.regenerate_task',
            businessEntityId: 'task-2',
            scene: 'work_ai',
            generateKey: _regenerateKey,
          ),
        );

        expect(detail.ok, isTrue);
        expect(detail.data?.topicResult?.topics.single.title, 'A useful topic');
        expect(detail.data?.retryActions.single.allowed, isTrue);
        expect(retry.data?.taskId, 'task-2');
        expect(regenerated.data?.taskId, 'task-3');

        final detailRequest = transport.requests[0];
        expect(detailRequest.method, 'GET');
        expect(detailRequest.url.path, '/api/v1/tasks/task-1');
        final retryRequest = transport.requests[1];
        expect(retryRequest.url.path, '/api/v1/tasks/task-1/retry');
        expect(retryRequest.headers['X-Idempotency-Key'], 'retry-key');
        expect(_body(retryRequest), <String, Object?>{
          'stage': 'model_generation',
        });
        final regenerateRequest = transport.requests[2];
        expect(regenerateRequest.url.path, '/api/v1/tasks/task-2/regenerate');
        expect(
          regenerateRequest.headers['X-Idempotency-Key'],
          'regenerate-key',
        );
        expect(_body(regenerateRequest), <String, Object?>{
          'supplement': 'Focus on customer objections',
        });
      },
    );

    test('rejects malformed task identifiers before transport', () async {
      final transport = _QueueTransport(const <ApiTransportResponse>[]);
      final api = WorkAiTaskApi(apiClient: _apiClient(transport));

      final result = await api.getTask('../task-1');

      expect(result.ok, isFalse);
      expect(result.error?.code, 'WORK_AI_TASK_ID_INVALID');
      expect(transport.requests, isEmpty);
    });
  });
}

Map<String, Object?> _taskDetailData() {
  return <String, Object?>{
    'task': _task(taskId: 'task-1', status: 'succeeded'),
    'topicResult': <String, Object?>{
      'taskId': 'task-1',
      'topics': <Object?>[
        <String, Object?>{
          'title': 'A useful topic',
          'reason': 'It is grounded in deposited material.',
          'sourceRecordingIds': <Object?>['recording-1'],
        },
      ],
    },
    'retryActions': <Object?>[
      <String, Object?>{
        'action': 'model_generation',
        'title': 'Retry generation',
        'allowed': true,
      },
    ],
  };
}

Map<String, Object?> _task({required String taskId, required String status}) {
  return <String, Object?>{
    'taskId': taskId,
    'taskType': 'topic_generation',
    'status': status,
  };
}

ApiTransportResponse _response(Map<String, Object?> data) {
  return ApiTransportResponse(
    status: 200,
    body: <String, Object?>{'success': true, 'data': data},
  );
}

ApiClient _apiClient(_QueueTransport transport) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'test',
      locale: 'en-US',
      getAccessToken: () async => 'access-token',
    ),
    transport: transport,
  );
}

Map<String, Object?> _body(ApiTransportRequest request) {
  final decoded = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

String _retryKey() => 'retry-key';

String _regenerateKey() => 'regenerate-key';

final class _QueueTransport implements ApiTransport {
  _QueueTransport(List<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.of(responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('Unexpected request');
    return _responses.removeAt(0);
  }
}
