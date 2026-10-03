import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart'
    hide documentProposalAgentProfileId, documentProposalSkillProfileIds;
import 'package:huahuoai_app/features/ui_v3/data/document_change_proposal_api.dart';

void main() {
  group('RemoteDocumentChangeProposalApi', () {
    test(
      'creates an exact raw HNote proposal and retains its strong ETag',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _proposalResponse(state: 'generating', etag: '"dcp:dcp-1:1"'),
        ]);
        final api = RemoteDocumentChangeProposalApi(
          apiClient: _client(transport),
          workspaceId: () => 'workspace-1',
        );

        final snapshot = await api.create(
          const DocumentProposalCreateRequest(
            noteId: 'note-1',
            rawPartRevisionId: 'raw-revision-1',
            instruction: '请扩写并保留全部事实。',
            idempotencyKey: 'create-key-1',
          ),
        );

        expect(snapshot.proposal.proposalId, 'dcp-1');
        expect(snapshot.etag, '"dcp:dcp-1:1"');
        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/api/v1/workspaces/workspace-1/document-change-proposals',
        );
        expect(request.headers['X-Idempotency-Key'], 'create-key-1');
        final body = jsonDecode(request.body!) as Map<String, Object?>;
        expect(body, <String, Object?>{
          'target': <String, Object?>{
            'ownerRef': <String, Object?>{'kind': 'hnote', 'id': 'note-1'},
            'part': 'raw',
            'partRevisionId': 'raw-revision-1',
          },
          'instruction': '请扩写并保留全部事实。',
          'agentProfileId': documentProposalAgentProfileId,
          'skillProfileIds': documentProposalSkillProfileIds,
        });
      },
    );

    test(
      'reads review data and sends explicit apply or reject preconditions',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          ApiTransportResponse(
            status: 200,
            body: _success(<String, Object?>{
              'schema': 'huahuo.document-diff.v1',
              'proposalId': 'dcp-1',
              'proposalVersion': 1,
              'base': const <String, Object?>{},
              'candidate': const <String, Object?>{},
              'algorithm': const <String, Object?>{
                'name': 'line-myers-intraline',
                'version': '1.0.0',
                'granularity': 'line+character',
                'fallbackUsed': false,
              },
              'summary': const <String, Object?>{
                'hunks': 1,
                'insertedLines': 1,
                'deletedLines': 1,
                'changedLines': 1,
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
                    const <String, Object?>{'op': 'delete', 'text': '旧句\n'},
                    const <String, Object?>{'op': 'insert', 'text': '新句\n'},
                  ],
                },
              ],
            }),
          ),
          ApiTransportResponse(
            status: 200,
            body: _success(const <String, Object?>{
              'schema': 'huahuo.document-candidate-chunk.v1',
              'proposalId': 'dcp-1',
              'proposalVersion': 1,
              'candidateHash':
                  'sha256:b0f7fc7a56e441ad3f2e70be0cbc65343512ec50b19e6c3b6f341ac1346cf14a',
              'offsetBytes': 0,
              'text': '新句\n',
            }),
          ),
          _proposalResponse(
            state: 'applied',
            etag: '"dcp:dcp-1:2"',
            applied: true,
          ),
          _proposalResponse(state: 'rejected', etag: '"dcp:dcp-1:3"'),
        ]);
        final api = RemoteDocumentChangeProposalApi(
          apiClient: _client(transport),
          workspaceId: () => 'workspace-1',
        );

        final diff = await api.getDiff(proposalId: 'dcp-1');
        final candidate = await api.getCandidate(proposalId: 'dcp-1');
        final applied = await api.apply(
          proposalId: 'dcp-1',
          etag: '"dcp:dcp-1:1"',
          idempotencyKey: 'apply-key-1',
        );
        final rejected = await api.reject(
          proposalId: 'dcp-1',
          etag: '"dcp:dcp-1:2"',
          idempotencyKey: 'reject-key-1',
        );

        expect(diff.items.single.changes.map((item) => item.op), <String>[
          'delete',
          'insert',
        ]);
        expect(candidate.text, '新句\n');
        expect(applied.proposal.appliedPartRevisionId, 'raw-revision-2');
        expect(rejected.proposal.state, DocumentProposalState.rejected);
        final applyRequest = transport.requests[2];
        expect(applyRequest.headers['If-Match'], '"dcp:dcp-1:1"');
        expect(applyRequest.headers['X-Idempotency-Key'], 'apply-key-1');
        expect(applyRequest.body, isNull);
        final rejectRequest = transport.requests[3];
        expect(rejectRequest.headers['If-Match'], '"dcp:dcp-1:2"');
        expect(jsonDecode(rejectRequest.body!), <String, Object?>{
          'reasonCode': 'user_declined',
        });
      },
    );

    test('fails closed when a proposal response has no strong ETag', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _proposalResponse(state: 'generating'),
      ]);
      final api = RemoteDocumentChangeProposalApi(
        apiClient: _client(transport),
        workspaceId: () => 'workspace-1',
      );

      await expectLater(
        api.create(
          const DocumentProposalCreateRequest(
            noteId: 'note-1',
            rawPartRevisionId: 'raw-revision-1',
            instruction: '改写。',
            idempotencyKey: 'create-key-1',
          ),
        ),
        throwsA(
          isA<DocumentChangeProposalException>().having(
            (error) => error.code,
            'code',
            'DOCUMENT_PROPOSAL_ETAG_MISSING',
          ),
        ),
      );
    });
  });
}

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-1',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: () async => 'access-token',
  ),
  transport: transport,
);

ApiTransportResponse _proposalResponse({
  required String state,
  String? etag,
  bool applied = false,
}) => ApiTransportResponse(
  status: state == 'generating' ? 202 : 200,
  headers: etag == null
      ? const <String, String>{}
      : <String, String>{'etag': etag},
  body: _success(<String, Object?>{
    'proposalId': 'dcp-1',
    'proposalVersion': 1,
    'rowVersion': state == 'applied'
        ? 2
        : state == 'rejected'
        ? 3
        : 1,
    'state': state,
    'target': const <String, Object?>{
      'ownerRef': <String, Object?>{'kind': 'hnote', 'id': 'note-1'},
      'part': 'raw',
      'basePartRevisionId': 'raw-revision-1',
      'baseHash': 'sha256:base',
    },
    'run': const <String, Object?>{'bindingState': 'pending'},
    'candidateAvailable': state != 'generating',
    'hasChanges': state == 'generating' ? null : true,
    if (applied)
      'applied': const <String, Object?>{
        'ownerRevisionId': 'owner-revision-2',
        'partRevisionId': 'raw-revision-2',
        'hash': 'sha256:candidate',
      },
  }),
);

Map<String, Object?> _success(Map<String, Object?> data) => <String, Object?>{
  'success': true,
  'data': data,
};

final class _QueueTransport implements ApiTransport {
  _QueueTransport(Iterable<ApiTransportResponse> responses)
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
