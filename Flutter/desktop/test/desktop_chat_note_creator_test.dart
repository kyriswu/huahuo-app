import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/chat/application/desktop_chat_note_creator.dart';
import 'package:huahuo_desktop/features/chat/domain/desktop_chat_port.dart';

void main() {
  test(
    'creates one HNote from durable Assistant Markdown and image resources',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(_noteJson()),
        _success(_noteJson()),
      ]);
      final creator = RemoteDesktopChatNoteCreator(_client(transport));
      const reply = DesktopChatMessage(
        messageId: 'assistant_1',
        threadId: 'thread_1',
        role: 'assistant',
        text: '# 图像方案\n\n保留主体和留白。',
        imageAttachments: <DesktopChatImageAttachment>[
          DesktopChatImageAttachment(
            resourceId: 'resource_image_1',
            displayName: 'render.png',
            mimeType: 'image/png',
          ),
        ],
      );

      final result = await creator.create(
        workspaceId: 'workspace_1',
        assistantMessage: reply,
      );

      expect(
        result.isSuccess,
        isTrue,
        reason: '${result.code}: ${result.message}',
      );
      expect(result.data?.noteId, 'note_1');
      expect(result.data?.title, '图像方案');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/workspace_1/notes',
        '/api/v1/workspaces/workspace_1/notes/note_1',
      ]);
      final request = transport.requests.first;
      final body = jsonDecode(request.body!) as Map<String, dynamic>;
      expect(body['title'], '图像方案');
      expect((body['parts'] as Map<String, dynamic>)['raw'], reply.text);
      expect(body['resourceRefs'], <Object?>[
        <String, Object?>{
          'resourceId': 'resource_image_1',
          'usage': 'inline_image',
          'anchor': 'assistant-image-1',
          'alt': 'render.png',
        },
      ]);
      expect(
        request.headers['X-Idempotency-Key'],
        startsWith('desktop-chat-note-'),
      );
    },
  );

  test(
    'rejects invalid generated image IDs before creating a partial HNote',
    () async {
      final transport = _QueueTransport(const <ApiTransportResponse>[]);
      final creator = RemoteDesktopChatNoteCreator(_client(transport));
      const reply = DesktopChatMessage(
        messageId: 'assistant_1',
        threadId: 'thread_1',
        role: 'assistant',
        text: '带图回复',
        imageAttachments: <DesktopChatImageAttachment>[
          DesktopChatImageAttachment(resourceId: '../not-a-resource'),
        ],
      );

      final result = await creator.create(
        workspaceId: 'workspace_1',
        assistantMessage: reply,
      );

      expect(result.isSuccess, isFalse);
      expect(result.code, 'DESKTOP_CHAT_NOTE_IMAGE_REFERENCE_INVALID');
      expect(transport.requests, isEmpty);
    },
  );
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

ApiTransportResponse _success(Object data) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{'success': true, 'data': data},
);

Map<String, Object?> _noteJson() => <String, Object?>{
  'noteId': 'note_1',
  'workspaceId': 'workspace_1',
  'folderId': null,
  'title': '图像方案',
  'state': 'active',
  'noteRevisionId': 'note-revision-1',
  'parts': <String, Object?>{
    'raw': <String, Object?>{
      'partRevisionId': 'raw-revision-1',
      'markdown': '# 图像方案\n\n保留主体和留白。',
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
  'resourceRefs': <Object?>[
    <String, Object?>{
      'resourceId': 'resource_image_1',
      'order': 0,
      'usage': 'inline_image',
      'sha256': 'sha256:test',
      'mimeType': 'image/png',
      'anchor': 'assistant-image-1',
      'alt': 'render.png',
    },
  ],
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
