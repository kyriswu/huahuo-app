import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test('parses the deployed subscription catalog list wire', () {
    final publication =
        SharedSubscriptionPublication.fromJson(const <String, Object?>{
          'publicationId': 'publication-1',
          'title': '知识日报',
          'description': '来自正式目录的描述',
          'coverResourceId': 'resource-cover-1',
          'lifecycle': 'active',
          'updatedAt': '2026-08-17T08:00:00Z',
        });
    final section = SharedSubscriptionSection.fromJson(const <String, Object?>{
      'sectionId': 'section-1',
      'publicationId': 'publication-1',
      'parentSectionId': null,
      'title': '栏目',
      'ordinal': 2,
      'lifecycle': 'active',
    });
    final legacySection =
        SharedSubscriptionSection.fromJson(const <String, Object?>{
          'sectionId': 'section-legacy',
          'publicationId': 'publication-1',
          'title': '兼容栏目',
          'sortOrder': 3,
        });
    final article = SharedSubscriptionArticle.fromJson(const <String, Object?>{
      'articleId': 'article-1',
      'publicationId': 'publication-1',
      'title': '目录文章',
      'summary': '文章摘要',
      'currentArticleRevisionId': 'article-revision-1',
      'lifecycle': 'active',
    });

    expect(publication.summary, '来自正式目录的描述');
    expect(publication.coverResourceId, 'resource-cover-1');
    expect(publication.lifecycle, 'active');
    expect(publication.sectionCount, isNull);
    expect(section.sortOrder, 2);
    expect(section.parentSectionId, isNull);
    expect(legacySection.sortOrder, 3);
    expect(article.publishedAt, isNull);
    expect(article.lifecycle, 'active');
  });

  test('parses the retained SMS login contract', () {
    final session = SharedAuthSession.fromJson(const <String, Object?>{
      'accessToken': 'access-1',
      'refreshToken': 'refresh-1',
      'user': <String, Object?>{'userId': 'user-1', 'displayName': 'Hua Huo'},
      'onboardingRequired': false,
      'workspaceStatus': 'ready',
      'defaultContentLineId': 'positioning-1',
    });

    expect(session.tokens.accessToken, 'access-1');
    expect(session.user.userId, 'user-1');
    expect(session.workspaceStatus, 'ready');
  });

  test('parses the fixed nested login Workspace projection', () {
    final session = SharedAuthSession.fromJson(const <String, Object?>{
      'accessToken': 'access-1',
      'refreshToken': 'refresh-1',
      'user': <String, Object?>{'userId': 'user-1'},
      'onboardingRequired': false,
      'workspace': <String, Object?>{
        'workspaceId': 'workspace-1',
        'status': 'ready',
      },
    });

    expect(session.workspaceId, 'workspace-1');
    expect(session.workspaceStatus, 'ready');
  });

  test('parses the formal HNote contract and opaque cursor', () {
    final note = SharedHNote.fromJson(<String, Object?>{
      'noteId': 'note-1',
      'workspaceId': 'ws-1',
      'folderId': null,
      'sourceKind': 'recording',
      'sourceRef': <String, Object?>{
        'kind': 'recording',
        'id': 'recording-1',
        'revisionId': 'recording-revision-1',
      },
      'title': 'Interview notes',
      'state': 'active',
      'noteRevisionId': 'note-rev-1',
      'parts': <String, Object?>{
        for (final part in <String>['raw', 'outline', 'germination'])
          part: <String, Object?>{
            'partRevisionId': '$part-rev-1',
            'markdown': part == 'raw' ? '# Interview notes\n' : '',
            'contentHash': '$part-hash',
          },
      },
      'resourceRefs': <Object?>[
        <String, Object?>{
          'resourceId': 'res-image',
          'order': 0,
          'usage': 'inline_image',
          'anchor': 'raw:block-2',
          'alt': 'diagram',
          'sha256': 'abc123',
          'mimeType': 'image/png',
        },
      ],
      'etag': '"note-1"',
      'contentCursor': '184',
      'createdAt': '2026-08-17T07:46:58Z',
      'updatedAt': '2026-08-17T07:47:01Z',
    });

    expect(note.raw.markdown, startsWith('# Interview'));
    expect(note.sourceKind, 'recording');
    expect(note.sourceRef?.kind, 'recording');
    expect(note.sourceRef?.id, 'recording-1');
    expect(note.sourceRef?.revisionId, 'recording-revision-1');
    expect(note.resourceRefs.single.resourceId, 'res-image');
    expect(note.contentCursor, '184');
    expect(note.activeDerivedTasks, isNull);
    expect(note.createdAt, DateTime.utc(2026, 8, 17, 7, 46, 58));
    expect(note.updatedAt, DateTime.utc(2026, 8, 17, 7, 47, 1));
  });

  test('parses only public HNote active derived-task projections', () {
    final note = SharedHNote.fromJson(<String, Object?>{
      'noteId': 'note-1',
      'folderId': null,
      'title': 'Interview notes',
      'state': 'active',
      'noteRevisionId': 'note-rev-1',
      'parts': <String, Object?>{
        for (final part in <String>['raw', 'outline', 'germination'])
          part: <String, Object?>{
            'partRevisionId': '$part-rev-1',
            'markdown': '',
            'contentHash': '$part-hash',
          },
      },
      'resourceRefs': const <Object?>[],
      'etag': '"note-1"',
      'contentCursor': '184',
      'activeDerivedTasks': const <Object?>[
        <String, Object?>{
          'fileAgentRunId': 'file_agent_run_1',
          'agentRunId': 'agent_run_1',
          'stage': 'outline',
          'status': 'running',
        },
        <String, Object?>{
          'fileAgentRunId': 'file_agent_run_2',
          'stage': 'outline',
          'status': 'retry_wait',
        },
        <String, Object?>{
          'fileAgentRunId': 'file_agent_run_3',
          'stage': 'sprout',
          'status': 'retry_admitting',
        },
      ],
    });

    expect(note.activeDerivedTasks, hasLength(3));
    expect(note.activeDerivedTasks!.first.stage, 'outline');
    expect(note.activeDerivedTasks!.first.agentRunId, 'agent_run_1');
    expect(note.activeDerivedTasks!.map((task) => task.status), <String>[
      'running',
      'retry_wait',
      'retry_admitting',
    ]);
  });

  test('rejects unsafe HNote active derived-task projections', () {
    final json = <String, Object?>{
      'noteId': 'note-1',
      'folderId': null,
      'title': 'Interview notes',
      'state': 'active',
      'noteRevisionId': 'note-rev-1',
      'parts': <String, Object?>{
        for (final part in <String>['raw', 'outline', 'germination'])
          part: <String, Object?>{
            'partRevisionId': '$part-rev-1',
            'markdown': '',
            'contentHash': '$part-hash',
          },
      },
      'resourceRefs': const <Object?>[],
      'etag': '"note-1"',
      'contentCursor': '184',
      'activeDerivedTasks': const <Object?>[
        <String, Object?>{
          'fileAgentRunId': '../private',
          'stage': 'outline',
          'status': 'running',
        },
      ],
    };

    expect(() => SharedHNote.fromJson(json), throwsFormatException);

    json['activeDerivedTasks'] = const <Object?>[
      <String, Object?>{
        'fileAgentRunId': 'file_agent_run_1',
        'stage': 'outline',
        'status': 'retrying',
      },
    ];
    expect(() => SharedHNote.fromJson(json), throwsFormatException);
  });

  test('parses deployed flat HNote heads and deployed part wire aliases', () {
    final note = SharedHNote.fromJson(const <String, Object?>{
      'noteId': 'note-1',
      'workspaceId': 'ws-1',
      'folderId': null,
      'title': 'Interview notes',
      'state': 'live',
      'noteRevisionId': 'note-rev-1',
      'rawPartRevisionId': 'raw-rev-1',
      'outlinePartRevisionId': 'outline-rev-1',
      'germinationPartRevisionId': 'germination-rev-1',
      'resourceRefs': <Object?>[],
      'etag': '"note-1"',
      'contentCursor': '184',
    });
    final part = SharedHNotePartView.fromJson(const <String, Object?>{
      'noteId': 'note-1',
      'part': 'outline',
      'partRevisionId': 'outline-rev-2',
      'contentMarkdown': '# 纲要',
      'contentSha256': 'sha256:outline',
      'etag': '"outline-2"',
    });

    expect(note.outline.partRevisionId, 'outline-rev-1');
    expect(note.sourceKind, isNull);
    expect(note.outline.markdown, isEmpty);
    expect(part.markdown, '# 纲要');
    expect(part.contentHash, 'sha256:outline');
  });

  test('parses a raw-only flat HNote head before derived Parts exist', () {
    final note = SharedHNote.fromJson(const <String, Object?>{
      'noteId': 'note-raw-only-1',
      'workspaceId': 'ws-1',
      'folderId': null,
      'title': 'Recording transcript',
      'state': 'live',
      'noteRevisionId': 'note-rev-raw-only-1',
      'rawPartRevisionId': 'raw-rev-raw-only-1',
      'outlinePartRevisionId': '',
      'resourceRefs': <Object?>[],
      'etag': '"note-raw-only-1"',
      'contentCursor': '185',
    });

    expect(note.raw.partRevisionId, 'raw-rev-raw-only-1');
    expect(note.outline.partRevisionId, isEmpty);
    expect(note.outline.markdown, isEmpty);
    expect(note.outline.contentHash, isEmpty);
    expect(note.germination.partRevisionId, isEmpty);
    expect(note.germination.markdown, isEmpty);
    expect(note.germination.contentHash, isEmpty);
  });

  test('parses deployed aliases inside a hydrated HNote parts object', () {
    final note = SharedHNote.fromJson(<String, Object?>{
      'noteId': 'note-2',
      'workspaceId': 'ws-1',
      'folderId': null,
      'title': 'Hydrated recording',
      'state': 'live',
      'noteRevisionId': 'note-rev-2',
      'parts': <String, Object?>{
        for (final part in <String>['raw', 'outline', 'germination'])
          part: <String, Object?>{
            'partRevisionId': '$part-rev-2',
            'contentMarkdown': part == 'raw' ? '逐字稿' : '',
            'contentSha256': 'sha256:$part',
          },
      },
      'resourceRefs': const <Object?>[],
      'etag': '"note-2"',
      'contentCursor': '185',
    });

    expect(note.raw.markdown, '逐字稿');
    expect(note.outline.contentHash, 'sha256:outline');
  });

  test('parses an HNote mutation receipt with exact part revisions', () {
    final receipt = SharedHNoteMutationReceipt.fromJson(const <String, Object?>{
      'noteId': 'note-1',
      'noteRevisionId': 'note-rev-2',
      'parts': <String, Object?>{
        'raw': <String, Object?>{'partRevisionId': 'raw-rev-2'},
        'outline': <String, Object?>{'partRevisionId': 'outline-rev-2'},
        'germination': <String, Object?>{'partRevisionId': 'germination-rev-2'},
      },
      'etag': '"note-2"',
      'contentCursor': '185',
    });

    expect(receipt.rawPartRevisionId, 'raw-rev-2');
    expect(receipt.germinationPartRevisionId, 'germination-rev-2');
  });

  test('serializes canonical AgentInput without local identifiers', () {
    const scopedMarkdown = '  # 标题\n\n正文\n';
    final input = SharedAgentInput(
      content: <SharedAgentInputContent>[
        SharedAgentTextContent(text: '整理这份材料'),
        SharedAgentTextContent(text: scopedMarkdown),
        SharedAgentResourceContent(type: 'image', resourceId: 'resource-1'),
        SharedAgentWorkspaceDocumentContent(
          ownerKind: 'hnote',
          ownerId: 'note-1',
          part: 'raw',
          partRevisionId: 'raw-rev-2',
        ),
      ],
    ).toJson();

    expect(input['content'], hasLength(4));
    final content = input['content']! as List<Object?>;
    expect((content[1] as Map<String, Object?>)['text'], scopedMarkdown);
    expect(input.toString(), isNot(contains('/Users/')));
    expect(
      () => SharedAgentWorkspaceDocumentContent(
        ownerKind: 'hnote',
        ownerId: '/Users/private.md',
        part: 'raw',
        partRevisionId: 'raw-rev-2',
      ),
      throwsArgumentError,
    );
  });

  test('serializes the shared public Chat request envelopes', () {
    expect(const SharedChatThreadCreateRequest().toJson(), isEmpty);
    expect(
      const SharedChatThreadCreateRequest(
        workspaceId: 'workspace-1',
        scene: 'self_media_creation_standard',
        creativePositioningId: 'positioning-1',
      ).toJson(),
      <String, Object?>{
        'workspaceId': 'workspace-1',
        'scene': 'self_media_creation_standard',
        'creativePositioningId': 'positioning-1',
      },
    );

    final message = SharedChatTextMessageRequest(
      agentProfileId: 'positioning_lv1',
      modelProfileId: '  deepseek-v4-flash-vision  ',
      content: <SharedAgentInputContent>[
        SharedAgentTextContent(text: '分析这份素材'),
        SharedAgentWorkspaceDocumentContent(
          ownerKind: 'hnote',
          ownerId: 'note-1',
          part: 'raw',
          partRevisionId: 'raw-rev-1',
        ),
        SharedAgentResourceContent(
          type: 'file',
          resourceId: 'resource-1',
          usage: 'reference',
        ),
      ],
    ).toJson();

    expect(message.keys, <String>{'agentProfileId', 'modelProfileId', 'input'});
    expect(message['agentProfileId'], 'positioning_lv1');
    expect(message['modelProfileId'], 'deepseek-v4-flash-vision');
    final input = message['input']! as Map<String, Object?>;
    expect(input.keys, <String>{'content'});
    expect(input['content'], <Object?>[
      <String, Object?>{'type': 'text', 'text': '分析这份素材'},
      <String, Object?>{
        'type': 'workspace_document',
        'source': <String, Object?>{
          'kind': 'workspace_document',
          'ownerRef': <String, Object?>{'kind': 'hnote', 'id': 'note-1'},
          'part': 'raw',
          'partRevisionId': 'raw-rev-1',
        },
        'usage': 'reference',
      },
      <String, Object?>{
        'type': 'file',
        'source': <String, Object?>{
          'kind': 'resource',
          'resourceId': 'resource-1',
        },
        'usage': 'reference',
      },
    ]);
    expect(message, isNot(contains('skillProfileIds')));
    expect(message, isNot(contains('runtimeConfigId')));
    expect(message, isNot(contains('inputManifest')));
    expect(message, isNot(contains('plan')));

    final defaultModelMessage = SharedChatTextMessageRequest(
      agentProfileId: 'positioning_lv1',
      content: <SharedAgentInputContent>[
        SharedAgentTextContent(text: '沿用服务端模型'),
      ],
    ).toJson();
    expect(defaultModelMessage, isNot(contains('modelProfileId')));
  });

  test('validates optional shared Chat model-profile identifiers', () {
    SharedChatTextMessageRequest requestWithModel(String modelProfileId) =>
        SharedChatTextMessageRequest(
          agentProfileId: 'script_draft',
          modelProfileId: modelProfileId,
          content: <SharedAgentInputContent>[
            SharedAgentTextContent(text: '生成口播稿'),
          ],
        );

    expect(() => requestWithModel('   '), throwsArgumentError);
    expect(() => requestWithModel('provider/model'), throwsArgumentError);
    expect(
      () => requestWithModel(List<String>.filled(129, 'm').join()),
      throwsArgumentError,
    );
  });

  test('parses the retained personal asset Markdown projection', () {
    final document = SharedAssetMarkdownDocument.fromJson(
      const <String, Object?>{
        'schemaVersion': 'personal_assets.markdown.v1',
        'documentId': 'assets-1',
        'documentVersion': 3,
        'title': 'Personal assets',
        'markdown': '# Personal assets\n',
        'renderedAt': '2026-07-31T08:00:00Z',
        'locale': 'zh-CN',
        'anchors': <Object?>[
          <String, Object?>{
            'anchorId': 'overview',
            'title': 'Overview',
            'level': 1,
          },
        ],
        'links': <Object?>[],
        'imagePolicy': 'none',
        'allowedMarkdown': <Object?>['heading', 'paragraph'],
      },
    );

    expect(document.anchors.single.level, 1);
    expect(document.renderedAt.isUtc, isTrue);
  });

  test('chat context rejects duplicate resources and private path fields', () {
    const context = SharedChatContext(
      expectedMetaWorkspaceKey: 'writing',
      attachments: <SharedChatResourceRef>[
        SharedChatResourceRef(resourceId: 'res-1', usage: 'reference'),
      ],
    );

    expect(context.toRequestJson(), <String, Object?>{
      'expectedMetaWorkspaceKey': 'writing',
      'attachments': <Object?>[
        <String, Object?>{'resourceId': 'res-1', 'usage': 'reference'},
      ],
    });
    expect(context.toRequestJson().keys, isNot(contains('localPath')));

    expect(
      () => const SharedChatContext(
        attachments: <SharedChatResourceRef>[
          SharedChatResourceRef(resourceId: 'res-1', usage: 'reference'),
          SharedChatResourceRef(resourceId: 'res-1', usage: 'primary_input'),
        ],
      ).toRequestJson(),
      throwsFormatException,
    );
  });

  test('parses retained chat DTOs and serializes identifier-only context', () {
    final page = SharedChatThreadPage.fromJson(const <String, Object?>{
      'items': <Object?>[
        <String, Object?>{
          'threadId': 'thread-1',
          'title': '创作讨论',
          'activeWorkspaceId': 'workspace-1',
          'updatedAt': '2026-07-31T08:00:00Z',
        },
      ],
      'nextCursor': 'cursor-2',
    });
    final mutation = SharedChatMutation.fromJson(const <String, Object?>{
      'userMessage': <String, Object?>{
        'messageId': 'message-user',
        'role': 'user',
        'content': '整理材料',
      },
      'assistantMessage': <String, Object?>{
        'messageId': 'message-assistant',
        'role': 'assistant',
        'textPreview': '已整理',
      },
    }, fallbackThreadId: 'thread-1');
    final context = SharedChatContextEnvelope(
      references: <SharedChatContextReference>[
        SharedChatContextReference(type: 'material', id: 'document-1'),
        SharedChatContextReference(type: 'material', id: 'document-1'),
      ],
    ).toJson();

    expect(page.items.single.activeWorkspaceId, 'workspace-1');
    expect(page.nextCursor, 'cursor-2');
    expect(mutation.assistantMessage!.text, '已整理');
    expect(context['schemaVersion'], 'huahuo.chat-context.v1');
    expect(context['references'], hasLength(1));
    expect(context, isNot(contains('localPath')));
    expect(
      () => SharedChatContextReference(
        type: 'material',
        id: '/Users/demo/private.md',
      ),
      throwsArgumentError,
    );
  });

  test('future asset schema fails explicitly', () {
    expect(
      () => SharedAssetMarkdownDocument.fromJson(const <String, Object?>{
        'schemaVersion': 'personal_assets.markdown.v2',
      }),
      throwsFormatException,
    );
  });
}
