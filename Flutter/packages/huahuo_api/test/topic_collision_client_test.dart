import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'topic collision submits four HNote IDs and reads a response without private sources',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(status: 202, body: _envelope(_run('running'))),
        ApiTransportResponse(status: 200, body: _envelope(_run('succeeded'))),
      ]);
      final client = TopicCollisionClient(_client(transport));

      final submitted = await client.submit(
        'workspace_1',
        noteIds: const ['note-1', 'note-2', 'note-3', 'note-4'],
        idempotencyKey: 'collision-1',
      );
      final finished = await client.get('workspace_1', 'collision_1');

      expect(submitted.ok, isTrue);
      expect(submitted.data!.selectedNoteCount, 4);
      expect(submitted.data!.sources, isEmpty);
      expect(submitted.data!.workspaceId, 'workspace_1');
      expect(finished.data!.isSuccessful, isTrue);
      expect(finished.data!.outputNoteId, 'note_collision_1');
      expect(
        transport.requests[0].url.path,
        '/api/v1/workspaces/workspace_1/note-topic-collision-runs',
      );
      expect(jsonDecode(transport.requests[0].body!), {
        'noteIds': ['note-1', 'note-2', 'note-3', 'note-4'],
      });
      expect(transport.requests[0].headers['X-Idempotency-Key'], 'collision-1');
      expect(
        transport.requests[1].url.path,
        '/api/v1/workspaces/workspace_1/note-topic-collision-runs/collision_1',
      );
    },
  );

  for (final status in topicCollisionStatuses) {
    test('parses public $status status with no sources', () {
      final run = TopicCollisionRun.fromJson(
        _run(status)['topicCollisionRun']! as Map<String, Object?>,
      );
      expect(run.status, status);
      expect(run.sources, isEmpty);
      expect(
        run.isTerminal,
        ['succeeded', 'failed', 'dead_letter'].contains(status),
      );
    });
  }
  for (final field in [
    'workspaceId',
    'stage',
    'attempt',
    'maxAttempts',
    'retryable',
  ]) {
    test('rejects missing public $field', () {
      final value =
          _run('running')['topicCollisionRun']! as Map<String, Object?>;
      value.remove(field);
      expect(() => TopicCollisionRun.fromJson(value), throwsFormatException);
    });
  }
  test('unknown server status is a protocol error, never pending forever', () {
    final value =
        _run('new_unknown_phase')['topicCollisionRun']! as Map<String, Object?>;
    expect(() => TopicCollisionRun.fromJson(value), throwsFormatException);
  });
  test('successful run must identify its output', () {
    final value =
        _run('succeeded')['topicCollisionRun']! as Map<String, Object?>;
    value.remove('outputNoteId');
    expect(() => TopicCollisionRun.fromJson(value), throwsFormatException);
  });
  test('invalid selections are rejected before transport', () {
    final transport = _QueueTransport([]);
    final client = TopicCollisionClient(_client(transport));
    for (final ids in <List<String>>[
      [],
      ['a', 'b', 'c'],
      ['a', 'b', 'c', 'c'],
      ['a', 'b', 'c', ''],
      ['a', 'b', 'c', 'd', 'e'],
    ]) {
      expect(
        () => client.submit('workspace_1', noteIds: ids, idempotencyKey: 'key'),
        throwsArgumentError,
      );
    }
    expect(transport.requests, isEmpty);
  });
}

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device_1',
    platform: 'windows',
    locale: 'zh-CN',
    getAccessToken: () => 'token_1',
  ),
  transport: transport,
);

Map<String, Object?> _envelope(Object data) => <String, Object?>{
  'success': true,
  'data': data,
};

Map<String, Object?> _run(String status) => <String, Object?>{
  'topicCollisionRun': <String, Object?>{
    'topicCollisionRunId': 'collision_1',
    'status': status,
    'selectedNoteCount': 4,
    'workspaceId': 'workspace_1',
    'stage': status == 'succeeded' ? 'completed' : 'source_frozen',
    'attempt': 0,
    'maxAttempts': 3,
    'retryable': false,
    if (status == 'succeeded') ...<String, Object?>{
      'outputNoteId': 'note_collision_1',
    },
  },
};

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
