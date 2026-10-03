import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/app/desktop_services.dart';
import 'package:huahuo_desktop/features/assets/data/desktop_assets_adapters.dart';
import 'package:huahuo_desktop/features/auth/data/desktop_auth_adapters.dart';
import 'package:huahuo_desktop/features/auth/domain/desktop_auth_port.dart';
import 'package:huahuo_desktop/features/chat/data/desktop_chat_adapters.dart';
import 'package:huahuo_desktop/features/chat/domain/desktop_chat_port.dart';
import 'package:huahuo_desktop/features/documents/data/desktop_document_sync_adapters.dart';
import 'package:huahuo_desktop/features/documents/domain/desktop_document_sync_port.dart';
import 'package:huahuo_desktop/features/integration/data/desktop_api_domains_adapters.dart';
import 'package:huahuo_desktop/features/integration/domain/desktop_api_domains_port.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

void main() {
  test('desktop document writeback is enabled by default', () {
    expect(desktopDocumentWriteEnabled, isTrue);
  });

  test(
    'desktop production API configuration matches mobile HTTPS defaults',
    () {
      expect(
        resolveDesktopApiBaseUrl(''),
        Uri.parse(desktopProductionApiBaseUrl),
      );
      expect(
        resolveDesktopApiBaseUrl('https://desktop.example.test/'),
        Uri.parse('https://desktop.example.test'),
      );
      expect(resolveDesktopApiBaseUrl('http://desktop.example.test'), isNull);
      expect(
        resolveDesktopApiBaseUrl('https://desktop.example.test/api'),
        isNull,
      );
      expect(resolveDesktopApiBaseUrl('https://user@example.test'), isNull);
    },
  );

  test('desktop runtime only emits an IANA or UTC time zone', () {
    expect(
      resolveDesktopTimeZone('Asia/Shanghai', localTimeZoneName: 'CST'),
      'Asia/Shanghai',
    );
    expect(resolveDesktopTimeZone('', localTimeZoneName: 'UTC'), 'UTC');
    expect(resolveDesktopTimeZone('', localTimeZoneName: 'CST'), 'UTC');
    expect(resolveDesktopTimeZone('CST', localTimeZoneName: 'PDT'), 'UTC');
  });

  test('unconfigured services return typed unavailable states', () async {
    final auth = await const UnavailableDesktopAuthPort().restoreSession();
    final assets = await const UnavailableDesktopAssetsPort()
        .loadMarkdownDocument();
    final chat = await const UnavailableDesktopChatPort().createThread();
    const domains = UnavailableDesktopApiDomains();
    final workspace = await domains.loadFolders('workspace-1');
    final catalog = await domains.loadProfiles();
    final subscription = await domains.loadLibrary('workspace-1');
    final membership = await domains.loadMembership();

    expect(auth.isUnavailable, isTrue);
    expect(auth.code, 'DESKTOP_AUTH_UNAVAILABLE');
    expect(assets.isUnavailable, isTrue);
    expect(chat.isUnavailable, isTrue);
    expect(workspace.isUnavailable, isTrue);
    expect(catalog.isUnavailable, isTrue);
    expect(subscription.isUnavailable, isTrue);
    expect(membership.isUnavailable, isTrue);
  });

  test(
    'Desktop formal domain ports preserve paths, scope and cursors',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'folders': <Object?>[
                <String, Object?>{
                  'folderId': 'folder-1',
                  'displayName': 'Research',
                },
              ],
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'catalogVersion': 'catalog-2',
              'items': <Object?>[
                <String, Object?>{
                  'agentProfileId': 'renshe_content',
                  'displayName': '人设内容',
                },
              ],
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'publicationId': 'publication-1',
                  'title': 'Research',
                  'summary': 'Research publication',
                  'sectionCount': 1,
                  'articleCount': 2,
                  'updatedAt': '2026-08-07T08:00:00Z',
                },
              ],
              'nextCursor': 'cursor-2',
            },
          },
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': _accountMembershipJson(),
          },
        ),
      ]);
      final domains = RemoteDesktopApiDomains(
        _client(transport, token: 'access-token'),
      );

      final folders = await domains.loadFolders('workspace-1');
      final catalog = await domains.loadProfiles();
      final publications = await domains.loadPublications(cursor: 'cursor-1');
      final membership = await domains.loadMembership();

      expect(folders.data?.items.single.requireString('folderId'), 'folder-1');
      expect(catalog.data?.catalogVersion, 'catalog-2');
      expect(publications.data?.nextCursor, 'cursor-2');
      expect(publications.data?.items.single.publicationId, 'publication-1');
      expect(membership.data?.levelCode, 'pilot_paid');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/workspace-1/folders',
        '/api/v1/agent-profiles',
        '/api/v1/subscription/publications',
        '/api/v1/membership',
      ]);
      expect(transport.requests[2].url.queryParameters['cursor'], 'cursor-1');
    },
  );

  test(
    'Desktop Agent adapter uses formal Catalog, installation and AgentRun contracts',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'catalogVersion': 'catalog-agent-1',
              'items': <Object?>[
                <String, Object?>{
                  'agentProfileId': 'faya_germination',
                  'displayName': '发芽',
                },
              ],
            },
          },
        ),
        _apiSuccess(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'skillProfileId': 'viewpoint_germination',
              'displayName': '观点发芽',
              'installation': 'enabled',
            },
          ],
        }),
        _apiSuccess(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'modelProfileId': 'model-public-1',
              'displayName': '标准模型',
            },
          ],
        }),
        _apiSuccess(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'skillProfileId': 'viewpoint_germination',
              'state': 'enabled',
              'installMode': 'user_managed',
              'installedAt': '2026-08-01T08:00:00Z',
              'updatedAt': '2026-08-07T08:00:00Z',
            },
          ],
        }),
        _agentRunCreateResponse(),
        _agentRunResponse(completionMode: 'normal'),
      ]);
      final domains = RemoteDesktopApiDomains(
        _client(transport, token: 'access-token'),
      );

      final profiles = await domains.loadProfiles();
      final skills = await domains.loadSkills('faya_germination');
      final models = await domains.loadModels('faya_germination');
      final installations = await domains.loadInstallations('workspace-1');
      final created = await domains.createAgentRun(
        AgentRunRequest(
          workspaceId: 'workspace-1',
          agentProfileId: 'faya_germination',
          skillProfileIds: const <String>['viewpoint_germination'],
          modelProfileId: 'model-public-1',
          input: SharedAgentInput(
            content: <SharedAgentInputContent>[
              SharedAgentTextContent(text: '生成发芽洞见'),
              SharedAgentWorkspaceDocumentContent(
                ownerKind: 'hnote',
                ownerId: 'note-1',
                part: 'raw',
                partRevisionId: 'part-revision-7',
              ),
            ],
          ),
        ),
        idempotencyKey: 'desktop-agent-key-1',
      );
      final polled = await domains.loadAgentRun('run-1');

      expect(profiles.data?.catalogVersion, 'catalog-agent-1');
      expect(skills.data?.single.skillProfileId, 'viewpoint_germination');
      expect(models.data?.single.modelProfileId, 'model-public-1');
      expect(installations.data?.items.single.isEnabled, isTrue);
      expect(created.data?.agentRunId, 'run-1');
      expect(polled.data?.isSuccessful, isTrue);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/agent-profiles',
        '/api/v1/agent-profiles/faya_germination/skills',
        '/api/v1/agent-profiles/faya_germination/models',
        '/api/v1/workspaces/workspace-1/skill-installations',
        '/api/v1/agent/runs',
        '/api/v1/agent/runs/run-1',
      ]);
      final createRequest = transport.requests[4];
      expect(createRequest.headers['X-Idempotency-Key'], 'desktop-agent-key-1');
      final request = jsonDecode(createRequest.body!) as Map<String, dynamic>;
      expect(request['agentProfileId'], 'faya_germination');
      expect(request['skillProfileIds'], <String>['viewpoint_germination']);
      expect(request['modelProfileId'], 'model-public-1');
      expect(request, isNot(contains('taskType')));
      expect(request, isNot(contains('sourceSurface')));
      expect(request, isNot(contains('prompt')));
      expect(request.toString(), isNot(contains('localPath')));
      expect(request.toString(), isNot(contains('/Users/')));
      expect((request['input'] as Map<String, dynamic>)['content'], <Object?>[
        <String, Object?>{'type': 'text', 'text': '生成发芽洞见'},
        <String, Object?>{
          'type': 'workspace_document',
          'source': <String, Object?>{
            'kind': 'workspace_document',
            'ownerRef': <String, Object?>{'kind': 'hnote', 'id': 'note-1'},
            'part': 'raw',
            'partRevisionId': 'part-revision-7',
          },
          'usage': 'reference',
        },
      ]);
      expect(
        transport.requests.any(
          (request) =>
              request.url.path.contains('/work-ai/') ||
              request.url.path.contains('/feed-ai/'),
        ),
        isFalse,
      );
    },
  );

  test(
    'Desktop germination uses the canonical HNote File-Agent routes',
    () async {
      Map<String, Object?> fileAgentRun(String status) => <String, Object?>{
        'fileAgentRun': <String, Object?>{
          'fileAgentRunId': 'file-agent-run-1',
          'agentRunId': 'agent-run-file-1',
          'noteId': 'note-1',
          'status': status,
          'input': <String, Object?>{
            'part': 'raw',
            'partRevisionId': 'raw-revision-7',
          },
          'target': <String, Object?>{
            'part': 'germination',
            'partRevisionId': 'germination-revision-3',
          },
          'selector': <String, Object?>{
            'agentProfileId': 'faya_germination',
            'skillProfileIds': <String>['viewpoint_germination'],
          },
          if (status == 'succeeded')
            'outputPartRevisionId': 'germination-revision-4',
        },
      };
      final transport = _QueueTransport(<ApiTransportResponse>[
        _apiSuccess(fileAgentRun('queued')),
        _apiSuccess(fileAgentRun('succeeded')),
      ]);
      final domains = RemoteDesktopApiDomains(
        _client(transport, token: 'access-token'),
      );

      final created = await domains.createNoteFileAgentRun(
        workspaceId: 'workspace-1',
        noteId: 'note-1',
        inputPart: 'raw',
        inputPartRevisionId: 'raw-revision-7',
        targetPart: 'germination',
        targetPartRevisionId: 'germination-revision-3',
        instruction: '请基于原始内容生成发芽洞见。',
        agentProfileId: 'faya_germination',
        skillProfileIds: const <String>['viewpoint_germination'],
        idempotencyKey: 'desktop-file-agent-key-1',
      );
      final completed = await domains.loadNoteFileAgentRun(
        workspaceId: 'workspace-1',
        noteId: 'note-1',
        fileAgentRunId: 'file-agent-run-1',
      );

      expect(created.data?.status, 'queued');
      expect(completed.data?.status, 'succeeded');
      expect(completed.data?.outputPartRevisionId, 'germination-revision-4');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/workspace-1/notes/note-1/file-agent-runs',
        '/api/v1/workspaces/workspace-1/notes/note-1/file-agent-runs/file-agent-run-1',
      ]);
      expect(
        transport.requests.first.headers['X-Idempotency-Key'],
        'desktop-file-agent-key-1',
      );
      expect(jsonDecode(transport.requests.first.body!), <String, Object?>{
        'input': <String, Object?>{
          'part': 'raw',
          'partRevisionId': 'raw-revision-7',
        },
        'target': <String, Object?>{
          'part': 'germination',
          'partRevisionId': 'germination-revision-3',
        },
        'instruction': '请基于原始内容生成发芽洞见。',
        'agentProfileId': 'faya_germination',
        'skillProfileIds': <String>['viewpoint_germination'],
      });
    },
  );

  test('Desktop Subscription port exposes all typed API 25 operations', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _apiSuccess(<String, Object?>{
        'items': <Object?>[_subscriptionPublicationJson()],
        'nextCursor': 'publication-next',
      }),
      _apiSuccess(_subscriptionPublicationJson()),
      _apiSuccess(<String, Object?>{
        'items': <Object?>[_subscriptionSectionJson()],
      }),
      _apiSuccess(<String, Object?>{
        'items': <Object?>[_subscriptionArticleJson()],
        'nextCursor': 'article-next',
      }),
      _apiSuccess(_subscriptionRevisionJson()),
      _apiSuccess(<String, Object?>{
        'items': <Object?>[_subscriptionRevisionJson()],
      }),
      _apiSuccess(_subscriptionRevisionJson()),
      _apiSuccess(<String, Object?>{
        'items': <Object?>[
          <String, Object?>{
            'publication': _subscriptionPublicationJson(),
            'followedAt': '2026-08-07T08:00:00Z',
            'availability': 'available',
          },
        ],
      }),
      _apiSuccess(<String, Object?>{
        'workspaceId': 'workspace-1',
        'publicationId': 'publication-1',
        'lifecycle': 'following',
        'followedAt': '2026-08-07T08:00:00Z',
      }),
      _apiSuccess(<String, Object?>{
        'workspaceId': 'workspace-1',
        'publicationId': 'publication-1',
        'lifecycle': 'unfollowed',
        'unfollowedAt': '2026-08-07T08:01:00Z',
      }),
      _apiSuccess(<String, Object?>{
        'noteId': 'note-1',
        'noteRevisionId': 'note-revision-1',
        'rawPartRevisionId': 'raw-1',
        'outlinePartRevisionId': 'outline-1',
        'germinationPartRevisionId': 'germination-1',
        'articleId': 'article-1',
        'articleRevisionId': 'article-revision-1',
        'created': true,
        'lifecycle': 'live',
        'etag': '"note-1"',
        'contentCursor': '10',
      }),
    ]);
    final port = RemoteDesktopApiDomains(
      _client(transport, token: 'access-token'),
    );

    expect(
      (await port.loadPublications(cursor: 'p0', limit: 20)).isSuccess,
      isTrue,
    );
    expect((await port.loadPublication('publication-1')).isSuccess, isTrue);
    expect(
      (await port.loadSections('publication-1', limit: 20)).isSuccess,
      isTrue,
    );
    expect(
      (await port.loadArticles(
        publicationId: 'publication-1',
        sectionId: 'section-1',
        cursor: 'a0',
        limit: 20,
      )).isSuccess,
      isTrue,
    );
    expect((await port.loadArticle('article-1')).isSuccess, isTrue);
    expect(
      (await port.loadArticleRevisions('article-1', limit: 20)).isSuccess,
      isTrue,
    );
    expect(
      (await port.loadArticleRevision(
        'article-1',
        'article-revision-1',
      )).isSuccess,
      isTrue,
    );
    expect(
      (await port.loadLibrary('workspace-1', limit: 20)).isSuccess,
      isTrue,
    );
    expect(
      (await port.followPublication(
        'workspace-1',
        'publication-1',
        idempotencyKey: 'follow-key',
      )).data?.lifecycle,
      'following',
    );
    expect(
      (await port.unfollowPublication(
        'workspace-1',
        'publication-1',
        idempotencyKey: 'unfollow-key',
      )).data?.lifecycle,
      'unfollowed',
    );
    expect(
      (await port.saveArticleAsNote(
        'workspace-1',
        'article-1',
        articleRevisionId: 'article-revision-1',
        idempotencyKey: 'save-key',
      )).data?.noteId,
      'note-1',
    );

    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/subscription/publications',
      '/api/v1/subscription/publications/publication-1',
      '/api/v1/subscription/publications/publication-1/sections',
      '/api/v1/subscription/articles',
      '/api/v1/subscription/articles/article-1',
      '/api/v1/subscription/articles/article-1/revisions',
      '/api/v1/subscription/articles/article-1/revisions/article-revision-1',
      '/api/v1/workspaces/workspace-1/subscription-library/publications',
      '/api/v1/workspaces/workspace-1/subscription-library/publications/publication-1',
      '/api/v1/workspaces/workspace-1/subscription-library/publications/publication-1',
      '/api/v1/workspaces/workspace-1/subscription-articles/article-1/save-as-note',
    ]);
    expect(
      transport.requests[3].url.queryParameters,
      containsPair('publicationId', 'publication-1'),
    );
    expect(
      transport.requests[3].url.queryParameters,
      containsPair('sectionId', 'section-1'),
    );
    expect(transport.requests[8].headers['X-Idempotency-Key'], 'follow-key');
    expect(transport.requests[9].headers['X-Idempotency-Key'], 'unfollow-key');
    expect(transport.requests[10].headers['X-Idempotency-Key'], 'save-key');
    expect(
      transport.requests[10].body,
      '{"articleRevisionId":"article-revision-1"}',
    );
  });

  test(
    'Desktop Search Relations and API27 ports preserve the formal contract',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _apiSuccess(_workspaceSearchJson()),
        _apiSuccess(_exactHNoteJson()),
        _apiSuccess(_hNotePartViewJson()),
        _apiSuccess(<String, Object?>{
          'items': <Object?>[_explicitRelationJson()],
          'nextCursor': 'relation-next',
        }),
        _apiSuccess(_noteRelationEventJson(version: 1)),
        _apiSuccess(_noteRelationEventJson(version: 2)),
        _apiSuccess(_noteRelationEventJson(version: 3, tombstone: true)),
        _apiSuccess(_accountMembershipJson()),
        _apiSuccess(_accountCreditsJson(nextCursor: 'credit-next')),
        _apiSuccess(_runUsageJson()),
      ]);
      final port = RemoteDesktopApiDomains(
        _client(transport, token: 'access-token'),
      );
      final source = SharedNotePartSourceRef(
        noteId: 'note-source',
        part: 'raw',
        partRevisionId: 'part-source-1',
      );
      final target = SharedNotePartSourceRef(
        noteId: 'note-target',
        part: 'outline',
        partRevisionId: 'part-target-1',
      );

      final search = await port.searchWorkspace(
        'workspace-1',
        SharedWorkspaceSearchRequest.keyword(
          query: '创作方法',
          ownerKinds: const <String>['hnote'],
          noteParts: const <String>['raw', 'outline'],
          limit: 20,
        ),
      );
      final note = await port.loadNote(
        'workspace-1',
        'note-1',
        revisionId: 'note-revision-1',
      );
      final part = await port.loadNotePart(
        'workspace-1',
        'note-target',
        'outline',
        partRevisionId: 'part-target-1',
      );
      final relations = await port.loadNoteRelations(
        'workspace-1',
        'note-1',
        cursor: 'relation-0',
        limit: 25,
      );
      final created = await port.createNoteRelation(
        'workspace-1',
        'note-1',
        SharedCreateExplicitNoteRelationRequest(
          relationType: 'supports',
          source: SharedNotePartRevisionRef(
            part: source.part,
            partRevisionId: source.partRevisionId,
          ),
          target: target,
          rationale: '目标笔记提供事实支持',
        ),
        idempotencyKey: 'relation-create-key',
      );
      final updated = await port.updateNoteRelation(
        'workspace-1',
        'relation-1',
        SharedUpdateExplicitNoteRelationRequest(rationale: '更新后的依据'),
        etag: '"relation-1-v1"',
        idempotencyKey: 'relation-update-key',
      );
      final deleted = await port.deleteNoteRelation(
        'workspace-1',
        'relation-1',
        etag: '"relation-1-v2"',
        idempotencyKey: 'relation-delete-key',
      );
      final membership = await port.loadMembership();
      final credits = await port.loadCredits(cursor: 'credit-0', limit: 25);
      final usage = await port.loadRunUsage('run-1');

      expect(search.data?.results.single.revisionId, 'note-revision-1');
      expect(note.data?.noteRevisionId, 'note-revision-1');
      expect(part.data?.partRevisionId, 'part-target-1');
      expect(relations.data?.nextCursor, 'relation-next');
      expect(relations.data?.items.single, isA<SharedExplicitNoteRelation>());
      expect(created.data?.version, 1);
      expect(updated.data?.version, 2);
      expect(deleted.data?.tombstone, isTrue);
      expect(membership.data?.levelCode, 'pilot_paid');
      expect(credits.data?.permanentCredit.nextCursor, 'credit-next');
      expect(usage.data?.accountedCredits, 360);

      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/workspace-1/search',
        '/api/v1/workspaces/workspace-1/notes/note-1',
        '/api/v1/workspaces/workspace-1/notes/note-target/parts/outline',
        '/api/v1/workspaces/workspace-1/notes/note-1/relations',
        '/api/v1/workspaces/workspace-1/notes/note-1/relations',
        '/api/v1/workspaces/workspace-1/note-relations/relation-1',
        '/api/v1/workspaces/workspace-1/note-relations/relation-1',
        '/api/v1/membership',
        '/api/v1/account/credits',
        '/api/v1/runs/run-1/usage',
      ]);
      final searchRequest = transport.requests[0];
      final searchBody = jsonDecode(searchRequest.body!) as Map;
      expect(searchRequest.headers, isNot(contains('X-Idempotency-Key')));
      expect(searchBody, containsPair('query', '创作方法'));
      expect(searchBody, containsPair('mode', 'keyword'));
      expect(searchBody, containsPair('ownerKinds', <String>['hnote']));
      for (final forbidden in <String>[
        'body',
        'content',
        'markdown',
        'localPath',
        'path',
      ]) {
        expect(searchBody, isNot(contains(forbidden)));
      }
      expect(
        transport.requests[1].url.queryParameters['revisionId'],
        'note-revision-1',
      );
      expect(
        transport.requests[2].url.queryParameters['partRevisionId'],
        'part-target-1',
      );
      expect(
        transport.requests[3].url.queryParameters,
        containsPair('cursor', 'relation-0'),
      );
      expect(
        transport.requests[4].headers['X-Idempotency-Key'],
        'relation-create-key',
      );
      expect(transport.requests[5].headers['If-Match'], '"relation-1-v1"');
      expect(
        transport.requests[5].headers['X-Idempotency-Key'],
        'relation-update-key',
      );
      expect(transport.requests[6].headers['If-Match'], '"relation-1-v2"');
      expect(
        transport.requests[6].headers['X-Idempotency-Key'],
        'relation-delete-key',
      );
      expect(
        transport.requests[8].url.queryParameters,
        containsPair('cursor', 'credit-0'),
      );
    },
  );

  test('Desktop Note Relation preserves HTTP 412 as a typed failure', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 412,
        body: <String, Object?>{
          'success': false,
          'error': <String, Object?>{
            'code': 'PRECONDITION_FAILED',
            'message': 'relation version changed',
          },
        },
      ),
    ]);
    final port = RemoteDesktopApiDomains(
      _client(transport, token: 'access-token'),
    );

    final result = await port.deleteNoteRelation(
      'workspace-1',
      'relation-1',
      etag: '"relation-1-v1"',
      idempotencyKey: 'relation-delete-key',
    );

    expect(result.isFailure, isTrue);
    expect(result.code, 'PRECONDITION_FAILED');
    expect(transport.requests.single.headers['If-Match'], '"relation-1-v1"');
    expect(
      transport.requests.single.headers['X-Idempotency-Key'],
      'relation-delete-key',
    );
  });

  test('remote login stores only the accepted token pair', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'accessToken': 'access-1',
            'refreshToken': 'refresh-1',
            'user': <String, Object?>{
              'userId': 'user-1',
              'displayName': '测试用户',
            },
            'onboardingRequired': false,
            'workspaceStatus': 'ready',
          },
        },
      ),
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'user': <String, Object?>{
              'userId': 'user-1',
              'displayName': '测试用户',
            },
            'workspace': <String, Object?>{
              'workspaceId': 'workspace-1',
              'status': 'ready',
            },
          },
        },
      ),
    ]);
    final tokenStore = _MemoryTokenStore();
    final auth = RemoteDesktopAuthPort(
      _client(transport),
      tokenStore,
      runtime: const DesktopAuthRuntime(
        deviceId: 'desktop-test-1',
        clientVersion: 'desktop-test',
        timeZone: 'Asia/Shanghai',
      ),
    );

    final result = await auth.signIn(
      phone: '13800000000',
      smsRequestId: 'sms-1',
      code: '123456',
      agreementAccepted: true,
    );

    expect(result.isSuccess, isTrue);
    expect(result.data!.displayName, '测试用户');
    expect(result.data!.workspaceId, 'workspace-1');
    expect(tokenStore.tokens!.accessToken, 'access-1');
    final body = jsonDecode(transport.requests.first.body!) as Map;
    expect(body['smsRequestId'], 'sms-1');
    expect(body['smsCode'], '123456');
    expect(body, isNot(contains('code')));
    expect(body['deviceId'], 'desktop-test-1');
    expect(body['clientVersion'], 'desktop-test');
    expect(body['timeZone'], 'Asia/Shanghai');
    expect(body, isNot(contains('localPath')));
  });

  test(
    'desktop profile reads and writes the public profile projection',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _apiSuccess(<String, Object?>{
          'userId': 'user-1',
          'displayName': '旧昵称',
          'avatarResourceId': 'avatar-resource-1',
        }),
        _apiSuccess(<String, Object?>{
          'userId': 'user-1',
          'displayName': '新昵称',
          'avatarResourceId': 'avatar-resource-1',
        }),
      ]);
      final auth = RemoteDesktopAuthPort(
        _client(transport, token: 'access-token'),
        _MemoryTokenStore(),
      );

      final loaded = await auth.loadProfile();
      final updated = await auth.updateProfile(displayName: ' 新昵称 ');

      expect(loaded.isSuccess, isTrue);
      expect(loaded.data?.displayName, '旧昵称');
      expect(loaded.data?.avatarResourceId, 'avatar-resource-1');
      expect(updated.isSuccess, isTrue);
      expect(updated.data?.displayName, '新昵称');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/me/profile',
        '/api/v1/me/profile',
      ]);
      final update = transport.requests.last;
      expect(update.method, 'PATCH');
      expect(jsonDecode(update.body!), <String, Object?>{'displayName': '新昵称'});
      expect(update.headers['X-Idempotency-Key'], isNotEmpty);
    },
  );

  test(
    'expired access token refreshes without deleting refresh credential',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 401,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'AUTH_SESSION_EXPIRED',
              'message': 'expired',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'accessToken': 'access-2',
              'refreshToken': 'refresh-2',
              'rotated': true,
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'user': <String, Object?>{'userId': 'user-1'},
              'workspace': <String, Object?>{
                'workspaceId': 'workspace-1',
                'status': 'ready',
              },
            },
          },
        ),
      ]);
      final tokenStore = _MemoryTokenStore()
        ..tokens = const SharedAuthTokens(
          accessToken: 'access-1',
          refreshToken: 'refresh-1',
        );
      final auth = RemoteDesktopAuthPort(_client(transport), tokenStore);

      final restored = await auth.restoreSession();

      expect(restored.isSuccess, isTrue);
      expect(restored.data!.workspaceId, 'workspace-1');
      expect(tokenStore.tokens!.accessToken, 'access-2');
      expect(tokenStore.tokens!.refreshToken, 'refresh-2');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/me/status',
        '/api/v1/auth/refresh',
        '/api/v1/me/status',
      ]);
    },
  );

  test(
    'non-expiry status failure retains the cached desktop account',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 503,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'SERVICE_TEMPORARY',
              'message': 'retry later',
              'retryable': true,
            },
          },
        ),
      ]);
      final cached = const DesktopAuthAccount(
        userId: 'user-cached',
        displayName: '缓存用户',
        workspaceStatus: 'ready',
        workspaceId: 'workspace-cached',
      );
      final tokenStore = _MemoryTokenStore()
        ..tokens = const SharedAuthTokens(
          accessToken: 'access-cached',
          refreshToken: 'refresh-cached',
        )
        ..cachedAccount = cached;
      final auth = RemoteDesktopAuthPort(_client(transport), tokenStore);

      final restored = await auth.restoreSession();

      expect(restored.isSuccess, isTrue);
      expect(restored.data?.userId, cached.userId);
      expect(tokenStore.tokens?.accessToken, 'access-cached');
      expect(tokenStore.tokens?.refreshToken, 'refresh-cached');
      expect(tokenStore.cachedAccount?.workspaceId, 'workspace-cached');
      expect(transport.requests.single.url.path, '/api/v1/me/status');
    },
  );

  test(
    'restored session stays authenticated while Workspace is creating',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'user': <String, Object?>{
                'userId': 'user-preparing',
                'displayName': '准备中的用户',
              },
              'workspace': <String, Object?>{
                'workspaceId': 'workspace-preparing',
                'status': 'creating',
              },
            },
          },
        ),
      ]);
      final tokenStore = _MemoryTokenStore()
        ..tokens = const SharedAuthTokens(
          accessToken: 'access-preparing',
          refreshToken: 'refresh-preparing',
        );
      final auth = RemoteDesktopAuthPort(_client(transport), tokenStore);

      final restored = await auth.restoreSession();

      expect(restored.isSuccess, isTrue);
      expect(restored.data!.workspaceStatus, 'creating');
      expect(restored.data!.workspaceId, 'workspace-preparing');
      expect(tokenStore.tokens!.accessToken, 'access-preparing');
      expect(tokenStore.tokens!.refreshToken, 'refresh-preparing');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/me/status',
      ]);
    },
  );

  test('remote asset adapter parses fixed Markdown projection', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'document': <String, Object?>{
              'schemaVersion': 'personal_assets.markdown.v1',
              'documentId': 'assets-1',
              'documentVersion': 4,
              'title': '我的资产',
              'markdown': '# 我的资产\n',
              'renderedAt': '2026-07-31T08:00:00Z',
              'locale': 'zh-CN',
              'anchors': <Object?>[],
              'links': <Object?>[],
              'imagePolicy': 'none',
              'allowedMarkdown': <Object?>['heading', 'paragraph'],
            },
          },
        },
      ),
    ]);

    final result = await RemoteDesktopAssetsPort(
      _client(transport, token: 'access-token'),
    ).loadMarkdownDocument();

    expect(result.isSuccess, isTrue);
    expect(result.data!.version, 4);
    expect(transport.requests.single.url.path, '/api/v1/assets/markdown');
  });

  test('remote asset adapter parses overview and typed detail', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'overview': <String, Object?>{
              'recordingCount': 3,
              'transcriptWordCount': 2400,
              'contentLineCount': 1,
              'lifeEventCount': 2,
              'expressionCount': 4,
              'syncStatus': 'normal',
            },
            'contentLines': <Object?>[
              <String, Object?>{
                'contentLineId': 'positioning-1',
                'name': '真实经历',
              },
            ],
          },
        },
      ),
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'assetType': 'content_line',
            'assetId': 'positioning-1',
            'asset': <String, Object?>{'name': '真实经历'},
            'editable': true,
            'baseVersion': 5,
            'sourceRefs': <Object?>[],
            'updatedAt': '2026-07-31T08:00:00Z',
          },
        },
      ),
    ]);
    final assets = RemoteDesktopAssetsPort(
      _client(transport, token: 'access-token'),
    );

    final overview = await assets.loadOverview();
    final detail = await assets.loadDetail(
      assetType: 'content_line',
      assetId: overview.data!.items.single.assetId,
    );

    expect(overview.data!.recordingCount, 3);
    expect(overview.data!.items.single.title, '真实经历');
    expect(detail.data!.baseVersion, 5);
    expect(
      transport.requests.last.url.path,
      '/api/v1/assets/content_line/positioning-1',
    );
  });

  test('chat request carries canonical AgentInput references', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _agentCatalogResponse(),
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'userMessage': <String, Object?>{
              'messageId': 'message-user',
              'threadId': 'thread-1',
              'role': 'user',
              'content': '整理材料',
            },
            'assistantMessage': <String, Object?>{
              'messageId': 'message-assistant',
              'threadId': 'thread-1',
              'role': 'assistant',
              'content': '已整理',
            },
          },
        },
      ),
    ]);
    final chat = RemoteDesktopChatPort(
      _client(transport, token: 'access-token'),
    );

    final result = await chat.sendText(
      threadId: 'thread-1',
      content: '整理材料',
      references: <DesktopChatContextReference>[
        DesktopChatContextReference.workspaceDocument(
          ownerId: 'note-1',
          part: 'raw',
          partRevisionId: 'raw-revision-1',
        ),
      ],
    );

    expect(result.data!.assistantMessage!.text, '已整理');
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/agent-profiles',
      '/api/v1/chat/threads/thread-1/messages',
    ]);
    final request = jsonDecode(transport.requests.last.body!) as Map;
    final input = request['input'] as Map;
    final content = input['content'] as List;
    expect(content, hasLength(2));
    expect((content.last as Map)['type'], 'workspace_document');
    expect(request['agentProfileId'], 'self_media_creation_standard');
    expect(request, isNot(contains('skillProfileIds')));
    expect(request, isNot(contains('context')));
    expect(request, isNot(contains('taskType')));
    expect(request, isNot(contains('prompt')));
    expect(input.toString(), isNot(contains('localPath')));
    expect(
      () => DesktopChatContextReference.workspaceDocument(
        ownerId: '/Users/demo/private.md',
        part: 'raw',
        partRevisionId: 'raw-revision-1',
      ),
      throwsArgumentError,
    );
  });

  test(
    'history Agent profile is sent without a blocking catalog reread',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'userMessage': <String, Object?>{
                'messageId': 'message-user',
                'threadId': 'thread-visual',
                'role': 'user',
                'content': '继续调整画面',
              },
              'assistantMessage': <String, Object?>{
                'messageId': 'message-assistant',
                'threadId': 'thread-visual',
                'role': 'assistant',
                'content': '已继续调整。',
              },
            },
          },
        ),
      ]);
      final chat = RemoteDesktopChatPort(
        _client(transport, token: 'access-token'),
      );

      final result = await chat.sendText(
        threadId: 'thread-visual',
        content: '继续调整画面',
        agentProfileId: 'visual_chat',
      );

      expect(result.isSuccess, isTrue);
      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.url.path,
        '/api/v1/chat/threads/thread-visual/messages',
      );
      final body = jsonDecode(transport.requests.single.body!) as Map;
      expect(body['agentProfileId'], 'visual_chat');
      expect(body, isNot(contains('skillProfileIds')));
      expect(body, isNot(contains('modelProfileId')));
      expect(body, isNot(contains('runtimeConfigId')));
    },
  );

  test(
    'desktop Chat detail retains generated image Resource references',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'thread': <String, Object?>{
                'threadId': 'thread-1',
                'title': '视觉方案',
              },
              'lastRequestProfile': <String, Object?>{
                'agentProfileId': 'visual_chat',
                'skillProfileIds': <String>['visual_chat_assistant'],
                'modelProfileId': 'server-owned-model',
              },
              'messages': <Object?>[
                <String, Object?>{
                  'messageId': 'assistant-image-1',
                  'threadId': 'thread-1',
                  'role': 'assistant',
                  'content': <Object?>[
                    <String, Object?>{'type': 'text', 'text': '已生成视觉方案。'},
                    <String, Object?>{
                      'type': 'image',
                      'source': <String, Object?>{
                        'kind': 'resource',
                        'resourceId': 'resource-image-1',
                      },
                      'displayName': 'visual.png',
                      'mimeType': 'image/png',
                    },
                  ],
                },
              ],
            },
          },
        ),
      ]);
      final chat = RemoteDesktopChatPort(
        _client(transport, token: 'access-token'),
      );

      final detail = await chat.getThreadDetail('thread-1');

      expect(detail.isSuccess, isTrue);
      expect(detail.data?.thread.agentProfileId, 'visual_chat');
      final image = detail.data?.messages.single.imageAttachments.single;
      expect(image?.resourceId, 'resource-image-1');
      expect(image?.displayName, 'visual.png');
      expect(image?.mimeType, 'image/png');
      expect(
        transport.requests.single.url.path,
        '/api/v1/chat/threads/thread-1',
      );
    },
  );

  test(
    'desktop Chat accepts a public Agent Run without blocking the tracker',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _agentCatalogResponse(),
        const ApiTransportResponse(
          status: 202,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'userMessage': <String, Object?>{
                'messageId': 'message-user',
                'threadId': 'thread-1',
                'role': 'user',
                'content': '后台继续处理',
              },
              'agentRunId': 'run-1',
            },
          },
        ),
      ]);
      final chat = RemoteDesktopChatPort(
        _client(transport, token: 'access-token'),
        pollInterval: Duration.zero,
      );

      final accepted = await chat.sendAcceptedText(
        threadId: 'thread-1',
        content: '后台继续处理',
      );

      expect(accepted.isSuccess, isTrue);
      expect(accepted.data?.agentRunId, 'run-1');
      expect(accepted.data?.assistantMessage, isNull);
      expect(transport.requests, hasLength(2));
      final body =
          jsonDecode(transport.requests.last.body!) as Map<String, dynamic>;
      expect(body['agentProfileId'], 'self_media_creation_standard');
      expect(body, isNot(contains('skillProfileIds')));
      expect(body['input'], <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '后台继续处理'},
        ],
      });
    },
  );

  test(
    'chat refuses to send when the public Agent is not selectable',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'catalogVersion': 'catalog-empty',
              'items': <Object?>[],
            },
          },
        ),
      ]);
      final chat = RemoteDesktopChatPort(
        _client(transport, token: 'access-token'),
        pollInterval: Duration.zero,
      );

      final result = await chat.sendText(
        threadId: 'thread-1',
        content: '不能绕过目录',
      );

      expect(result.isFailure, isTrue);
      expect(result.code, 'AGENT_PROFILE_NOT_SELECTABLE');
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.url.path, '/api/v1/agent-profiles');
    },
  );

  test(
    'chat waits for a normal AgentRun and its durable Assistant Message',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _agentCatalogResponse(),
        const ApiTransportResponse(
          status: 202,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'userMessage': <String, Object?>{
                'messageId': 'message-user',
                'threadId': 'thread-1',
                'role': 'user',
                'content': '等待正式回复',
              },
              'nextAction': <String, Object?>{
                'type': 'poll_agent_run',
                'agentRunId': 'run-1',
              },
            },
          },
        ),
        _agentRunResponse(completionMode: 'normal'),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'thread': <String, Object?>{
                'threadId': 'thread-1',
                'title': '等待正式回复',
              },
              'messages': <Object?>[
                <String, Object?>{
                  'messageId': 'message-user',
                  'threadId': 'thread-1',
                  'role': 'user',
                  'content': '等待正式回复',
                },
                <String, Object?>{
                  'messageId': 'message-assistant',
                  'threadId': 'thread-1',
                  'role': 'assistant',
                  'content': '这是已持久化的正式回复',
                },
              ],
            },
          },
        ),
      ]);
      final chat = RemoteDesktopChatPort(
        _client(transport, token: 'access-token'),
        pollInterval: Duration.zero,
        maxPollAttempts: 2,
      );

      final result = await chat.sendText(
        threadId: 'thread-1',
        content: '等待正式回复',
      );

      expect(result.isSuccess, isTrue);
      expect(result.data!.agentRunId, 'run-1');
      expect(result.data!.completionMode, 'normal');
      expect(result.data!.assistantMessage!.messageId, 'message-assistant');
      expect(result.data!.assistantMessage!.text, '这是已持久化的正式回复');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/agent-profiles',
        '/api/v1/chat/threads/thread-1/messages',
        '/api/v1/agent/runs/run-1',
        '/api/v1/chat/threads/thread-1',
      ]);
    },
  );

  test(
    'task-only Chat acknowledgement polls the matching thread turn',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _agentCatalogResponse(),
        const ApiTransportResponse(
          status: 202,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'userMessage': <String, Object?>{
                'messageId': 'message-user-new',
                'threadId': 'thread-1',
                'role': 'user',
                'content': '兼容任务',
              },
              'taskId': 'task-1',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'thread': <String, Object?>{
                'threadId': 'thread-1',
                'title': '兼容任务',
              },
              'messages': <Object?>[
                <String, Object?>{
                  'messageId': 'old-assistant',
                  'threadId': 'thread-1',
                  'role': 'assistant',
                  'content': '不能误用的旧回复',
                },
                <String, Object?>{
                  'messageId': 'message-user-new',
                  'threadId': 'thread-1',
                  'role': 'user',
                  'content': '兼容任务',
                },
                <String, Object?>{
                  'messageId': 'new-assistant',
                  'threadId': 'thread-1',
                  'role': 'assistant',
                  'content': '兼容任务的回复',
                },
              ],
            },
          },
        ),
      ]);
      final chat = RemoteDesktopChatPort(
        _client(transport, token: 'access-token'),
        pollInterval: Duration.zero,
        maxPollAttempts: 1,
      );

      final result = await chat.sendText(threadId: 'thread-1', content: '兼容任务');

      expect(result.isSuccess, isTrue);
      expect(result.data!.taskId, 'task-1');
      expect(result.data!.assistantMessage!.messageId, 'new-assistant');
    },
  );

  test(
    'Chat does not present non-normal AgentRun outcomes as success',
    () async {
      final cases = <(String, String, String)>[
        ('succeeded', 'degraded', 'DESKTOP_CHAT_DEGRADED_RESULT'),
        ('succeeded', 'system_fallback', 'DESKTOP_CHAT_SYSTEM_FALLBACK'),
        ('cancelled', 'cancelled', 'DESKTOP_CHAT_AGENT_RUN_CANCELLED'),
      ];
      for (final testCase in cases) {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _agentCatalogResponse(),
          const ApiTransportResponse(
            status: 202,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'userMessage': <String, Object?>{
                  'messageId': 'message-user',
                  'threadId': 'thread-1',
                  'role': 'user',
                  'content': '不能显示兜底结果',
                },
                'agentRunId': 'run-1',
              },
            },
          ),
          _agentRunResponse(status: testCase.$1, completionMode: testCase.$2),
        ]);
        final chat = RemoteDesktopChatPort(
          _client(transport, token: 'access-token'),
          pollInterval: Duration.zero,
          maxPollAttempts: 1,
        );

        final result = await chat.sendText(
          threadId: 'thread-1',
          content: '不能显示兜底结果',
        );

        expect(result.isFailure, isTrue, reason: testCase.$2);
        expect(result.code, testCase.$3, reason: testCase.$2);
        expect(transport.requests, hasLength(3), reason: testCase.$2);
      }
    },
  );

  test('document pull hydrates every paged snapshot HNote exactly', () async {
    final root = await Directory.systemTemp.createTemp(
      'huahuo-snapshot-pull-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    final transport = _QueueTransport(<ApiTransportResponse>[
      _contentSnapshotResponse(
        cursor: '10',
        noteId: 'note-1',
        revisionId: 'note-revision-1',
        hasMore: true,
        nextPageToken: 'page-2',
      ),
      _contentSnapshotResponse(
        cursor: '10',
        noteId: 'note-2',
        revisionId: 'note-revision-2',
      ),
      _hNoteResponse(
        noteId: 'note-1',
        revisionId: 'note-revision-1',
        title: '远端文稿一',
        raw: '# 第一篇\n',
        cursor: '9',
      ),
      _hNoteResponse(
        noteId: 'note-2',
        revisionId: 'note-revision-2',
        title: '远端文稿二',
        raw: '第二篇',
        cursor: '10',
      ),
    ]);
    final port = RemoteDesktopDocumentSyncPort(
      _client(transport, token: 'access-token'),
      remoteWriteEnabled: true,
      outboxStore: store,
      now: () => DateTime.utc(2026, 8, 7, 9),
    );
    await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');
    DesktopDocumentPullBatch? applied;

    final result = await port.pullRemote(
      apply: (batch) async => applied = batch,
    );

    expect(result.isSuccess, isTrue);
    expect(applied!.rebuiltFromSnapshot, isTrue);
    expect(applied!.contentCursor, '10');
    expect(applied!.documents.map((item) => item.id), <String>[
      'note-1',
      'note-2',
    ]);
    expect(applied!.documents.first.markdownProjection, '# 第一篇\n');
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/workspaces/workspace-1/content-snapshot',
      '/api/v1/workspaces/workspace-1/content-snapshot',
      '/api/v1/workspaces/workspace-1/notes/note-1',
      '/api/v1/workspaces/workspace-1/notes/note-2',
    ]);
    expect(transport.requests[1].url.queryParameters['pageToken'], 'page-2');
    expect(
      transport.requests[2].url.queryParameters['revisionId'],
      'note-revision-1',
    );
    final outbox = await store.load('user-1:workspace-1');
    expect(outbox.contentCursor, '10');
    expect(outbox.bindings['note-1']!.rawPartRevisionId, 'note-1-raw');
  });

  test(
    'document delta advances nextAfter and retains the local binding',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-delta-pull-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = LocalDesktopDocumentOutboxStore(
        supportDirectory: () async => root,
      );
      await store.save(
        'user-1:workspace-1',
        const DesktopDocumentOutbox(
          contentCursor: '10',
          bindings: <String, DesktopDocumentBinding>{
            'local-document': DesktopDocumentBinding(
              noteId: 'note-1',
              etag: '"note-revision-1"',
              serverRevision: 'note-revision-1',
              localRevision: 4,
              rawPartRevisionId: 'note-1-raw-old',
            ),
          },
        ),
      );
      final transport = _QueueTransport(<ApiTransportResponse>[
        _contentChangesResponse(
          cursor: '11',
          noteId: 'note-1',
          revisionId: 'note-revision-2',
        ),
        _hNoteResponse(
          noteId: 'note-1',
          revisionId: 'note-revision-2',
          title: '远端已更新',
          raw: '更新正文',
          cursor: '11',
        ),
      ]);
      final port = RemoteDesktopDocumentSyncPort(
        _client(transport, token: 'access-token'),
        remoteWriteEnabled: true,
        outboxStore: store,
      );
      await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');
      DesktopDocumentPullBatch? applied;

      final result = await port.pullRemote(
        apply: (batch) async => applied = batch,
      );

      expect(result.isSuccess, isTrue);
      expect(applied!.rebuiltFromSnapshot, isFalse);
      expect(applied!.documents.single.id, 'local-document');
      expect(applied!.documents.single.revision, 5);
      final outbox = await store.load('user-1:workspace-1');
      expect(outbox.contentCursor, '11');
      expect(
        outbox.bindings['local-document']!.serverRevision,
        'note-revision-2',
      );
      expect(
        outbox.bindings['local-document']!.rawPartRevisionId,
        'note-1-raw',
      );
    },
  );

  test('expired document delta rebuilds from a canonical snapshot', () async {
    final root = await Directory.systemTemp.createTemp(
      'huahuo-delta-rebuild-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    await store.save(
      'user-1:workspace-1',
      const DesktopDocumentOutbox(contentCursor: '2'),
    );
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 410,
        body: <String, Object?>{
          'success': false,
          'error': <String, Object?>{
            'code': 'CONTENT_CURSOR_EXPIRED',
            'message': 'cursor expired',
          },
        },
      ),
      _contentSnapshotResponse(
        cursor: '20',
        noteId: 'note-1',
        revisionId: 'note-revision-20',
      ),
      _hNoteResponse(
        noteId: 'note-1',
        revisionId: 'note-revision-20',
        title: '重建后的文稿',
        raw: '重建正文',
        cursor: '20',
      ),
    ]);
    final port = RemoteDesktopDocumentSyncPort(
      _client(transport, token: 'access-token'),
      remoteWriteEnabled: true,
      outboxStore: store,
    );
    await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

    final result = await port.pullRemote(apply: (_) async {});

    expect(result.isSuccess, isTrue);
    expect(result.data!.rebuiltFromSnapshot, isTrue);
    expect(result.data!.contentCursor, '20');
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/workspaces/workspace-1/content-changes',
      '/api/v1/workspaces/workspace-1/content-snapshot',
      '/api/v1/workspaces/workspace-1/notes/note-1',
    ]);
  });

  test(
    'pending document is protected while its delta cursor advances',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-pending-pull-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = LocalDesktopDocumentOutboxStore(
        supportDirectory: () async => root,
      );
      final pending = const DesktopDocumentOutbox(
        contentCursor: '10',
        bindings: <String, DesktopDocumentBinding>{
          'local-document': DesktopDocumentBinding(
            noteId: 'note-1',
            etag: '"note-revision-1"',
            serverRevision: 'note-revision-1',
            localRevision: 4,
            rawPartRevisionId: 'note-1-raw-old',
          ),
        },
      ).enqueue(_snapshot(revision: 5));
      await store.save('user-1:workspace-1', pending);
      final transport = _QueueTransport(<ApiTransportResponse>[
        _contentChangesResponse(
          cursor: '11',
          noteId: 'note-1',
          revisionId: 'note-revision-2',
        ),
      ]);
      final port = RemoteDesktopDocumentSyncPort(
        _client(transport, token: 'access-token'),
        remoteWriteEnabled: true,
        outboxStore: store,
      );
      await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

      final result = await port.pullRemote(apply: (_) async {});

      expect(result.isSuccess, isTrue);
      expect(result.data!.documents, isEmpty);
      expect(result.data!.deletedDocumentIds, isEmpty);
      expect(result.data!.protectedPendingCount, 1);
      expect(transport.requests, hasLength(1));
      final outbox = await store.load('user-1:workspace-1');
      expect(outbox.contentCursor, '11');
      expect(outbox.pending, hasLength(1));
      expect(
        outbox.bindings['local-document']!.serverRevision,
        'note-revision-1',
      );
    },
  );

  test('unavailable document sync keeps a durable local outbox', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-outbox-test-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    final port = UnavailableDesktopDocumentSyncPort(outboxStore: store);

    final result = await port.enqueue(_snapshot());
    final outbox = await store.load('unbound');

    expect(result.isQueued, isTrue);
    expect(result.data!.pendingCount, 1);
    expect(outbox.pending.single.localDocumentId, 'local-document');
    expect(outbox.bindings, isEmpty);
  });

  test('remote conflict leaves the mutation in the outbox', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-conflict-test-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 412,
        body: <String, Object?>{
          'success': false,
          'error': <String, Object?>{
            'code': 'PRECONDITION_FAILED',
            'message': 'revision conflict',
          },
        },
      ),
    ]);
    final port = RemoteDesktopDocumentSyncPort(
      _client(transport, token: 'access-token'),
      remoteWriteEnabled: true,
      outboxStore: store,
    );
    await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

    final result = await port.enqueue(_snapshot());

    expect(result.isFailure, isTrue);
    expect(result.code, 'PRECONDITION_FAILED');
    expect(result.data!.phase, DesktopDocumentSyncPhase.conflict);
    expect((await store.load('user-1:workspace-1')).pending, hasLength(1));
  });

  test('document outboxes are isolated by account and Workspace', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-scope-test-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    final port = UnavailableDesktopDocumentSyncPort(outboxStore: store);

    await port.bindAccount(userId: 'user-a', workspaceId: 'workspace-a');
    await port.enqueue(_snapshot(id: 'document-a'));
    await port.bindAccount(userId: 'user-b', workspaceId: 'workspace-b');
    await port.enqueue(_snapshot(id: 'document-b'));

    expect(
      (await store.load('user-a:workspace-a')).pending.single.localDocumentId,
      'document-a',
    );
    expect(
      (await store.load('user-b:workspace-b')).pending.single.localDocumentId,
      'document-b',
    );
  });

  test('HNote receipt persists exact part revisions for Chat', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-receipt-test-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'noteId': 'note-1',
            'noteRevisionId': 'note-revision-1',
            'parts': <String, Object?>{
              'raw': <String, Object?>{'partRevisionId': 'raw-revision-1'},
              'outline': <String, Object?>{
                'partRevisionId': 'outline-revision-1',
              },
              'germination': <String, Object?>{
                'partRevisionId': 'germination-revision-1',
              },
            },
            'etag': '"note-1"',
            'contentCursor': '1',
          },
        },
      ),
    ]);
    final port = RemoteDesktopDocumentSyncPort(
      _client(transport, token: 'access-token'),
      remoteWriteEnabled: true,
      outboxStore: store,
    );
    await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

    final result = await port.enqueue(_snapshot());
    final reference = await port.remoteReferenceFor(
      localDocumentId: 'local-document',
      part: 'outline',
    );

    expect(result.isSuccess, isTrue);
    expect(reference!.noteId, 'note-1');
    expect(reference.partRevisionId, 'outline-revision-1');
    expect(reference.localRevision, 1);
    expect((await store.load('user-1:workspace-1')).contentCursor, isNull);
    expect(transport.requests.single.headers, contains('X-Idempotency-Key'));
    final body = jsonDecode(transport.requests.single.body!) as Map;
    expect(body['sourceKind'], 'manual');
    expect(body['resourceRefs'], isEmpty);
  });

  test('document pull hydrates canonical sparse Mobile HNote parts', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-sparse-pull-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    final transport = _QueueTransport(<ApiTransportResponse>[
      _contentSnapshotResponse(
        cursor: '10',
        noteId: 'note-1',
        revisionId: 'note-revision-1',
      ),
      _hNoteResponse(
        noteId: 'note-1',
        revisionId: 'note-revision-1',
        title: '手机端笔记',
        raw: '',
        cursor: '10',
        sparse: true,
      ),
      _hNotePartResponse(part: 'raw', markdown: '手机端原文'),
      _hNotePartResponse(part: 'outline', markdown: '手机端大纲'),
      _hNotePartResponse(part: 'germination', markdown: '手机端发芽'),
    ]);
    final port = RemoteDesktopDocumentSyncPort(
      _client(transport, token: 'access-token'),
      remoteWriteEnabled: true,
      outboxStore: store,
    );
    await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

    final result = await port.pullRemote(apply: (_) async {});

    expect(result.isSuccess, isTrue);
    final document = result.data!.documents.single;
    expect(document.markdownProjection, '手机端原文');
    expect(document.summaryMarkdown, '手机端大纲');
    expect(document.sproutMarkdown, '手机端发芽');
    expect(
      transport.requests
          .skip(2)
          .map((request) => request.url.queryParameters['partRevisionId']),
      <String>['note-1-raw', 'note-1-outline', 'note-1-germination'],
    );
    expect((await store.load('user-1:workspace-1')).contentCursor, '10');
  });

  test(
    'document pull rejects mismatched immutable parts before apply',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-part-mismatch-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = LocalDesktopDocumentOutboxStore(
        supportDirectory: () async => root,
      );
      await store.save(
        'user-1:workspace-1',
        const DesktopDocumentOutbox(contentCursor: '10'),
      );
      final transport = _QueueTransport(<ApiTransportResponse>[
        _contentChangesResponse(
          cursor: '11',
          noteId: 'note-1',
          revisionId: 'note-revision-1',
        ),
        _hNoteResponse(
          noteId: 'note-1',
          revisionId: 'note-revision-1',
          title: '手机端笔记',
          raw: '',
          cursor: '11',
          sparse: true,
        ),
        _hNotePartResponse(part: 'raw', markdown: '错误版本', revisionId: 'wrong'),
        _hNotePartResponse(part: 'outline', markdown: '手机端大纲'),
        _hNotePartResponse(part: 'germination', markdown: '手机端发芽'),
      ]);
      final port = RemoteDesktopDocumentSyncPort(
        _client(transport, token: 'access-token'),
        remoteWriteEnabled: true,
        outboxStore: store,
      );
      await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');
      var applied = false;

      final result = await port.pullRemote(apply: (_) async => applied = true);

      expect(result.isFailure, isTrue);
      expect(applied, isFalse);
      final persisted = await store.load('user-1:workspace-1');
      expect(persisted.contentCursor, '10');
      expect(persisted.bindings, isEmpty);
    },
  );

  test('document writes do not skip intervening Mobile changes', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-cross-device-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    await store.save(
      'user-1:workspace-1',
      const DesktopDocumentOutbox(
        contentCursor: '10',
        bindings: <String, DesktopDocumentBinding>{
          'local-document': DesktopDocumentBinding(
            noteId: 'note-desktop',
            etag: '"note-desktop-1"',
            serverRevision: 'note-desktop-1',
            localRevision: 1,
          ),
        },
      ),
    );
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'noteId': 'note-desktop',
            'noteRevisionId': 'note-desktop-2',
            'rawPartRevisionId': 'note-desktop-raw',
            'outlinePartRevisionId': 'note-desktop-outline',
            'germinationPartRevisionId': 'note-desktop-germination',
            'etag': '"note-desktop-2"',
            'contentCursor': '12',
          },
        },
      ),
      _contentChangesResponse(
        cursor: '11',
        noteId: 'note-mobile',
        revisionId: 'note-mobile-1',
        hasMore: true,
      ),
      _contentChangesResponse(
        cursor: '12',
        noteId: 'note-desktop',
        revisionId: 'note-desktop-2',
      ),
      _hNoteResponse(
        noteId: 'note-mobile',
        revisionId: 'note-mobile-1',
        title: '手机新笔记',
        raw: '手机端的并发更新',
        cursor: '11',
      ),
      _hNoteResponse(
        noteId: 'note-desktop',
        revisionId: 'note-desktop-2',
        title: 'Local document',
        raw: 'Body',
        cursor: '12',
      ),
    ]);
    final port = RemoteDesktopDocumentSyncPort(
      _client(transport, token: 'access-token'),
      remoteWriteEnabled: true,
      outboxStore: store,
    );
    await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

    final written = await port.enqueue(_snapshot(revision: 2));

    expect(written.isSuccess, isTrue);
    expect((await store.load('user-1:workspace-1')).contentCursor, '10');
    final request = transport.requests.single;
    expect(request.headers['If-Match'], '"note-desktop-1"');
    final body = jsonDecode(request.body!) as Map;
    expect(body.containsKey('sourceKind'), isFalse);
    expect(body.containsKey('resourceRefs'), isFalse);

    final pulled = await port.pullRemote(apply: (_) async {});

    expect(pulled.isSuccess, isTrue);
    expect(transport.requests[1].url.queryParameters['after'], '10');
    expect(transport.requests[2].url.queryParameters['after'], '11');
    expect(pulled.data!.documents.first.markdownProjection, '手机端的并发更新');
    expect(pulled.data!.documents.last.id, 'local-document');
    expect((await store.load('user-1:workspace-1')).contentCursor, '12');
  });

  test('legacy document cursors reset without losing drafts and bindings', () {
    final original = const DesktopDocumentOutbox(
      contentCursor: '12',
      bindings: <String, DesktopDocumentBinding>{
        'local-document': DesktopDocumentBinding(
          noteId: 'note-1',
          etag: '"note-1"',
          serverRevision: 'note-revision-1',
        ),
      },
    ).enqueue(_snapshot());
    for (final version in <int>[1, 2, 3]) {
      final migrated = DesktopDocumentOutbox.fromJson(<String, Object?>{
        ...original.toJson(),
        'formatVersion': version,
      });
      expect(migrated.contentCursor, isNull);
      expect(
        migrated.pending.single.mutationId,
        original.pending.single.mutationId,
      );
      expect(migrated.bindings['local-document']!.noteId, 'note-1');
      expect(migrated.toJson()['formatVersion'], 4);
    }
    expect(
      DesktopDocumentOutbox.fromJson(original.toJson()).contentCursor,
      '12',
    );
  });

  test(
    'documents with local media remain queued without a remote request',
    () async {
      final root = await Directory.systemTemp.createTemp('huahuo-media-queue-');
      addTearDown(() => root.delete(recursive: true));
      final transport = _QueueTransport(<ApiTransportResponse>[]);
      final store = LocalDesktopDocumentOutboxStore(
        supportDirectory: () async => root,
      );
      final port = RemoteDesktopDocumentSyncPort(
        _client(transport, token: 'access-token'),
        remoteWriteEnabled: true,
        outboxStore: store,
      );
      await port.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

      final result = await port.enqueue(
        _snapshot(
          deltaJson:
              '[{"insert":{"image":"huahuo-media://asset/abcdefghijklmnop"}},{"insert":"\\n"}]',
        ),
      );

      expect(result.isQueued, isTrue);
      expect(result.code, 'DESKTOP_DOCUMENT_MEDIA_UPLOAD_REQUIRED');
      expect(transport.requests, isEmpty);
      expect((await store.load('user-1:workspace-1')).pending, hasLength(1));
    },
  );

  test('serialized concurrent enqueue retains pre-create revisions', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-serial-test-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    final port = UnavailableDesktopDocumentSyncPort(outboxStore: store);

    await Future.wait(<Future<Object?>>[
      port.enqueue(_snapshot(revision: 1)),
      port.enqueue(_snapshot(revision: 2)),
    ]);

    final pending = (await store.load('unbound')).pending;
    expect(pending.map((entry) => entry.snapshot.revision), <int>[1, 2]);
  });

  test('legacy global outbox migrates into the unbound scope', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-legacy-outbox-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    await store.save(
      'unbound',
      const DesktopDocumentOutbox().enqueue(_snapshot()),
    );
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}document-sync',
    );
    final scoped = directory.listSync().whereType<File>().singleWhere(
      (file) => file.path.endsWith('.json'),
    );
    await scoped.rename(
      '${directory.path}${Platform.pathSeparator}outbox.json',
    );

    final migrated = await store.load('unbound');

    expect(migrated.pending.single.localDocumentId, 'local-document');
    expect(
      File(
        '${directory.path}${Platform.pathSeparator}outbox.json',
      ).existsSync(),
      isFalse,
    );
  });

  test('corrupt scoped outbox recovers its retained backup', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-outbox-backup-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopDocumentOutboxStore(
      supportDirectory: () async => root,
    );
    final first = const DesktopDocumentOutbox().enqueue(_snapshot(revision: 1));
    await store.save('user:workspace', first);
    await store.save('user:workspace', first.enqueue(_snapshot(revision: 2)));
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}document-sync',
    );
    final current = directory.listSync().whereType<File>().singleWhere(
      (file) => file.path.endsWith('.json'),
    );
    await current.writeAsString('{corrupt');

    final recovered = await store.load('user:workspace');

    expect(recovered.pending.single.snapshot.revision, 1);
  });
}

