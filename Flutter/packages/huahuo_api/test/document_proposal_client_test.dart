import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test('lists by owner and creates with a preserved 202 snapshot', () async {
    final transport = _QueueTransport([
      _success(<String, Object?>{
        'items': <Object?>[_proposal()],
        'nextCursor': 'page-2',
      }),
      _snapshot(_proposal(state: 'generating'), status: 202),
    ]);
    final client = DocumentProposalClient(_client(transport));

    final page = await client.list(
      'workspace-1',
      ownerKind: 'creation',
      ownerId: 'creation-1',
      state: 'ready',
    );
    final created = await client.createForCreation(
      'workspace-1',
      creationId: 'creation-1',
      rawPartRevisionId: 'part-revision-1',
      instruction: ' 优化结构和表达 ',
      idempotencyKey: 'proposal-create-1',
      threadId: 'thread-1',
    );

    expect(page.data?.items.single.proposalId, 'proposal-1');
    expect(page.data?.nextCursor, 'page-2');
    expect(created.status, 202);
    expect(created.data?.etag, _etag(1));
    expect(transport.requests.first.url.queryParameters, <String, String>{
      'ownerKind': 'creation',
      'ownerId': 'creation-1',
      'state': 'ready',
      'limit': '50',
    });
    final create = transport.requests[1];
    expect(
      create.url.path,
      '/api/v1/workspaces/workspace-1/document-change-proposals',
    );
    expect(create.headers['X-Idempotency-Key'], 'proposal-create-1');
    expect(jsonDecode(create.body!), <String, Object?>{
      'target': <String, Object?>{
        'ownerRef': <String, Object?>{'kind': 'creation', 'id': 'creation-1'},
        'part': 'raw',
        'partRevisionId': 'part-revision-1',
      },
      'instruction': '优化结构和表达',
      'agentProfileId': 'self_media_creation',
      'skillProfileIds': <Object?>['self_media_creation_advisor'],
      'threadId': 'thread-1',
    });
  });

  test('parses current and immutable version review resources', () async {
    final transport = _QueueTransport([
      _success(_diff(nextCursor: 'diff-next')),
      _success(_candidate(nextCursor: 'candidate-next')),
      _success(<String, Object?>{
        'items': <Object?>[_version()],
      }),
      _success(_diff(version: 2)),
      _success(_candidate(version: 2)),
    ]);
    final client = DocumentProposalClient(_client(transport));

    final diff = await client.diff('workspace-1', 'proposal-1');
    final candidate = await client.candidate('workspace-1', 'proposal-1');
    final versions = await client.versions('workspace-1', 'proposal-1');
    final oldDiff = await client.diff(
      'workspace-1',
      'proposal-1',
      proposalVersion: 2,
    );
    final oldCandidate = await client.candidate(
      'workspace-1',
      'proposal-1',
      proposalVersion: 2,
    );

    expect(diff.data?.summary.changedLines, 2);
    expect(diff.data?.items.single.changes.last.operation, 'insert');
    expect(candidate.data?.text, '# 优化后的正文');
    expect(candidate.data?.offsetBytes, 0);
    expect(versions.data?.single.diffBundleId, 'bundle-1');
    expect(oldDiff.data?.proposalVersion, 2);
    expect(oldCandidate.data?.proposalVersion, 2);
    expect(
      transport.requests[3].url.path,
      '/api/v1/workspaces/workspace-1/document-change-proposals/proposal-1/versions/2/diff',
    );
  });

  test(
    'writes mutation preconditions, idempotency, and exact bodies',
    () async {
      final transport = _QueueTransport([
        _snapshot(_proposal(state: 'applying', rowVersion: 2), status: 202),
        _snapshot(_proposal(state: 'rejected', rowVersion: 2)),
        _snapshot(_proposal(state: 'rejected', rowVersion: 2)),
        _snapshot(_proposal(state: 'stale', rowVersion: 2)),
        _snapshot(_proposal(state: 'generating', rowVersion: 2), status: 202),
      ]);
      final client = DocumentProposalClient(_client(transport));

      await client.apply(
        'workspace-1',
        'proposal-1',
        etag: _etag(1),
        idempotencyKey: 'apply-1',
      );
      await client.reject(
        'workspace-1',
        'proposal-1',
        etag: _etag(1),
        idempotencyKey: 'reject-1',
      );
      await client.cancel(
        'workspace-1',
        'proposal-1',
        etag: _etag(1),
        idempotencyKey: 'cancel-1',
      );
      await client.rebase(
        'workspace-1',
        'proposal-1',
        etag: _etag(1),
        idempotencyKey: 'rebase-1',
      );
      final revised = await client.revise(
        'workspace-1',
        'proposal-1',
        baseProposalVersion: 1,
        instruction: '仅调整第一段',
        etag: _etag(1),
        idempotencyKey: 'revise-1',
        selectedHunks: const [
          (diffBundleId: 'bundle-1', hunkId: 'hunk-1', quotedText: '旧正文'),
        ],
      );

      expect(revised.status, 202);
      expect(
        transport.requests.map((request) => request.headers['If-Match']),
        List<String>.filled(5, _etag(1)),
      );
      expect(
        transport.requests.map(
          (request) => request.headers['X-Idempotency-Key'],
        ),
        <String>['apply-1', 'reject-1', 'cancel-1', 'rebase-1', 'revise-1'],
      );
      expect(transport.requests[0].body, isNull);
      expect(jsonDecode(transport.requests[1].body!), <String, Object?>{
        'reasonCode': 'user_declined',
      });
      expect(transport.requests[2].body, isNull);
      expect(jsonDecode(transport.requests[3].body!), <String, Object?>{
        'strategy': 'auto',
      });
      expect(jsonDecode(transport.requests[4].body!), <String, Object?>{
        'baseProposalVersion': 1,
        'instruction': '仅调整第一段',
        'selectedHunks': <Object?>[
          <String, Object?>{
            'proposalVersion': 1,
            'diffBundleId': 'bundle-1',
            'hunkId': 'hunk-1',
            'quotedText': '旧正文',
          },
        ],
        'agentProfileId': 'self_media_creation',
        'skillProfileIds': <Object?>['self_media_creation_advisor'],
      });
    },
  );

  test('rejects identity, version-link, and ETag contract drift', () async {
    final wrongIdentity = _proposal()..['proposalId'] = 'proposal-2';
    final version = _version();
    (version['links']! as Map<String, Object?>)['privateObjectKey'] = 'hidden';
    final transport = _QueueTransport([
      _snapshot(wrongIdentity),
      _success(<String, Object?>{
        'items': <Object?>[version],
      }),
      _snapshot(_proposal(), etag: _etag(2)),
    ]);
    final client = DocumentProposalClient(_client(transport));

    expect(
      (await client.detail('workspace-1', 'proposal-1')).error?.code,
      'API_RESPONSE_INVALID',
    );
    expect(
      (await client.versions('workspace-1', 'proposal-1')).error?.code,
      'API_RESPONSE_INVALID',
    );
    expect(
      (await client.detail('workspace-1', 'proposal-1')).error?.code,
      'DOCUMENT_PROPOSAL_ETAG_INVALID',
    );
    expect(
      () => client.detail('workspace-1', '../unsafe'),
      throwsArgumentError,
    );
    expect(
      () => client.apply(
        'workspace-1',
        'proposal-1',
        etag: 'W/${_etag(1)}',
        idempotencyKey: 'apply-1',
      ),
      throwsFormatException,
    );
  });
}

