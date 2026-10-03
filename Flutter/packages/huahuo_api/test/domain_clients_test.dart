import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'AgentRun preserves fractional video duration and canonical completion',
    () async {
      for (final seconds in <num?>[36.734, 36, 0, null]) {
        final payload = _run(status: 'succeeded', terminal: true);
        (payload['usage']! as Map<String, Object?>)['videoSeconds'] = seconds;
        final transport = _QueueTransport(<ApiTransportResponse>[
          ApiTransportResponse(
            status: 200,
            body: <String, Object?>{'success': true, 'data': payload},
          ),
        ]);
        final result = await AgentRunClient(_client(transport)).get('run_1');
        expect(result.ok, isTrue);
        expect(result.data?.usage.videoSeconds, seconds);
        expect(result.data?.assistantMessageId, 'message_1');
        expect(result.data?.completionMode, 'normal');
        expect(result.data?.isSuccessful, isTrue);
      }
    },
  );

  test(
    'AgentRun rejects invalid video measurements without weakening usage',
    () {
      for (final value in <Object?>[
        -0.001,
        double.nan,
        double.infinity,
        double.negativeInfinity,
        '36.734',
        true,
      ]) {
        final payload = _run(status: 'succeeded', terminal: true);
        final usage = payload['usage']! as Map<String, Object?>;
        usage['videoSeconds'] = value;
        expect(
          () => AgentRunSnapshot.fromValue(payload),
          throwsFormatException,
        );
      }
      final missing = _run(status: 'succeeded', terminal: true);
      (missing['usage']! as Map<String, Object?>).remove('videoSeconds');
      expect(() => AgentRunSnapshot.fromValue(missing), throwsFormatException);
      final fractionalTokens = _run(status: 'succeeded', terminal: true);
      (fractionalTokens['usage']! as Map<String, Object?>)['inputTokens'] = 1.5;
      expect(
        () => AgentRunSnapshot.fromValue(fractionalTokens),
        throwsFormatException,
      );
    },
  );

  test(
    'AgentRun request uses only public selection and ordered input',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 202,
          body: <String, Object?>{
            'success': true,
            'data': _createRunResponse(_run(status: 'queued')),
          },
        ),
      ]);
      final client = AgentRunClient(_client(transport));

      final result = await client.create(
        AgentRunRequest(
          agentProfileId: 'renshe_content',
          skillProfileIds: const <String>[
            'renshe_content_creation',
            'a_skill',
            'renshe_content_creation',
          ],
          workspaceId: 'ws_1',
          input: SharedAgentInput(
            content: <SharedAgentInputContent>[
              SharedAgentTextContent(text: 'first'),
              SharedAgentWorkspaceDocumentContent(
                ownerKind: 'hnote',
                ownerId: 'note_1',
                part: 'raw',
                partRevisionId: 'part_rev_1',
              ),
            ],
          ),
        ),
        idempotencyKey: 'idem-run-1',
      );

      expect(result.ok, isTrue);
      expect(result.data?.isTerminal, isFalse);
      expect(result.data?.usage.measurementStatus, 'pending');
      final request = transport.requests.single;
      final body = jsonDecode(request.body!) as Map<String, dynamic>;
      expect(
        body['skillProfileIds'],
        orderedEquals(<String>['a_skill', 'renshe_content_creation']),
      );
      expect(body, isNot(contains('taskType')));
      expect(body, isNot(contains('runtimeProfileId')));
      expect(body, isNot(contains('prompt')));
      expect((body['input'] as Map)['content'], hasLength(2));
      expect(request.headers['X-Idempotency-Key'], 'idem-run-1');
      expect(request.headers.containsKey('Idempotency-Key'), isFalse);
    },
  );

  test(
    'shared Chat facade client owns create submit and detail transport',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'thread': <String, Object?>{'threadId': 'thread-1'},
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{'agentRunId': 'run-1'},
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'thread': <String, Object?>{'threadId': 'thread-1'},
              'messages': <Object?>[],
            },
          },
        ),
      ]);
      final client = SharedChatFacadeClient(_client(transport));

      final created = await client.createThread<ApiContractObject>(
        request: const SharedChatThreadCreateRequest(
          scene: 'self_media_creation_standard',
        ),
        idempotency: const IdempotencyRequestContext(
          explicitKey: 'chat-thread-key',
        ),
        parseData: ApiContractObject.fromValue,
      );
      final submitted = await client.sendTextMessage<ApiContractObject>(
        threadId: 'thread-1',
        request: SharedChatTextMessageRequest(
          agentProfileId: 'positioning_lv1',
          modelProfileId: 'deepseek-v4-flash-vision',
          content: <SharedAgentInputContent>[
            SharedAgentTextContent(text: '开始基础定位'),
          ],
        ),
        idempotency: const IdempotencyRequestContext(
          explicitKey: 'chat-message-key',
        ),
        parseData: ApiContractObject.fromValue,
      );
      final detail = await client.getThreadDetail<ApiContractObject>(
        threadId: 'thread-1',
        parseData: ApiContractObject.fromValue,
      );

      expect(created.ok, isTrue);
      expect(submitted.ok, isTrue);
      expect(detail.ok, isTrue);
      expect(transport.requests, hasLength(3));
      expect(transport.requests[0].method, 'POST');
      expect(transport.requests[0].url.path, '/api/v1/chat/threads');
      expect(jsonDecode(transport.requests[0].body!), <String, Object?>{
        'scene': 'self_media_creation_standard',
      });
      expect(
        transport.requests[0].headers['X-Idempotency-Key'],
        'chat-thread-key',
      );
      expect(transport.requests[1].method, 'POST');
      expect(
        transport.requests[1].url.path,
        '/api/v1/chat/threads/thread-1/messages',
      );
      expect(jsonDecode(transport.requests[1].body!), <String, Object?>{
        'agentProfileId': 'positioning_lv1',
        'modelProfileId': 'deepseek-v4-flash-vision',
        'input': <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '开始基础定位'},
          ],
        },
      });
      expect(
        transport.requests[1].headers['X-Idempotency-Key'],
        'chat-message-key',
      );
      expect(transport.requests[2].method, 'GET');
      expect(transport.requests[2].url.path, '/api/v1/chat/threads/thread-1');
    },
  );

  test('AgentRun cancellation sends the fixed public wire contract', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 202,
        body: <String, Object?>{
          'success': true,
          'data': _run(status: 'aborting'),
        },
      ),
    ]);

    final result = await AgentRunClient(
      _client(transport),
    ).cancel('run_1', idempotencyKey: 'cancel-run-1');

    expect(result.ok, isTrue);
    expect(result.data?.agentRunId, 'run_1');
    expect(result.data?.status, 'aborting');
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/v1/agent/runs/run_1/cancel');
    expect(jsonDecode(request.body!), <String, Object?>{
      'reason': 'user_cancelled',
    });
    expect(request.headers['X-Idempotency-Key'], 'cancel-run-1');
    expect(request.headers, isNot(contains('Idempotency-Key')));
    final endpoint = EndpointCatalog.byId('cancelAgentRun');
    expect(endpoint.idempotency, EndpointIdempotencyPolicy.required);
    expect(endpoint.idempotencyHeaderName, 'X-Idempotency-Key');
  });

  test('AgentRun terminal result and safe Tool output are parsed', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _run(status: 'succeeded', terminal: true),
        },
      ),
    ]);

    final result = await AgentRunClient(_client(transport)).get('run_1');

    expect(result.ok, isTrue);
    expect(result.data?.isTerminal, isTrue);
    expect(result.data?.isSuccessful, isTrue);
    expect(result.data?.assistantMessageId, 'message_1');
    expect(result.data?.completionMode, 'normal');
    expect(result.data?.usage.accountedCredits, 30);
    expect(result.data?.outputFiles.single.resourceId, 'resource_1');
    expect(result.data?.toolTrace.single.inputSummary, <String, Object?>{
      'promptSummary': '一个新鲜的西瓜，放在木质桌面上',
      'count': 1,
    });
  });

  test(
    'AgentRun rejects unsafe Tool input-summary fields and values',
    () async {
      final unknownField = _run(status: 'succeeded', terminal: true);
      final unknownTrace = unknownField['toolTrace']! as List<Object?>;
      (unknownTrace.single! as Map<String, Object?>)['inputSummary'] =
          <String, Object?>{'providerApiKey': 'must-not-cross-contract'};
      final invalidValue = _run(status: 'succeeded', terminal: true);
      final invalidTrace = invalidValue['toolTrace']! as List<Object?>;
      (invalidTrace.single! as Map<String, Object?>)['inputSummary'] =
          <String, Object?>{'count': 'one'};
      final foreignMarker = _run(status: 'succeeded', terminal: true);
      final foreignMarkerTrace = foreignMarker['toolTrace']! as List<Object?>;
      (foreignMarkerTrace.single!
          as Map<String, Object?>)['inputSummary'] = <String, Object?>{
        'promptSummary': '安全摘要',
        'redactedFields': <Object?>['providerApiKey'],
      };
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(unknownField),
        _objectResponse(invalidValue),
        _objectResponse(foreignMarker),
      ]);
      final client = AgentRunClient(_client(transport));

      expect((await client.get('run_1')).error?.code, 'API_RESPONSE_INVALID');
      expect((await client.get('run_1')).error?.code, 'API_RESPONSE_INVALID');
      expect((await client.get('run_1')).error?.code, 'API_RESPONSE_INVALID');
    },
  );

  test('AgentRun accepts public input summaries for every Chat Tool', () async {
    const summaries = <String, Map<String, Object?>>{
      'read': <String, Object?>{
        'logicalTarget': 'Notes/customer.md',
        'offset': 0,
        'limit': 50,
      },
      'workspace_list': <String, Object?>{
        'logicalDirectory': 'Assets',
        'depth': 2,
        'limit': 100,
      },
      'workspace_search': <String, Object?>{
        'query': '客户案例',
        'logicalScope': 'Notes',
        'limit': 10,
        'timeRange': 'recent',
      },
      'write': <String, Object?>{
        'logicalTarget': 'Notes/output.md',
        'operation': 'replace',
        'contentBytes': 1024,
      },
      'image_analysis': <String, Object?>{
        'attachmentCount': 1,
        'instructionSummary': '分析画面内容',
      },
      'image_generation': <String, Object?>{
        'promptSummary': '生成产品封面',
        'count': 1,
        'aspectRatio': '1:1',
      },
      'video_analysis': <String, Object?>{
        'attachmentCount': 1,
        'instructionSummary': '分析视频节奏',
      },
      'huahuo_hotspot_query': <String, Object?>{
        'keywords': <String>['AI', '营销'],
        'timeRange': 'today',
        'limit': 20,
        'action': 'search',
        'date': '2026-08-22',
        'rankCount': 10,
      },
    };
    final transport = _QueueTransport(<ApiTransportResponse>[
      for (final entry in summaries.entries)
        _objectResponse(
          _run(status: 'succeeded', terminal: true)
            ..['toolTrace'] = <Object?>[
              <String, Object?>{
                'invocationId': 'invocation_${entry.key}',
                'toolName': entry.key,
                'state': 'finished',
                'outcome': 'succeeded',
                'createdAt': '2026-08-22T05:00:00Z',
                'completedAt': '2026-08-22T05:00:01Z',
                'inputSummary': entry.value,
                'outputFiles': <Object?>[],
              },
            ],
        ),
    ]);
    final client = AgentRunClient(_client(transport));

    for (final entry in summaries.entries) {
      final result = await client.get('run_1');
      expect(result.ok, isTrue, reason: entry.key);
      expect(result.data?.isTerminal, isTrue, reason: entry.key);
      expect(
        result.data?.toolTrace.single.inputSummary,
        entry.value,
        reason: entry.key,
      );
    }
  });

  test(
    'AgentRun retains the backend public workspace_list Tool trace',
    () async {
      final run = _run(status: 'running')
        ..['toolTrace'] = <Object?>[
          <String, Object?>{
            'invocationId': 'invocation_workspace_list',
            'toolName': 'workspace_list',
            'state': 'started',
            'outcome': null,
            'createdAt': '2026-08-17T08:00:00Z',
            'completedAt': null,
            'outputFiles': <Object?>[],
          },
        ];
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(run),
      ]);

      final result = await AgentRunClient(_client(transport)).get('run_1');

      expect(result.ok, isTrue);
      expect(result.data?.toolTrace.single.toolName, 'workspace_list');
    },
  );

  test('AgentRun terminal completion modes are classified safely', () async {
    for (final expectation in <(String, bool, bool, bool)>[
      ('normal', true, false, false),
      ('degraded', false, true, false),
      ('system_fallback', false, false, true),
      ('cancelled', false, false, false),
    ]) {
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': _run(
              status: 'succeeded',
              terminal: true,
              completionMode: expectation.$1,
            ),
          },
        ),
      ]);

      final result = await AgentRunClient(_client(transport)).get('run_1');

      expect(result.data?.hasDurableAssistantResult, isTrue);
      expect(result.data?.isSuccessful, expectation.$2);
      expect(result.data?.isDegraded, expectation.$3);
      expect(result.data?.isSystemFallback, expectation.$4);
    }
  });

  test('AgentRun orphaned status is terminal and non-successful', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _run(status: 'orphaned'),
        },
      ),
    ]);

    final result = await AgentRunClient(_client(transport)).get('run_1');

    expect(result.ok, isTrue);
    expect(result.data?.isTerminal, isTrue);
    expect(result.data?.isSuccessful, isFalse);
  });

  test('AgentRun events preserve sequence and gap recovery metadata', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'sequence': 8,
                'eventType': 'run.stage_changed',
                'status': 'running',
                'data': <String, Object?>{'stage': 'writing'},
                'createdAt': '2026-08-01T00:00:08Z',
              },
            ],
            'nextAfterSequence': 8,
            'hasMore': false,
            'oldestAvailableSequence': 3,
            'latestSequence': 8,
            'gap': true,
          },
        },
      ),
    ]);

    final result = await AgentRunClient(
      _client(transport),
    ).events('run_1', afterSequence: 2);

    expect(result.ok, isTrue);
    expect(result.data?.items.single.sequence, 8);
    expect(result.data?.items.single.data?.fields['stage'], 'writing');
    expect(result.data?.gap, isTrue);
    expect(result.data?.oldestAvailableSequence, 3);
    expect(transport.requests.single.url.queryParameters['afterSequence'], '2');
  });

  test(
    'AgentRun detail and event leases abort after their last consumer',
    () async {
      final transport = _BlockingCancellableTransport();
      final client = AgentRunClient(_client(transport));

      final detail = client.leaseGet('run_1');
      final events = client.leaseEvents('run_1', afterSequence: 2);
      await _waitForRequestCount(transport.requests, 2);

      detail.cancel();
      events.cancel();

      expect((await detail.result).error?.code, 'API_REQUEST_CANCELLED');
      expect((await events.result).error?.code, 'API_REQUEST_CANCELLED');
      expect(transport.cancelCalls, 2);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/agent/runs/run_1',
        '/api/v1/agent/runs/run_1/events',
      ]);
    },
  );

  test('AgentRun SSE keeps event, gap and capacity recovery typed', () async {
    final transport = _StreamingTransport(
      ApiTransportStreamResponse(
        status: 200,
        headers: const <String, String>{},
        events: Stream<ApiTransportStreamEvent>.fromIterable(
          const <ApiTransportStreamEvent>[
            ApiTransportStreamEvent(
              id: '9',
              event: 'run.stage_changed',
              data: <String, Object?>{
                'sequence': 9,
                'eventType': 'draft_delta',
                'status': 'running',
                'data': <String, Object?>{
                  'deltaText': '第一段流式回复',
                  'replace': false,
                },
                'createdAt': '2026-08-01T00:00:09Z',
              },
            ),
            ApiTransportStreamEvent(
              id: '10',
              event: 'gap',
              data: <String, Object?>{
                'error': <String, Object?>{
                  'code': 'RUNTIME_EVENT_GAP',
                  'retryable': false,
                  'oldestAvailableSequence': 5,
                  'latestSequence': 10,
                  'resumeAfterSequence': 4,
                },
              },
            ),
            ApiTransportStreamEvent(
              event: 'error',
              data: <String, Object?>{
                'error': <String, Object?>{
                  'code': 'RUNTIME_CAPACITY_UNAVAILABLE',
                  'retryable': true,
                },
              },
            ),
            ApiTransportStreamEvent(comment: 'heartbeat'),
          ],
        ),
      ),
    );

    final opened = await AgentRunClient(
      _client(transport),
    ).eventStream('run_1', lastEventId: '8');
    final events = await opened.data!.toList();

    expect(opened.ok, isTrue);
    expect(events[0].data?.kind, AgentRunStreamPayloadKind.event);
    expect(events[0].data?.item?.sequence, 9);
    expect(events[0].data?.item?.data?.deltaText, '第一段流式回复');
    expect(events[0].data?.item?.data?.replace, isFalse);
    expect(events[1].data?.kind, AgentRunStreamPayloadKind.gap);
    expect(events[1].data?.resumeAfterSequence, 4);
    expect(events[2].data?.kind, AgentRunStreamPayloadKind.capacityError);
    expect(events[2].data?.retryable, isTrue);
    expect(events[3].comment, 'heartbeat');
    expect(transport.requests.single.headers['Last-Event-ID'], '8');
    expect(transport.requests.single.url.queryParameters['afterSequence'], '8');
  });

  test('AgentRun rejects undocumented state and incomplete success', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _run(status: 'accepted'),
        },
      ),
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _run(status: 'succeeded'),
        },
      ),
    ]);
    final client = AgentRunClient(_client(transport));

    final undocumented = await client.get('run_1');
    final incomplete = await client.get('run_1');

    expect(undocumented.ok, isFalse);
    expect(undocumented.error?.code, 'API_RESPONSE_INVALID');
    expect(incomplete.ok, isFalse);
    expect(incomplete.error?.code, 'API_RESPONSE_INVALID');
  });

  test(
    'Workspace lifecycle reads are parsed into strict API 21 DTOs',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[_workspaceSummary()],
            },
          },
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              ..._workspaceSummary(),
              'bootstrapReceiptId': 'bootstrap_1',
              'bootstrapContentCursor': '100',
              'contentCursor': '184',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'currentContentBytes': 10,
              'retainedHistoryBytes': 20,
              'resourceBytes': 30,
              'logicalTotalBytes': 60,
              'formalProjectionBytes': 55,
              'userLogicalTotalBytes': 60,
              'limitBytes': 32212254720,
              'remainingBytes': 32212254660,
              'fileCountLimit': null,
              'measurementStatus': 'partial',
              'unmeasuredObjectCount': 2,
              'calculatedAt': '2026-08-07T09:00:00Z',
            },
          },
        ),
      ]);
      final client = WorkspaceLifecycleClient(_client(transport));

      final list = await client.list();
      final detail = await client.detail('ws_1');
      final usage = await client.storageUsage('ws_1');

      expect(list.data?.items.single.workspaceId, 'ws_1');
      expect(detail.data?.contentCursor, '184');
      expect(usage.data?.measurementStatus, 'partial');
      expect(usage.data?.limitBytes, 32212254720);
      expect(usage.data?.remainingBytes, 32212254660);
      expect(usage.data?.fileCountLimit, isNull);
      expect(usage.data?.calculatedAt.isUtc, isTrue);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces',
        '/api/v1/workspaces/ws_1',
        '/api/v1/workspaces/ws_1/storage-usage',
      ]);
    },
  );

  test('Workspace lifecycle mutations preserve ETag and idempotency', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 201,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'workspaceId': 'ws_2',
            'state': 'ready',
            'etag': '"workspace-2"',
            'bootstrapReceiptId': 'bootstrap_2',
            'bootstrapContentCursor': '1',
            'contentCursor': '1',
          },
        },
      ),
      for (var index = 0; index < 4; index++)
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{'success': true, 'data': _workspaceSummary()},
        ),
    ]);
    final client = WorkspaceLifecycleClient(_client(transport));

    final created = await client.create(
      displayName: '第二空间',
      setAsDefault: true,
      idempotencyKey: 'workspace-create-1',
    );
    await client.update(
      'ws_1',
      displayName: '个人空间',
      etag: '"workspace-1"',
      idempotencyKey: 'workspace-update-1',
    );
    await client.setDefault(
      'ws_1',
      etag: '"workspace-1"',
      idempotencyKey: 'workspace-default-1',
    );
    await client.disable(
      'ws_1',
      etag: '"workspace-1"',
      idempotencyKey: 'workspace-disable-1',
    );
    await client.restore(
      'ws_1',
      etag: '"workspace-1"',
      idempotencyKey: 'workspace-restore-1',
    );

    expect(created.data?.workspaceId, 'ws_2');
    expect(created.data?.contentCursor, '1');
    expect(transport.requests.map((request) => request.method), <String>[
      'POST',
      'PATCH',
      'POST',
      'POST',
      'POST',
    ]);
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/workspaces',
      '/api/v1/workspaces/ws_1',
      '/api/v1/workspaces/ws_1/set-default',
      '/api/v1/workspaces/ws_1/disable',
      '/api/v1/workspaces/ws_1/restore',
    ]);
    expect(jsonDecode(transport.requests.first.body!), <String, Object?>{
      'displayName': '第二空间',
      'setAsDefault': true,
    });
    expect(jsonDecode(transport.requests[1].body!), <String, Object?>{
      'displayName': '个人空间',
    });
    expect(transport.requests.first.headers, isNot(contains('If-Match')));
    for (final request in transport.requests.skip(1)) {
      expect(request.headers['If-Match'], '"workspace-1"');
    }
    expect(
      transport.requests.map((request) => request.headers['X-Idempotency-Key']),
      <String>[
        'workspace-create-1',
        'workspace-update-1',
        'workspace-default-1',
        'workspace-disable-1',
        'workspace-restore-1',
      ],
    );
  });

  test(
    'recording-card ownership flow sends direct SN bind with idempotency',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'binding': <String, Object?>{
                'bindingId': 'binding_1',
                'deviceId': 'device_1',
                'serialNumberMasked': 'SN****1234',
                'displayName': '无限花火录音卡',
                'modelCode': 'fw920',
                'firmwareVersion': '1.0.6',
                'status': 'active',
                'bindingGeneration': 4,
                'boundAt': '2026-08-21T00:00:00Z',
              },
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{'binding': null},
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'binding': <String, Object?>{
                'bindingId': 'binding_2',
                'deviceId': 'device_2',
                'serialNumberMasked': '****1234',
                'status': 'active',
                'bindingGeneration': 5,
                'boundAt': '2026-08-21T08:01:00Z',
              },
              'idempotent': false,
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'bindingId': 'binding_2',
              'deviceId': 'device_2',
              'status': 'revoked',
              'bindingGeneration': 6,
              'resetRequired': false,
              'idempotent': false,
            },
          },
        ),
      ]);
      final client = RecordingCardBindingClient(_client(transport));

      final bound = await client.currentBinding();
      final unbound = await client.currentBinding();
      final bind = await client.bind(
        serialNumber: 'SP63A00001',
        displayName: '我的录音卡',
        idempotencyKey: 'recording-card-bind-test-1',
      );
      final removed = await client.unbind(
        deviceId: 'device_2',
        bindingId: 'binding_2',
        idempotencyKey: 'recording-card-unbind-test-1',
      );

      expect(bound.data?.binding?.serialNumberMasked, 'SN****1234');
      expect(bound.data?.binding?.displayName, '无限花火录音卡');
      expect(bound.data?.binding?.bindingGeneration, 4);
      expect(unbound.data?.binding, isNull);
      expect(bind.data?.binding.bindingId, 'binding_2');
      expect(removed.data?.status, 'revoked');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/recording-card/device-binding',
        '/api/v1/recording-card/device-binding',
        '/api/v1/recording-card/bind',
        '/api/v1/recording-card/devices/device_2/unbind',
      ]);
      for (final request in transport.requests.take(2)) {
        expect(request.headers['Authorization'], startsWith('Bearer '));
        expect(request.headers, isNot(contains('X-Idempotency-Key')));
        expect(request.headers, isNot(contains('Idempotency-Key')));
      }
      expect(
        transport.requests[2].headers['X-Idempotency-Key'],
        'recording-card-bind-test-1',
      );
      expect(
        transport.requests[3].headers['X-Idempotency-Key'],
        'recording-card-unbind-test-1',
      );
      expect(jsonDecode(transport.requests[2].body!), <String, Object?>{
        'serialNumber': 'SP63A00001',
        'displayName': '我的录音卡',
      });
      expect(jsonDecode(transport.requests[3].body!), <String, Object?>{
        'bindingId': 'binding_2',
      });
    },
  );

  test(
    'current Workspace Profile read preserves the deployed snapshot',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'workspaceId': 'ws_1',
              'overview': '',
              'positioning': '面向本地创业者的访谈账号。',
              'conclusions': <Object?>[],
              'files': <Object?>[],
              'updatedAt': '2026-08-10T08:00:00Z',
            },
          },
        ),
      ]);
      final result = await WorkspaceLifecycleClient(
        _client(transport),
      ).currentProfile();

      expect(result.ok, isTrue);
      expect(result.data?.fields['workspaceId'], 'ws_1');
      expect(result.data?.fields['positioning'], '面向本地创业者的访谈账号。');
      final request = transport.requests.single;
      expect(request.url.path, '/api/v1/workspaces/current/profile');
      expect(request.headers['Authorization'], startsWith('Bearer '));
      expect(request.headers, isNot(contains('X-Idempotency-Key')));
      expect(request.headers, isNot(contains('Idempotency-Key')));
    },
  );

  test(
    'Workspace snapshot and changes preserve decimal string cursors',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'snapshotId': 'snapshot_1',
              'atCursor': '184',
              'folders': <Object?>[_workspaceFolder()],
              'objects': <Object?>[
                <String, Object?>{
                  'ownerRef': <String, Object?>{
                    'workspaceId': 'ws_1',
                    'kind': 'hnote',
                    'id': 'note_1',
                  },
                  'tombstone': false,
                  'etag': '"note-1"',
                  'resourceRefs': <Object?>[
                    <String, Object?>{
                      'resourceId': 'resource_1',
                      'order': 0,
                      'usage': 'inline_image',
                      'anchor': null,
                      'alt': null,
                      'sha256': 'hash_1',
                      'mimeType': 'image/png',
                    },
                  ],
                  'revisionId': 'note_revision_1',
                },
              ],
              'hasMore': true,
              'nextPageToken': 'page_2',
            },
          },
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'events': <Object?>[_workspaceEvent()],
              'nextAfter': '185',
              'hasMore': false,
            },
          },
        ),
      ]);
      final client = WorkspaceContentClient(_client(transport));

      final snapshot = await client.contentSnapshot(
        'ws_1',
        pageToken: 'page_1',
      );
      final changes = await client.changes('ws_1', after: '184', limit: 50);

      expect(snapshot.data?.atCursor, '184');
      expect(snapshot.data?.folders.single.folderId, 'folder_1');
      expect(snapshot.data?.objects.single.revisionId, 'note_revision_1');
      expect(changes.data?.events.single.cursor, '185');
      expect(changes.data?.events.single.previousRevisionId, 'note_revision_1');
      expect(changes.data?.nextAfter, '185');
      expect(
        transport.requests.first.url.queryParameters['pageToken'],
        'page_1',
      );
      expect(transport.requests.last.url.queryParameters, <String, String>{
        'after': '184',
        'limit': '50',
      });
    },
  );

  test(
    'Workspace changes exposes cursor expiry and rejects numeric cursors',
    () async {
      final expiredTransport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 410,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'CONTENT_CURSOR_EXPIRED',
              'message': 'snapshot required',
              'retryable': false,
            },
          },
        ),
      ]);
      final expiredClient = WorkspaceContentClient(_client(expiredTransport));

      final expired = await expiredClient.changes('ws_1', after: '100');

      expect(expired.ok, isFalse);
      expect(expired.status, 410);
      expect(expired.error?.code, 'CONTENT_CURSOR_EXPIRED');

      final malformedTransport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'events': <Object?>[],
              'nextAfter': 185,
              'hasMore': false,
            },
          },
        ),
      ]);
      final malformed = await WorkspaceContentClient(
        _client(malformedTransport),
      ).changes('ws_1', after: '184');
      expect(malformed.error?.code, 'API_RESPONSE_INVALID');
      expect(
        () => WorkspaceContentClient(
          _client(_QueueTransport(<ApiTransportResponse>[])),
        ).changes('ws_1', after: 'not-a-cursor'),
        throwsArgumentError,
      );
    },
  );

  test(
    'Workspace conditional snapshot forwards ETag and accepts an empty 304',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          headers: const <String, String>{'ETag': '"snapshot-1"'},
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'snapshotId': 'snapshot_1',
              'atCursor': '184',
              'folders': <Object?>[],
              'objects': <Object?>[],
              'hasMore': false,
              'nextPageToken': null,
            },
          },
        ),
        const ApiTransportResponse(
          status: 304,
          headers: <String, String>{'etag': '"snapshot-1"'},
          body: null,
        ),
      ]);
      final client = WorkspaceContentClient(_client(transport));

      final snapshot = await client.conditionalContentSnapshot(
        'ws_1',
        pageToken: 'page_1',
        ifNoneMatch: '"snapshot-0"',
      );
      final unchanged = await client.conditionalContentSnapshot(
        'ws_1',
        ifNoneMatch: snapshot.etag,
      );

      expect(snapshot.ok, isTrue);
      expect(snapshot.isNotModified, isFalse);
      expect(snapshot.data?.snapshotId, 'snapshot_1');
      expect(snapshot.etag, '"snapshot-1"');
      expect(unchanged.ok, isTrue);
      expect(unchanged.isNotModified, isTrue);
      expect(unchanged.status, 304);
      expect(unchanged.data, isNull);
      expect(unchanged.etag, '"snapshot-1"');
      expect(
        transport.requests.first.url.queryParameters['pageToken'],
        'page_1',
      );
      expect(transport.requests.first.headers['If-None-Match'], '"snapshot-0"');
      expect(transport.requests.last.headers['If-None-Match'], '"snapshot-1"');
    },
  );

  test('Workspace content read leases abort every abandoned GET', () async {
    final transport = _BlockingCancellableTransport();
    final client = WorkspaceContentClient(_client(transport));

    final snapshot = client.leaseConditionalContentSnapshot(
      'ws_1',
      ifNoneMatch: '"snapshot-1"',
    );
    final changes = client.leaseChanges('ws_1', after: '184');
    final folder = client.leaseFolder(
      'ws_1',
      'folder_1',
      revisionId: 'folder_revision_1',
    );
    final note = client.leaseNote(
      'ws_1',
      'note_1',
      revisionId: 'note_revision_1',
    );
    final part = client.leaseNotePart(
      'ws_1',
      'note_1',
      'raw',
      partRevisionId: 'raw_revision_1',
    );
    await _waitForRequestCount(transport.requests, 5);

    snapshot.cancel();
    changes.cancel();
    folder.cancel();
    note.cancel();
    part.cancel();

    expect((await snapshot.result).error?.code, 'API_REQUEST_CANCELLED');
    expect((await changes.result).error?.code, 'API_REQUEST_CANCELLED');
    expect((await folder.result).error?.code, 'API_REQUEST_CANCELLED');
    expect((await note.result).error?.code, 'API_REQUEST_CANCELLED');
    expect((await part.result).error?.code, 'API_REQUEST_CANCELLED');
    expect(transport.cancelCalls, 5);
    expect(
      transport.requests.map((request) => request.url.path).toSet(),
      <String>{
        '/api/v1/workspaces/ws_1/content-snapshot',
        '/api/v1/workspaces/ws_1/content-changes',
        '/api/v1/workspaces/ws_1/folders/folder_1',
        '/api/v1/workspaces/ws_1/notes/note_1',
        '/api/v1/workspaces/ws_1/notes/note_1/parts/raw',
      },
    );
  });

  test(
    'Folder mutations send idempotency, If-Match and typed receipts',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        for (var index = 0; index < 2; index += 1)
          ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': _workspaceFolder(cursor: '${185 + index}'),
            },
          ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'eventId': 'event_folder_move',
              'workspaceId': 'ws_1',
              'cursor': '187',
              'operationId': 'operation_folder_move',
              'occurredAt': '2026-08-07T09:01:00Z',
              'objectKind': 'folder',
              'objectId': 'folder_1',
              'changeType': 'moved',
              'revisionId': 'folder_revision_3',
              'previousRevisionId': 'folder_revision_2',
              'tombstone': false,
              'resourcePinDelta': <String, Object?>{
                'added': <Object?>[],
                'released': <Object?>[],
              },
            },
          },
        ),
        for (var index = 0; index < 2; index += 1)
          ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'affectedObjectCount': 2,
                'firstContentCursor': '${188 + index * 2}',
                'contentCursor': '${189 + index * 2}',
              },
            },
          ),
      ]);
      final client = WorkspaceContentClient(_client(transport));

      await client.createFolder(
        'ws_1',
        displayName: ' Research ',
        parentFolderId: null,
        idempotencyKey: 'idem-folder-create',
      );
      await client.updateFolder(
        'ws_1',
        'folder_1',
        displayName: 'Research 2',
        etag: '"folder-1"',
        idempotencyKey: 'idem-folder-update',
      );
      final moved = await client.moveFolder(
        'ws_1',
        'folder_1',
        parentFolderId: 'folder_parent',
        etag: '"folder-2"',
        idempotencyKey: 'idem-folder-move',
      );
      final deleted = await client.deleteFolder(
        'ws_1',
        'folder_1',
        etag: '"folder-3"',
        idempotencyKey: 'idem-folder-delete',
      );
      final restored = await client.restoreFolder(
        'ws_1',
        'folder_1',
        parentFolderId: null,
        overrideParentFolder: true,
        etag: '"folder-4"',
        idempotencyKey: 'idem-folder-restore',
      );

      expect(deleted.data?.affectedObjectCount, 2);
      expect(restored.data?.contentCursor, '191');
      expect(moved.data?.objectKind, 'folder');
      expect(moved.data?.changeType, 'moved');
      expect(transport.requests.map((request) => request.method), <String>[
        'POST',
        'PATCH',
        'POST',
        'DELETE',
        'POST',
      ]);
      expect(
        transport.requests.map(
          (request) => request.headers['X-Idempotency-Key'],
        ),
        <String>[
          'idem-folder-create',
          'idem-folder-update',
          'idem-folder-move',
          'idem-folder-delete',
          'idem-folder-restore',
        ],
      );
      for (final request in transport.requests) {
        expect(request.headers.containsKey('Idempotency-Key'), isFalse);
      }
      expect(transport.requests.first.headers.containsKey('If-Match'), isFalse);
      for (final request in transport.requests.skip(1)) {
        expect(request.headers['If-Match'], isNotNull);
      }
      expect(jsonDecode(transport.requests.first.body!), <String, Object?>{
        'displayName': 'Research',
        'parentFolderId': null,
      });
      expect(jsonDecode(transport.requests[2].body!), <String, Object?>{
        'parentFolderId': 'folder_parent',
      });
      expect(jsonDecode(transport.requests.last.body!), <String, Object?>{
        'parentFolderId': null,
      });
    },
  );

  test('Workspace Folder detail forwards an exact event revision', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _workspaceFolder(
            revision: 'folder_revision_exact',
            cursor: '192',
          ),
        },
      ),
    ]);

    final result = await WorkspaceContentClient(
      _client(transport),
    ).folder('ws_1', 'folder_1', revisionId: 'folder_revision_exact');

    expect(result.ok, isTrue);
    expect(result.data?.currentRevisionId, 'folder_revision_exact');
    expect(
      transport.requests.single.url.queryParameters['revisionId'],
      'folder_revision_exact',
    );
  });

  test('HNote batch move uses per-Note ETags and an exact receipt', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'notes': <Object?>[
              <String, Object?>{
                'noteId': 'note_1',
                'noteRevisionId': 'note_revision_3',
                'etag': '"hnote-3"',
                'contentCursor': '192',
              },
            ],
          },
        },
      ),
    ]);
    final result = await WorkspaceContentClient(_client(transport))
        .batchMoveNotes(
          'ws_1',
          folderId: null,
          notes: const <SharedHNoteBatchMoveInput>[
            SharedHNoteBatchMoveInput(noteId: 'note_1', etag: '"hnote-2"'),
          ],
          idempotencyKey: 'idem-note-batch-move',
        );

    expect(result.ok, isTrue);
    expect(result.data?.notes.single.noteRevisionId, 'note_revision_3');
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/v1/workspaces/ws_1/notes/batch-move');
    expect(request.headers['X-Idempotency-Key'], 'idem-note-batch-move');
    expect(request.headers.containsKey('Idempotency-Key'), isFalse);
    expect(request.headers.containsKey('If-Match'), isFalse);
    expect(jsonDecode(request.body!), <String, Object?>{
      'folderId': null,
      'notes': <Object?>[
        <String, Object?>{'noteId': 'note_1', 'etag': '"hnote-2"'},
      ],
    });
  });

  test('HNote mutations use formal routes and exact typed revisions', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      for (var index = 0; index < 2; index += 1)
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': _workspaceHNote(cursor: '${200 + index}'),
          },
        ),
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _tombstoneEvent(cursor: '202'),
        },
      ),
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _workspaceHNote(cursor: '203'),
        },
      ),
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _workspaceHNote(cursor: '204'),
        },
      ),
    ]);
    final client = WorkspaceContentClient(_client(transport));

    await client.createNote(
      'ws_1',
      title: ' Interview ',
      rawMarkdown: '# Raw',
      outlineMarkdown: '',
      germinationMarkdown: '',
      resourceRefs: <SharedHNoteResourceInput>[
        SharedHNoteResourceInput(
          resourceId: 'resource_1',
          usage: 'inline_image',
        ),
      ],
      idempotencyKey: 'idem-note-create',
    );
    await client.updateNote(
      'ws_1',
      'note_1',
      title: 'Interview 2',
      parts: <String, String>{'outline': 'Outline'},
      etag: '"note-1"',
      idempotencyKey: 'idem-note-update',
    );
    await client.deleteNote(
      'ws_1',
      'note_1',
      etag: '"note-2"',
      idempotencyKey: 'idem-note-delete',
    );
    final restored = await client.restoreNote(
      'ws_1',
      'note_1',
      etag: '"note-3"',
      idempotencyKey: 'idem-note-restore',
    );
    final part = await client.putNotePart(
      'ws_1',
      'note_1',
      'raw',
      markdown: '# changed',
      basePartRevisionId: 'raw_revision_1',
      etag: '"note-4"',
      idempotencyKey: 'idem-note-part',
    );

    expect(part.data?.raw.partRevisionId, 'raw_revision_3');
    expect(restored.data?.title, 'Restored note');
    expect(restored.data?.folderId, 'folder_1');
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/workspaces/ws_1/notes',
      '/api/v1/workspaces/ws_1/notes/note_1',
      '/api/v1/workspaces/ws_1/notes/note_1',
      '/api/v1/workspaces/ws_1/notes/note_1/restore',
      '/api/v1/workspaces/ws_1/notes/note_1/parts/raw',
    ]);
    expect(transport.requests[2].method, 'DELETE');
    expect(transport.requests.first.headers.containsKey('If-Match'), isFalse);
    for (final request in transport.requests.skip(1)) {
      expect(request.headers['If-Match'], isNotNull);
    }
    expect(
      transport.requests.map((request) => request.headers['X-Idempotency-Key']),
      <String>[
        'idem-note-create',
        'idem-note-update',
        'idem-note-delete',
        'idem-note-restore',
        'idem-note-part',
      ],
    );
    for (final request in transport.requests) {
      expect(request.headers.containsKey('Idempotency-Key'), isFalse);
    }
    expect(jsonDecode(transport.requests.first.body!), <String, Object?>{
      'title': 'Interview',
      'sourceKind': 'manual',
      'folderId': null,
      'parts': <String, Object?>{
        'raw': '# Raw',
        'outline': '',
        'germination': '',
      },
      'resourceRefs': <Object?>[
        <String, Object?>{'resourceId': 'resource_1', 'usage': 'inline_image'},
      ],
    });
    expect(jsonDecode(transport.requests.last.body!), <String, Object?>{
      'contentMarkdown': '# changed',
      'basePartRevisionId': 'raw_revision_1',
    });
  });

  test('manual assets use the deployed Workspace Note contract', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 202,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'note': <String, Object?>{'noteId': 'note_manual_1'},
            'partRevision': <String, Object?>{'partRevisionId': 'raw_manual_1'},
          },
        },
      ),
    ]);
    final client = WorkspaceContentClient(_client(transport));

    final result = await client.createManualNote(
      'ws_1',
      title: ' 手动资产 ',
      contentMarkdown: '真实正文',
      idempotencyKey: 'idem-manual-note',
    );

    expect(result.ok, isTrue);
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/v1/workspaces/ws_1/notes/manual');
    expect(request.headers['X-Idempotency-Key'], 'idem-manual-note');
    expect(request.headers.containsKey('Idempotency-Key'), isFalse);
    expect(jsonDecode(request.body!), <String, Object?>{
      'title': '手动资产',
      'contentMarkdown': '真实正文',
    });
  });

  test('manual Note raw update sends the exact base part revision', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{'accepted': true},
        },
      ),
    ]);
    final client = WorkspaceContentClient(_client(transport));

    final result = await client.updateLegacyRawNotePart(
      'ws_1',
      'note_manual_1',
      contentMarkdown: '更新后的正文',
      basePartRevisionId: 'raw_manual_1',
      etag: '"raw-manual-1"',
      idempotencyKey: 'idem-manual-raw-update',
    );

    expect(result.ok, isTrue);
    final request = transport.requests.single;
    expect(request.method, 'PUT');
    expect(
      request.url.path,
      '/api/v1/workspaces/ws_1/notes/note_manual_1/parts/raw',
    );
    expect(request.headers['If-Match'], '"raw-manual-1"');
    expect(request.headers['X-Idempotency-Key'], 'idem-manual-raw-update');
    expect(jsonDecode(request.body!), <String, Object?>{
      'contentMarkdown': '更新后的正文',
      'basePartRevisionId': 'raw_manual_1',
    });
  });

  test('HNote formal responses expose top-level part revisions', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 201,
        body: <String, Object?>{
          'success': true,
          'data': _formalHNoteHeadReceipt(),
        },
      ),
    ]);
    final client = WorkspaceContentClient(_client(transport));

    final result = await client.createNote(
      'ws_1',
      title: 'Formal note',
      rawMarkdown: 'Raw',
      outlineMarkdown: '',
      germinationMarkdown: '',
      idempotencyKey: 'idem-formal-hnote-head',
    );

    expect(result.ok, isTrue);
    expect(result.data?.noteId, 'note_formal_1');
    expect(result.data?.noteRevisionId, 'note_revision_formal_1');
    expect(result.data?.raw.partRevisionId, 'raw_revision_formal_1');
    expect(result.data?.outline.partRevisionId, 'outline_revision_formal_1');
    expect(
      result.data?.germination.partRevisionId,
      'germination_revision_formal_1',
    );
  });

  test('Workspace part update rejects an incomplete HNote response', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'partRevisionId': 'part_rev_2',
            'etag': '"part-2"',
          },
        },
      ),
    ]);
    final client = WorkspaceContentClient(_client(transport));

    final result = await client.putNotePart(
      'ws_1',
      'note_1',
      'raw',
      markdown: '# changed',
      basePartRevisionId: 'part_rev_1',
      etag: '"part-1"',
      idempotencyKey: 'idem-part-1',
    );

    expect(result.ok, isFalse);
    expect(result.error?.code, 'API_RESPONSE_INVALID');
    final request = transport.requests.single;
    expect(request.url.path, '/api/v1/workspaces/ws_1/notes/note_1/parts/raw');
    expect(request.headers['If-Match'], '"part-1"');
    expect(request.headers['X-Idempotency-Key'], 'idem-part-1');
    expect(request.headers.containsKey('Idempotency-Key'), isFalse);
    expect(jsonDecode(request.body!), <String, Object?>{
      'contentMarkdown': '# changed',
      'basePartRevisionId': 'part_rev_1',
    });
  });

  test('catalog parser rejects malformed availability', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'skillProfileId': 'skill_1',
                'displayName': 'Skill',
                'installation': 'secret_internal_state',
              },
            ],
          },
        },
      ),
    ]);

    final result = await AgentCatalogClient(
      _client(transport),
    ).skills('renshe_content');

    expect(result.ok, isFalse);
    expect(result.error?.code, 'API_RESPONSE_INVALID');
  });

  test(
    'Agent catalog and Skill installations use strict API 23 contracts',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(<String, Object?>{
          'catalogVersion': 'catalog-v1',
          'items': <Object?>[
            <String, Object?>{
              'agentProfileId': 'agent/opaque+id',
              'displayName': 'Agent',
              'description': 'Public agent',
              'icon': <String, Object?>{'resourceId': 'resource_icon_1'},
            },
          ],
        }),
        _objectResponse(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'skillProfileId': 'skill/opaque+id',
              'displayName': 'Skill',
              'installation': 'enabled',
            },
          ],
        }),
        _objectResponse(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'modelProfileId': 'model/opaque+id',
              'displayName': 'Model',
            },
          ],
        }),
        _objectResponse(<String, Object?>{
          'items': <Object?>[
            _skillInstallation(),
            _skillInstallation(
              skillProfileId: 'skill_system',
              state: 'disabled',
              installMode: 'system_managed',
            ),
          ],
        }),
        _objectResponse(_skillInstallation()),
        _objectResponse(_skillInstallation(state: 'disabled')),
        const ApiTransportResponse(status: 204, body: null),
      ]);
      final client = AgentCatalogClient(_client(transport));

      final profiles = await client.profiles();
      final skills = await client.skills(' agent/opaque+id ');
      final models = await client.models('agent/opaque+id');
      final installations = await client.installations('ws_1');
      final installed = await client.installSkill(
        'ws_1',
        'skill/opaque+id',
        idempotencyKey: 'skill-install-key',
      );
      final disabled = await client.updateSkillInstallation(
        'ws_1',
        'skill/opaque+id',
        state: 'disabled',
        idempotencyKey: 'skill-update-key',
      );
      final deleted = await client.deleteSkillInstallation(
        'ws_1',
        'skill/opaque+id',
        idempotencyKey: 'skill-delete-key',
      );

      expect(profiles.data?.items.single.icon?.resourceId, 'resource_icon_1');
      expect(skills.data?.single.installation, 'enabled');
      expect(models.data?.single.modelProfileId, 'model/opaque+id');
      expect(installations.data?.items[1].isUserManaged, isFalse);
      expect(installed.data?.isEnabled, isTrue);
      expect(disabled.data?.state, 'disabled');
      expect(deleted.data, isTrue);
      expect(transport.requests.map((request) => request.method), <String>[
        'GET',
        'GET',
        'GET',
        'GET',
        'POST',
        'PATCH',
        'DELETE',
      ]);
      expect(
        transport.requests[1].url.path,
        '/api/v1/agent-profiles/agent%2Fopaque%2Bid/skills',
      );
      expect(jsonDecode(transport.requests[4].body!), <String, Object?>{
        'skillProfileId': 'skill/opaque+id',
      });
      expect(jsonDecode(transport.requests[5].body!), <String, Object?>{
        'state': 'disabled',
      });
      expect(
        transport.requests[4].headers['X-Idempotency-Key'],
        'skill-install-key',
      );
      expect(
        transport.requests[5].headers['X-Idempotency-Key'],
        'skill-update-key',
      );
      expect(
        transport.requests[6].headers['X-Idempotency-Key'],
        'skill-delete-key',
      );
      expect(transport.requests[6].body, isNull);
      expect(transport.requests[6].responseMode, EndpointResponseMode.empty);
    },
  );

  test('Agent API 23 rejects unsafe icon and malformed installation', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _objectResponse(<String, Object?>{
        'catalogVersion': 'catalog-v1',
        'items': <Object?>[
          <String, Object?>{
            'agentProfileId': 'agent_1',
            'displayName': 'Agent',
            'icon': <String, Object?>{
              'resourceId': 'resource_1',
              'signedUrl': 'https://private.example/icon',
            },
          },
        ],
      }),
      _objectResponse(<String, Object?>{
        'items': <Object?>[
          <String, Object?>{..._skillInstallation(), 'state': 'pending'},
        ],
      }),
      _objectResponse(_skillInstallation(skillProfileId: 'different_skill')),
    ]);
    final client = AgentCatalogClient(_client(transport));

    expect((await client.profiles()).error?.code, 'API_RESPONSE_INVALID');
    expect(
      (await client.installations('ws_1')).error?.code,
      'API_RESPONSE_INVALID',
    );
    expect(
      (await client.installSkill(
        'ws_1',
        'skill_1',
        idempotencyKey: 'install-key',
      )).error?.code,
      'API_RESPONSE_INVALID',
    );
    expect(
      () => client.updateSkillInstallation(
        'ws_1',
        'skill_1',
        state: 'pending',
        idempotencyKey: 'key',
      ),
      throwsArgumentError,
    );
  });

  test('AgentRun parses only current public routing projection', () async {
    final planningRun = _run(status: 'planning')
      ..addAll(<String, Object?>{
        'routingMode': 'catalog',
        'sourceSurface': 'mobile_chat',
        'routing': <String, Object?>{'state': 'clarification_required'},
        'clarification': <String, Object?>{
          'kind': 'clarify_intent',
          'userMessage': '请补充目标',
        },
      });
    final failedRun = _run(status: 'failed')
      ..['error'] = <String, Object?>{
        'code': 'AGENT_MODEL_INCOMPATIBLE',
        'retryable': false,
      };
    final privateRun = _run(status: 'queued')
      ..['resolvedAgentProfile'] = <String, Object?>{
        'agentProfileId': 'agent_1',
        'releaseId': 'private_release',
      };
    final transport = _QueueTransport(<ApiTransportResponse>[
      _objectResponse(planningRun),
      _objectResponse(failedRun),
      _objectResponse(privateRun),
    ]);
    final client = AgentRunClient(_client(transport));

    final planning = await client.get('run_1');
    final failed = await client.get('run_1');
    final privateProjection = await client.get('run_1');

    expect(planning.data?.routingMode, 'catalog');
    expect(planning.data?.routing?.state, 'clarification_required');
    expect(planning.data?.clarification?.kind, 'clarify_intent');
    expect(failed.data?.error?.code, 'AGENT_MODEL_INCOMPATIBLE');
    expect(failed.data?.error?.fields['retryable'], isFalse);
    expect(privateProjection.error?.code, 'API_RESPONSE_INVALID');

    final opaqueRequest = AgentRunRequest(
      agentProfileId: ' agent/opaque+id ',
      skillProfileIds: const <String>[' skill/z ', 'skill/a', 'skill/z'],
      modelProfileId: ' model/opaque+id ',
      input: SharedAgentInput(
        content: <SharedAgentInputContent>[
          SharedAgentTextContent(text: 'test'),
        ],
      ),
    ).toJson();
    expect(opaqueRequest['agentProfileId'], 'agent/opaque+id');
    expect(opaqueRequest['skillProfileIds'], <Object?>['skill/a', 'skill/z']);
    expect(opaqueRequest['modelProfileId'], 'model/opaque+id');
  });

  test('Subscription client traverses all twelve API 25 operations', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _subscriptionPageResponse(<Object?>[_subscriptionPublication()]),
      _subscriptionObjectResponse(_subscriptionPublication()),
      _subscriptionPageResponse(<Object?>[_subscriptionSection()]),
      _subscriptionPageResponse(<Object?>[_subscriptionArticle()]),
      _subscriptionObjectResponse(_subscriptionRevision()),
      _subscriptionPageResponse(<Object?>[_subscriptionRevision()]),
      _subscriptionObjectResponse(_subscriptionRevision()),
      ApiTransportResponse(
        status: 200,
        headers: const <String, String>{'content-type': 'image/png'},
        body: Uint8List.fromList(<int>[137, 80, 78, 71]),
      ),
      _subscriptionPageResponse(<Object?>[_subscriptionLibraryItem()]),
      _subscriptionObjectResponse(
        _subscriptionFollowResult(lifecycle: 'following'),
      ),
      _subscriptionObjectResponse(
        _subscriptionFollowResult(lifecycle: 'unfollowed'),
      ),
      _subscriptionObjectResponse(_subscriptionSaveReceipt(), status: 201),
    ]);
    final client = SubscriptionClient(_client(transport));

    final publications = await client.publicationPage(
      cursor: 'publication_cursor_1',
      limit: 20,
    );
    final publication = await client.publication('publication_1');
    final sections = await client.sectionPage(
      'publication_1',
      cursor: 'section_cursor_1',
      limit: 30,
    );
    final articles = await client.articles(
      publicationId: 'publication_1',
      sectionId: 'section_1',
      cursor: 'article_cursor_1',
      limit: 40,
    );
    final article = await client.article('article_1');
    final revisions = await client.articleRevisionPage(
      'article_1',
      cursor: 'revision_cursor_1',
      limit: 50,
    );
    final revision = await client.articleRevision(
      'article_1',
      'article_revision_1',
    );
    final asset = await client.articleRevisionAsset(
      'article_1',
      'article_revision_1',
      'image_file_1',
    );
    final library = await client.libraryPage(
      'ws_1',
      cursor: 'library_cursor_1',
      limit: 60,
    );
    final followed = await client.followPublication(
      'ws_1',
      'publication_1',
      idempotencyKey: 'idem-follow',
    );
    final unfollowed = await client.unfollowPublication(
      'ws_1',
      'publication_1',
      idempotencyKey: 'idem-unfollow',
    );
    final saved = await client.saveArticleAsNote(
      'ws_1',
      'article_1',
      articleRevisionId: 'article_revision_1',
      idempotencyKey: 'idem-save',
    );

    expect(publications.data?.items.single.title, 'Infinite Huahuo Daily');
    expect(publications.data?.nextCursor, 'next_opaque_cursor');
    expect(publication.data?.sectionCount, 2);
    expect(sections.data?.items.single.sortOrder, 1);
    expect(articles.data?.items.single.sectionId, 'section_1');
    expect(article.data?.contentMarkdown, '# Article');
    expect(
      revisions.data?.items.single.articleRevisionId,
      'article_revision_1',
    );
    expect(revision.data?.contentSha256, 'sha256_1');
    expect(revision.data?.assetRefs.single.logicalPath, 'images/cover.png');
    expect(asset.data, Uint8List.fromList(<int>[137, 80, 78, 71]));
    expect(library.data?.items.single.availability, 'available');
    expect(followed.data?.lifecycle, 'following');
    expect(unfollowed.data?.lifecycle, 'unfollowed');
    expect(saved.data?.created, isTrue);
    expect(saved.data?.contentCursor, '220');

    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/subscription/publications',
      '/api/v1/subscription/publications/publication_1',
      '/api/v1/subscription/publications/publication_1/sections',
      '/api/v1/subscription/articles',
      '/api/v1/subscription/articles/article_1',
      '/api/v1/subscription/articles/article_1/revisions',
      '/api/v1/subscription/articles/article_1/revisions/article_revision_1',
      '/api/v1/subscription/articles/article_1/revisions/article_revision_1/assets/image_file_1',
      '/api/v1/workspaces/ws_1/subscription-library/publications',
      '/api/v1/workspaces/ws_1/subscription-library/publications/publication_1',
      '/api/v1/workspaces/ws_1/subscription-library/publications/publication_1',
      '/api/v1/workspaces/ws_1/subscription-articles/article_1/save-as-note',
    ]);
    expect(transport.requests[3].url.queryParameters, <String, String>{
      'publicationId': 'publication_1',
      'sectionId': 'section_1',
      'cursor': 'article_cursor_1',
      'limit': '40',
    });
    expect(transport.requests.map((request) => request.method), <String>[
      'GET',
      'GET',
      'GET',
      'GET',
      'GET',
      'GET',
      'GET',
      'GET',
      'GET',
      'PUT',
      'DELETE',
      'POST',
    ]);
    final mutations = transport.requests.skip(9).toList();
    expect(
      mutations.map((request) => request.headers['X-Idempotency-Key']),
      <String>['idem-follow', 'idem-unfollow', 'idem-save'],
    );
    for (final request in mutations.take(2)) {
      expect(request.headers['X-Request-Id'], isNotEmpty);
      expect(request.headers.containsKey('Idempotency-Key'), isFalse);
      expect(request.body, isNull);
      expect(request.responseMode, EndpointResponseMode.strictEnvelope);
    }
    final saveRequest = mutations.last;
    expect(saveRequest.headers['X-Request-Id'], isNotEmpty);
    expect(saveRequest.headers.containsKey('Idempotency-Key'), isFalse);
    expect(saveRequest.body, '{"articleRevisionId":"article_revision_1"}');
    expect(saveRequest.responseMode, EndpointResponseMode.strictEnvelope);
  });

  test('Subscription client fails closed on invalid query and DTO', () async {
    final malformedTransport = _QueueTransport(<ApiTransportResponse>[
      _subscriptionPageResponse(<Object?>[
        <String, Object?>{..._subscriptionPublication(), 'articleCount': -1},
      ]),
    ]);
    final malformed = await SubscriptionClient(
      _client(malformedTransport),
    ).publicationPage();
    expect(malformed.error?.code, 'API_RESPONSE_INVALID');

    final fractional = await SubscriptionClient(
      _client(
        _QueueTransport(<ApiTransportResponse>[
          _subscriptionPageResponse(<Object?>[
            <String, Object?>{
              ..._subscriptionPublication(),
              'sectionCount': 1.5,
            },
          ]),
        ]),
      ),
    ).publicationPage();
    expect(fractional.error?.code, 'API_RESPONSE_INVALID');

    final client = SubscriptionClient(
      _client(_QueueTransport(<ApiTransportResponse>[])),
    );
    expect(
      () => client.articles(publicationId: '', limit: 20),
      throwsArgumentError,
    );
    expect(
      () => client.articles(publicationId: 'publication_1', limit: 101),
      throwsArgumentError,
    );
  });

  test(
    'Workspace Search serializes keyword, semantic and compatibility hybrid',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(
          _workspaceSearchOutput(mode: 'keyword', withResult: true),
        ),
        _objectResponse(_workspaceSearchOutput(mode: 'semantic')),
        _objectResponse(
          _workspaceSearchOutput(mode: 'hybrid', withResult: true),
        ),
      ]);
      final client = WorkspaceContentClient(_client(transport));
      const opaqueReceipt = '  receipt/+ same query ==  ';

      final keyword = await client.workspaceSearch(
        'ws_1',
        request: SharedWorkspaceSearchRequest.keyword(
          query: ' product strategy ',
          ownerKinds: const <String>['hnote', 'hnote'],
          noteParts: const <String>['raw'],
          folderIds: const <String>[' folder opaque/value '],
          noteTypeIds: const <String>['type opaque:value'],
          from: DateTime.utc(2026, 8, 1),
          to: DateTime.utc(2026, 8, 7),
          limit: 30,
        ),
      );
      final semantic = await client.workspaceSearch(
        'ws_1',
        request: SharedWorkspaceSearchRequest.semantic(
          query: 'product strategy',
          keywordAttemptId: opaqueReceipt,
        ),
      );
      final hybrid = await client.workspaceSearch(
        'ws_1',
        request: SharedWorkspaceSearchRequest.hybridCompatibility(
          query: 'legacy query',
        ),
      );

      expect(keyword.data?.results.single.ownerRef.kind, 'hnote');
      expect(keyword.data?.results.single.path, 'notes/note_1/raw.md');
      expect(semantic.data?.mode, 'semantic');
      expect(hybrid.data?.results.single.matchMode, 'hybrid');
      final keywordBody = jsonDecode(transport.requests[0].body!) as Map;
      expect(keywordBody['query'], 'product strategy');
      expect(keywordBody['ownerKinds'], <Object?>['hnote']);
      expect(keywordBody['folderIds'], <Object?>['folder opaque/value']);
      expect(keywordBody['limit'], 30);
      final semanticBody = jsonDecode(transport.requests[1].body!) as Map;
      expect(semanticBody['keywordAttemptId'], opaqueReceipt);
      expect(semanticBody['mode'], 'semantic');
      expect(jsonDecode(transport.requests[2].body!)['mode'], 'hybrid');
      for (final request in transport.requests) {
        expect(request.method, 'POST');
        expect(request.headers.containsKey('Idempotency-Key'), isFalse);
        expect(request.headers.containsKey('X-Idempotency-Key'), isFalse);
      }
    },
  );

  test(
    'Workspace Search rejects unsafe output and exposes semantic conflict',
    () async {
      final unsafe = _workspaceSearchOutput(mode: 'keyword', withResult: true);
      ((unsafe['results'] as List).single as Map<String, Object?>)['body'] =
          'not allowed';
      final absolute = _workspaceSearchOutput(
        mode: 'keyword',
        withResult: true,
      );
      ((absolute['results'] as List).single as Map<String, Object?>)['path'] =
          '/Users/run/private.md';
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(unsafe),
        _objectResponse(absolute),
        const ApiTransportResponse(
          status: 409,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'SEMANTIC_SEARCH_REQUIRES_KEYWORD_MISS',
              'message': 'keyword miss receipt required',
              'retryable': false,
            },
          },
        ),
      ]);
      final client = WorkspaceContentClient(_client(transport));
      final request = SharedWorkspaceSearchRequest.keyword(query: 'safe');

      final leaked = await client.workspaceSearch('ws_1', request: request);
      final localPath = await client.workspaceSearch('ws_1', request: request);
      final conflict = await client.workspaceSearch(
        'ws_1',
        request: SharedWorkspaceSearchRequest.semantic(
          query: 'safe',
          keywordAttemptId: 'opaque receipt',
        ),
      );

      expect(leaked.error?.code, 'API_RESPONSE_INVALID');
      expect(localPath.error?.code, 'API_RESPONSE_INVALID');
      expect(conflict.status, 409);
      expect(conflict.error?.code, 'SEMANTIC_SEARCH_REQUIRES_KEYWORD_MISS');
      expect(
        () => SharedWorkspaceSearchRequest.semantic(
          query: 'query',
          keywordAttemptId: ' ',
        ),
        throwsArgumentError,
      );
      expect(
        () => SharedWorkspaceSearchRequest.keyword(query: 'query', limit: 31),
        throwsArgumentError,
      );
    },
  );

  test(
    'Note relations parse unions and enforce mutation headers and receipts',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(<String, Object?>{
          'items': <Object?>[_explicitRelation(), _automaticRelation()],
          'nextCursor': 'relation-cursor-2',
        }),
        _objectResponse(_relationEvent(version: 1)),
        _objectResponse(_relationEvent(version: 2)),
        _objectResponse(_relationEvent(version: 3, tombstone: true)),
      ]);
      final client = WorkspaceContentClient(_client(transport));
      final target = SharedNotePartSourceRef(
        noteId: 'note_2',
        part: 'outline',
        partRevisionId: 'part_revision_2',
      );

      final page = await client.noteRelationPage(
        'ws_1',
        'note_1',
        cursor: 'relation-cursor-1',
        limit: 100,
      );
      final created = await client.createNoteRelation(
        'ws_1',
        'note_1',
        request: SharedCreateExplicitNoteRelationRequest(
          relationType: 'supports',
          source: SharedNotePartRevisionRef(
            part: 'raw',
            partRevisionId: 'part_revision_1',
          ),
          target: target,
          rationale: 'Direct evidence',
        ),
        idempotencyKey: 'relation-create-key',
      );
      final updated = await client.updateNoteRelation(
        'ws_1',
        'relation_1',
        request: SharedUpdateExplicitNoteRelationRequest(
          relationType: 'causal',
          target: target,
        ),
        etag: '"relation-1"',
        idempotencyKey: 'relation-update-key',
      );
      final deleted = await client.deleteNoteRelation(
        'ws_1',
        'relation_1',
        etag: '"relation-2"',
        idempotencyKey: 'relation-delete-key',
      );

      expect(page.data?.items[0], isA<SharedExplicitNoteRelation>());
      expect(page.data?.items[1], isA<SharedAutomaticNoteRelation>());
      expect(page.data?.nextCursor, 'relation-cursor-2');
      expect(created.data?.version, 1);
      expect(updated.data?.version, 2);
      expect(deleted.data?.tombstone, isTrue);
      expect(transport.requests[0].url.queryParameters, <String, String>{
        'cursor': 'relation-cursor-1',
        'limit': '100',
      });
      expect(
        transport.requests[1].headers['X-Idempotency-Key'],
        'relation-create-key',
      );
      expect(transport.requests[1].headers.containsKey('If-Match'), isFalse);
      expect(transport.requests[2].headers['If-Match'], '"relation-1"');
      expect(transport.requests[3].headers['If-Match'], '"relation-2"');
      expect(
        transport.requests[3].headers['X-Idempotency-Key'],
        'relation-delete-key',
      );
      expect(transport.requests[3].body, isNull);
      expect(
        transport.requests[3].responseMode,
        EndpointResponseMode.strictEnvelope,
      );
      expect(jsonDecode(transport.requests[1].body!), <String, Object?>{
        'relationType': 'supports',
        'source': <String, Object?>{
          'part': 'raw',
          'partRevisionId': 'part_revision_1',
        },
        'target': <String, Object?>{
          'noteId': 'note_2',
          'part': 'outline',
          'partRevisionId': 'part_revision_2',
        },
        'rationale': 'Direct evidence',
      });
    },
  );

  test(
    'Note relation rejects malformed receipt and preserves conflicts',
    () async {
      final invalidReceipt = _relationEvent(version: 2);
      (invalidReceipt['resourcePinDelta'] as Map<String, Object?>)['added'] =
          <Object?>['resource_1'];
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(invalidReceipt),
        const ApiTransportResponse(
          status: 412,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'NOTE_RELATION_REVISION_INVALID',
              'message': 'stale ETag',
              'retryable': false,
            },
          },
        ),
      ]);
      final client = WorkspaceContentClient(_client(transport));
      final request = SharedUpdateExplicitNoteRelationRequest(
        rationale: 'updated',
      );

      final malformed = await client.updateNoteRelation(
        'ws_1',
        'relation_1',
        request: request,
        etag: '"relation-1"',
        idempotencyKey: 'relation-update-1',
      );
      final conflict = await client.updateNoteRelation(
        'ws_1',
        'relation_1',
        request: request,
        etag: '"relation-1"',
        idempotencyKey: 'relation-update-2',
      );

      expect(malformed.error?.code, 'API_RESPONSE_INVALID');
      expect(conflict.status, 412);
      expect(conflict.error?.code, 'NOTE_RELATION_REVISION_INVALID');
    },
  );

  test(
    'Account usage parses membership, credit page and public Run usage',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(_membershipResponse()),
        _objectResponse(_creditSummaryResponse()),
        _objectResponse(_runUsageResponse()),
      ]);
      final client = AccountUsageClient(_client(transport));

      final membership = await client.membershipDetail();
      final credits = await client.creditSummary(
        cursor: 'credit-page-1',
        limit: 50,
      );
      final usage = await client.runUsageDetail('run_1');

      expect(membership.data?.levelCode, 'pilot_paid');
      expect(membership.data?.monthlyCredit.quotaCredits, 10000000);
      expect(membership.data?.expiresAt, isNull);
      expect(
        credits.data?.permanentCredit.lots.single.originKind,
        'admin_grant',
      );
      expect(credits.data?.permanentCredit.nextCursor, 'credit-page-2');
      expect(usage.data?.settlementStatus, 'settled');
      expect(usage.data?.measurements.single.mediaDurationSeconds, 1.5);
      expect(usage.data?.measurements.single.providerCost?.currency, 'CNY');
      expect(transport.requests[1].url.queryParameters, <String, String>{
        'cursor': 'credit-page-1',
        'limit': '50',
      });
      expect(transport.requests[2].url.path, '/api/v1/runs/run_1/usage');
    },
  );

  test(
    'Account usage rejects damaged nested DTOs and invalid page limit',
    () async {
      final invalidMembership = _membershipResponse();
      (invalidMembership['membership'] as Map<String, Object?>)['levelCode'] =
          'trial';
      final missingPurchasedExpiry = _membershipResponse(levelCode: 'max');
      final invalidUsage = _runUsageResponse();
      ((invalidUsage['measurements'] as List).single
              as Map<String, Object?>)['measurementStatus'] =
          'estimated';
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(invalidMembership),
        _objectResponse(missingPurchasedExpiry),
        _objectResponse(invalidUsage),
      ]);
      final client = AccountUsageClient(_client(transport));

      expect(
        (await client.membershipDetail()).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(
        (await client.membershipDetail()).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(
        (await client.runUsageDetail('run_1')).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(() => client.creditSummary(limit: 101), throwsArgumentError);
    },
  );

  test('Account membership accepts API 28 pro/max projections', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _objectResponse(
        _membershipResponse(
          levelCode: 'pro',
          expiresAt: '2026-09-01T00:00:00Z',
        ),
      ),
      _objectResponse(
        _membershipResponse(
          levelCode: 'max',
          status: 'grace_period',
          expiresAt: '2027-08-07T00:00:00Z',
        ),
      ),
    ]);
    final client = AccountUsageClient(_client(transport));

    final pro = await client.membershipDetail();
    final max = await client.membershipDetail();

    expect(pro.data?.levelCode, 'pro');
    expect(pro.data?.expiresAt, DateTime.utc(2026, 9, 1));
    expect(max.data?.levelCode, 'max');
    expect(max.data?.status, 'grace_period');
  });

  test(
    'API 24 typed client traverses all 27 Book and Work operations',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(_api24Book()),
        _objectResponse(
          _api24Event(kind: 'book', id: 'book_1', revision: true),
        ),
        _objectResponse(<String, Object?>{
          'items': <Object?>[_api24BookRevision()],
          'nextCursor': 'book_revision_cursor',
        }),
        _objectResponse(_api24BookRevision()),
        ApiTransportResponse(
          status: 202,
          body: <String, Object?>{
            'success': true,
            'data': _api24BookImportPending(),
          },
        ),
        _objectResponse(_api24BookImportPending()),
        _objectResponse(_api24Event(kind: 'book_section', id: 'chapter-1')),
        _objectResponse(_api24BookSection()),
        _objectResponse(
          _api24Event(kind: 'book_section', id: 'chapter-1', version: 2),
        ),
        _objectResponse(
          _api24Event(
            kind: 'book_section',
            id: 'chapter-1',
            version: 3,
            tombstone: true,
          ),
        ),
        _objectResponse(
          _api24Event(kind: 'book_section', id: 'chapter-1', version: 4),
        ),
        _objectResponse(
          _api24Event(kind: 'book_section', id: 'chapter-1', version: 5),
        ),
        _objectResponse(_api24PartRevision()),
        _objectResponse(
          _api24Event(
            kind: 'book_section',
            id: 'chapter-1',
            revision: true,
            identity: 'part_revision_2',
          ),
        ),
        _objectResponse(<String, Object?>{
          'items': <Object?>[_api24PartRevision()],
          'nextCursor': 'part_cursor',
        }),
        ApiTransportResponse(
          status: 200,
          headers: const <String, String>{
            'Content-Type': 'application/zip',
            'ETag': '"package-1"',
            'X-Package-ETag': '"package-1"',
          },
          body: Uint8List.fromList(<int>[80, 75, 3, 4]),
        ),
        _objectResponse(<String, Object?>{
          'items': <Object?>[_api24Work()],
          'nextCursor': 'work_cursor',
        }),
        _objectResponse(_api24Event(kind: 'work', id: 'work_1')),
        _objectResponse(_api24Work()),
        _objectResponse(_api24Event(kind: 'work', id: 'work_1', version: 2)),
        _objectResponse(
          _api24Event(kind: 'work', id: 'work_1', version: 3, tombstone: true),
        ),
        _objectResponse(_api24Event(kind: 'work', id: 'work_1', version: 4)),
        _objectResponse(_api24Event(kind: 'work', id: 'work_1', version: 5)),
        _objectResponse(_api24PartRevision()),
        _objectResponse(
          _api24Event(
            kind: 'work',
            id: 'work_1',
            revision: true,
            identity: 'part_revision_2',
          ),
        ),
        _objectResponse(<String, Object?>{
          'items': <Object?>[_api24PartRevision()],
          'nextCursor': 'work_part_cursor',
        }),
        _objectResponse(
          _api24Event(kind: 'creation', id: 'creation_1', revision: true),
        ),
      ]);
      final client = BookWorkClient(_client(transport));
      const etag = '"current-etag"';

      expect((await client.bookDetail('ws_1')).ok, isTrue);
      expect(
        (await client.updateBook(
          'ws_1',
          request: SharedUpdateBookRequest(
            title: 'Infinite Huahuo',
            language: 'zh-CN',
            status: 'active',
          ),
          etag: etag,
          idempotencyKey: 'idem-book-update',
        )).ok,
        isTrue,
      );
      expect(
        (await client.bookRevisions(
          'ws_1',
          cursor: 'book_cursor',
          limit: 20,
        )).data?.nextCursor,
        'book_revision_cursor',
      );
      expect((await client.bookRevision('ws_1', 'book_revision_1')).ok, isTrue);
      expect(
        (await client.importBook(
          'ws_1',
          request: SharedImportBookRequest(
            resourceId: 'resource_import_1',
            expectedBookRevisionId: 'book_revision_1',
          ),
          idempotencyKey: 'idem-book-import',
        )).status,
        202,
      );
      expect((await client.bookImport('ws_1', 'book_import_1')).ok, isTrue);

      final sectionCreate = SharedCreateBookSectionRequest(
        sectionKey: 'chapter-1',
        title: 'Chapter one',
        group: 'chapters',
        ordinal: 0,
        parts: const <String, String>{'raw': '# Draft'},
        sourceRefs: <SharedManagedLineageRef>[
          SharedManagedNotePartLineageRef(
            noteId: 'note_1',
            part: 'raw',
            partRevisionId: 'note_part_revision_1',
          ),
        ],
        resourceRefs: <SharedManagedResourceRef>[
          SharedManagedResourceRef(
            resourceId: 'resource_1',
            role: 'illustration',
            ordinal: 0,
          ),
        ],
      );
      expect(
        (await client.createBookSection(
          'ws_1',
          request: sectionCreate,
          idempotencyKey: 'idem-section-create',
        )).ok,
        isTrue,
      );
      expect((await client.bookSection('ws_1', 'chapter-1')).ok, isTrue);
      expect(
        (await client.updateBookSection(
          'ws_1',
          'chapter-1',
          request: SharedUpdateBookSectionRequest(title: 'Updated chapter'),
          etag: etag,
          idempotencyKey: 'idem-section-update',
        )).ok,
        isTrue,
      );
      expect(
        (await client.deleteBookSection(
          'ws_1',
          'chapter-1',
          etag: etag,
          idempotencyKey: 'idem-section-delete',
        )).ok,
        isTrue,
      );
      expect(
        (await client.restoreBookSection(
          'ws_1',
          'chapter-1',
          etag: etag,
          idempotencyKey: 'idem-section-restore',
        )).ok,
        isTrue,
      );
      expect(
        (await client.moveBookSection(
          'ws_1',
          'chapter-1',
          request: SharedMoveBookSectionRequest(
            targetGroup: 'chapters',
            targetOrdinal: 0,
            expectedBookRevisionId: 'book_revision_1',
          ),
          sectionEtag: etag,
          idempotencyKey: 'idem-section-move',
        )).ok,
        isTrue,
      );
      expect(
        (await client.bookSectionPart(
          'ws_1',
          'chapter-1',
          'raw',
          partRevisionId: 'part_revision_1',
        )).ok,
        isTrue,
      );
      final partUpdate = SharedUpdateManagedPartRequest(
        contentMarkdown: '# Updated',
        basePartRevisionId: 'part_revision_1',
        sourceRefs: <SharedNotePartSourceRef>[
          SharedNotePartSourceRef(
            noteId: 'note_1',
            part: 'raw',
            partRevisionId: 'note_part_revision_1',
          ),
        ],
      );
      expect(
        (await client.putBookSectionPart(
          'ws_1',
          'chapter-1',
          'raw',
          request: partUpdate,
          etag: etag,
          idempotencyKey: 'idem-section-part',
        )).ok,
        isTrue,
      );
      expect(
        (await client.bookSectionPartRevisions(
          'ws_1',
          'chapter-1',
          'raw',
          cursor: 'section_part_cursor',
          limit: 10,
        )).ok,
        isTrue,
      );
      expect(
        (await client.exportBook(
          'ws_1',
          bookRevisionId: 'book_revision_1',
        )).data,
        Uint8List.fromList(<int>[80, 75, 3, 4]),
      );

      expect(
        (await client.workPage('ws_1', cursor: 'work_cursor', limit: 25)).ok,
        isTrue,
      );
      final createWorkRequest = SharedCreateWorkRequest(
        title: 'Research result',
        initialPart: SharedInitialWorkPart(
          part: 'raw',
          contentMarkdown: '# Work',
        ),
        lineageRefs: <SharedWorkLineageRef>[
          SharedWorkNotePartLineageRef(
            ordinal: 0,
            noteId: 'note_1',
            part: 'raw',
            partRevisionId: 'note_part_revision_1',
          ),
        ],
      );
      expect(
        (await client.createWork(
          'ws_1',
          request: createWorkRequest,
          idempotencyKey: 'idem-work-create',
        )).ok,
        isTrue,
      );
      expect((await client.workDetail('ws_1', 'work_1')).ok, isTrue);
      expect(
        (await client.updateWork(
          'ws_1',
          'work_1',
          request: SharedUpdateWorkRequest(title: 'Updated work'),
          etag: etag,
          idempotencyKey: 'idem-work-update',
        )).ok,
        isTrue,
      );
      expect(
        (await client.deleteWork(
          'ws_1',
          'work_1',
          etag: etag,
          idempotencyKey: 'idem-work-delete',
        )).ok,
        isTrue,
      );
      expect(
        (await client.restoreWork(
          'ws_1',
          'work_1',
          etag: etag,
          idempotencyKey: 'idem-work-restore',
        )).ok,
        isTrue,
      );
      expect(
        (await client.completeWork(
          'ws_1',
          'work_1',
          etag: etag,
          idempotencyKey: 'idem-work-complete',
        )).ok,
        isTrue,
      );
      expect((await client.workPart('ws_1', 'work_1', 'raw')).ok, isTrue);
      expect(
        (await client.putWorkPart(
          'ws_1',
          'work_1',
          'raw',
          request: partUpdate,
          etag: etag,
          idempotencyKey: 'idem-work-part',
        )).ok,
        isTrue,
      );
      expect(
        (await client.workPartRevisions(
          'ws_1',
          'work_1',
          'raw',
          cursor: 'work_part_cursor',
          limit: 10,
        )).ok,
        isTrue,
      );
      expect(
        (await client.promoteWork(
          'ws_1',
          'work_1',
          request: SharedPromoteWorkRequest.creation(
            sourcePart: 'raw',
            sourcePartRevisionId: 'part_revision_1',
            title: 'Promoted creation',
          ),
          etag: etag,
          idempotencyKey: 'idem-work-promote',
        )).ok,
        isTrue,
      );

      final expected = <(String, String)>[
        ('GET', '/api/v1/workspaces/ws_1/book'),
        ('PUT', '/api/v1/workspaces/ws_1/book'),
        ('GET', '/api/v1/workspaces/ws_1/book/revisions'),
        ('GET', '/api/v1/workspaces/ws_1/book/revisions/book_revision_1'),
        ('POST', '/api/v1/workspaces/ws_1/book/import'),
        ('GET', '/api/v1/workspaces/ws_1/book/imports/book_import_1'),
        ('POST', '/api/v1/workspaces/ws_1/book/sections'),
        ('GET', '/api/v1/workspaces/ws_1/book/sections/chapter-1'),
        ('PATCH', '/api/v1/workspaces/ws_1/book/sections/chapter-1'),
        ('DELETE', '/api/v1/workspaces/ws_1/book/sections/chapter-1'),
        ('POST', '/api/v1/workspaces/ws_1/book/sections/chapter-1/restore'),
        ('POST', '/api/v1/workspaces/ws_1/book/sections/chapter-1/move'),
        ('GET', '/api/v1/workspaces/ws_1/book/sections/chapter-1/parts/raw'),
        ('PUT', '/api/v1/workspaces/ws_1/book/sections/chapter-1/parts/raw'),
        (
          'GET',
          '/api/v1/workspaces/ws_1/book/sections/chapter-1/parts/raw/revisions',
        ),
        ('GET', '/api/v1/workspaces/ws_1/book/export'),
        ('GET', '/api/v1/workspaces/ws_1/work'),
        ('POST', '/api/v1/workspaces/ws_1/work'),
        ('GET', '/api/v1/workspaces/ws_1/work/work_1'),
        ('PATCH', '/api/v1/workspaces/ws_1/work/work_1'),
        ('DELETE', '/api/v1/workspaces/ws_1/work/work_1'),
        ('POST', '/api/v1/workspaces/ws_1/work/work_1/restore'),
        ('POST', '/api/v1/workspaces/ws_1/work/work_1/complete'),
        ('GET', '/api/v1/workspaces/ws_1/work/work_1/parts/raw'),
        ('PUT', '/api/v1/workspaces/ws_1/work/work_1/parts/raw'),
        ('GET', '/api/v1/workspaces/ws_1/work/work_1/parts/raw/revisions'),
        ('POST', '/api/v1/workspaces/ws_1/work/work_1/promotions'),
      ];
      expect(transport.requests, hasLength(expected.length));
      for (var index = 0; index < expected.length; index += 1) {
        expect(transport.requests[index].method, expected[index].$1);
        expect(transport.requests[index].url.path, expected[index].$2);
      }

      const mutationIndexes = <int>{
        1,
        4,
        6,
        8,
        9,
        10,
        11,
        13,
        17,
        19,
        20,
        21,
        22,
        24,
        26,
      };
      const etagIndexes = <int>{1, 8, 9, 10, 11, 13, 19, 20, 21, 22, 24, 26};
      for (var index = 0; index < transport.requests.length; index += 1) {
        final request = transport.requests[index];
        expect(
          request.headers.containsKey('X-Idempotency-Key'),
          mutationIndexes.contains(index),
          reason: 'idempotency mismatch at API24 operation ${index + 1}',
        );
        expect(request.headers.containsKey('Idempotency-Key'), isFalse);
        expect(
          request.headers.containsKey('If-Match'),
          etagIndexes.contains(index),
          reason: 'If-Match mismatch at API24 operation ${index + 1}',
        );
      }
      expect(transport.requests[2].url.queryParameters, <String, String>{
        'cursor': 'book_cursor',
        'limit': '20',
      });
      expect(transport.requests[15].url.queryParameters, <String, String>{
        'bookRevisionId': 'book_revision_1',
      });
      final importBody = jsonDecode(transport.requests[4].body!) as Map;
      expect(importBody, <String, Object?>{
        'resourceId': 'resource_import_1',
        'expectedBookRevisionId': 'book_revision_1',
      });
      expect(importBody, isNot(contains('path')));
      final promotionBody = jsonDecode(transport.requests[26].body!) as Map;
      expect(promotionBody['target'], 'creation');
      expect(promotionBody, isNot(contains('bookSection')));
    },
  );

  test(
    'API 24 rejects damaged views and preserves 409/412 conflicts',
    () async {
      final leakedBook = _api24Book()..['objectKey'] = 'private/object.zip';
      final impossibleImport = <String, Object?>{
        ..._api24BookImportPending(),
        'status': 'succeeded',
        'resultBookRevisionId': 'book_revision_2',
      };
      final transport = _QueueTransport(<ApiTransportResponse>[
        _objectResponse(leakedBook),
        _objectResponse(impossibleImport),
        ApiTransportResponse(
          status: 200,
          headers: const <String, String>{
            'Content-Type': 'application/zip',
            'ETag': '"package-1"',
            'X-Package-ETag': '"package-2"',
          },
          body: Uint8List.fromList(<int>[80, 75]),
        ),
        const ApiTransportResponse(
          status: 409,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'BOOK_VERSION_CONFLICT',
              'message': 'stale Book revision',
              'retryable': false,
            },
          },
        ),
        const ApiTransportResponse(
          status: 412,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'WORK_VERSION_CONFLICT',
              'message': 'stale Work ETag',
              'retryable': false,
            },
          },
        ),
      ]);
      final client = BookWorkClient(_client(transport));

      expect(
        (await client.bookDetail('ws_1')).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(
        (await client.bookImport('ws_1', 'book_import_1')).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(
        (await client.exportBook('ws_1')).error?.code,
        'API_RESPONSE_INVALID',
      );
      final bookConflict = await client.updateBook(
        'ws_1',
        request: SharedUpdateBookRequest(
          title: 'Book',
          language: 'zh-CN',
          status: 'active',
        ),
        etag: '"stale"',
        idempotencyKey: 'idem-conflict-book',
      );
      final workConflict = await client.completeWork(
        'ws_1',
        'work_1',
        etag: '"stale"',
        idempotencyKey: 'idem-conflict-work',
      );
      expect(bookConflict.status, 409);
      expect(bookConflict.error?.code, 'BOOK_VERSION_CONFLICT');
      expect(workConflict.status, 412);
      expect(workConflict.error?.code, 'WORK_VERSION_CONFLICT');

      expect(
        () => SharedCreateBookSectionRequest(
          sectionKey: '../chapter',
          title: 'unsafe',
          group: 'chapters',
        ),
        throwsArgumentError,
      );
      expect(
        () => SharedCreateWorkRequest(
          title: 'bad lineage',
          lineageRefs: <SharedWorkLineageRef>[
            SharedWorkNotePartLineageRef(
              ordinal: 1,
              noteId: 'note_1',
              part: 'raw',
              partRevisionId: 'part_revision_1',
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => SharedPromoteWorkRequest.bookSection(
          sourcePart: 'raw',
          sourcePartRevisionId: 'part_revision_1',
          sectionKey: 'Invalid Key',
          title: 'Chapter',
          group: 'chapters',
        ),
        throwsArgumentError,
      );
    },
  );
}

Map<String, Object?> _api24BookSectionSnapshot() => <String, Object?>{
  'sectionKey': 'chapter-1',
  'title': 'Chapter one',
  'group': 'chapters',
  'ordinal': 0,
  'metadataVersion': 1,
  'currentPartRevisionIds': <String, Object?>{'raw': 'part_revision_1'},
};

Map<String, Object?> _api24BookRevision() => <String, Object?>{
  'bookRevisionId': 'book_revision_1',
  'revision': 1,
  'title': 'Infinite Huahuo',
  'language': 'zh-CN',
  'status': 'active',
  'sectionOrderVersion': 1,
  'sections': <Object?>[_api24BookSectionSnapshot()],
  'createdAt': '2026-08-07T10:00:00Z',
};

Map<String, Object?> _api24BookSection() => <String, Object?>{
  ..._api24BookSectionSnapshot(),
  'parts': <Object?>[
    <String, Object?>{
      'part': 'raw',
      'currentRevisionId': 'part_revision_1',
      'revision': 1,
      'status': 'current',
    },
  ],
  'sourceRefs': <Object?>[
    <String, Object?>{
      'kind': 'note_part',
      'noteId': 'note_1',
      'part': 'raw',
      'partRevisionId': 'note_part_revision_1',
    },
  ],
  'resourceRefs': <Object?>[
    <String, Object?>{
      'resourceId': 'resource_1',
      'role': 'illustration',
      'ordinal': 0,
      'caption': 'Cover image',
    },
  ],
  'etag': '"section-1"',
};

Map<String, Object?> _api24Book() => <String, Object?>{
  'bookId': 'book_1',
  'currentBookRevisionId': 'book_revision_1',
  'current': _api24BookRevision(),
  'sections': <Object?>[_api24BookSection()],
  'etag': '"book-1"',
};

Map<String, Object?> _api24PartRevision() => <String, Object?>{
  'part': 'raw',
  'partRevisionId': 'part_revision_1',
  'revision': 1,
  'contentMarkdown': '# Content',
  'contentHash': 'sha256:part-1',
  'sizeBytes': 9,
  'sourceRefs': <Object?>[
    <String, Object?>{
      'noteId': 'note_1',
      'part': 'raw',
      'partRevisionId': 'note_part_revision_1',
    },
  ],
  'createdAt': '2026-08-07T10:00:00Z',
  'etag': '"part-1"',
};

Map<String, Object?> _api24Work() => <String, Object?>{
  'workId': 'work_1',
  'title': 'Research result',
  'lifecycle': 'active',
  'metadataVersion': 1,
  'lineageRefs': <Object?>[
    <String, Object?>{
      'ordinal': 0,
      'kind': 'note_part_revision',
      'noteId': 'note_1',
      'part': 'raw',
      'partRevisionId': 'note_part_revision_1',
    },
  ],
  'resourceRefs': <Object?>[
    <String, Object?>{
      'resourceId': 'resource_1',
      'role': 'reference',
      'ordinal': 0,
    },
  ],
  'parts': <Object?>[
    <String, Object?>{
      'part': 'raw',
      'currentRevisionId': 'part_revision_1',
      'revision': 1,
      'status': 'current',
    },
  ],
  'etag': '"work-1"',
};

Map<String, Object?> _api24BookImportPending() => <String, Object?>{
  'bookImportId': 'book_import_1',
  'status': 'validating',
  'resourceId': 'resource_import_1',
  'expectedBookRevisionId': 'book_revision_1',
};

Map<String, Object?> _api24Event({
  required String kind,
  required String id,
  bool revision = false,
  int version = 1,
  String? identity,
  bool tombstone = false,
}) => <String, Object?>{
  'eventId': 'event_${kind}_$version',
  'workspaceId': 'ws_1',
  'cursor': '${300 + version}',
  'operationId': 'operation_${kind}_$version',
  'occurredAt': '2026-08-07T10:01:00Z',
  'objectKind': kind,
  'objectId': id,
  'changeType': tombstone ? 'tombstoned' : 'updated',
  if (revision) 'revisionId': identity ?? '${kind}_revision_$version',
  if (!revision) 'version': version,
  'tombstone': tombstone,
  'resourcePinDelta': <String, Object?>{
    'added': <Object?>[],
    'released': <Object?>[],
  },
};

ApiTransportResponse _objectResponse(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

Map<String, Object?> _skillInstallation({
  String skillProfileId = 'skill/opaque+id',
  String state = 'enabled',
  String installMode = 'user_managed',
}) => <String, Object?>{
  'skillProfileId': skillProfileId,
  'state': state,
  'installMode': installMode,
  'installedAt': '2026-08-07T10:00:00Z',
  'updatedAt': '2026-08-07T10:01:00Z',
};

Map<String, Object?> _workspaceSearchOutput({
  required String mode,
  bool withResult = false,
}) => <String, Object?>{
  'mode': mode,
  'queryFingerprint': 'sha256:query',
  'keywordReadiness': 'current',
  'vectorReadiness': 'current',
  'contentCursor': '230',
  if (mode == 'keyword' && !withResult) 'keywordAttemptId': 'opaque-receipt',
  if (mode != 'keyword') 'vectorStatus': 'current',
  'results': <Object?>[
    if (withResult)
      <String, Object?>{
        'ownerRef': <String, Object?>{
          'workspaceId': 'ws_1',
          'kind': 'hnote',
          'id': 'note_1',
        },
        'revisionId': 'note_revision_1',
        'part': 'raw',
        'path': 'notes/note_1/raw.md',
        'title': 'Product strategy',
        'updatedAt': '2026-08-07T10:00:00Z',
        'matchMode': mode,
        'score': 0.95,
        'staleSource': false,
      },
  ],
};

Map<String, Object?> _sourceRef({
  String noteId = 'note_1',
  String part = 'raw',
  String partRevisionId = 'part_revision_1',
}) => <String, Object?>{
  'noteId': noteId,
  'part': part,
  'partRevisionId': partRevisionId,
};

Map<String, Object?> _explicitRelation() => <String, Object?>{
  'relationId': 'relation_1',
  'relationType': 'supports',
  'origin': 'explicit',
  'source': _sourceRef(),
  'target': _sourceRef(
    noteId: 'note_2',
    part: 'outline',
    partRevisionId: 'part_revision_2',
  ),
  'rationale': 'Direct evidence',
  'version': 1,
  'etag': '"relation-1"',
};

Map<String, Object?> _automaticRelation() => <String, Object?>{
  'relationId': 'relation_auto_1',
  'relationType': 'similar',
  'origin': 'automatic',
  'source': _sourceRef(),
  'target': _sourceRef(noteId: 'note_3', partRevisionId: 'part_revision_3'),
  'score': 0.8,
  'embeddingVersion': 'embedding-v1',
  'algorithmVersion': 'similarity-v1',
};

Map<String, Object?> _relationEvent({
  required int version,
  bool tombstone = false,
}) => <String, Object?>{
  'eventId': 'relation_event_$version',
  'workspaceId': 'ws_1',
  'cursor': '${230 + version}',
  'operationId': 'relation_operation_$version',
  'occurredAt': '2026-08-07T10:00:00Z',
  'objectKind': 'note_relation',
  'objectId': 'relation_1',
  'changeType': tombstone ? 'tombstoned' : 'version_changed',
  'version': version,
  if (version > 1) 'previousVersion': version - 1,
  'tombstone': tombstone,
  'resourcePinDelta': <String, Object?>{
    'added': <Object?>[],
    'released': <Object?>[],
  },
};

Map<String, Object?> _monthlyCredit() => <String, Object?>{
  'policyVersion': 'credit-policy-v1',
  'quotaCredits': 10000000,
  'periodStart': '2026-08-01T00:00:00Z',
  'periodEnd': '2026-09-01T00:00:00Z',
  'availableCredits': 9000000,
  'reservedCredits': 100000,
  'settledCredits': 900000,
  'expiresAt': '2026-09-01T00:00:00Z',
};

Map<String, Object?> _accountAdmission() => <String, Object?>{
  'runAdmission': 'allowed',
  'outstandingUncoveredCredits': 0,
};

Map<String, Object?> _membershipResponse({
  String levelCode = 'pilot_paid',
  String status = 'active',
  String? expiresAt,
}) => <String, Object?>{
  'membership': <String, Object?>{
    'membershipId': 'membership_1',
    'levelCode': levelCode,
    'status': status,
    'expiresAt': expiresAt,
  },
  'monthlyCredit': _monthlyCredit(),
  'permanentCredit': <String, Object?>{
    'availableCredits': 5000,
    'reservedCredits': 100,
  },
  'account': _accountAdmission(),
};

Map<String, Object?> _creditSummaryResponse() => <String, Object?>{
  'monthlyCredit': _monthlyCredit(),
  'permanentCredit': <String, Object?>{
    'availableCredits': 5000,
    'reservedCredits': 100,
    'lots': <Object?>[
      <String, Object?>{
        'lotId': 'lot_1',
        'originKind': 'admin_grant',
        'originalCredits': 10000,
        'availableCredits': 5000,
        'reservedCredits': 100,
        'createdAt': '2026-08-07T10:00:00Z',
        'expiresAt': null,
      },
    ],
    'nextCursor': 'credit-page-2',
  },
  'account': _accountAdmission(),
};

Map<String, Object?> _runUsageResponse() => <String, Object?>{
  'runId': 'run_1',
  'policyVersion': 'credit-policy-v1',
  'rawInputTokens': 100,
  'rawOutputTokens': 50,
  'accountedCredits': 150,
  'settlementStatus': 'settled',
  'assistantResultPersisted': true,
  'measurements': <Object?>[
    <String, Object?>{
      'usageKind': 'video_analysis',
      'mediaDurationSeconds': 1.5,
      'measurementStatus': 'measured',
      'accountedCredits': 100,
      'providerCost': <String, Object?>{'amount': '0.01', 'currency': 'CNY'},
    },
  ],
};

ApiTransportResponse _subscriptionPageResponse(List<Object?> items) {
  return ApiTransportResponse(
    status: 200,
    body: <String, Object?>{
      'success': true,
      'data': <String, Object?>{
        'items': items,
        'nextCursor': 'next_opaque_cursor',
      },
    },
  );
}

ApiTransportResponse _subscriptionObjectResponse(
  Map<String, Object?> data, {
  int status = 200,
}) {
  return ApiTransportResponse(
    status: status,
    body: <String, Object?>{'success': true, 'data': data},
  );
}

Map<String, Object?> _subscriptionPublication() => <String, Object?>{
  'publicationId': 'publication_1',
  'title': 'Infinite Huahuo Daily',
  'summary': 'Daily local publication',
  'sectionCount': '2',
  'articleCount': '10',
  'updatedAt': '2026-08-07T10:00:00Z',
};

Map<String, Object?> _subscriptionSection() => <String, Object?>{
  'sectionId': 'section_1',
  'publicationId': 'publication_1',
  'title': 'Product',
  'sortOrder': 1,
};

Map<String, Object?> _subscriptionArticle() => <String, Object?>{
  'articleId': 'article_1',
  'publicationId': 'publication_1',
  'sectionId': 'section_1',
  'currentArticleRevisionId': 'article_revision_1',
  'title': 'Article title',
  'summary': 'Article summary',
  'author': 'Huahuo',
  'publishedAt': '2026-08-07T09:00:00Z',
};

Map<String, Object?> _subscriptionRevision() => <String, Object?>{
  'articleId': 'article_1',
  'articleRevisionId': 'article_revision_1',
  'title': 'Article title',
  'contentMarkdown': '# Article',
  'contentSha256': 'sha256_1',
  'assetRefs': <Object?>[
    <String, Object?>{
      'fileKey': 'image_file_1',
      'logicalPath': 'images/cover.png',
    },
  ],
};

Map<String, Object?> _subscriptionLibraryItem() => <String, Object?>{
  'publication': _subscriptionPublication(),
  'followedAt': '2026-08-07T10:01:00Z',
  'availability': 'available',
};

Map<String, Object?> _subscriptionFollowResult({required String lifecycle}) =>
    <String, Object?>{
      'workspaceId': 'ws_1',
      'publicationId': 'publication_1',
      'lifecycle': lifecycle,
      if (lifecycle == 'following') 'followedAt': '2026-08-07T10:01:00Z',
      if (lifecycle == 'unfollowed') 'unfollowedAt': '2026-08-07T10:02:00Z',
    };

Map<String, Object?> _subscriptionSaveReceipt() => <String, Object?>{
  'noteId': 'note_subscription_1',
  'noteRevisionId': 'note_revision_1',
  'rawPartRevisionId': 'raw_revision_1',
  'outlinePartRevisionId': 'outline_revision_1',
  'germinationPartRevisionId': 'germination_revision_1',
  'articleId': 'article_1',
  'articleRevisionId': 'article_revision_1',
  'created': true,
  'lifecycle': 'live',
  'etag': '"note-subscription-1"',
  'contentCursor': '220',
};

Map<String, Object?> _workspaceSummary() => <String, Object?>{
  'workspaceId': 'ws_1',
  'displayName': 'Personal workspace',
  'state': 'ready',
  'isDefault': true,
  'etag': '"workspace-1"',
};

Map<String, Object?> _workspaceFolder({
  String cursor = '184',
  String revision = 'folder_revision_1',
}) => <String, Object?>{
  'folderId': 'folder_1',
  'workspaceId': 'ws_1',
  'parentFolderId': null,
  'displayName': 'Research',
  'normalizedName': 'research',
  'state': 'active',
  'currentRevisionId': revision,
  'etag': '"folder-1"',
  'contentCursor': cursor,
};

Map<String, Object?> _workspaceEvent() => <String, Object?>{
  'eventId': 'event_1',
  'workspaceId': 'ws_1',
  'cursor': '185',
  'operationId': 'operation_1',
  'occurredAt': '2026-08-07T09:01:00Z',
  'objectKind': 'hnote',
  'objectId': 'note_1',
  'changeType': 'revision_created',
  'revisionId': 'note_revision_2',
  'previousRevisionId': 'note_revision_1',
  'tombstone': false,
  'resourcePinDelta': <String, Object?>{
    'added': <Object?>['resource_2'],
    'released': <Object?>['resource_1'],
  },
};

Map<String, Object?> _tombstoneEvent({required String cursor}) =>
    <String, Object?>{
      'eventId': 'event-tombstone-$cursor',
      'workspaceId': 'ws_1',
      'cursor': cursor,
      'operationId': 'operation-tombstone-$cursor',
      'occurredAt': '2026-08-07T09:01:00Z',
      'objectKind': 'hnote',
      'objectId': 'note_1',
      'changeType': 'tombstoned',
      'revisionId': 'note_revision_tombstoned',
      'previousRevisionId': 'note_revision_2',
      'tombstone': true,
      'resourcePinDelta': <String, Object?>{
        'added': <Object?>[],
        'released': <Object?>[],
      },
    };

Map<String, Object?> _workspaceHNote({required String cursor}) =>
    <String, Object?>{
      'noteId': 'note_1',
      'workspaceId': 'ws_1',
      'folderId': 'folder_1',
      'title': 'Restored note',
      'state': 'live',
      'noteRevisionId': 'note_revision_3',
      'rawPartRevisionId': 'raw_revision_3',
      'outlinePartRevisionId': 'outline_revision_3',
      'germinationPartRevisionId': 'germination_revision_3',
      'resourceRefs': <Object?>[],
      'etag': '"note-3"',
      'contentCursor': cursor,
    };

Map<String, Object?> _formalHNoteHeadReceipt() => <String, Object?>{
  'noteId': 'note_formal_1',
  'workspaceId': 'ws_1',
  'folderId': null,
  'title': 'Formal note',
  'state': 'live',
  'noteRevisionId': 'note_revision_formal_1',
  'rawPartRevisionId': 'raw_revision_formal_1',
  'outlinePartRevisionId': 'outline_revision_formal_1',
  'germinationPartRevisionId': 'germination_revision_formal_1',
  'resourceRefs': <Object?>[],
  'etag': '"note-formal-1"',
  'contentCursor': '201',
};

Map<String, Object?> _createRunResponse(Map<String, Object?> run) =>
    <String, Object?>{
      'run': run,
      'nextAction': <String, Object?>{
        'type': 'poll_agent_run',
        'agentRunId': run['agentRunId'],
        'afterSequence': 0,
      },
    };

Map<String, Object?> _run({
  required String status,
  bool terminal = false,
  String completionMode = 'normal',
}) => <String, Object?>{
  'agentRunId': 'run_1',
  'workspaceId': 'ws_1',
  'threadId': 'thread_1',
  'status': status,
  'workspaceVersion': 4,
  'workspaceBindingVersion': 2,
  'contextGeneration': 7,
  if (terminal)
    'result': <String, Object?>{
      'finalAnswer': 'done',
      'assistantMessageId': 'message_1',
      'completionMode': completionMode,
    },
  if (terminal) 'assistantMessageId': 'message_1',
  if (terminal) 'completionMode': completionMode,
  'usage': <String, Object?>{
    'measurementStatus': terminal ? 'measured' : 'pending',
    'inputTokens': terminal ? 10 : null,
    'outputTokens': terminal ? 20 : null,
    'imageCount': terminal ? 1 : null,
    'videoSeconds': null,
    'accountedCredits': terminal ? 30 : null,
    'policyVersion': terminal ? 'credits-v1' : null,
  },
  if (terminal)
    'toolTrace': <Object?>[
      <String, Object?>{
        'invocationId': 'invocation_1',
        'toolName': 'image_generation',
        'state': 'finished',
        'outcome': 'succeeded',
        'createdAt': '2026-08-01T00:00:00Z',
        'completedAt': '2026-08-01T00:00:02Z',
        'inputSummary': <String, Object?>{
          'promptSummary': '一个新鲜的西瓜，放在木质桌面上',
          'count': 1,
        },
        'outputFiles': <Object?>[
          <String, Object?>{
            'resourceId': 'resource_1',
            'fileName': 'image.png',
            'mimeType': 'image/png',
            'sizeBytes': 2048,
          },
        ],
      },
    ],
  'createdAt': '2026-08-01T00:00:00Z',
  'updatedAt': '2026-08-01T00:00:03Z',
};

ApiClient _client(ApiTransport transport) => ApiClient(
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

Future<void> _waitForRequestCount(
  List<ApiTransportRequest> requests,
  int count,
) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (requests.length == count) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Expected $count requests, saw ${requests.length}');
}

final class _BlockingCancellableTransport
    implements ApiTransport, CancellableApiTransport {
  final requests = <ApiTransportRequest>[];
  int cancelCalls = 0;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) =>
      sendCancellable(request).response;

  @override
  ApiTransportOperation sendCancellable(ApiTransportRequest request) {
    requests.add(request);
    final response = Completer<ApiTransportResponse>();
    return ApiTransportOperation(
      response: response.future,
      cancel: () {
        cancelCalls += 1;
        if (!response.isCompleted) {
          response.completeError(StateError('transport-cancelled'));
        }
      },
    );
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

final class _StreamingTransport implements ApiTransport, ApiStreamingTransport {
  _StreamingTransport(this.response);

  final ApiTransportStreamResponse response;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportStreamResponse> open(ApiTransportRequest request) async {
    requests.add(request);
    return response;
  }

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) =>
      throw StateError('Unexpected non-streaming request');
}
