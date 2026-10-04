import 'dart:async';
import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/workspace_search_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  test(
    'keyword search normalizes metadata and never sends local content',
    () async {
      final port = _QueueSearchPort(<Future<MobileWorkspaceSearchResult>>[
        Future<MobileWorkspaceSearchResult>.value(
          MobileWorkspaceSearchResult.success(<V3FeedItem>[
            _searchNote('note-1', '# exact remote body'),
          ], contentCursor: '42'),
        ),
      ]);
      final controller = WorkspaceSearchController(
        port: port,
        debounce: Duration.zero,
      );

      await controller.searchNow('  客户   复盘  ');

      expect(port.queries, <String>['客户 复盘']);
      expect(port.limits, <int>[30]);
      expect(controller.status, MobileWorkspaceSearchStatus.success);
      expect(controller.results.single.rawBody, '# exact remote body');
      expect(controller.contentCursor, '42');
    },
  );

  test('newer query wins when an older response completes last', () async {
    final first = Completer<MobileWorkspaceSearchResult>();
    final second = Completer<MobileWorkspaceSearchResult>();
    final port = _QueueSearchPort(<Future<MobileWorkspaceSearchResult>>[
      first.future,
      second.future,
    ]);
    final controller = WorkspaceSearchController(
      port: port,
      debounce: Duration.zero,
    );

    final firstSearch = controller.searchNow('旧查询');
    final secondSearch = controller.searchNow('新查询');
    second.complete(
      MobileWorkspaceSearchResult.success(<V3FeedItem>[
        _searchNote('new-note', 'new'),
      ], contentCursor: '2'),
    );
    await secondSearch;
    first.complete(
      MobileWorkspaceSearchResult.success(<V3FeedItem>[
        _searchNote('old-note', 'old'),
      ], contentCursor: '1'),
    );
    await firstSearch;

    expect(controller.query, '新查询');
    expect(controller.results.single.id, 'new-note');
    expect(controller.contentCursor, '2');
  });

  test(
    'debounce collapses rapid input and errors never expose stale results',
    () async {
      final port = _QueueSearchPort(<Future<MobileWorkspaceSearchResult>>[
        Future<MobileWorkspaceSearchResult>.value(
          const MobileWorkspaceSearchResult.failure(
            'WORKSPACE_KEYWORD_SEARCH_UNAVAILABLE',
          ),
        ),
      ]);
      final controller = WorkspaceSearchController(
        port: port,
        debounce: const Duration(milliseconds: 20),
      );

      controller
        ..setQuery('第一个')
        ..setQuery('第二个')
        ..setQuery('最终查询');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(port.queries, <String>['最终查询']);
      expect(controller.results, isEmpty);
      expect(controller.status, MobileWorkspaceSearchStatus.failure);
      expect(controller.errorCode, 'WORKSPACE_KEYWORD_SEARCH_UNAVAILABLE');
    },
  );

  test('demo mode retains the existing local search without network calls', () {
    final controller = WorkspaceSearchController(
      port: const DemoMobileWorkspaceSearchPort(),
    );

    controller.setQuery('本地演示');

    expect(controller.status, MobileWorkspaceSearchStatus.demo);
    expect(controller.results, isEmpty);
  });

  test(
    'remote identity merges into the existing local ID exactly once',
    () async {
      final local = _searchNote('local-note-id', 'pending-local').copyWith(
        remoteNoteId: 'remote-note-id',
        remoteRevision: 5,
        syncState: NoteSyncState.synced,
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[local],
      );
      final remote = _searchNote(
        'remote-note-id',
        'remote-body',
      ).copyWith(remoteRevision: 0);
      final port = _QueueSearchPort(<Future<MobileWorkspaceSearchResult>>[
        Future<MobileWorkspaceSearchResult>.value(
          MobileWorkspaceSearchResult.success(<V3FeedItem>[
            remote,
          ], contentCursor: '8'),
        ),
      ]);
      final controller = WorkspaceSearchController(
        port: port,
        library: library,
        debounce: Duration.zero,
      );

      await controller.searchNow('精确结果');

      expect(controller.results.single.id, 'local-note-id');
      expect(library.noteForId('local-note-id')?.rawBody, 'remote-body');
      expect(library.noteForId('local-note-id')?.remoteRevision, 5);
      expect(library.noteForId('remote-note-id'), isNull);
      expect(
        library.notes.where((note) => note.remoteNoteId == 'remote-note-id'),
        hasLength(1),
      );
    },
  );

  test(
    'remote Search sends safe keyword metadata then reads exact HNote',
    () async {
      final transport = _SearchTransport(<ApiTransportResponse>[
        _searchResponse(),
        _searchExactHNoteResponse(sparse: true),
        _searchPartResponse(
          part: 'raw',
          revisionId: 'raw-part-revision-9',
          markdown: '# 精确正文',
          contentHash: 'raw-hash',
        ),
        _searchPartResponse(
          part: 'outline',
          revisionId: 'outline-revision-1',
          markdown: '## 精确纲要',
          contentHash: 'outline-hash',
        ),
        _searchPartResponse(
          part: 'germination',
          revisionId: 'germination-revision-1',
          markdown: '精确发芽',
          contentHash: 'germination-hash',
        ),
      ]);
      final port = RemoteMobileWorkspaceSearchPort(
        apiClient: _searchApiClient(transport),
        workspaceId: () => 'workspace opaque/+1',
      );

      final result = await port.searchKeyword(query: '客户复盘', limit: 30);

      expect(result.status, MobileWorkspaceSearchResultStatus.success);
      expect(result.notes.single.rawBody, '# 精确正文');
      expect(result.notes.single.summaryBody, '## 精确纲要');
      expect(result.notes.single.sproutReport?.markdown, '精确发芽');
      expect(transport.requests, hasLength(5));
      final search = transport.requests.first;
      expect(search.method, 'POST');
      expect(search.url.path, contains('/search'));
      final body = jsonDecode(search.body!) as Map<String, dynamic>;
      expect(body, <String, dynamic>{
        'query': '客户复盘',
        'mode': 'keyword',
        'ownerKinds': <dynamic>['hnote'],
        'noteParts': <dynamic>['raw'],
        'limit': 30,
      });
      expect(search.headers.containsKey('Idempotency-Key'), isFalse);
      expect(search.headers.containsKey('X-Idempotency-Key'), isFalse);
      expect(search.body, isNot(contains('local/path')));
      expect(
        transport.requests[1].url.queryParameters['partRevisionId'],
        isNull,
      );
      expect(
        transport.requests[1].url.queryParameters['revisionId'],
        'note-revision-1',
      );
      expect(transport.requests[1].url.path, isNot(contains('/parts/')));
      expect(
        transport.requests
            .skip(2)
            .map((request) => request.url.path.split('/').last),
        unorderedEquals(<String>['raw', 'outline', 'germination']),
      );
      expect(result.notes.single.noteRevisionId, 'note-revision-1');
      expect(result.notes.single.rawPartRevisionId, 'raw-part-revision-9');
      expect(result.notes.single.etag, '"note-current"');
    },
  );

  test(
    'remote Search rejects owner workspace and exact revision mismatch',
    () async {
      final ownerMismatch = _SearchTransport(<ApiTransportResponse>[
        _searchResponse(ownerWorkspaceId: 'other-workspace'),
      ]);
      final ownerPort = RemoteMobileWorkspaceSearchPort(
        apiClient: _searchApiClient(ownerMismatch),
        workspaceId: () => 'workspace opaque/+1',
      );
      final ownerResult = await ownerPort.searchKeyword(query: '查询', limit: 30);
      expect(ownerResult.errorCode, 'WORKSPACE_SEARCH_OWNER_INVALID');
      expect(ownerMismatch.requests, hasLength(1));

      final revisionMismatch = _SearchTransport(<ApiTransportResponse>[
        _searchResponse(),
        _searchExactHNoteResponse(noteRevisionId: 'unexpected-revision'),
      ]);
      final revisionPort = RemoteMobileWorkspaceSearchPort(
        apiClient: _searchApiClient(revisionMismatch),
        workspaceId: () => 'workspace opaque/+1',
      );
      final revisionResult = await revisionPort.searchKeyword(
        query: '查询',
        limit: 30,
      );
      expect(revisionResult.errorCode, 'WORKSPACE_SEARCH_REVISION_MISMATCH');
    },
  );
}

