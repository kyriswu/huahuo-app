import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'writes custom titles with the version and idempotency contract',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'thread': <String, Object?>{
                'threadId': 'thread_1',
                'title': '新的会话名',
                'titleMode': 'custom',
                'titleVersion': 2,
              },
            },
          },
        ),
      ]);
      final result = await ChatThreadMetadataClient(_apiClient(transport))
          .updateTitle(
            threadId: 'thread_1',
            titleMode: SharedChatThreadTitleMode.custom,
            title: '新的会话名',
            expectedTitleVersion: 1,
            idempotency: const IdempotencyRequestContext(
              explicitKey: 'title-mutation-1',
            ),
          );

      expect(result.data?.titleVersion, 2);
      expect(transport.requests.single.method, 'PATCH');
      expect(
        transport.requests.single.headers['X-Idempotency-Key'],
        'title-mutation-1',
      );
      expect(jsonDecode(transport.requests.single.body!), <String, Object?>{
        'titleMode': 'custom',
        'title': '新的会话名',
        'expectedTitleVersion': 1,
      });
    },
  );

  test('recognizes runtime trace 304 without parsing a body', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 200,
        headers: const <String, String>{'ETag': '"run-1"'},
        body: <String, Object?>{'success': true, 'data': _tracePayload()},
      ),
      const ApiTransportResponse(
        status: 304,
        headers: <String, String>{'ETag': '"run-1"'},
        body: null,
      ),
    ]);
    final client = ChatThreadMetadataClient(_apiClient(transport));
    final first = await client.latestInvocation(threadId: 'thread_1');
    final second = await client.latestInvocation(
      threadId: 'thread_1',
      ifNoneMatch: first.etag,
    );

    expect(first.data?.agentRunId, 'agent_run_1');
    expect(second.isNotModified, isTrue);
    expect(
      transport.requests.first.url.path,
      '/api/v1/chat/threads/thread_1/runtime-invocations/latest',
    );
    expect(transport.requests[1].headers['If-None-Match'], '"run-1"');
  });

  test('lists runtime invocations with cursor limit and ETag', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 200,
        headers: const <String, String>{'etag': '"history-1"'},
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'items': <Object?>[_canonicalTracePayload()],
            'nextCursor': 'opaque_cursor_2',
          },
        },
      ),
      const ApiTransportResponse(
        status: 304,
        headers: <String, String>{'ETag': '"history-1"'},
        body: null,
      ),
    ]);
    final client = ChatThreadMetadataClient(_apiClient(transport));

    final first = await client.listInvocations(
      threadId: ' thread_1 ',
      cursor: ' opaque_cursor_1 ',
      limit: 1,
    );
    final second = await client.listInvocations(
      threadId: 'thread_1',
      cursor: 'opaque_cursor_1',
      limit: 1,
      ifNoneMatch: first.etag,
    );

    expect(first.ok, isTrue);
    expect(first.etag, '"history-1"');
    expect(first.data?.nextCursor, 'opaque_cursor_2');
    expect(first.data?.items.single.dispatchId, 'dispatch_1');
    expect(first.data?.items.single.creativePositioningId, 'positioning_1');
    expect(first.data?.items.single.files.single.category, 'attachment');
    expect(first.data?.items.single.files.single.editable, isFalse);
    expect(second.isNotModified, isTrue);

    final request = transport.requests.first;
    expect(
      request.url.path,
      '/api/v1/chat/threads/thread_1/runtime-invocations',
    );
    expect(request.url.queryParameters, <String, String>{
      'limit': '1',
      'cursor': 'opaque_cursor_1',
    });
    expect(transport.requests.last.headers['If-None-Match'], '"history-1"');
    expect(
      EndpointCatalog.byId('chatThreadRuntimeInvocation').pathTemplate,
      endsWith('/runtime-invocations/latest'),
    );
  });

  test('runtime invocation page parser rejects partial malformed history', () {
    final parsed = parseSharedThreadRuntimeInvocationPage(<String, Object?>{
      'items': <Object?>[_canonicalTracePayload()],
      'nextCursor': 'opaque_cursor_2',
    });
    expect(parsed, isNotNull);
    expect(
      () => parsed!.items.add(parsed.items.single),
      throwsUnsupportedError,
    );

    expect(
      parseSharedThreadRuntimeInvocationPage(<String, Object?>{
        'items': <Object?>[_canonicalTracePayload()],
        'unexpected': true,
      }),
      isNull,
    );
    expect(
      parseSharedThreadRuntimeInvocationPage(<String, Object?>{
        'items': <Object?>[_canonicalTracePayload(), _canonicalTracePayload()],
      }),
      isNull,
    );
    expect(
      parseSharedThreadRuntimeInvocationPage(<String, Object?>{
        'items': <Object?>[
          _canonicalTracePayload(),
          _canonicalTracePayload(
            threadId: 'thread_2',
            runId: 'agent_run_2',
            dispatchId: 'dispatch_2',
            createdAt: '2026-08-31T23:59:00Z',
          ),
        ],
      }),
      isNull,
    );
    expect(
      parseSharedThreadRuntimeInvocationPage(<String, Object?>{
        'items': <Object?>[_canonicalTracePayload()],
        'nextCursor': '',
      }),
      isNull,
    );
    expect(
      parseSharedThreadRuntimeInvocationPage(<String, Object?>{
        'items': List<Object?>.generate(
          51,
          (index) => _canonicalTracePayload(
            runId: 'agent_run_$index',
            dispatchId: 'dispatch_$index',
          ),
        ),
      }),
      isNull,
    );
  });

  test('accepts backend tool budget and logical path bounds', () {
    final logicalPath = 'workspace/${List<String>.filled(4086, 'x').join()}';
    final payload = _canonicalTracePayload();
    payload['tools'] = <Object?>[
      for (var index = 0; index < 800; index += 1)
        <String, Object?>{
          'invocationId': 'runtime_tool_$index',
          'toolName': 'read',
          'status': 'succeeded',
          'durationMs': 1,
          'inputSummary': <String, Object?>{
            'logicalTarget': index == 0 ? logicalPath : 'workspace/$index',
            'offset': 0,
            'limit': 1,
          },
          'outputSummary': <String, Object?>{},
          'createdAt': '2026-09-01T00:00:01Z',
        },
    ];

    final parsed = parseSharedThreadRuntimeInvocationPage(<String, Object?>{
      'items': <Object?>[payload],
    });
    expect(parsed?.items.single.tools, hasLength(800));
    expect(
      parsed?.items.single.tools.first.inputSummary['logicalTarget'],
      logicalPath,
    );

    (payload['tools']! as List<Object?>).add(<String, Object?>{
      'invocationId': 'runtime_tool_800',
      'toolName': 'read',
      'status': 'succeeded',
      'inputSummary': <String, Object?>{'logicalTarget': 'workspace/800'},
      'outputSummary': <String, Object?>{},
      'createdAt': '2026-09-01T00:00:01Z',
    });
    expect(
      parseSharedThreadRuntimeInvocationPage(<String, Object?>{
        'items': <Object?>[payload],
      }),
      isNull,
    );
  });

  test('accepts backend-unbounded public runtime collections', () {
    final payload = _canonicalTracePayload();
    final selection = payload['selection']! as Map<String, Object?>;
    selection['skillProfileIds'] = <Object?>[
      for (var index = 0; index < 81; index += 1) 'skill_profile_$index',
    ];
    selection['skillReleaseVersions'] = <Object?>[
      for (var index = 0; index < 81; index += 1) 'skill_release_$index',
    ];
    payload['progress'] = <Object?>[
      for (var index = 0; index < 121; index += 1)
        <String, Object?>{
          'kind': 'item',
          'title': '步骤 $index',
          'status': 'completed',
          'createdAt': '2026-09-01T00:00:01Z',
        },
    ];
    payload['files'] = <Object?>[
      for (var index = 0; index < 121; index += 1)
        <String, Object?>{
          'ordinal': index,
          'category': 'runtime_input',
          'mediaType': 'application/x-runtime-$index',
          'sizeBytes': index,
          'editable': false,
        },
    ];
    payload['tools'] = <Object?>[
      <String, Object?>{
        'invocationId': 'runtime_tool_many_media',
        'toolName': 'read',
        'status': 'succeeded',
        'inputSummary': <String, Object?>{},
        'outputSummary': <String, Object?>{
          'mediaTypes': <Object?>[
            for (var index = 0; index < 33; index += 1)
              'application/x-output-$index',
          ],
        },
        'createdAt': '2026-09-01T00:00:01Z',
      },
    ];

    final parsed = parseSharedThreadRuntimeInvocationPage(<String, Object?>{
      'items': <Object?>[payload],
    });

    expect(parsed?.items.single.progress, hasLength(121));
    expect(parsed?.items.single.files, hasLength(121));
    expect(parsed?.items.single.skillProfileIds, hasLength(81));
    expect(parsed?.items.single.skillReleaseVersions, hasLength(81));
    expect(
      parsed?.items.single.tools.single.outputSummary['mediaTypes'],
      hasLength(33),
    );
  });

  test('runtime invocation list validates public query bounds', () {
    final client = ChatThreadMetadataClient(_apiClient(_QueueTransport([])));

    expect(
      () => client.listInvocations(threadId: 'thread_1', limit: 0),
      throwsArgumentError,
    );
    expect(
      () => client.listInvocations(threadId: 'thread_1', limit: 51),
      throwsArgumentError,
    );
    expect(
      () => client.listInvocations(threadId: 'thread_1', cursor: '   '),
      throwsArgumentError,
    );
    expect(
      () => client.listInvocations(
        threadId: 'thread_1',
        cursor: List<String>.filled(1025, 'x').join(),
      ),
      throwsArgumentError,
    );
  });

  test('parses versioned custom thread title', () {
    final title = parseSharedChatThreadMetadata(<String, Object?>{
      'thread': <String, Object?>{
        'threadId': 'thread_1',
        'title': '新的会话名',
        'titleMode': 'custom',
        'titleVersion': 2,
      },
    });
    expect(title?.titleMode, SharedChatThreadTitleMode.custom);
    expect(title?.titleVersion, 2);
  });

  test('runtime parser keeps only whitelisted public fields', () {
    final invocation = parseSharedThreadRuntimeInvocation(<String, Object?>{
      'schemaVersion': 'huahuo.thread-runtime-invocation.v1',
      'threadId': 'thread_1',
      'agentRunId': 'agent_run_1',
      'status': 'succeeded',
      'createdAt': '2026-09-01T00:00:00Z',
      'completedAt': '2026-09-01T00:00:02Z',
      'selection': <String, Object?>{
        'agentProfileId': 'renshe_content',
        'modelProfileId': 'model_1',
        'skillProfileIds': <Object?>['skill_1'],
        'prompt': 'must never be retained',
      },
      'requestSummary': <String, Object?>{
        'contentTypes': <Object?>['text'],
        'request': <String, Object?>{'raw': 'hidden'},
      },
      'tools': <Object?>[
        <String, Object?>{
          'invocationId': 'runtime_tool_1',
          'toolName': 'workspace_search',
          'status': 'succeeded',
          'durationMs': 430,
          'inputSummary': <String, Object?>{
            'query': '发布计划',
            'limit': 3,
            'redactedFields': <Object?>['query'],
            'privatePrompt': 'must never be retained',
          },
          'outputSummary': <String, Object?>{
            'outputFileCount': 1,
            'mediaTypes': <Object?>['image/png'],
            'totalSizeBytes': 12,
          },
          'createdAt': '2026-09-01T00:00:01Z',
        },
      ],
      'progress': <Object?>[
        <String, Object?>{
          'kind': 'plan',
          'title': '整理输入',
          'status': 'updated',
          'summary': '正在梳理已有资料',
          'createdAt': '2026-09-01T00:00:00.500Z',
        },
        <String, Object?>{
          'kind': 'item',
          'title': '检索工作区',
          'status': 'completed',
          'createdAt': '2026-09-01T00:00:01.500Z',
        },
      ],
      'files': <Object?>[
        <String, Object?>{'fileName': 'profile.md', 'sizeBytes': 12},
      ],
      'providerPayload': <String, Object?>{'secret': 'hidden'},
    });
    expect(invocation?.contentTypes, <String>['text']);
    expect(invocation?.tools.single.name, 'workspace_search');
    expect(invocation?.tools.single.state, 'succeeded');
    expect(invocation?.tools.single.invocationId, 'runtime_tool_1');
    expect(invocation?.tools.single.durationMs, 430);
    expect(
      invocation?.tools.single.createdAt,
      DateTime.utc(2026, 9, 1, 0, 0, 1),
    );
    expect(invocation?.tools.single.inputSummary['query'], '发布计划');
    expect(invocation?.tools.single.inputSummary['privatePrompt'], isNull);
    expect(invocation?.tools.single.outputSummary['outputFileCount'], 1);
    expect(invocation?.createdAt, DateTime.utc(2026, 9, 1));
    expect(invocation?.completedAt, DateTime.utc(2026, 9, 1, 0, 0, 2));
    expect(invocation?.progress, hasLength(2));
    expect(invocation?.progress.first.kind, 'plan');
    expect(invocation?.progress.first.status, 'updated');
    expect(invocation?.progress.first.summary, '正在梳理已有资料');
    expect(
      invocation?.progress.last.createdAt,
      DateTime.utc(2026, 9, 1, 0, 0, 1, 500),
    );
    expect(invocation?.files.single.name, 'profile.md');
  });

  test('every GET endpoint has a cache classification', () {
    for (final endpoint in EndpointCatalog.definitions.values) {
      if (endpoint.method == HttpMethod.get) {
        expect(endpoint.readCachePolicy, isNotNull, reason: endpoint.id);
      }
    }
  });
}

