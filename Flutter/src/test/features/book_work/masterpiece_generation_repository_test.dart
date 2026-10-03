import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/book_work/data/masterpiece_generation_repository.dart';
import 'package:huahuoai_app/features/book_work/domain/masterpiece_generation.dart';
import 'package:huahuoai_app/features/book_work/domain/masterpiece_state.dart';

void main() {
  test(
    'complete snapshot counts only unique live HNotes across pages',
    () async {
      final transport = _Transport([
        _page([
          _head('note-1'),
          _head('internal', kind: 'book_section'),
        ], next: 'page-2'),
        _page([
          _head('note-1'),
          _head('deleted', deleted: true),
          _head('note-2'),
        ]),
      ]);
      final result = await _repository(transport).eligibility();
      expect(result.count, 2);
      expect(result.notes.map((head) => head.noteId), ['note-1', 'note-2']);
      expect(
        transport.requests.last.url.queryParameters['pageToken'],
        'page-2',
      );
    },
  );

  test(
    'inconsistent snapshots fail closed rather than unlock on partial count',
    () async {
      final transport = _Transport([
        _page([_head('note-1')], next: 'page-2'),
        {
          ..._page([_head('note-2')]),
          'snapshotId': 'different',
        },
      ]);
      await expectLater(
        _repository(transport).eligibility(),
        throwsA(isA<MasterpieceRemoteException>()),
      );
    },
  );

  test(
    'catalog selection and Note preparation use exact snapshot revision',
    () async {
      final transport = _Transport([
        {
          'catalogVersion': 'v1',
          'items': [
            {'agentProfileId': 'book_writing', 'displayName': 'Book writing'},
          ],
        },
        {
          'noteId': 'note-1',
          'workspaceId': 'workspace-1',
          'folderId': null,
          'title': '我的笔记',
          'state': 'active',
          'noteRevisionId': 'note-revision-1',
          'rawPartRevisionId': 'raw-revision-1',
          'resourceRefs': <Object?>[],
          'etag': '"note-1"',
          'contentCursor': '1',
        },
      ]);
      final preparation = await _repository(transport).prepare(
        MasterpieceEligibility([
          const MasterpieceSourceHead('note-1', 'note-revision-1'),
        ]),
      );
      expect(preparation.profileId, 'book_writing');
      expect(preparation.sources.single.partRevisionId, 'raw-revision-1');
      expect(
        transport.requests.last.url.queryParameters['revisionId'],
        'note-revision-1',
      );
    },
  );

  test(
    'generation and publication use real API19/API24 contracts and retained sources',
    () async {
      final transport = _Transport([
        {
          'agentRunId': 'run-1',
          'workspaceId': 'workspace-1',
          'status': 'queued',
          'workspaceVersion': 1,
          'workspaceBindingVersion': 1,
          'contextGeneration': 1,
          'usage': {
            'measurementStatus': 'pending',
            'inputTokens': null,
            'outputTokens': null,
            'imageCount': null,
            'videoSeconds': null,
            'accountedCredits': null,
            'policyVersion': null,
          },
          'toolTrace': <Object?>[],
          'createdAt': '2026-09-05T00:00:00Z',
          'updatedAt': '2026-09-05T00:00:00Z',
        },
        {
          'eventId': 'event-1',
          'workspaceId': 'workspace-1',
          'cursor': '2',
          'operationId': 'operation-1',
          'occurredAt': '2026-09-05T00:00:00Z',
          'objectKind': 'book_section',
          'objectId': 'opaque-section-id',
          'changeType': 'created',
          'version': 1,
          'tombstone': false,
          'resourcePinDelta': {'added': <Object?>[], 'released': <Object?>[]},
        },
      ]);
      final repository = _repository(transport);
      final intent = MasterpieceGenerationIntent(
        bookId: 'book-1',
        baseBookRevisionId: 'book-revision-1',
        profileId: 'book_writing',
        instruction: '生成代表作正文',
        sources: [
          SharedNotePartSourceRef(
            noteId: 'note-1',
            part: 'raw',
            partRevisionId: 'raw-revision-1',
          ),
        ],
        sectionKey: 'masterpiece-initial',
        title: '代表作 · 初稿',
        requestKey: 'frozen-key',
        initial: true,
      );
      await repository.create(intent);
      final request = transport.requests.first;
      expect(request.url.path, '/api/v1/agent/runs');
      expect(request.headers['X-Idempotency-Key'], 'frozen-key');
      final body = jsonDecode(request.body!) as Map;
      expect(body.keys.toSet(), {'workspaceId', 'agentProfileId', 'input'});
      expect(body['agentProfileId'], 'book_writing');
      expect(
        (body['input']['content'] as List).last['source']['partRevisionId'],
        'raw-revision-1',
      );
      await repository.publish(
        intent.copyWith(
          runId: 'run-1',
          markdown: '正式候选正文',
          stage: MasterpieceGenerationStage.publishing,
        ),
      );
      final publish = transport.requests.last;
      expect(publish.url.path, '/api/v1/workspaces/workspace-1/book/sections');
      expect(publish.headers['X-Idempotency-Key'], 'frozen-key-publish');
      final publication = jsonDecode(publish.body!) as Map;
      expect(publication['parts']['raw'], '正式候选正文');
      expect(publication['sourceRefs'].single['kind'], 'note_part');
      expect(
        publication['sourceRefs'].single['partRevisionId'],
        'raw-revision-1',
      );
    },
  );
}

RemoteMasterpieceGenerationRepository _repository(ApiTransport transport) =>
    RemoteMasterpieceGenerationRepository(
      ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: '0.1.0',
          deviceId: 'test',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () => 'token',
        ),
        transport: transport,
      ),
      'workspace-1',
    );

Map<String, Object?> _page(
  List<Map<String, Object?>> objects, {
  String? next,
}) => {
  'snapshotId': 'snapshot-1',
  'atCursor': '10',
  'folders': <Object?>[],
  'objects': objects,
  'hasMore': next != null,
  'nextPageToken': next,
};

Map<String, Object?> _head(
  String id, {
  String kind = 'hnote',
  bool deleted = false,
}) => {
  'ownerRef': {'workspaceId': 'workspace-1', 'kind': kind, 'id': id},
  'revisionId': 'revision-$id',
  'tombstone': deleted,
  'etag': '"$id"',
  'resourceRefs': <Object?>[],
};

final class _Transport implements ApiTransport {
  _Transport(this.responses);
  final List<Object> responses;
  final requests = <ApiTransportRequest>[];
  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    final payload = responses[requests.length - 1];
    final creatingRun = request.url.path == '/api/v1/agent/runs';
    return ApiTransportResponse(
      status: creatingRun ? 202 : 200,
      body: {
        'success': true,
        'data': creatingRun
            ? {
                'run': payload,
                'nextAction': {
                  'type': 'poll_agent_run',
                  'agentRunId': (payload as Map)['agentRunId'],
                  'afterSequence': 0,
                },
              }
            : payload,
      },
    );
  }
}