ApiClient _client(_QueueTransport transport, {String? token}) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: '0.1.0',
      deviceId: 'desktop-test',
      platform: 'macos',
      locale: 'zh-CN',
      getAccessToken: () => token,
      traceIdFactory: () => 'trace-desktop-test',
    ),
    transport: transport,
  );
}

ApiTransportResponse _apiSuccess(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

Map<String, Object?> _workspaceSearchJson() => <String, Object?>{
  'mode': 'keyword',
  'queryFingerprint': 'fingerprint-1',
  'keywordReadiness': 'current',
  'vectorReadiness': 'unavailable',
  'contentCursor': '10',
  'results': <Object?>[
    <String, Object?>{
      'ownerRef': <String, Object?>{
        'workspaceId': 'workspace-1',
        'kind': 'hnote',
        'id': 'note-1',
      },
      'revisionId': 'note-revision-1',
      'part': 'raw',
      'path': 'notes/note-1/parts/raw',
      'title': '创作方法',
      'updatedAt': '2026-08-07T08:00:00Z',
      'matchMode': 'keyword',
      'score': 0.9,
      'staleSource': false,
    },
  ],
};

Map<String, Object?> _exactHNoteJson() => <String, Object?>{
  'noteId': 'note-1',
  'workspaceId': 'workspace-1',
  'folderId': null,
  'title': '创作方法',
  'state': 'active',
  'noteRevisionId': 'note-revision-1',
  'parts': <String, Object?>{
    'raw': <String, Object?>{
      'partRevisionId': 'part-raw-1',
      'markdown': '# 创作方法\n',
      'contentHash': 'hash-raw-1',
    },
    'outline': <String, Object?>{
      'partRevisionId': 'part-outline-1',
      'markdown': '## 纲要\n',
      'contentHash': 'hash-outline-1',
    },
    'germination': <String, Object?>{
      'partRevisionId': 'part-germination-1',
      'markdown': '## 洞见\n',
      'contentHash': 'hash-germination-1',
    },
  },
  'resourceRefs': <Object?>[],
  'etag': '"note-revision-1"',
  'contentCursor': '10',
};

Map<String, Object?> _hNotePartViewJson() => <String, Object?>{
  'noteId': 'note-target',
  'part': 'outline',
  'partRevisionId': 'part-target-1',
  'markdown': '# 关系目标\n',
  'contentHash': 'hash-part-target-1',
  'etag': '"part-target-1"',
};

Map<String, Object?> _explicitRelationJson() => <String, Object?>{
  'relationId': 'relation-1',
  'relationType': 'supports',
  'origin': 'explicit',
  'source': <String, Object?>{
    'noteId': 'note-source',
    'part': 'raw',
    'partRevisionId': 'part-source-1',
  },
  'target': <String, Object?>{
    'noteId': 'note-target',
    'part': 'outline',
    'partRevisionId': 'part-target-1',
  },
  'rationale': '目标笔记提供事实支持',
  'version': 1,
  'etag': '"relation-1-v1"',
};

Map<String, Object?> _noteRelationEventJson({
  required int version,
  bool tombstone = false,
}) => <String, Object?>{
  'eventId': 'event-relation-$version',
  'workspaceId': 'workspace-1',
  'cursor': '${20 + version}',
  'operationId': 'operation-relation-$version',
  'occurredAt': '2026-08-07T08:00:00Z',
  'objectKind': 'note_relation',
  'objectId': 'relation-1',
  'changeType': tombstone ? 'tombstoned' : 'updated',
  'tombstone': tombstone,
  'resourcePinDelta': <String, Object?>{
    'added': <Object?>[],
    'released': <Object?>[],
  },
  'version': version,
};

Map<String, Object?> _monthlyCreditJson() => <String, Object?>{
  'policyVersion': 'credit-policy-v1',
  'quotaCredits': 10000000,
  'periodStart': '2026-08-01T00:00:00Z',
  'periodEnd': '2026-09-01T00:00:00Z',
  'availableCredits': 9000000,
  'reservedCredits': 1000,
  'settledCredits': 999000,
  'expiresAt': '2026-09-01T00:00:00Z',
};

Map<String, Object?> _accountAdmissionJson() => <String, Object?>{
  'runAdmission': 'allowed',
  'outstandingUncoveredCredits': 0,
};

Map<String, Object?> _accountMembershipJson() => <String, Object?>{
  'membership': <String, Object?>{
    'membershipId': 'membership-1',
    'levelCode': 'pilot_paid',
    'status': 'active',
    'expiresAt': null,
  },
  'monthlyCredit': _monthlyCreditJson(),
  'permanentCredit': <String, Object?>{
    'availableCredits': 800,
    'reservedCredits': 0,
  },
  'account': _accountAdmissionJson(),
};

Map<String, Object?> _accountCreditsJson({String? nextCursor}) =>
    <String, Object?>{
      'monthlyCredit': _monthlyCreditJson(),
      'permanentCredit': <String, Object?>{
        'availableCredits': 800,
        'reservedCredits': 0,
        'lots': <Object?>[
          <String, Object?>{
            'lotId': 'lot-1',
            'originKind': 'migration',
            'originalCredits': 1000,
            'availableCredits': 800,
            'reservedCredits': 0,
            'createdAt': '2026-08-01T00:00:00Z',
            'expiresAt': null,
          },
        ],
        if (nextCursor != null) 'nextCursor': nextCursor,
      },
      'account': _accountAdmissionJson(),
    };

Map<String, Object?> _runUsageJson() => <String, Object?>{
  'runId': 'run-1',
  'policyVersion': 'credit-policy-v1',
  'rawInputTokens': 120,
  'rawOutputTokens': 240,
  'accountedCredits': 360,
  'settlementStatus': 'settled',
  'assistantResultPersisted': true,
  'measurements': <Object?>[],
};

Map<String, Object?> _subscriptionPublicationJson() => <String, Object?>{
  'publicationId': 'publication-1',
  'title': 'Research',
  'summary': 'Research publication',
  'sectionCount': 1,
  'articleCount': 1,
  'updatedAt': '2026-08-07T08:00:00Z',
};

Map<String, Object?> _subscriptionSectionJson() => <String, Object?>{
  'sectionId': 'section-1',
  'publicationId': 'publication-1',
  'title': 'Section',
  'sortOrder': 0,
};

Map<String, Object?> _subscriptionArticleJson() => <String, Object?>{
  'articleId': 'article-1',
  'publicationId': 'publication-1',
  'sectionId': 'section-1',
  'currentArticleRevisionId': 'article-revision-1',
  'title': 'Article',
  'summary': 'Article summary',
  'author': 'Author',
  'publishedAt': '2026-08-07T08:00:00Z',
};

Map<String, Object?> _subscriptionRevisionJson() => <String, Object?>{
  ..._subscriptionArticleJson(),
  'articleRevisionId': 'article-revision-1',
  'contentMarkdown': '# Article\n',
  'contentSha256': 'sha256-article-1',
};

ApiTransportResponse _contentSnapshotResponse({
  required String cursor,
  required String noteId,
  required String revisionId,
  bool hasMore = false,
  String? nextPageToken,
}) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'snapshotId': 'snapshot-1',
      'atCursor': cursor,
      'folders': <Object?>[],
      'objects': <Object?>[
        <String, Object?>{
          'ownerRef': <String, Object?>{
            'workspaceId': 'workspace-1',
            'kind': 'hnote',
            'id': noteId,
          },
          'tombstone': false,
          'revisionId': revisionId,
          'etag': '"$revisionId"',
          'resourceRefs': <Object?>[],
        },
      ],
      'hasMore': hasMore,
      'nextPageToken': nextPageToken,
    },
  },
);