const _hashA =
    'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hashB =
    'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

String _etag(int rowVersion) => '"dcp:proposal-1:$rowVersion"';

Map<String, Object?> _proposal({
  String state = 'ready',
  int rowVersion = 1,
}) => <String, Object?>{
  'proposalId': 'proposal-1',
  'proposalVersion': 1,
  'rowVersion': rowVersion,
  'state': state,
  'generationStage': state == 'generating' ? 'queued' : 'completed',
  'target': <String, Object?>{
    'ownerRef': <String, Object?>{'kind': 'creation', 'id': 'creation-1'},
    'part': 'raw',
    'basePartRevisionId': 'part-revision-1',
    'baseHash': _hashA,
  },
  'run': <String, Object?>{
    'bindingState': 'bound',
    'runId': 'run-1',
    'state': state == 'generating' ? 'queued' : 'succeeded',
  },
  'candidateAvailable': state != 'generating',
  'hasChanges': state == 'generating' ? null : true,
  'links': <String, Object?>{
    'self':
        '/api/v1/workspaces/workspace-1/document-change-proposals/proposal-1',
    'runEvents': '/api/v1/agent/runs/run-1/events/stream',
    if (state != 'generating') 'diff': '/diff',
    if (state != 'generating') 'candidate': '/candidate',
  },
  'createdAt': '2026-09-03T03:00:00Z',
  'updatedAt': '2026-09-03T03:01:00Z',
};

