import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/chat/application/chat_runtime_invocation_mapper.dart';
import 'package:huahuoai_app/features/chat/data/chat_api.dart';
import 'package:huahuoai_app/features/chat/data/remote_project_assistant_runtime.dart';
import 'package:huahuoai_app/features/chat/domain/assistant_runtime.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_context.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';

const _longPersonaReplyFinalQuestion = '要不要按照这个视觉参考设计直接生成图片？';

String _longPersonaReply({int length = 20561}) {
  return '人' * (length - _longPersonaReplyFinalQuestion.length) +
      _longPersonaReplyFinalQuestion;
}

void main() {
  group('RemoteProjectChatRepository', () {
    test('classifies 2xx parse failures as outcome unknown', () {
      final responseInvalid = ApiResult<ChatTextMutation>.failure(
        error: chatApiFailure('API_RESPONSE_INVALID'),
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      );
      final malformedThread = ApiResult<ChatThread>.failure(
        error: chatApiFailure('API_MALFORMED_ENVELOPE'),
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      );

      expect(
        chatTextSubmissionFailureDisposition(responseInvalid),
        ChatSubmissionFailureDisposition.outcomeUnknown,
      );
      expect(
        chatThreadCreationFailureDisposition(malformedThread),
        ChatSubmissionFailureDisposition.outcomeUnknown,
      );
    });

    test('classifies transient HTTP write failures as outcome unknown', () {
      for (final fixture in <(int, String)>[
        (408, 'REQUEST_TIMEOUT'),
        (429, 'RATE_LIMITED'),
        (500, 'INTERNAL_SERVER_ERROR'),
        (503, 'API_SERVER_UNAVAILABLE'),
        (400, 'API_SERVER_UNAVAILABLE'),
      ]) {
        final failure = AppFailure(
          code: fixture.$2,
          category: AppFailureCategory.api,
          message: fixture.$2,
          userMessageKey: 'chat.test.${fixture.$2}',
        );
        final textResult = ApiResult<ChatTextMutation>.failure(
          error: failure,
          status: fixture.$1,
          idempotencyStore: SubmissionKeyStore.empty,
        );
        final threadResult = ApiResult<ChatThread>.failure(
          error: failure,
          status: fixture.$1,
          idempotencyStore: SubmissionKeyStore.empty,
        );

        expect(
          chatTextSubmissionFailureDisposition(textResult),
          ChatSubmissionFailureDisposition.outcomeUnknown,
          reason: '${fixture.$1} ${fixture.$2}',
        );
        expect(
          chatThreadCreationFailureDisposition(threadResult),
          ChatSubmissionFailureDisposition.outcomeUnknown,
          reason: '${fixture.$1} ${fixture.$2}',
        );
      }

      final rejected = ApiResult<ChatTextMutation>.failure(
        error: chatApiFailure('CHAT_REQUEST_REJECTED'),
        status: 422,
        idempotencyStore: SubmissionKeyStore.empty,
      );
      expect(
        chatTextSubmissionFailureDisposition(rejected),
        ChatSubmissionFailureDisposition.knownRejected,
      );
    });

    test(
      'lists ordinary chat history through its persisted server scene',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'items': <Object?>[
                  <String, Object?>{
                    'threadId': 'feed-1',
                    'title': '内容沉淀',
                    'firstUserMessagePreview': '帮我整理今天的内容',
                    'updatedAt': '2026-07-10T08:00:00Z',
                  },
                ],
                'nextCursor': 'cursor-2',
              },
            },
          ),
        ]);
        final api = _api(transport);

        final result = await api.listThreads(
          scene: ChatScene.feedAi,
          limit: 20,
        );

        expect(result.ok, isTrue);
        expect(result.data?.items.single.threadId, 'feed-1');
        expect(result.data?.items.single.scene, ChatScene.feedAi);
        expect(result.data?.items.single.firstUserMessageText, '帮我整理今天的内容');
        expect(result.data?.nextCursor, 'cursor-2');
        final request = transport.requests.single;
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/chat/threads');
        expect(
          request.url.queryParameters['scene'],
          'self_media_creation_standard',
        );
        expect(request.headers['Authorization'], 'Bearer access-token');
        expect(request.headers.containsKey('X-Idempotency-Key'), isFalse);
      },
    );

    test('lists deep positioning history through the work AI scene', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'threadId': 'deep-history-1',
                  'scene': 'work_ai',
                  'title': '深度定位历史',
                },
              ],
            },
          },
        ),
      ]);

      final result = await _api(transport).listThreads(
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.deepPositioning,
      );

      expect(result.ok, isTrue);
      expect(transport.requests.single.url.queryParameters['scene'], 'work_ai');
      expect(
        result.data?.items.single.purpose,
        ChatConversationPurpose.deepPositioning,
      );
      expect(result.data?.items.single.scene, ChatScene.feedAi);
    });

    test(
      'reads app-safe assistant draft deltas with an opaque cursor',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'threadId': 'thread-1',
                'nextSequence': 8,
                'events': <Object?>[
                  <String, Object?>{
                    'sequence': 7,
                    'threadId': 'thread-1',
                    'runId': 'agent-run-1',
                    'eventType': 'draft_delta',
                    'visibility': 'app_safe',
                    'deltaText': '  第一段\n',
                    'replace': true,
                  },
                  <String, Object?>{
                    'sequence': 8,
                    'threadId': 'thread-1',
                    'runId': 'agent-run-1',
                    'eventType': 'draft_delta',
                    'visibility': 'app_safe',
                    'deltaText': '\t第二段 ',
                  },
                ],
              },
            },
          ),
        ]);

        final result = await RemoteProjectAssistantRuntime(
          _client(transport),
        ).readProgress(conversationId: 'thread-1', afterSequence: 6);

        expect(result.ok, isTrue);
        expect(result.data?.nextSequence, 8);
        expect(result.data?.events.map((event) => event.deltaText), <String?>[
          '  第一段\n',
          '\t第二段 ',
        ]);
        expect(result.data?.events.first.replace, isTrue);
        expect(result.data?.events.last.replace, isFalse);
        final request = transport.requests.single;
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/chat/threads/thread-1/events');
        expect(request.url.queryParameters, <String, String>{
          'afterSequence': '6',
          'limit': '100',
        });
        expect(request.headers['Authorization'], 'Bearer access-token');
        expect(request.headers.containsKey('X-Idempotency-Key'), isFalse);
      },
    );

    test('round trips aggregate runtime progress without a sequence', () {
      final invocation = SharedThreadRuntimeInvocation(
        schemaVersion: 'huahuo.thread-runtime-invocation.v1',
        threadId: 'thread-1',
        agentRunId: 'agent-run-1',
        status: 'succeeded',
        agentProfileId: 'renshe_content',
        modelProfileId: 'model-1',
        skillProfileIds: const <String>['skill-1'],
        contentTypes: const <String>['text'],
        createdAt: DateTime.utc(2026, 9, 1),
        completedAt: DateTime.utc(2026, 9, 1, 0, 0, 2),
        tools: <SharedRuntimeTool>[
          SharedRuntimeTool(
            name: 'workspace_search',
            state: 'succeeded',
            invocationId: 'runtime-tool-1',
            durationMs: 430,
            createdAt: DateTime.utc(2026, 9, 1, 0, 0, 1),
            inputSummary: const <String, Object?>{'query': '发布计划', 'limit': 3},
            outputSummary: const <String, Object?>{
              'outputFileCount': 1,
              'mediaTypes': <String>['image/png'],
              'totalSizeBytes': 12,
            },
          ),
        ],
        files: const <SharedRuntimeFile>[],
        progress: <SharedRuntimeProgress>[
          SharedRuntimeProgress(
            kind: 'plan',
            title: '整理输入',
            status: 'updated',
            summary: '正在梳理已有资料',
            createdAt: DateTime.utc(2026, 9, 1, 0, 0, 0, 500),
          ),
        ],
      );

      final payload = runtimeInvocationPayload(invocation);
      final tool = (payload['tools']! as List).single as Map;
      final progress = (payload['progress']! as List).single as Map;
      expect(payload.containsKey('sequence'), isFalse);
      expect(tool.containsKey('sequence'), isFalse);
      expect(progress.containsKey('sequence'), isFalse);
      expect(tool['status'], 'succeeded');
      expect(tool['durationMs'], 430);
      expect(progress['summary'], '正在梳理已有资料');

      final reparsed = parseSharedThreadRuntimeInvocation(payload);
      expect(reparsed?.createdAt, DateTime.utc(2026, 9, 1));
      expect(reparsed?.tools.single.invocationId, 'runtime-tool-1');
      expect(reparsed?.tools.single.inputSummary['query'], '发布计划');
      expect(reparsed?.progress.single.status, 'updated');
      expect(
        reparsed?.progress.single.createdAt,
        DateTime.utc(2026, 9, 1, 0, 0, 0, 500),
      );
    });

    test('creates a thread and sends text with idempotency headers', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'thread': <String, Object?>{
                'threadId': 'feed-1',
                'scene': 'work_ai',
                'title': '新会话',
              },
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'messageId': 'msg-1',
                'contentType': 'text',
                'sentAt': '2026-08-01T08:00:00Z',
              },
              'assistantMessage': <String, Object?>{
                'messageId': 'assistant-1',
                'threadId': 'feed-1',
                'scene': 'work_ai',
                'role': 'assistant',
                'contentType': 'text',
                'status': 'sent',
                'textPreview': '来自服务器的回答',
                'createdAt': '2026-08-01T08:00:02Z',
              },
              'nextAction': <String, Object?>{'type': 'none'},
            },
          },
        ),
      ]);
      final api = _api(transport);

      final created = await api.createThread(
        scene: ChatScene.feedAi,
        contentLineId: 'line-1',
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.feed_ai.create_thread',
          businessEntityId: 'feed_ai',
          scene: 'feed_ai',
          generateKey: _fixedCreateKey,
        ),
      );
      final sent = await api.sendTextMessage(
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        content: '请帮我整理访谈观点',
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.feed_ai.send_text',
          businessEntityId: 'feed-1',
          localDraftId: 'draft-1',
          scene: 'feed_ai',
          generateKey: _fixedSendKey,
        ),
      );

      expect(created.ok, isTrue);
      expect(sent.ok, isTrue);
      expect(sent.data?.message?.threadId, 'feed-1');
      expect(sent.data?.message?.role, ChatMessageRole.user);
      expect(sent.data?.message?.createdAt, DateTime.utc(2026, 8, 1, 8));
      expect(sent.data?.assistantMessage?.visibleText, '来自服务器的回答');
      expect(
        sent.data?.assistantMessage?.createdAt,
        DateTime.utc(2026, 8, 1, 8, 0, 2),
      );
      expect(transport.requests, hasLength(2));
      final createRequest = transport.requests.first;
      expect(createRequest.method, 'POST');
      expect(createRequest.url.path, '/api/v1/chat/threads');
      expect(createRequest.headers['X-Idempotency-Key'], 'idem-create');
      expect(_body(createRequest), <String, Object?>{
        'scene': 'self_media_creation_standard',
        'creativePositioningId': 'line-1',
      });
      final sendRequest = transport.requests.last;
      expect(sendRequest.url.path, '/api/v1/chat/threads/feed-1/messages');
      expect(sendRequest.headers['X-Idempotency-Key'], 'idem-send');
      expect(_body(sendRequest), <String, Object?>{
        'input': <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '请帮我整理访谈观点'},
          ],
        },
        'agentProfileId': 'self_media_creation_standard',
      });
    });

    test('treats a malformed successful thread creation as unknown', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'thread': <String, Object?>{
                'threadId': 'not a safe id',
                'scene': 'work_ai',
              },
            },
          },
        ),
      ]);

      final result = await _api(transport).createThread(
        scene: ChatScene.feedAi,
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.feed_ai.create_thread',
          generateKey: _fixedCreateKey,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'API_MALFORMED_ENVELOPE');
      expect(
        chatThreadCreationFailureDisposition(result),
        ChatSubmissionFailureDisposition.outcomeUnknown,
      );
    });

    test('sends ordinary chat without an Agent Catalog preflight', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'messageId': 'ordinary-message-1',
                'contentType': 'text',
              },
            },
          },
        ),
      ]);

      final result =
          await _api(
            transport,
            catalog: _TestChatAgentCatalog(
              failure: chatApiFailure('CATALOG_DOWN', retryable: true),
            ),
          ).sendTextMessage(
            threadId: 'feed-1',
            scene: ChatScene.feedAi,
            content: '你好',
            idempotency: const IdempotencyRequestContext(
              operation: 'chat.feed_ai.send_text',
              generateKey: _fixedSendKey,
            ),
          );

      expect(result.ok, isTrue);
      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.url.path,
        '/api/v1/chat/threads/feed-1/messages',
      );
      expect(
        _body(transport.requests.single)['agentProfileId'],
        'self_media_creation_standard',
      );
    });

    test(
      'sends completed image Resources as canonical image input parts',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'message': <String, Object?>{
                  'messageId': 'image-message-1',
                  'contentType': 'text',
                },
                'agentRunId': 'agent-run-image-1',
              },
            },
          ),
        ]);
        final context = ChatContextEnvelope.create(
          purpose: ChatContextPurpose.general,
          references: const <ChatContextReference>[
            ChatContextReference(
              type: ChatContextReferenceType.image,
              id: 'resource-image-1',
            ),
          ],
        );

        final result = await _api(transport).sendTextMessage(
          threadId: 'feed-image-1',
          scene: ChatScene.feedAi,
          content: '请分析这张图',
          context: context,
          idempotency: const IdempotencyRequestContext(
            operation: 'chat.feed_ai.send_text',
            generateKey: _fixedSendKey,
          ),
        );

        expect(result.ok, isTrue);
        expect(_body(transport.requests.single), <String, Object?>{
          'agentProfileId': 'self_media_creation_standard',
          'input': <String, Object?>{
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': '请分析这张图'},
              <String, Object?>{
                'type': 'image',
                'source': <String, Object?>{
                  'kind': 'resource',
                  'resourceId': 'resource-image-1',
                },
                'usage': 'primary_input',
              },
            ],
          },
        });
      },
    );

    test(
      'locks video media analysis to the public video Agent Profile',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{'agentRunId': 'agent-run-video-1'},
            },
          ),
        ]);
        final context = ChatContextEnvelope.create(
          purpose: ChatContextPurpose.videoAnalysis,
          references: const <ChatContextReference>[
            ChatContextReference(
              type: ChatContextReferenceType.image,
              id: 'resource-video-cover-1',
            ),
            ChatContextReference(
              type: ChatContextReferenceType.file,
              id: 'resource-video-file-1',
            ),
          ],
        );

        final result = await _api(transport).sendTextMessage(
          threadId: 'video-thread-1',
          scene: ChatScene.feedAi,
          content: '分析画面、声音和叙事结构',
          context: context,
          agentProfileId: 'video_analysis',
          idempotency: const IdempotencyRequestContext(
            operation: 'chat.feed_ai.send_text',
            generateKey: _fixedSendKey,
          ),
        );

        expect(result.ok, isTrue);
        expect(_body(transport.requests.single), <String, Object?>{
          'agentProfileId': 'video_analysis',
          'input': <String, Object?>{
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': '分析画面、声音和叙事结构'},
              <String, Object?>{
                'type': 'image',
                'source': <String, Object?>{
                  'kind': 'resource',
                  'resourceId': 'resource-video-cover-1',
                },
                'usage': 'primary_input',
              },
              <String, Object?>{
                'type': 'file',
                'source': <String, Object?>{
                  'kind': 'resource',
                  'resourceId': 'resource-video-file-1',
                },
                'usage': 'reference',
              },
            ],
          },
        });
      },
    );

    test(
      'sends a validated masterpiece draft as bounded canonical text',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{'agentRunId': 'agent-run-book-1'},
            },
          ),
        ]);
        final snapshot = ChatLocalDraftSnapshot.create(
          kind: 'masterpiece_markdown',
          content: '# 我的代表作\n\n这是当前正文。',
          revision: 'current',
        );

        final result = await _api(transport).sendTextMessage(
          threadId: 'book-thread-1',
          scene: ChatScene.feedAi,
          content: '帮我提炼中心思想',
          context: ChatContextEnvelope.create(
            purpose: ChatContextPurpose.masterpiece,
            localDraftSnapshot: snapshot,
          ),
          agentProfileId: 'book_writing',
          idempotency: const IdempotencyRequestContext(
            operation: 'chat.feed_ai.send_text',
            generateKey: _fixedSendKey,
          ),
        );

        expect(result.ok, isTrue);
        expect(_body(transport.requests.single), <String, Object?>{
          'agentProfileId': 'book_writing',
          'input': <String, Object?>{
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': '帮我提炼中心思想'},
              <String, Object?>{
                'type': 'text',
                'text':
                    '$chatLocalDraftAgentEnvelopeMarker\n'
                    '{"schemaVersion":"$chatLocalDraftAgentEnvelopeSchemaVersion",'
                    '"usage":"reference","kind":"masterpiece_markdown",'
                    '"revision":"current","contentLength":16,'
                    '"contentSha256":"${snapshot!.contentSha256}"}\n'
                    '# 我的代表作\n\n这是当前正文。',
              },
            ],
          },
        });
      },
    );

    test('projects only a complete local-draft envelope to its prompt', () {
      final snapshot = ChatLocalDraftSnapshot.create(
        kind: 'creation_canvas',
        content:
            '第一段正文。\n\n'
            '$chatLocalDraftAgentEnvelopeMarker 只是正文内容。\n\n'
            '第二段正文。',
        revision: 'revision-7',
      )!;
      final transportText = '请帮我把结尾写得更有力量\n\n${snapshot.toAgentTextPart()}';

      expect(projectChatLocalDraftUserPrompt(transportText), '请帮我把结尾写得更有力量');
      expect(projectChatLocalDraftUserPrompt(snapshot.toAgentTextPart()), '');
      final collapsedTitle = transportText.replaceAll(RegExp(r'\s+'), ' ');
      final boundedTitle = collapsedTitle.substring(0, 120);
      expect(projectChatLocalDraftUserPrompt(boundedTitle), '请帮我把结尾写得更有力量');

      final tampered = transportText.replaceFirst('第二段正文。', '被篡改正文。');
      expect(projectChatLocalDraftUserPrompt(tampered), tampered);
      const markerLikeUserText =
          '解释一下 <<<huahuo.chat-local-draft-agent.v1>>> 这个标记';
      expect(
        projectChatLocalDraftUserPrompt(markerLikeUserText),
        markerLikeUserText,
      );
    });

    test('creation Canvas projection removes only its exact scope prefix', () {
      final snapshot = ChatLocalDraftSnapshot.create(
        kind: 'creation_canvas',
        content: '这段正文只提供给 Agent，不应该出现在用户气泡或标题中。',
        revision: 'revision-8',
      )!;
      const prompt = '请只调整结尾的表达';
      const scopedPrompt = '$creationCanvasChatScopeInstruction\n\n$prompt';
      final transportText = '$scopedPrompt\n\n${snapshot.toAgentTextPart()}';

      expect(
        projectChatLocalDraftUserPrompt(transportText),
        scopedPrompt,
        reason: 'the generic projector must not alter non-Canvas Chat scope',
      );
      expect(projectCreationCanvasChatUserPrompt(scopedPrompt), prompt);
      expect(projectCreationCanvasChatUserPrompt(transportText), prompt);

      final collapsedTitle = transportText.replaceAll(RegExp(r'\s+'), ' ');
      final boundedTitle = collapsedTitle.substring(0, 120);
      expect(projectCreationCanvasChatUserPrompt(boundedTitle), prompt);

      const nearMatch =
          '$creationCanvasChatScopeInstruction：请额外参考资料\n\n$prompt';
      expect(projectCreationCanvasChatUserPrompt(nearMatch), nearMatch);
    });

    test(
      'thread detail uses the first user message as its default title',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'thread': <String, Object?>{
                  'threadId': 'feed-history-1',
                  'title': '新会话',
                },
                'messages': <Object?>[
                  <String, Object?>{
                    'messageId': 'assistant-before-user',
                    'role': 'assistant',
                    'contentType': 'text',
                    'status': 'sent',
                    'textPreview': '欢迎使用',
                    'created_at': '2026-08-01T07:59:59Z',
                  },
                  <String, Object?>{
                    'messageId': 'first-user',
                    'role': 'user',
                    'contentType': 'text',
                    'status': 'sent',
                    'textPreview': '  请帮我   分析这次客户访谈  ',
                    'createdAt': '2026-08-01T08:00:00Z',
                  },
                  <String, Object?>{
                    'messageId': 'second-user',
                    'role': 'user',
                    'contentType': 'text',
                    'status': 'sent',
                    'textPreview': '第二条问题不能成为标题',
                    'createdAt': '2026-08-01T08:01:00Z',
                  },
                ],
              },
            },
          ),
        ]);

        final result = await _api(
          transport,
        ).getThreadDetail(threadId: 'feed-history-1');

        expect(result.ok, isTrue);
        expect(result.data?.thread.displayTitle, '请帮我 分析这次客户访谈');
        expect(
          result.data?.messages.first.createdAt,
          DateTime.utc(2026, 8, 1, 7, 59, 59),
        );
      },
    );

    test(
      'thread detail recovers its historical Agent from last request profile',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'thread': <String, Object?>{
                  'threadId': 'history-video-1',
                  'title': '视频复盘',
                },
                'lastRequestProfile': <String, Object?>{
                  'agentProfileId': 'video_analysis',
                  'skillProfileIds': <String>['video_analysis_advisor'],
                  'modelProfileId': 'server-owned-model',
                },
                'messages': <Object?>[],
              },
            },
          ),
        ]);

        final result = await _api(
          transport,
        ).getThreadDetail(threadId: 'history-video-1');

        expect(result.ok, isTrue);
        expect(result.data?.thread.agentProfileId, 'video_analysis');
      },
    );

    test('rejects malformed historical Agent provenance', () {
      final detail = parseChatThreadDetail(<String, Object?>{
        'thread': <String, Object?>{
          'threadId': 'history-invalid-agent-1',
          'title': '异常会话',
        },
        'lastRequestProfile': <String, Object?>{
          'agentProfileId': '../internal-agent',
        },
        'messages': <Object?>[],
      });

      expect(detail, isNull);
    });

    test(
      'thread detail recovers active Runs from top-level task summaries',
      () {
        final detail = parseChatThreadDetail(<String, Object?>{
          'thread': <String, Object?>{
            'threadId': 'history-active-task-1',
            'title': '仍在处理的会话',
          },
          'messages': <Object?>[],
          // The Backend returns task summaries newest-first.
          'tasks': <Object?>[
            <String, Object?>{
              'taskId': 'task-active-new',
              'threadId': 'history-active-task-1',
              'status': 'running',
              'agentRunId': 'agent_run_active_new',
            },
            <String, Object?>{
              'taskId': 'task-terminal',
              'threadId': 'history-active-task-1',
              'status': 'succeeded',
              'agentRunId': 'agent_run_terminal',
            },
            <String, Object?>{
              'taskId': 'legacy-task-without-run',
              'threadId': 'history-active-task-1',
              'status': 'queued',
            },
            <String, Object?>{
              'taskId': 'task-active-old',
              'threadId': 'history-active-task-1',
              'status': 'queued',
              'agentRunId': 'agent_run_active_old',
            },
          ],
        });

        expect(
          detail?.thread.activeRuns
              .map((run) => '${run.agentRunId}:${run.status}')
              .toList(),
          <String>[
            'agent_run_active_old:queued',
            'agent_run_active_new:running',
          ],
        );
      },
    );

    test('rejects a cross-thread active task Run binding', () {
      final detail = parseChatThreadDetail(<String, Object?>{
        'thread': <String, Object?>{
          'threadId': 'history-task-owner',
          'title': '当前会话',
        },
        'messages': <Object?>[],
        'tasks': <Object?>[
          <String, Object?>{
            'taskId': 'task-cross-thread',
            'threadId': 'different-thread',
            'status': 'running',
            'agentRunId': 'agent_run_cross_thread',
          },
        ],
      });

      expect(detail, isNull);
    });

    test(
      'retains a complete durable Assistant reply beyond the composer limit',
      () {
        final reply = _longPersonaReply();
        final detail = parseChatThreadDetail(<String, Object?>{
          'thread': <String, Object?>{
            'threadId': 'long-reply-thread',
            'scene': 'feed_ai',
            'status': 'active',
          },
          'messages': <Object?>[
            <String, Object?>{
              'messageId': 'long-reply-assistant',
              'threadId': 'long-reply-thread',
              'scene': 'feed_ai',
              'role': 'assistant',
              'contentType': 'text',
              'status': 'sent',
              'payload': <String, Object?>{'reply': reply},
            },
          ],
        });

        final assistant = detail?.messages.single;
        expect(assistant?.visibleText, reply);
        expect(assistant?.visibleText?.length, 20561);
        expect(
          assistant?.visibleText,
          endsWith(_longPersonaReplyFinalQuestion),
        );
      },
    );

    test(
      'retains a durable Assistant reply beyond the former 64 KiB ceiling',
      () {
        final reply = _longPersonaReply(length: 65537);
        final message = parseChatMessage(<String, Object?>{
          'messageId': 'unbounded-reply-assistant',
          'threadId': 'unbounded-reply-thread',
          'scene': 'feed_ai',
          'role': 'assistant',
          'contentType': 'text',
          'status': 'sent',
          'payload': <String, Object?>{'reply': reply},
        });

        expect(message?.visibleText, reply);
        expect(message?.visibleText?.length, 65537);
        expect(message?.visibleText, endsWith(_longPersonaReplyFinalQuestion));
      },
    );

    test('requires every declared Assistant Run identity to agree', () {
      final agreeing = parseChatMessage(<String, Object?>{
        'messageId': 'assistant-run-identity-1',
        'threadId': 'thread-run-identity-1',
        'scene': 'feed_ai',
        'role': 'assistant',
        'contentType': 'text',
        'status': 'succeeded',
        'taskId': 'public-task-1',
        'agentRunId': 'agent-run-1',
        'payload': <String, Object?>{
          'reply': '已完成',
          'agentRunId': 'agent-run-1',
          'runId': 'agent-run-1',
        },
      });
      expect(agreeing?.agentRunId, 'agent-run-1');
      expect(agreeing?.taskId, 'public-task-1');

      expect(
        parseChatMessage(<String, Object?>{
          'messageId': 'assistant-run-identity-malformed',
          'threadId': 'thread-run-identity-1',
          'scene': 'feed_ai',
          'role': 'assistant',
          'contentType': 'text',
          'status': 'succeeded',
          'agentRunId': 'agent-run-1',
          'payload': <String, Object?>{
            'reply': '已完成',
            'runId': 'unsafe run identity',
          },
        }),
        isNull,
      );
      expect(
        parseChatMessage(<String, Object?>{
          'messageId': 'assistant-run-identity-conflict',
          'threadId': 'thread-run-identity-1',
          'scene': 'feed_ai',
          'role': 'assistant',
          'contentType': 'text',
          'status': 'succeeded',
          'agentRunId': 'agent-run-1',
          'payload': <String, Object?>{
            'reply': '已完成',
            'agentRunId': 'agent-run-2',
          },
        }),
        isNull,
      );
    });

    test('parses canonical image Resources in durable chat history', () {
      final message = parseChatMessage(<String, Object?>{
        'messageId': 'image-history-1',
        'threadId': 'feed-image-1',
        'role': 'assistant',
        'contentType': 'text',
        'status': 'sent',
        'content': <Object?>[
          <String, Object?>{
            'type': 'image',
            'source': <String, Object?>{
              'kind': 'resource',
              'resourceId': 'resource-image-history-1',
            },
            'mimeType': 'image/png',
            'fileName': 'analysis.png',
          },
        ],
      }, fallbackScene: ChatScene.feedAi);

      expect(message?.contentType, ChatMessageContentType.text);
      expect(message?.imageAttachments, hasLength(1));
      expect(
        message?.imageAttachments.single.resourceId,
        'resource-image-history-1',
      );
      expect(message?.imageAttachments.single.mimeType, 'image/png');
      expect(message?.imageAttachments.single.displayName, 'analysis.png');
    });

    test(
      'parses only available generated image Resources from Assistant output',
      () {
        final message = parseChatMessage(<String, Object?>{
          'messageId': 'assistant-generated-image-1',
          'threadId': 'visual-thread-1',
          'role': 'assistant',
          'contentType': 'text',
          'status': 'succeeded',
          'payload': <String, Object?>{
            'reply': '这是为你生成的封面方向。',
            'attachments': <Object?>[
              <String, Object?>{
                'kind': 'image',
                'resourceId': 'resource-generated-cover-1',
                'displayName': 'cover.png',
                'mimeType': 'image/png',
                'availability': 'available',
              },
              <String, Object?>{
                'kind': 'image',
                'resourceId': 'resource-output-pending-1',
                'displayName': 'pending.png',
                'mimeType': 'image/png',
                'availability': 'pending',
              },
              <String, Object?>{
                'kind': 'image',
                'resourceId': 'https://provider.example/generated.png',
                'displayName': 'provider.png',
                'mimeType': 'image/png',
                'availability': 'available',
              },
              <String, Object?>{
                'kind': 'image',
                'resourceId': 'resource-unsupported-image-1',
                'displayName': 'output.svg',
                'mimeType': 'image/svg+xml',
                'availability': 'available',
              },
            ],
          },
        }, fallbackScene: ChatScene.feedAi);

        expect(message?.visibleText, '这是为你生成的封面方向。');
        expect(message?.imageAttachments, hasLength(1));
        expect(
          message?.imageAttachments.single.resourceId,
          'resource-generated-cover-1',
        );
        expect(message?.imageAttachments.single.displayName, 'cover.png');
        expect(message?.imageAttachments.single.mimeType, 'image/png');
      },
    );

    test('retains every public Assistant text and Resource output', () {
      final message = parseChatMessage(<String, Object?>{
        'messageId': 'assistant-complete-output-1',
        'threadId': 'assistant-complete-thread-1',
        'role': 'assistant',
        'contentType': 'text',
        'status': 'succeeded',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '第一段分析。'},
          <String, Object?>{'type': 'text', 'markdown': '第二段结论。'},
        ],
        'outputAttachments': <Object?>[
          <String, Object?>{
            'kind': 'image',
            'resourceId': 'resource-complete-image-1',
            'displayName': 'design.png',
            'mimeType': 'image/png',
            'sizeBytes': 2048,
            'availability': 'available',
          },
          <String, Object?>{
            'kind': 'file',
            'resourceId': 'resource-complete-file-1',
            'displayName': 'report.pdf',
            'mimeType': 'application/pdf',
            'sizeBytes': 4096,
            'availability': 'available',
          },
          <String, Object?>{
            'kind': 'audio',
            'resourceId': 'resource-complete-audio-1',
            'displayName': 'summary.m4a',
            'mimeType': 'audio/mp4',
            'sizeBytes': 8192,
            'availability': 'available',
          },
          <String, Object?>{
            'kind': 'video',
            'resourceId': 'resource-complete-video-1',
            'displayName': 'analysis.mp4',
            'mimeType': 'video/mp4',
            'sizeBytes': 16384,
            'availability': 'available',
          },
          <String, Object?>{
            'kind': 'image',
            'resourceId': 'resource-complete-vector-1',
            'displayName': 'diagram.svg',
            'mimeType': 'image/svg+xml',
            'sizeBytes': 1024,
            'availability': 'available',
          },
          <String, Object?>{
            'kind': 'file',
            'resourceId': 'resource-pending-file-1',
            'displayName': 'pending.pdf',
            'mimeType': 'application/pdf',
            'sizeBytes': 128,
            'availability': 'pending',
          },
        ],
      }, fallbackScene: ChatScene.feedAi);

      expect(message?.visibleText, '第一段分析。\n\n第二段结论。');
      expect(message?.imageAttachments, hasLength(1));
      expect(
        message?.imageAttachments.single.resourceId,
        'resource-complete-image-1',
      );
      expect(
        message?.resourceAttachments.map(
          (attachment) => (
            attachment.kind,
            attachment.resourceId,
            attachment.displayName,
            attachment.mimeType,
            attachment.sizeBytes,
          ),
        ),
        <Object?>[
          (
            ChatResourceAttachmentKind.file,
            'resource-complete-file-1',
            'report.pdf',
            'application/pdf',
            4096,
          ),
          (
            ChatResourceAttachmentKind.audio,
            'resource-complete-audio-1',
            'summary.m4a',
            'audio/mp4',
            8192,
          ),
          (
            ChatResourceAttachmentKind.video,
            'resource-complete-video-1',
            'analysis.mp4',
            'video/mp4',
            16384,
          ),
          (
            ChatResourceAttachmentKind.image,
            'resource-complete-vector-1',
            'diagram.svg',
            'image/svg+xml',
            1024,
          ),
        ],
      );
      expect(message?.hasVisibleContent, isTrue);
    });

    test('keeps a file-only Assistant projection visible', () {
      final message = parseChatMessage(<String, Object?>{
        'messageId': 'assistant-file-only-1',
        'threadId': 'assistant-file-thread-1',
        'role': 'assistant',
        'status': 'succeeded',
        'attachments': <Object?>[
          <String, Object?>{
            'kind': 'file',
            'resourceId': 'resource-file-only-1',
            'displayName': 'full-report.pdf',
            'mimeType': 'application/pdf',
            'sizeBytes': 12345,
            'availability': 'available',
          },
        ],
      }, fallbackScene: ChatScene.feedAi);

      expect(message?.contentType, ChatMessageContentType.file);
      expect(message?.visibleText, isNull);
      expect(message?.resourceAttachments, hasLength(1));
      expect(message?.hasVisibleContent, isTrue);
    });

    test(
      'keeps conversation history when legacy system task cards use new types',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'thread': <String, Object?>{
                  'threadId': 'feed-history-legacy-1',
                  'scene': 'self_media_creation_standard',
                  'purpose': 'self_media_creation_standard',
                },
                'messages': <Object?>[
                  <String, Object?>{
                    'messageId': 'legacy-task-card',
                    'role': 'system',
                    'messageType': 'task_status_v2',
                    'status': 'queued',
                  },
                  <String, Object?>{
                    'messageId': 'user-message-1',
                    'role': 'user',
                    'messageType': 'workspace_document',
                    'status': 'sent',
                    'content': <Object?>[
                      <String, Object?>{'type': 'text', 'text': '请继续'},
                      <String, Object?>{
                        'type': 'workspace_document',
                        'ownerId': 'note-1',
                      },
                    ],
                  },
                  <String, Object?>{
                    'messageId': 'assistant-message-1',
                    'role': 'assistant',
                    'messageType': 'markdown',
                    'status': 'succeeded',
                    'contentMarkdown': '**好的**',
                  },
                  <String, Object?>{
                    'messageId': 'reference-only-1',
                    'role': 'user',
                    'messageType': 'workspace_document',
                    'status': 'sent',
                  },
                  <String, Object?>{
                    'messageId': 'progress-projection-1',
                    'role': 'tool',
                    'messageType': 'agent_progress',
                    'status': 'running',
                  },
                ],
              },
            },
          ),
        ]);

        final result = await _api(
          transport,
        ).getThreadDetail(threadId: 'feed-history-legacy-1');

        expect(result.ok, isTrue);
        expect(result.data?.thread.purpose, ChatConversationPurpose.general);
        expect(
          result.data?.messages.map((message) => message.messageId),
          <String>['user-message-1', 'assistant-message-1'],
        );
        expect(result.data?.messages.first.visibleText, '请继续');
        expect(result.data?.messages.last.visibleText, '**好的**');
      },
    );

    test('sends a Feed AI voice resource with an idempotency header', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'messageId': 'voice-1',
                'contentType': 'voice',
              },
              'nextAction': <String, Object?>{
                'type': 'poll_asr',
                'asrTaskId': 'asr-1',
              },
            },
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.sendVoiceMessage(
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        audioResourceId: 'resource-1',
        durationSeconds: 12,
        contentLineId: 'line-1',
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.feed_ai.send_voice',
          businessEntityId: 'feed-1',
          localDraftId: 'voice-draft-1',
          scene: 'feed_ai',
          generateKey: _fixedVoiceKey,
        ),
      );

      expect(result.ok, isTrue);
      expect(result.data?.message.contentType, ChatMessageContentType.voice);
      expect(result.data?.nextAction.type, ChatNextActionType.pollAsr);
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/chat/threads/feed-1/voice-messages');
      expect(request.headers['X-Idempotency-Key'], 'idem-voice');
      expect(_body(request), <String, Object?>{
        'audioResourceId': 'resource-1',
        'durationSeconds': 12,
        'creativePositioningId': 'line-1',
      });
    });

    test(
      'sends exact HNote and completed Resource references in canonical order',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'message': <String, Object?>{
                  'messageId': 'message-context-1',
                  'contentType': 'text',
                },
                'acceptedContext': <String, Object?>{
                  'schemaVersion': 'huahuo.chat-context.v1',
                  'purpose': 'persona',
                  'references': <Object?>[
                    <String, Object?>{
                      'type': 'material',
                      'id': 'material-1',
                      'revision': 'revision-2',
                    },
                    <String, Object?>{'type': 'file', 'id': 'resource-alpha'},
                    <String, Object?>{'type': 'file', 'id': 'resource-beta'},
                  ],
                },
              },
            },
          ),
        ]);
        final context = ChatContextEnvelope.create(
          purpose: ChatContextPurpose.persona,
          entryPoint: const ChatContextEntryPoint(
            surface: 'workbench_chat',
            entityType: 'skill',
            entityId: 'persona',
          ),
          references: const <ChatContextReference>[
            ChatContextReference(
              type: ChatContextReferenceType.material,
              id: 'material-1',
              revision: 'revision-2',
            ),
            ChatContextReference(
              type: ChatContextReferenceType.material,
              id: 'material-1',
            ),
            ChatContextReference(
              type: ChatContextReferenceType.file,
              id: 'resource-alpha',
            ),
            ChatContextReference(
              type: ChatContextReferenceType.file,
              id: 'resource-beta',
            ),
          ],
          includeAccountProfile: true,
        );
        expect(context?.references, hasLength(3));

        final result = await _api(transport).sendTextMessage(
          threadId: 'feed-1',
          scene: ChatScene.feedAi,
          content: '只发送用户原文',
          context: context,
          idempotency: const IdempotencyRequestContext(
            operation: 'chat.feed_ai.send_text',
            generateKey: _fixedSendKey,
          ),
        );

        expect(result.ok, isTrue);
        expect(
          result.data?.acceptedContext?.purpose,
          ChatContextPurpose.persona,
        );
        final body = _body(transport.requests.single);
        expect(body['input'], <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '只发送用户原文'},
            <String, Object?>{
              'type': 'workspace_document',
              'source': <String, Object?>{
                'kind': 'workspace_document',
                'ownerRef': <String, Object?>{
                  'kind': 'hnote',
                  'id': 'material-1',
                },
                'part': 'raw',
                'partRevisionId': 'revision-2',
              },
              'usage': 'reference',
            },
            <String, Object?>{
              'type': 'file',
              'source': <String, Object?>{
                'kind': 'resource',
                'resourceId': 'resource-alpha',
              },
              'usage': 'reference',
            },
            <String, Object?>{
              'type': 'file',
              'source': <String, Object?>{
                'kind': 'resource',
                'resourceId': 'resource-beta',
              },
              'usage': 'reference',
            },
          ],
        });
        expect(body['agentProfileId'], 'renshe_content');
        expect(body, isNot(contains('skillProfileIds')));
        expect(body, isNot(contains('modelProfileId')));
        expect(body, isNot(contains('creativePositioningId')));
        expect(body, isNot(contains('expectedMetaWorkspaceKey')));
        expect(body, isNot(contains('context')));
        expect(body, isNot(contains('scene')));
        expect(jsonEncode(body), isNot(contains('access-token')));
      },
    );

    test('blocks an unselectable profile before message transport', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[]);
      final result =
          await _api(
            transport,
            catalog: const _TestChatAgentCatalog(
              agentProfileIds: <String>{'self_media_creation'},
            ),
          ).sendTextMessage(
            threadId: 'feed-1',
            scene: ChatScene.feedAi,
            content: '不能静默丢上下文',
            context: ChatContextEnvelope.create(
              purpose: ChatContextPurpose.deepPositioning,
              includeAccountProfile: true,
            ),
            idempotency: const IdempotencyRequestContext(
              operation: 'chat.feed_ai.send_text',
              generateKey: _fixedSendKey,
            ),
          );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'AGENT_PROFILE_NOT_SELECTABLE');
      expect(
        chatTextSubmissionFailureDisposition(result),
        ChatSubmissionFailureDisposition.knownRejected,
      );
      expect(transport.requests, isEmpty);
    });

    test('maps lead chat to the published huoke capability', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'messageId': 'message-lead-1',
                'contentType': 'text',
              },
            },
          },
        ),
      ]);

      final result = await _api(transport).sendTextMessage(
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        content: '生成一条获客内容',
        context: ChatContextEnvelope.create(purpose: ChatContextPurpose.lead),
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.feed_ai.send_text',
          generateKey: _fixedSendKey,
        ),
      );

      expect(result.ok, isTrue);
      final body = _body(transport.requests.single);
      expect(body['agentProfileId'], 'huoke_content');
      expect(body, isNot(contains('skillProfileIds')));
      expect(body, isNot(contains('modelProfileId')));
      expect(body, isNot(contains('expectedMetaWorkspaceKey')));
    });

    test(
      'maps book writing, positioning, and media stages to public profiles',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          for (var index = 0; index < 5; index++)
            ApiTransportResponse(
              status: 200,
              body: <String, Object?>{
                'success': true,
                'data': <String, Object?>{
                  'agentRunId': 'agent-run-profile-$index',
                },
              },
            ),
        ]);
        final api = _api(transport);

        for (final purpose in <ChatContextPurpose>[
          ChatContextPurpose.masterpiece,
          ChatContextPurpose.deepPositioning,
          ChatContextPurpose.socialPositioning,
          ChatContextPurpose.visualDesign,
          ChatContextPurpose.videoAnalysis,
        ]) {
          final result = await api.sendTextMessage(
            threadId: 'feed-1',
            scene: ChatScene.feedAi,
            content: '请继续帮助我梳理方向',
            context: ChatContextEnvelope.create(purpose: purpose),
            idempotency: const IdempotencyRequestContext(
              operation: 'chat.feed_ai.send_text',
              generateKey: _fixedSendKey,
            ),
          );
          expect(result.ok, isTrue);
        }

        final bodies = transport.requests.map(_body).toList(growable: false);
        const expectedProfiles = <String>[
          'book_writing',
          'positioning_lv1',
          'positioning_lv2',
          'visual_chat',
          'video_analysis',
        ];
        for (var index = 0; index < bodies.length; index++) {
          expect(bodies[index], <String, Object?>{
            'agentProfileId': expectedProfiles[index],
            'input': <String, Object?>{
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': '请继续帮助我梳理方向'},
              ],
            },
          });
        }
      },
    );

    test('requires a public Run receipt for positioning chat', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'messageId': 'positioning-message-1',
                'contentType': 'text',
              },
            },
          },
        ),
      ]);

      final result = await _api(transport).sendTextMessage(
        threadId: 'positioning-thread-1',
        scene: ChatScene.workAi,
        content: '请根据问卷生成定位报告',
        context: ChatContextEnvelope.create(
          purpose: ChatContextPurpose.deepPositioning,
        ),
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.work_ai.send_text',
          generateKey: _fixedSendKey,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'CHAT_AGENT_RUN_RECEIPT_REQUIRED');
      expect(
        chatTextSubmissionFailureDisposition(result),
        ChatSubmissionFailureDisposition.outcomeUnknown,
      );
    });

    test(
      'does not call purpose-specific message transport when catalog fails',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[]);
        final result =
            await _api(
              transport,
              catalog: _TestChatAgentCatalog(
                failure: chatApiFailure('CATALOG_DOWN', retryable: true),
              ),
            ).sendTextMessage(
              threadId: 'feed-1',
              scene: ChatScene.feedAi,
              content: '目录不可用时不能发送',
              context: ChatContextEnvelope.create(
                purpose: ChatContextPurpose.persona,
              ),
              idempotency: const IdempotencyRequestContext(
                operation: 'chat.feed_ai.send_text',
                generateKey: _fixedSendKey,
              ),
            );

        expect(result.ok, isFalse);
        expect(result.error?.code, 'CATALOG_DOWN');
        expect(transport.requests, isEmpty);
      },
    );

    test('does not serialize a Skill selector for persona chat', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'messageId': 'persona-message-1',
                'contentType': 'text',
              },
            },
          },
        ),
      ]);
      final result = await _api(transport).sendTextMessage(
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        content: '生成我的人设内容',
        context: ChatContextEnvelope.create(
          purpose: ChatContextPurpose.persona,
        ),
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.feed_ai.send_text',
          generateKey: _fixedSendKey,
        ),
      );

      expect(result.ok, isTrue);
      final body = _body(transport.requests.single);
      expect(body['agentProfileId'], 'renshe_content');
      expect(body, isNot(contains('skillProfileIds')));
    });

    test('derives agent-run and thread polling from accepted mutations', () {
      final runMutation = parseChatTextMutation(
        <String, Object?>{
          'userMessage': <String, Object?>{
            'messageId': 'message-run-1',
            'contentType': 'text',
          },
          'run': <String, Object?>{'agentRunId': 'agent-run-1'},
        },
        fallbackThreadId: 'feed-1',
        fallbackScene: ChatScene.feedAi,
      );
      final threadMutation = parseChatTextMutation(
        <String, Object?>{
          'userMessage': <String, Object?>{
            'messageId': 'message-thread-1',
            'contentType': 'text',
          },
        },
        fallbackThreadId: 'feed-1',
        fallbackScene: ChatScene.feedAi,
      );
      final minimalRunReceipt = parseChatTextMutation(
        <String, Object?>{
          'agentRunId': 'agent-run-minimal-1',
          'taskId': 'task-minimal-1',
          'threadId': 'feed-1',
          'messageId': 'message-minimal-1',
          'status': 'sent',
        },
        fallbackThreadId: 'feed-1',
        fallbackScene: ChatScene.feedAi,
      );
      final taskScopedRunReceipt = parseChatTextMutation(
        <String, Object?>{
          'userMessage': <String, Object?>{
            'messageId': 'message-task-scoped-run-1',
            'contentType': 'text',
          },
          'task': <String, Object?>{'agentRunId': 'agent-run-task-scoped-1'},
          'nextAction': <String, Object?>{
            'type': 'poll_task',
            'taskId': 'task-1',
          },
        },
        fallbackThreadId: 'feed-1',
        fallbackScene: ChatScene.feedAi,
      );

      expect(runMutation?.nextAction.type, ChatNextActionType.pollAgentRun);
      expect(runMutation?.nextAction.agentRunId, 'agent-run-1');
      expect(threadMutation?.nextAction.type, ChatNextActionType.pollThread);
      expect(minimalRunReceipt?.message, isNull);
      expect(minimalRunReceipt?.nextAction.agentRunId, 'agent-run-minimal-1');
      expect(minimalRunReceipt?.nextAction.taskId, 'task-minimal-1');
      expect(minimalRunReceipt?.receiptThreadId, 'feed-1');
      expect(minimalRunReceipt?.receiptMessageId, 'message-minimal-1');
      expect(minimalRunReceipt?.receiptStatus, 'sent');
      expect(
        taskScopedRunReceipt?.nextAction.type,
        ChatNextActionType.pollAgentRun,
      );
      expect(
        taskScopedRunReceipt?.nextAction.agentRunId,
        'agent-run-task-scoped-1',
      );
    });

    test(
      'retains a scoped production Agent Run receipt beyond chat ID width',
      () {
        final agentRunId =
            'agent_run_user_${List<String>.filled(64, 'a').join()}'
            '_workspace_chat_workspace_chat_run_0123456789abcdef';
        final mutation = parseChatTextMutation(
          <String, Object?>{
            'message': <String, Object?>{
              'messageId': 'message-long-run-1',
              'contentType': 'text',
            },
            'agentRunId': agentRunId,
            'taskId': 'task-long-run-1',
            'nextAction': <String, Object?>{
              'type': 'poll_task',
              'taskId': 'task-long-run-1',
            },
          },
          fallbackThreadId: 'feed-1',
          fallbackScene: ChatScene.feedAi,
        );

        expect(agentRunId.length, greaterThan(128));
        expect(mutation?.nextAction.type, ChatNextActionType.pollAgentRun);
        expect(mutation?.nextAction.agentRunId, agentRunId);
        expect(mutation?.nextAction.taskId, 'task-long-run-1');
      },
    );

    test('reads Position LV1 reports from payload content compatibility', () {
      final message = parseChatMessage(<String, Object?>{
        'messageId': 'assistant-positioning-1',
        'threadId': 'thread-positioning-1',
        'role': 'assistant',
        'contentType': 'text',
        'status': 'sent',
        'payload': <String, Object?>{
          'taskId': 'task-positioning-1',
          'agentRunId': 'agent_run_positioning_1',
          'content': '## 正式定位报告',
        },
      }, fallbackScene: ChatScene.workAi);

      expect(message?.visibleText, '## 正式定位报告');
      expect(message?.taskId, 'task-positioning-1');
      expect(message?.agentRunId, 'agent_run_positioning_1');
    });

    test('keeps agent-run verification when an assistant is projected', () {
      final mutation = parseChatTextMutation(
        <String, Object?>{
          'userMessage': <String, Object?>{
            'messageId': 'message-run-projected-1',
            'contentType': 'text',
          },
          'assistantMessage': <String, Object?>{
            'messageId': 'assistant-run-projected-1',
            'role': 'assistant',
            'contentType': 'text',
            'status': 'sent',
            'textPreview': '尚未验证的响应投影',
          },
          'nextAction': <String, Object?>{
            'type': 'poll_agent_run',
            'agentRunId': 'agent-run-projected-1',
          },
        },
        fallbackThreadId: 'feed-1',
        fallbackScene: ChatScene.feedAi,
      );

      expect(mutation?.nextAction.type, ChatNextActionType.pollAgentRun);
      expect(mutation?.nextAction.agentRunId, 'agent-run-projected-1');
    });

    test(
      'reads a terminal agent run through the formal API 19 route',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'agentRunId': 'agent-run-1',
                'workspaceId': 'workspace-1',
                'threadId': 'feed-1',
                'status': 'succeeded',
                'workspaceVersion': 3,
                'workspaceBindingVersion': 2,
                'contextGeneration': 4,
                'result': <String, Object?>{
                  'finalAnswer': '持久化回答',
                  'assistantMessageId': 'assistant-1',
                  'completionMode': 'normal',
                },
                'usage': <String, Object?>{
                  'measurementStatus': 'unavailable',
                  'inputTokens': null,
                  'outputTokens': null,
                  'imageCount': null,
                  'videoSeconds': null,
                  'accountedCredits': null,
                  'policyVersion': null,
                },
                'toolTrace': <Object?>[],
                'createdAt': '2026-08-07T08:00:00Z',
                'updatedAt': '2026-08-07T08:00:02Z',
              },
            },
          ),
        ]);

        final result = await RemoteProjectAssistantRuntime(
          _client(transport),
        ).readRun(handle: const AssistantRunHandle('agent-run-1'));

        expect(result.ok, isTrue);
        expect(result.data?.status, AssistantRunStatus.succeeded);
        expect(
          result.data?.completionQuality,
          AssistantCompletionQuality.normal,
        );
        expect(result.data?.output?.messageId, 'assistant-1');
        expect(transport.requests.single.method, 'GET');
        expect(
          transport.requests.single.url.path,
          '/api/v1/agent/runs/agent-run-1',
        );
      },
    );

    test('parses the canonical voiceMessage response member', () {
      final mutation = parseChatVoiceMutation(
        <String, Object?>{
          'voiceMessage': <String, Object?>{
            'messageId': 'voice-canonical-1',
            'contentType': 'voice',
          },
          'nextAction': <String, Object?>{
            'type': 'poll_asr',
            'asrTaskId': 'asr-canonical-1',
          },
        },
        fallbackThreadId: 'feed-1',
        fallbackScene: ChatScene.feedAi,
      );

      expect(mutation?.message.messageId, 'voice-canonical-1');
      expect(mutation?.nextAction.type, ChatNextActionType.pollAsr);
      expect(mutation?.nextAction.asrTaskId, 'asr-canonical-1');
    });

    test('normalizes legacy and Agent Profile scenes on create', () {
      final thread = parseCreateChatThread(
        <String, Object?>{
          'thread': <String, Object?>{
            'threadId': 'thread-legacy-scene',
            'scene': 'work_ai',
          },
        },
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.deepPositioning,
      );
      final agentProfileThread = parseCreateChatThread(<String, Object?>{
        'thread': <String, Object?>{
          'threadId': 'thread-agent-profile-scene',
          'scene': 'self_media_creation_standard',
        },
      }, scene: ChatScene.feedAi);

      expect(thread, isNotNull);
      expect(thread?.scene, ChatScene.feedAi);
      expect(thread?.purpose, ChatConversationPurpose.deepPositioning);
      expect(agentProfileThread?.scene, ChatScene.feedAi);
    });

    test(
      'rejects an invalid voice resource or duration before transport',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[]);
        final api = _api(transport);

        final resourceResult = await api.sendVoiceMessage(
          threadId: 'feed-1',
          scene: ChatScene.feedAi,
          audioResourceId: 'not a safe resource',
          durationSeconds: 12,
          idempotency: const IdempotencyRequestContext(
            operation: 'chat.feed_ai.send_voice',
          ),
        );
        final durationResult = await api.sendVoiceMessage(
          threadId: 'feed-1',
          scene: ChatScene.feedAi,
          audioResourceId: 'resource-1',
          durationSeconds: 0,
          idempotency: const IdempotencyRequestContext(
            operation: 'chat.feed_ai.send_voice',
          ),
        );

        expect(resourceResult.error?.code, 'CHAT_VOICE_RESOURCE_ID_INVALID');
        expect(durationResult.error?.code, 'CHAT_VOICE_DURATION_INVALID');
        expect(transport.requests, isEmpty);
      },
    );

    test('rejects a malformed text mutation response', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'messageId': 'not a safe id',
                'contentType': 'text',
              },
            },
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.sendTextMessage(
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        content: '正常问题',
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.feed_ai.send_text',
          businessEntityId: 'feed-1',
          localDraftId: 'draft-1',
          scene: 'feed_ai',
          generateKey: _fixedSendKey,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'API_MALFORMED_ENVELOPE');
      expect(
        chatTextSubmissionFailureDisposition(result),
        ChatSubmissionFailureDisposition.outcomeUnknown,
      );
    });
    test('rejects a text response for a voice mutation', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'messageId': 'text-1',
                'contentType': 'text',
              },
            },
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.sendVoiceMessage(
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        audioResourceId: 'resource-1',
        durationSeconds: 12,
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.feed_ai.send_voice',
          generateKey: _fixedVoiceKey,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'API_MALFORMED_ENVELOPE');
    });

    test('rejects an unsafe thread identifier in a voice response', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'messageId': 'voice-1',
                'threadId': 'file:///private/thread',
                'contentType': 'voice',
              },
            },
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.sendVoiceMessage(
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        audioResourceId: 'resource-1',
        durationSeconds: 12,
        idempotency: const IdempotencyRequestContext(
          operation: 'chat.feed_ai.send_voice',
          generateKey: _fixedVoiceKey,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'API_MALFORMED_ENVELOPE');
    });
  });
}

