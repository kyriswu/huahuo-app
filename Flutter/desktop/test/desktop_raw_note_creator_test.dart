import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/documents/data/desktop_raw_note_creator.dart';
import 'package:huahuo_desktop/features/documents/domain/desktop_raw_note_creator.dart';

void main() {
  test('creates and reads back a raw desktop text asset', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _success(_noteJson()),
      _success(_noteJson()),
    ]);
    final creator = RemoteDesktopRawNoteCreator(_client(transport));

    final result = await creator.createRawNote(
      const DesktopRawNoteCreateRequest(
        workspaceId: 'workspace-1',
        title: '随录素材',
        rawMarkdown: '今天观察到一个内容切入点。',
        idempotencyKey: 'desktop-capture-text-1',
      ),
    );

    expect(
      result.isSuccess,
      isTrue,
      reason: '${result.code}: ${result.message}',
    );
    expect(result.data?.noteId, 'note-1');
    expect(result.data?.title, '随录素材');
    expect(result.data?.rawMarkdown, '今天观察到一个内容切入点。');
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/workspaces/workspace-1/notes',
      '/api/v1/workspaces/workspace-1/notes/note-1',
    ]);
    final request = transport.requests.first;
    final body = jsonDecode(request.body!) as Map<String, dynamic>;
    expect(body['title'], '随录素材');
    expect((body['parts'] as Map<String, dynamic>)['raw'], '今天观察到一个内容切入点。');
    expect((body['parts'] as Map<String, dynamic>)['outline'], '');
    expect((body['parts'] as Map<String, dynamic>)['germination'], '');
    expect(request.headers['X-Idempotency-Key'], 'desktop-capture-text-1');
  });

  test('rejects invalid raw text before making a request', () async {
    final transport = _QueueTransport(const <ApiTransportResponse>[]);
    final creator = RemoteDesktopRawNoteCreator(_client(transport));

    final result = await creator.createRawNote(
      const DesktopRawNoteCreateRequest(
        workspaceId: 'workspace-1',
        title: ' ',
        rawMarkdown: '内容',
        idempotencyKey: 'desktop-capture-text-1',
      ),
    );

    expect(result.isSuccess, isFalse);
    expect(result.code, 'DESKTOP_RAW_NOTE_INPUT_INVALID');
    expect(transport.requests, isEmpty);
  });
}

ApiClient _client(_QueueTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'windows',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
  ),
  transport: transport,
);

ApiTransportResponse _success(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

Map<String, Object?> _noteJson() => <String, Object?>{
  'noteId': 'note-1',
  'workspaceId': 'workspace-1',
  'folderId': null,
  'title': '随录素材',
  'state': 'active',
  'noteRevisionId': 'note-revision-1',
  'parts': <String, Object?>{
    'raw': <String, Object?>{
      'partRevisionId': 'raw-revision-1',
      'markdown': '今天观察到一个内容切入点。',
      'contentHash': 'hash-raw',
    },
    'outline': <String, Object?>{
      'partRevisionId': 'outline-revision-1',
      'markdown': '',
      'contentHash': 'hash-outline',
    },
    'germination': <String, Object?>{
      'partRevisionId': 'germination-revision-1',
      'markdown': '',
      'contentHash': 'hash-germination',
    },
  },
  'resourceRefs': const <Object?>[],
  'etag': 'etag-1',
  'contentCursor': '10',
};

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
