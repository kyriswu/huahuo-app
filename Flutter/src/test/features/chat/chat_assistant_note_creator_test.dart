import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/features/chat/application/chat_assistant_note_creator.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/workspace_folder_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  group('ChatAssistantNoteCreator', () {
    test(
      'uses one message-idempotent formal HNote mutation with images',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _success(_detail()),
          _success(_detail()),
        ]);
        final client = _client(transport);
        final library = KnowledgeLibraryController(
          initialNotes: const <V3FeedItem>[],
          includeDemoFixtures: false,
          workspaceFolderPort: ApiWorkspaceFolderPort(
            apiClient: client,
            workspaceId: () => 'workspace_1',
          ),
        );
        final creator = ChatAssistantNoteCreator(
          client: WorkspaceContentClient(client),
          workspaceId: () => 'workspace_1',
          library: library,
        );
        final message = _assistantMessage();

        final first = creator.create(message, folderId: 'folder_1');
        final duplicate = creator.create(message, folderId: 'folder_1');
        expect(identical(first, duplicate), isTrue);

        final result = await first;

        expect(result.isSuccess, isTrue, reason: result.errorCode);
        expect(result.note?.id, 'note_1');
        expect(result.note?.title, '项目复盘');
        expect(result.note?.rawBody, '# 项目复盘\n\n这是保留的 AI Markdown。');
        expect(result.note?.remoteMediaAttachments, hasLength(1));
        expect(
          result.note?.remoteMediaAttachments.single.resourceId,
          'resource_1',
        );
        expect(transport.requests, hasLength(2));
        final create = transport.requests.first;
        expect(create.method, 'POST');
        expect(create.url.path, '/api/v1/workspaces/workspace_1/notes');
        expect(
          create.headers['X-Idempotency-Key'],
          startsWith('chat-assistant-note-'),
        );
        final body = _body(create);
        expect(body['title'], '项目复盘');
        expect(body['folderId'], 'folder_1');
        expect(body, isNot(contains('tags')));
        expect(body['parts'], <String, Object?>{
          'raw': '# 项目复盘\n\n这是保留的 AI Markdown。',
          'outline': '',
          'germination': '',
        });
        expect(body['resourceRefs'], <Object?>[
          <String, Object?>{
            'resourceId': 'resource_1',
            'usage': 'inline_image',
            'anchor': 'assistant-image-1',
            'alt': '方案草图',
          },
        ]);
      },
    );

    test(
      'hydrates sparse formal HNote readback before merging the asset',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _success(_sparseDetail()),
          _success(_sparseDetail()),
          _success(
            _partView(
              part: 'raw',
              revisionId: 'raw_revision_1',
              markdown: '# 项目复盘\n\n这是保留的 AI Markdown。',
              contentHash: 'raw_hash',
            ),
          ),
          _success(
            _partView(
              part: 'outline',
              revisionId: 'outline_revision_1',
              markdown: '## 完整纲要',
              contentHash: 'outline_hash',
            ),
          ),
          _success(
            _partView(
              part: 'germination',
              revisionId: 'germination_revision_1',
              markdown: '完整发芽',
              contentHash: 'germination_hash',
            ),
          ),
        ]);
        final library = KnowledgeLibraryController(
          initialNotes: const <V3FeedItem>[],
          includeDemoFixtures: false,
        );
        final creator = ChatAssistantNoteCreator(
          client: WorkspaceContentClient(_client(transport)),
          workspaceId: () => 'workspace_1',
          library: library,
        );

        final result = await creator.create(_assistantMessage());

        expect(result.isSuccess, isTrue, reason: result.errorCode);
        expect(result.note?.rawBody, '# 项目复盘\n\n这是保留的 AI Markdown。');
        expect(result.note?.summaryBody, '## 完整纲要');
        expect(result.note?.sproutReport?.markdown, '完整发芽');
        expect(
          transport.requests.skip(2).map((request) => request.url.path),
          unorderedEquals(<String>[
            '/api/v1/workspaces/workspace_1/notes/note_1/parts/raw',
            '/api/v1/workspaces/workspace_1/notes/note_1/parts/outline',
            '/api/v1/workspaces/workspace_1/notes/note_1/parts/germination',
          ]),
        );
      },
    );

    test(
      'rejects invalid image references without creating a partial asset',
      () async {
        final transport = _QueueTransport(const <ApiTransportResponse>[]);
        final creator = ChatAssistantNoteCreator(
          client: WorkspaceContentClient(_client(transport)),
          workspaceId: () => 'workspace_1',
          library: KnowledgeLibraryController(
            initialNotes: const <V3FeedItem>[],
            includeDemoFixtures: false,
          ),
        );
        final message = ChatMessage(
          messageId: 'assistant_2',
          threadId: 'thread_1',
          scene: ChatScene.feedAi,
          role: ChatMessageRole.assistant,
          contentType: ChatMessageContentType.text,
          status: 'succeeded',
          textPreview: '不会写成缺图资产。',
          imageAttachments: const <ChatImageAttachment>[
            ChatImageAttachment(resourceId: ''),
          ],
        );

        final result = await creator.create(message);

        expect(result.status, ChatAssistantNoteCreateStatus.failure);
        expect(result.errorCode, 'CHAT_ASSISTANT_IMAGE_REFERENCE_INVALID');
        expect(transport.requests, isEmpty);
      },
    );

    test(
      'retains an image-resource ownership failure and records a safe diagnostic',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 403,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{
                'code': 'RESOURCE_REFERENCE_FORBIDDEN',
                'message': 'resource is not pinnable',
                'retryable': false,
              },
            },
          ),
        ]);
        final database = AppDatabase();
        final logDao = DiagnosticLogDao(database);
        final creator = ChatAssistantNoteCreator(
          client: WorkspaceContentClient(_client(transport)),
          workspaceId: () => 'workspace_1',
          library: KnowledgeLibraryController(
            initialNotes: const <V3FeedItem>[],
            includeDemoFixtures: false,
          ),
          diagnosticLogger: DiagnosticLogger(dao: logDao),
        );

        final result = await creator.create(_assistantMessage());

        expect(result.status, ChatAssistantNoteCreateStatus.failure);
        expect(result.errorCode, 'RESOURCE_REFERENCE_FORBIDDEN');
        expect(transport.requests, hasLength(1));
        expect(_body(transport.requests.single)['resourceRefs'], isNotEmpty);
        final events = logDao.query();
        expect(events, hasLength(1));
        expect(events.single.category, 'assets');
        expect(
          events.single.redactedMetadata['errorCode'],
          'RESOURCE_REFERENCE_FORBIDDEN',
        );
      },
    );

    test('derives a readable title from heading, text, or a safe fallback', () {
      expect(titleForAssistantMarkdown('## 可用标题 ##\n正文'), '可用标题');
      expect(titleForAssistantMarkdown('\n  普通第一行\n后续内容'), '普通第一行');
      expect(titleForAssistantMarkdown(' \n\t '), 'AI 回复');
    });
  });
}