String _fixedCreateKey() => 'idem-create';
String _fixedSendKey() => 'idem-send';
String _fixedVoiceKey() => 'idem-voice';

RemoteProjectChatRepository _api(
  _QueueTransport transport, {
  ChatAgentCatalogPort catalog = const _TestChatAgentCatalog(),
}) {
  return RemoteProjectChatRepository(
    apiClient: _client(transport),
    agentCatalog: catalog,
  );
}

ApiClient _client(_QueueTransport transport) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: '0.1.0',
      deviceId: 'device-1',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: () => 'access-token',
      traceIdFactory: () => 'trace-chat-api',
    ),
    transport: transport,
  );
}

Map<String, Object?> _body(ApiTransportRequest request) {
  final decoded = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this._responses);

  final List<ApiTransportResponse> _responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}

final class _TestChatAgentCatalog implements ChatAgentCatalogPort {
  const _TestChatAgentCatalog({
    this.agentProfileIds = const <String>{
      'self_media_creation',
      'self_media_creation_standard',
      'book_writing',
      'renshe_content',
      'huoke_content',
      'visual_chat',
      'positioning_lv1',
      'positioning_lv2',
      'video_analysis',
    },
    this.failure,
  });

  final Set<String> agentProfileIds;
  final AppFailure? failure;

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() async {
    final catalogFailure = failure;
    if (catalogFailure != null) {
      return ApiResult<AgentProfileCatalog>.failure(
        error: catalogFailure,
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return ApiResult<AgentProfileCatalog>.success(
      data: AgentProfileCatalog(
        catalogVersion: 'catalog-test-v1',
        items: <AgentProfileCatalogItem>[
          for (final id in agentProfileIds)
            AgentProfileCatalogItem(agentProfileId: id, displayName: id),
        ],
      ),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) async {
    return ApiResult<List<SkillProfileCatalogItem>>.success(
      data: const <SkillProfileCatalogItem>[],
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}