Map<String, Object?> _diff({int version = 1, String? nextCursor}) =>
    <String, Object?>{
      'schema': 'huahuo.document-diff.v1',
      'proposalId': 'proposal-1',
      'proposalVersion': version,
      'base': <String, Object?>{
        'partRevisionId': 'part-revision-1',
        'hash': _hashA,
      },
      'candidate': <String, Object?>{'hash': _hashB, 'sizeBytes': 24},
      'algorithm': <String, Object?>{
        'name': 'myers',
        'version': '1',
        'granularity': 'line',
        'fallbackUsed': false,
      },
      'summary': <String, Object?>{
        'hunks': 1,
        'insertedLines': 1,
        'deletedLines': 1,
        'changedLines': 2,
        'hasChanges': true,
      },
      'items': <Object?>[
        <String, Object?>{
          'hunkId': 'hunk-1',
          'oldStart': 1,
          'oldLines': 1,
          'newStart': 1,
          'newLines': 1,
          'changes': <Object?>[
            <String, Object?>{'op': 'delete', 'text': '旧正文'},
            <String, Object?>{'op': 'insert', 'text': '新正文'},
          ],
        },
      ],
      if (nextCursor != null) 'nextCursor': nextCursor,
    };

Map<String, Object?> _candidate({int version = 1, String? nextCursor}) =>
    <String, Object?>{
      'schema': 'huahuo.document-candidate-chunk.v1',
      'proposalId': 'proposal-1',
      'proposalVersion': version,
      'candidateHash': _hashB,
      'offsetBytes': 0,
      'text': '# 优化后的正文',
      if (nextCursor != null) 'nextCursor': nextCursor,
    };

Map<String, Object?> _version() => <String, Object?>{
  'proposalId': 'proposal-1',
  'proposalVersion': 1,
  'baseHash': _hashA,
  'candidateHash': _hashB,
  'candidateSizeBytes': 24,
  'diffBundleId': 'bundle-1',
  'agentRunId': 'run-1',
  'createdAt': '2026-09-03T03:01:00Z',
  'links': <String, Object?>{
    'self': '/versions/1',
    'runEvents': '/events',
    'diff': '/versions/1/diff',
    'candidate': '/versions/1/candidate',
  },
};

ApiClient _client(ApiTransport transport) => ApiClientFactory.create(
  baseUrl: Uri.parse('https://api.example.test'),
  runtime: const ApiClientRuntime(
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'macos',
    locale: 'zh-CN',
    timeZone: 'Asia/Shanghai',
  ),
  transport: transport,
  getAccessToken: () => 'access',
);

ApiTransportResponse _success(Object data, {int status = 200}) =>
    ApiTransportResponse(
      status: status,
      body: <String, Object?>{'success': true, 'data': data},
    );

ApiTransportResponse _snapshot(Object data, {int status = 200, String? etag}) =>
    ApiTransportResponse(
      status: status,
      headers: <String, String>{'etag': etag ?? _etag(1)},
      body: <String, Object?>{'success': true, 'data': data},
    );

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this.responses);

  final List<ApiTransportResponse> responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}
