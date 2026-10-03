import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test('parses list, detail, current part, and revision history', () async {
    final transport = _QueueTransport([
      _success(<String, Object?>{
        'items': <Object?>[_creation()],
      }),
      _success(_creation()),
      _success(_part()),
      _success(<String, Object?>{
        'items': <Object?>[_part(revision: 2), _part()],
      }),
    ]);
    final client = CreationClient(_client(transport));

    final page = await client.list('workspace-1');
    final detail = await client.detail('workspace-1', 'creation-1');
    final part = await client.part('workspace-1', 'creation-1', 'raw');
    final revisions = await client.revisions(
      'workspace-1',
      'creation-1',
      'raw',
    );

    expect(page.data?.items.single.title, '第一篇');
    expect(detail.data?.part('raw').currentRevisionId, 'raw-revision-1');
    expect(part.data?.contentMarkdown, '# 初稿');
    expect(revisions.data?.items.map((item) => item.revision), [2, 1]);
    expect(
      transport.requests.first.url.path,
      '/api/v1/workspaces/workspace-1/creations',
    );
  });

  test('writes exact ETags, idempotency keys, and request bodies', () async {
    final transport = _QueueTransport([
      _success(_event()),
      _success(_event(revision: 2)),
      _success(_event(revision: 3)),
      _success(_event(revision: 4)),
      _success(_event(revision: 5, tombstone: true)),
    ]);
    final client = CreationClient(_client(transport));

    await client.create(
      'workspace-1',
      title: ' 第一篇 ',
      rawMarkdown: '# 初稿',
      idempotencyKey: 'create-key',
    );
    await client.rename(
      'workspace-1',
      'creation-1',
      title: '新标题',
      etag: _etag,
      idempotencyKey: 'rename-key',
    );
    await client.putPart(
      'workspace-1',
      'creation-1',
      'raw',
      contentMarkdown: '# 第二稿',
      basePartRevisionId: 'raw-revision-1',
      etag: _etag,
      idempotencyKey: 'part-key',
    );
    await client.restore(
      'workspace-1',
      'creation-1',
      etag: _etag,
      idempotencyKey: 'restore-key',
    );
    final deleted = await client.delete(
      'workspace-1',
      'creation-1',
      etag: _etag,
      idempotencyKey: 'delete-key',
    );

    expect(deleted.data, isTrue);
    expect(
      transport.requests.map((request) => request.headers['X-Idempotency-Key']),
      ['create-key', 'rename-key', 'part-key', 'restore-key', 'delete-key'],
    );
    expect(transport.requests[0].headers.containsKey('If-Match'), isFalse);
    for (final request in transport.requests.skip(1)) {
      expect(request.headers['If-Match'], _etag);
    }
    expect(jsonDecode(transport.requests[0].body!), <String, Object?>{
      'title': '第一篇',
      'parts': <String, Object?>{
        'raw': '# 初稿',
        'outline': '',
        'germination': '',
      },
      'sourceRefs': <Object?>[],
      'resourceRefs': <Object?>[],
    });
    expect(jsonDecode(transport.requests[2].body!), <String, Object?>{
      'contentMarkdown': '# 第二稿',
      'basePartRevisionId': 'raw-revision-1',
      'sourceRefs': <Object?>[],
      'resourceRefs': <Object?>[],
    });
  });

  test('rejects malformed identities and unknown response fields', () async {
    final wrongIdentity = _creation()..['creationId'] = 'creation-2';
    final unknownField = _part()..['privateObjectKey'] = 'must-not-escape';
    final client = CreationClient(
      _client(
        _QueueTransport([_success(wrongIdentity), _success(unknownField)]),
      ),
    );

    expect(
      (await client.detail('workspace-1', 'creation-1')).error?.code,
      'API_RESPONSE_INVALID',
    );
    expect(
      (await client.part('workspace-1', 'creation-1', 'raw')).error?.code,
      'API_RESPONSE_INVALID',
    );
    expect(
      () => client.detail('workspace-1', '../unsafe'),
      throwsArgumentError,
    );
    expect(
      () => client.part('workspace-1', 'creation-1', 'preview'),
      throwsFormatException,
    );
  });
}

const _etag =
    '"wcc-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"';

Map<String, Object?> _creation() => <String, Object?>{
  'creationId': 'creation-1',
  'title': '第一篇',
  'lifecycle': 'active',
  'revisionId': 'creation-revision-1',
  'revision': 1,
  'parts': <Object?>[
    _partHead('raw'),
    _partHead('outline'),
    _partHead('germination'),
  ],
  'resourceRefs': <Object?>[],
  'etag': _etag,
};

Map<String, Object?> _partHead(String part) => <String, Object?>{
  'part': part,
  'currentRevisionId': '$part-revision-1',
  'revision': 1,
  'status': 'current',
};

Map<String, Object?> _part({int revision = 1}) => <String, Object?>{
  'part': 'raw',
  'partRevisionId': 'raw-revision-$revision',
  'revision': revision,
  if (revision > 1) 'previousPartRevisionId': 'raw-revision-${revision - 1}',
  'contentMarkdown': revision == 1 ? '# 初稿' : '# 第 $revision 稿',
  'contentHash':
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'sizeBytes': 8,
  'sourceRefs': <Object?>[],
  'createdAt': '2026-09-03T03:00:00Z',
  'etag': _etag,
};

Map<String, Object?> _event({
  int revision = 1,
  bool tombstone = false,
}) => <String, Object?>{
  'eventId': 'event-$revision',
  'workspaceId': 'workspace-1',
  'cursor': '$revision',
  'operationId': 'operation-$revision',
  'occurredAt': '2026-09-03T03:00:00Z',
  'objectKind': 'creation',
  'objectId': 'creation-1',
  'changeType': 'revision_changed',
  'revisionId': 'creation-revision-$revision',
  if (revision > 1) 'previousRevisionId': 'creation-revision-${revision - 1}',
  'tombstone': tombstone,
  'resourcePinDelta': <String, Object?>{
    'added': <Object?>[],
    'released': <Object?>[],
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

ApiTransportResponse _success(Object data) => ApiTransportResponse(
  status: 200,
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