Map<String, Object?> _tracePayload() => <String, Object?>{
  'schemaVersion': 'huahuo.thread-runtime-invocation.v1',
  'threadId': 'thread_1',
  'agentRunId': 'agent_run_1',
  'status': 'succeeded',
  'selection': <String, Object?>{
    'agentProfileId': 'renshe_content',
    'modelProfileId': 'model_1',
    'skillProfileIds': <Object?>['skill_1'],
  },
  'requestSummary': <String, Object?>{
    'contentTypes': <Object?>['text'],
  },
  'tools': const <Object?>[],
  'files': <Object?>[
    <String, Object?>{'fileName': 'profile.md'},
  ],
};

Map<String, Object?> _canonicalTracePayload({
  String threadId = 'thread_1',
  String runId = 'agent_run_1',
  String dispatchId = 'dispatch_1',
  String createdAt = '2026-09-01T00:00:00Z',
}) => <String, Object?>{
  'schemaVersion': 'huahuo.thread-runtime-invocation.v1',
  'threadId': threadId,
  'agentRunId': runId,
  'dispatchId': dispatchId,
  'status': 'succeeded',
  'createdAt': createdAt,
  'completedAt': '2026-09-01T00:00:02Z',
  'selection': <String, Object?>{
    'agentProfileId': 'renshe_content',
    'agentReleaseVersion': 'agent_release_1',
    'modelProfileId': 'model_1',
    'skillProfileIds': <Object?>['skill_1'],
    'skillReleaseVersions': <Object?>['skill_release_1'],
  },
  'requestSummary': <String, Object?>{
    'contentTypes': <Object?>['text'],
    'attachmentCount': 1,
    'workspaceDocumentCount': 0,
    'creativePositioningId': 'positioning_1',
  },
  'tools': <Object?>[
    <String, Object?>{
      'invocationId': 'runtime_tool_1',
      'toolName': 'workspace_search',
      'status': 'succeeded',
      'durationMs': 430,
      'inputSummary': <String, Object?>{'query': '发布计划', 'limit': 3},
      'outputSummary': <String, Object?>{
        'outputFileCount': 1,
        'mediaTypes': <Object?>['image/png'],
        'totalSizeBytes': 12,
      },
      'createdAt': '2026-09-01T00:00:01Z',
    },
  ],
  'progress': <Object?>[
    <String, Object?>{
      'kind': 'item',
      'title': '检索工作区',
      'status': 'completed',
      'createdAt': '2026-09-01T00:00:01Z',
    },
  ],
  'files': <Object?>[
    <String, Object?>{
      'ordinal': 0,
      'category': 'attachment',
      'mediaType': 'image/png',
      'sizeBytes': 12,
      'editable': false,
    },
  ],
};

ApiClient _apiClient(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'test-device',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: () => 'token',
  ),
  transport: transport,
);

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this._responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}
