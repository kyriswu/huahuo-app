import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/data/faya_germination_client.dart';

void main() {
  group('FayaGerminationClient', () {
    test(
      'writes a server-owned germination part with the exact Faya selector',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _noteHead(),
          _notePart(part: 'raw', revision: 'raw-r1', markdown: '原始内容保持完整。'),
          _noteHead(),
          _run(status: 'running'),
          _run(status: 'succeeded', outputPartRevisionId: 'germ-r2'),
          _noteHead(germinationRevisionId: 'germ-r2'),
          _notePart(
            part: 'germination',
            revision: 'germ-r2',
            markdown: '# 新观点\n\n从原始内容中生长出的观点。',
          ),
        ]);
        final client = FayaGerminationClient(
          apiClient: _apiClient(transport),
          workspaceId: () => 'workspace-1',
          pollInterval: Duration.zero,
          delay: (_) async {},
        );

        final result = await client.generate(
          const FayaGerminationRequest(
            noteId: 'note-1',
            expectedRawPartRevisionId: 'raw-r1',
            operationId: 'operation-1',
          ),
        );

        expect(result.markdown, '# 新观点\n\n从原始内容中生长出的观点。');
        expect(result.fileAgentRunId, 'faya-run-1');
        expect(result.agentRunId, 'agent-run-1');
        expect(result.agentProfileId, 'faya_germination');
        expect(result.sourcePartRevisionId, 'raw-r1');
        expect(result.germinationPartRevisionId, 'germ-r2');
        expect(transport.requests.map((request) => request.url.path), <String>[
          '/api/v1/workspaces/workspace-1/notes/note-1',
          '/api/v1/workspaces/workspace-1/notes/note-1/parts/raw',
          '/api/v1/workspaces/workspace-1/notes/note-1',
          '/api/v1/workspaces/workspace-1/notes/note-1/file-agent-runs',
          '/api/v1/workspaces/workspace-1/notes/note-1/file-agent-runs/faya-run-1',
          '/api/v1/workspaces/workspace-1/notes/note-1',
          '/api/v1/workspaces/workspace-1/notes/note-1/parts/germination',
        ]);
        expect(
          transport.requests.any(
            (request) => request.url.path.startsWith('/api/v1/chat/'),
          ),
          isFalse,
        );

        final create = transport.requests[3];
        expect(create.method, 'POST');
        expect(
          create.headers['X-Idempotency-Key'],
          'faya-germination-operation-1',
        );
        expect(_body(create), <String, Object?>{
          'input': <String, Object?>{'part': 'raw', 'partRevisionId': 'raw-r1'},
          'target': <String, Object?>{
            'part': 'germination',
            'partRevisionId': 'germ-r1',
          },
          'instruction':
              'Read the source faithfully and grow one genuinely new, '
              'well-supported viewpoint from it. Write the complete '
              'Markdown result to the germination file.',
          'agentProfileId': 'faya_germination',
          'skillProfileIds': <Object?>['viewpoint_germination'],
        });
      },
    );

    test(
      'rejects a stale Raw revision before it starts a File-Agent run',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _noteHead(rawRevisionId: 'raw-r2'),
        ]);
        final client = FayaGerminationClient(
          apiClient: _apiClient(transport),
          workspaceId: () => 'workspace-1',
          delay: (_) async {},
        );

        await expectLater(
          client.generate(
            const FayaGerminationRequest(
              noteId: 'note-1',
              expectedRawPartRevisionId: 'raw-r1',
              operationId: 'operation-1',
            ),
          ),
          throwsA(
            isA<FayaGerminationException>().having(
              (error) => error.code,
              'code',
              'FAYA_SOURCE_REVISION_CHANGED',
            ),
          ),
        );
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single.url.path, endsWith('/notes/note-1'));
      },
    );

    test(
      'stops at a terminal File-Agent conflict without reading a result',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _noteHead(),
          _notePart(part: 'raw', revision: 'raw-r1', markdown: '原始内容保持完整。'),
          _noteHead(),
          _run(status: 'running'),
          _run(status: 'conflict', failureCode: 'NOTE_PART_VERSION_CONFLICT'),
        ]);
        final client = FayaGerminationClient(
          apiClient: _apiClient(transport),
          workspaceId: () => 'workspace-1',
          pollInterval: Duration.zero,
          delay: (_) async {},
        );

        await expectLater(
          client.generate(
            const FayaGerminationRequest(
              noteId: 'note-1',
              expectedRawPartRevisionId: 'raw-r1',
              operationId: 'operation-1',
            ),
          ),
          throwsA(
            isA<FayaGerminationException>().having(
              (error) => error.code,
              'code',
              'FAYA_GERMINATION_CONFLICT',
            ),
          ),
        );
        expect(transport.requests, hasLength(5));
        expect(
          transport.requests.last.url.path,
          endsWith('/file-agent-runs/faya-run-1'),
        );
      },
    );
  });
}

ApiTransportResponse _success(Map<String, Object?> data, {int status = 200}) =>
    ApiTransportResponse(
      status: status,
      body: <String, Object?>{'success': true, 'data': data},
    );

ApiTransportResponse _noteHead({
  String rawRevisionId = 'raw-r1',
  String outlineRevisionId = 'outline-r1',
  String germinationRevisionId = 'germ-r1',
}) => _success(<String, Object?>{
  'noteId': 'note-1',
  'rawPartRevisionId': rawRevisionId,
  'outlinePartRevisionId': outlineRevisionId,
  'germinationPartRevisionId': germinationRevisionId,
});

ApiTransportResponse _notePart({
  required String part,
  required String revision,
  required String markdown,
}) => _success(<String, Object?>{
  'noteId': 'note-1',
  'part': part,
  'partRevisionId': revision,
  'contentMarkdown': markdown,
  'contentSha256': 'sha-$revision',
  'etag': 'etag-$revision',
});

ApiTransportResponse _run({
  required String status,
  String? outputPartRevisionId,
  String? failureCode,
}) => _success(<String, Object?>{
  'fileAgentRun': <String, Object?>{
    'fileAgentRunId': 'faya-run-1',
    'noteId': 'note-1',
    'status': status,
    'input': <String, Object?>{'part': 'raw', 'partRevisionId': 'raw-r1'},
    'target': <String, Object?>{
      'part': 'germination',
      'partRevisionId': 'germ-r1',
    },
    'selector': <String, Object?>{
      'agentProfileId': 'faya_germination',
      'skillProfileIds': <Object?>['viewpoint_germination'],
    },
    'agentRunId': 'agent-run-1',
    if (outputPartRevisionId != null)
      'outputPartRevisionId': outputPartRevisionId,
    if (failureCode != null) 'failure': <String, Object?>{'code': failureCode},
  },
});

ApiClient _apiClient(_QueueTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '0.1.0',
    deviceId: 'device-1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
    traceIdFactory: () => 'trace-faya',
  ),
  transport: transport,
);

Map<String, Object?> _body(ApiTransportRequest request) {
  final body = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return body.cast<String, Object?>();
}

final class _QueueTransport implements ApiTransport {
  _QueueTransport(Iterable<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.of(responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('Unexpected API request');
    return _responses.removeAt(0);
  }
}