ChatMessage _assistantMessage() => const ChatMessage(
  messageId: 'assistant_1',
  threadId: 'thread_1',
  scene: ChatScene.feedAi,
  role: ChatMessageRole.assistant,
  contentType: ChatMessageContentType.text,
  status: 'succeeded',
  textPreview: '# 项目复盘\n\n这是保留的 AI Markdown。',
  imageAttachments: <ChatImageAttachment>[
    ChatImageAttachment(
      resourceId: 'resource_1',
      displayName: '方案草图',
      mimeType: 'image/png',
    ),
  ],
);

Map<String, Object?> _detail() => <String, Object?>{
  'noteId': 'note_1',
  'workspaceId': 'workspace_1',
  'folderId': null,
  'title': '项目复盘',
  'state': 'active',
  'noteRevisionId': 'note_revision_1',
  'parts': <String, Object?>{
    'raw': <String, Object?>{
      'partRevisionId': 'raw_revision_1',
      'contentMarkdown': '# 项目复盘\n\n这是保留的 AI Markdown。',
      'contentSha256': 'raw_hash',
    },
    'outline': <String, Object?>{
      'partRevisionId': 'outline_revision_1',
      'contentMarkdown': '',
      'contentSha256': 'outline_hash',
    },
    'germination': <String, Object?>{
      'partRevisionId': 'germination_revision_1',
      'contentMarkdown': '',
      'contentSha256': 'germination_hash',
    },
  },
  'resourceRefs': <Object?>[
    <String, Object?>{
      'resourceId': 'resource_1',
      'order': 0,
      'usage': 'inline_image',
      'sha256': 'image_hash',
      'mimeType': 'image/png',
      'anchor': 'assistant-image-1',
      'alt': '方案草图',
    },
  ],
  'etag': 'etag_1',
  'contentCursor': '1',
  'createdAt': '2026-08-20T08:00:00Z',
  'updatedAt': '2026-08-20T08:00:00Z',
};

Map<String, Object?> _sparseDetail() {
  final detail = Map<String, Object?>.of(_detail())..remove('parts');
  detail.addAll(<String, Object?>{
    'rawPartRevisionId': 'raw_revision_1',
    'outlinePartRevisionId': 'outline_revision_1',
    'germinationPartRevisionId': 'germination_revision_1',
  });
  return detail;
}

Map<String, Object?> _partView({
  required String part,
  required String revisionId,
  required String markdown,
  required String contentHash,
}) => <String, Object?>{
  'noteId': 'note_1',
  'part': part,
  'partRevisionId': revisionId,
  'contentMarkdown': markdown,
  'contentSha256': contentHash,
  'etag': '"$revisionId"',
};

ApiTransportResponse _success(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

ApiClient _client(_QueueTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device_1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () async => 'access-token',
  ),
  transport: transport,
);

Map<String, Object?> _body(ApiTransportRequest request) {
  final decoded = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
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