ApiTransportResponse _contentChangesResponse({
  required String cursor,
  required String noteId,
  required String revisionId,
  bool tombstone = false,
  bool hasMore = false,
}) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'events': <Object?>[
        <String, Object?>{
          'eventId': 'event-$cursor',
          'workspaceId': 'workspace-1',
          'cursor': cursor,
          'operationId': 'operation-$cursor',
          'occurredAt': '2026-08-07T09:00:00Z',
          'objectKind': 'hnote',
          'objectId': noteId,
          'changeType': tombstone ? 'tombstoned' : 'revision_created',
          'revisionId': revisionId,
          'previousRevisionId': 'previous-$revisionId',
          'tombstone': tombstone,
          'resourcePinDelta': <String, Object?>{
            'added': <Object?>[],
            'released': <Object?>[],
          },
        },
      ],
      'nextAfter': cursor,
      'hasMore': hasMore,
    },
  },
);

ApiTransportResponse _hNoteResponse({
  required String noteId,
  required String revisionId,
  required String title,
  required String raw,
  required String cursor,
  bool sparse = false,
}) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'noteId': noteId,
      'workspaceId': 'workspace-1',
      'folderId': null,
      'title': title,
      'state': 'active',
      'noteRevisionId': revisionId,
      'rawPartRevisionId': '$noteId-raw',
      'outlinePartRevisionId': '$noteId-outline',
      'germinationPartRevisionId': '$noteId-germination',
      if (!sparse)
        'parts': <String, Object?>{
          'raw': <String, Object?>{
            'partRevisionId': '$noteId-raw',
            'markdown': raw,
            'contentHash': '$noteId-raw-hash',
          },
          'outline': <String, Object?>{
            'partRevisionId': '$noteId-outline',
            'markdown': '',
            'contentHash': '$noteId-outline-hash',
          },
          'germination': <String, Object?>{
            'partRevisionId': '$noteId-germination',
            'markdown': '',
            'contentHash': '$noteId-germination-hash',
          },
        },
      'resourceRefs': <Object?>[],
      'etag': '"$revisionId"',
      'contentCursor': cursor,
    },
  },
);