V3FeedItem _searchNote(String id, String body) {
  return V3FeedItem(
    id: id,
    title: '搜索结果 $id',
    source: V3MaterialSource.note,
    createdAt: DateTime.utc(2026, 8, 7),
    rawBody: body,
    remoteNoteId: id,
    noteRevisionId: 'revision-$id',
    rawPartRevisionId: 'raw-$id',
    etag: '"$id"',
    contentCursor: '42',
    syncState: NoteSyncState.synced,
  );
}

final class _QueueSearchPort implements MobileWorkspaceSearchPort {
  _QueueSearchPort(this.responses);

  final List<Future<MobileWorkspaceSearchResult>> responses;
  final List<String> queries = <String>[];
  final List<int> limits = <int>[];

  @override
  bool get isDemo => false;

  @override
  Future<MobileWorkspaceSearchResult> searchKeyword({
    required String query,
    required int limit,
  }) {
    queries.add(query);
    limits.add(limit);
    return responses.removeAt(0);
  }
}

ApiClient _searchApiClient(_SearchTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '1',
    deviceId: 'device',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'token',
    traceIdFactory: () => 'trace-search',
  ),
  transport: transport,
);

ApiTransportResponse _searchResponse({
  String ownerWorkspaceId = 'workspace opaque/+1',
}) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'mode': 'keyword',
      'queryFingerprint': 'sha256:query',
      'keywordReadiness': 'current',
      'vectorReadiness': 'unavailable',
      'contentCursor': '230',
      'results': <Object?>[
        <String, Object?>{
          'ownerRef': <String, Object?>{
            'workspaceId': ownerWorkspaceId,
            'kind': 'hnote',
            'id': 'remote-note-1',
          },
          'revisionId': 'note-revision-1',
          'part': 'raw',
          'path': 'notes/remote-note-1/raw.md',
          'title': '客户复盘',
          'updatedAt': '2026-08-07T10:00:00Z',
          'matchMode': 'keyword',
          'score': .95,
          'staleSource': false,
        },
      ],
    },
  },
);

