import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/features/ingestion/data/material_ingestion_api.dart';
import 'package:huahuoai_app/features/ingestion/domain/material_ingestion.dart';

void main() {
  test(
    'URL import sends only url to the 39 Workspace ingestion contract',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _response(<String, Object?>{
          'ingestion': <String, Object?>{
            'ingestionId': 'ingestion-1',
            'status': 'created',
          },
        }),
        _response(<String, Object?>{
          'ingestion': <String, Object?>{
            'ingestionId': 'ingestion-1',
            'status': 'promoted',
            'promotedNoteId': 'note-1',
          },
        }),
      ]);
      final api = _api(transport);

      final created = await api.createLinkImport(
        url: Uri.parse('https://example.test/article'),
        idempotencyKey: 'idem-link',
      );
      final promoted = await api.getLinkImport('ingestion-1');

      expect(created.data?.taskId, 'ingestion-1');
      expect(created.data?.status, MaterialRemoteTaskStatus.queued);
      expect(promoted.data?.status, MaterialRemoteTaskStatus.completed);
      expect(promoted.data?.promotedNoteId, 'note-1');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/ws-1/note-ingestions',
        '/api/v1/workspaces/ws-1/note-ingestions/ingestion-1',
      ]);
      expect(jsonDecode(transport.requests.first.body!), <String, Object?>{
        'url': 'https://example.test/article',
      });
      expect(
        transport.requests.first.headers['X-Idempotency-Key'],
        'idem-link',
      );
    },
  );

  test(
    'unpublished video analysis remains unavailable without transport',
    () async {
      final transport = _QueueTransport(const <ApiTransportResponse>[]);
      final api = _api(transport);

      final video = await api.createVideoAnalysis(
        resourceId: 'resource-1',
        title: 'video',
        idempotencyKey: 'idem-video',
      );

      expect(video.error?.code, 'AGENT_PROFILE_UNAVAILABLE');
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'recording list hydrates flat HNote heads before exposing assets',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[_workspaceNoteHead()],
              'nextCursor': 'cursor-2',
            },
          },
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': _workspaceNotePart(
              part: 'raw',
              revision: 'raw-rev-1',
              markdown: '重启后恢复的逐字稿',
            ),
          },
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': _workspaceNotePart(
              part: 'outline',
              revision: 'outline-rev-1',
              markdown: '# 重启后恢复的纲要',
            ),
          },
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': _workspaceNoteHead(),
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.listMemoryNotes(cursor: 'cursor-1');

      expect(result.ok, isTrue);
      expect(result.data?.items.single.id, 'note-1');
      expect(result.data?.items.single.markdown, '重启后恢复的逐字稿');
      expect(result.data?.items.single.summary, '# 重启后恢复的纲要');
      expect(result.data?.nextCursor, 'cursor-2');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/ws-1/notes',
        '/api/v1/workspaces/ws-1/notes/note-1/parts/raw',
        '/api/v1/workspaces/ws-1/notes/note-1/parts/outline',
        '/api/v1/workspaces/ws-1/notes/note-1',
      ]);
      expect(
        transport.requests.first.url.queryParameters['cursor'],
        'cursor-1',
      );
    },
  );

  test('recording HNote reads deployed raw and outline partitions', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{'success': true, 'data': _workspaceNoteHead()},
      ),
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _workspaceNotePart(
            part: 'raw',
            revision: 'raw-rev-1',
            markdown: '逐字转写原文',
          ),
        },
      ),
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _workspaceNotePart(
            part: 'outline',
            revision: 'outline-rev-1',
            markdown: '# 云端纲要',
          ),
        },
      ),
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{'success': true, 'data': _workspaceNoteHead()},
      ),
    ]);

    final result = await _api(transport).getMemoryNote('note-1');

    expect(result.data?.title, 'Workspace note');
    expect(result.data?.markdown, '逐字转写原文');
    expect(result.data?.summary, '# 云端纲要');
    expect(result.data?.remoteNoteId, 'note-1');
    expect(result.data?.rawPartRevisionId, 'raw-rev-1');
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/workspaces/ws-1/notes/note-1',
      '/api/v1/workspaces/ws-1/notes/note-1/parts/raw',
      '/api/v1/workspaces/ws-1/notes/note-1/parts/outline',
      '/api/v1/workspaces/ws-1/notes/note-1',
    ]);
  });

  test('missing Workspace fails before transport', () async {
    final transport = _QueueTransport(const <ApiTransportResponse>[]);
    final api = MaterialIngestionApi(
      apiClient: _client(transport),
      workspaceId: () => null,
    );

    final result = await api.listMemoryNotes();

    expect(result.error?.code, 'WORKSPACE_CONTEXT_UNAVAILABLE');
    expect(transport.requests, isEmpty);
  });

  test('URL ingestion parser rejects malformed terminal responses', () {
    expect(
      parseLinkIngestionSnapshot(<String, Object?>{
        'ingestion': <String, Object?>{
          'ingestionId': 'ingestion-1',
          'status': 'promoted',
        },
      }),
      isNull,
    );
    expect(
      parseLinkIngestionSnapshot(<String, Object?>{
        'ingestion': <String, Object?>{
          'ingestionId': 'ingestion-1',
          'status': 'failed',
        },
      }),
      isNull,
    );
    final failed = parseLinkIngestionSnapshot(<String, Object?>{
      'ingestion': <String, Object?>{
        'ingestionId': 'ingestion-1',
        'status': 'failed',
        'failureCode': 'URL_IMPORT_INVALID',
      },
    });
    expect(failed?.status, MaterialRemoteTaskStatus.failed);
    expect(failed?.errorCode, 'URL_IMPORT_INVALID');
  });

  test('media preview resolves the exact automatic Outline owner', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _response(<String, Object?>{
        'mediaPreview': <String, Object?>{
          'ingestionId': 'ingestion-video',
          'status': 'unavailable',
          'contentType': 'video',
        },
      }),
      _response(<String, Object?>{
        'mediaPreview': <String, Object?>{
          'ingestionId': 'ingestion-article',
          'status': 'unavailable',
          'contentType': 'article',
        },
      }),
      _response(<String, Object?>{
        'mediaPreview': <String, Object?>{
          'ingestionId': 'ingestion-embedded',
          'status': 'refreshing',
          'contentType': 'article',
        },
      }),
    ]);
    final api = _api(transport);

    final video = await api.getLinkOutlineOwnership('ingestion-video');
    final article = await api.getLinkOutlineOwnership('ingestion-article');
    final embedded = await api.getLinkOutlineOwnership('ingestion-embedded');

    expect(video.data?.owner, MaterialLinkOutlineOwner.backendMedia);
    expect(article.data?.owner, MaterialLinkOutlineOwner.client);
    expect(embedded.data?.owner, MaterialLinkOutlineOwner.backendMedia);
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/workspaces/ws-1/note-ingestions/ingestion-video/media-preview',
      '/api/v1/workspaces/ws-1/note-ingestions/ingestion-article/media-preview',
      '/api/v1/workspaces/ws-1/note-ingestions/ingestion-embedded/media-preview',
    ]);
  });
}