ApiTransportResponse _hNotePartResponse({
  required String part,
  required String markdown,
  String? revisionId,
}) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'noteId': 'note-1',
      'part': part,
      'partRevisionId': revisionId ?? 'note-1-$part',
      'contentMarkdown': markdown,
      'contentSha256': 'sha256:note-1-$part',
      'etag': '"note-1-$part"',
    },
  },
);

ApiTransportResponse _agentCatalogResponse() => const ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'catalogVersion': 'catalog-chat-1',
      'items': <Object?>[
        <String, Object?>{
          'agentProfileId': 'self_media_creation_standard',
          'displayName': '标准创作',
        },
      ],
    },
  },
);

ApiTransportResponse _agentRunCreateResponse() {
  final detail = _agentRunResponse(completionMode: 'normal');
  final envelope = detail.body! as Map<String, Object?>;
  final data = envelope['data']! as Map<String, Object?>;
  return ApiTransportResponse(
    status: 202,
    body: <String, Object?>{
      'success': true,
      'data': <String, Object?>{
        'run': data['run'],
        'nextAction': <String, Object?>{
          'type': 'poll_agent_run',
          'agentRunId': 'run-1',
          'afterSequence': 0,
        },
      },
    },
  );
}

ApiTransportResponse _agentRunResponse({
  String status = 'succeeded',
  required String completionMode,
}) {
  final succeeded = status == 'succeeded';
  return ApiTransportResponse(
    status: 200,
    body: <String, Object?>{
      'success': true,
      'data': <String, Object?>{
        'run': <String, Object?>{
          'agentRunId': 'run-1',
          'workspaceId': 'workspace-1',
          'threadId': 'thread-1',
          'status': status,
          'workspaceVersion': 1,
          'workspaceBindingVersion': 1,
          'contextGeneration': 1,
          if (succeeded) 'assistantMessageId': 'message-assistant',
          if (succeeded) 'completionMode': completionMode,
          if (succeeded)
            'result': <String, Object?>{
              'finalAnswer': '运行结果只用于核验，不直接显示',
              'assistantMessageId': 'message-assistant',
              'completionMode': completionMode,
            },
          'usage': <String, Object?>{
            'measurementStatus': 'measured',
            'inputTokens': 12,
            'outputTokens': 18,
            'imageCount': null,
            'videoSeconds': null,
            'accountedCredits': 30,
            'policyVersion': 'credits-v1',
          },
          'toolTrace': <Object?>[],
          'createdAt': '2026-08-07T08:00:00Z',
          'updatedAt': '2026-08-07T08:00:01Z',
        },
      },
    },
  );
}