ApiTransportResponse _searchExactHNoteResponse({
  String noteRevisionId = 'note-revision-1',
  bool sparse = false,
}) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'noteId': 'remote-note-1',
      'workspaceId': 'workspace opaque/+1',
      'folderId': null,
      'title': '客户复盘',
      'state': 'active',
      'noteRevisionId': noteRevisionId,
      if (sparse) 'rawPartRevisionId': 'raw-part-revision-9',
      if (sparse) 'outlinePartRevisionId': 'outline-revision-1',
      if (sparse) 'germinationPartRevisionId': 'germination-revision-1',
      if (!sparse)
        'parts': <String, Object?>{
          'raw': <String, Object?>{
            'partRevisionId': 'raw-part-revision-9',
            'markdown': '# 精确正文',
            'contentHash': 'raw-hash',
          },
          'outline': <String, Object?>{
            'partRevisionId': 'outline-revision-1',
            'markdown': '',
            'contentHash': 'outline-hash',
          },
          'germination': <String, Object?>{
            'partRevisionId': 'germination-revision-1',
            'markdown': '',
            'contentHash': 'germination-hash',
          },
        },
      'resourceRefs': <Object?>[],
      'etag': '"note-current"',
      'contentCursor': '230',
    },
  },
);

ApiTransportResponse _searchPartResponse({
  required String part,
  required String revisionId,
  required String markdown,
  required String contentHash,
}) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'noteId': 'remote-note-1',
      'part': part,
      'partRevisionId': revisionId,
      'contentMarkdown': markdown,
      'contentSha256': contentHash,
      'etag': '"$revisionId"',
    },
  },
);

final class _SearchTransport implements ApiTransport {
  _SearchTransport(this.responses);

  final List<ApiTransportResponse> responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}