ApiTransportResponse _response(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

MaterialIngestionApi _api(_QueueTransport transport) => MaterialIngestionApi(
  apiClient: _client(transport),
  workspaceId: () => 'ws-1',
);

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'token',
  ),
  transport: transport,
);

Map<String, Object?> _workspaceNoteHead() => <String, Object?>{
  'noteId': 'note-1',
  'workspaceId': 'ws-1',
  'folderId': null,
  'sourceKind': 'recording',
  'title': 'Workspace note',
  'state': 'active',
  'noteRevisionId': 'note-rev-1',
  'rawPartRevisionId': 'raw-rev-1',
  'outlinePartRevisionId': 'outline-rev-1',
  'germinationPartRevisionId': 'germination-rev-1',
  'resourceRefs': <Object?>[],
  'etag': '"note-1"',
  'contentCursor': '10',
  'createdAt': '2026-07-14T00:00:00.000Z',
  'updatedAt': '2026-07-14T01:00:00.000Z',
};

Map<String, Object?> _workspaceNotePart({
  required String part,
  required String revision,
  required String markdown,
}) => <String, Object?>{
  'noteId': 'note-1',
  'noteRevisionId': 'note-rev-1',
  'part': part,
  'partRevisionId': revision,
  'contentMarkdown': markdown,
  'contentSha256': 'sha256-$part',
  'etag': '"note-1-$part"',
  'createdAt': '2026-07-14T01:00:00.000Z',
};

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