HuahuoDocumentSnapshot _snapshot({
  String id = 'local-document',
  int revision = 1,
  String deltaJson = '[{"insert":"Body\\n"}]',
}) {
  final now = DateTime.utc(2026, 7, 31, 8);
  return HuahuoDocumentSnapshot(
    id: id,
    title: 'Local document',
    deltaJson: deltaJson,
    markdownProjection: 'Body',
    revision: revision,
    createdAt: now,
    modifiedAt: now,
  );
}

final class _MemoryTokenStore implements DesktopTokenStore {
  SharedAuthTokens? tokens;
  DesktopAuthAccount? cachedAccount;

  @override
  Future<void> clear() async {
    tokens = null;
    cachedAccount = null;
  }

  @override
  Future<void> clearAccessToken() async {
    final current = tokens;
    if (current == null) return;
    tokens = SharedAuthTokens(
      accessToken: '',
      refreshToken: current.refreshToken,
    );
  }

  @override
  Future<String?> readAccessToken() async {
    final value = tokens?.accessToken;
    return value == null || value.isEmpty ? null : value;
  }

  @override
  Future<String?> readRefreshToken() async => tokens?.refreshToken;

  @override
  Future<DesktopAuthAccount?> readCachedAccount() async => cachedAccount;

  @override
  Future<void> write(SharedAuthTokens tokens) async => this.tokens = tokens;

  @override
  Future<void> writeCachedAccount(DesktopAuthAccount account) async {
    cachedAccount = account;
  }
}

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
