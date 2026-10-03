import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/features/ui_v3/application/script_draft_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/script_draft_api.dart';
import 'package:huahuoai_app/features/ui_v3/domain/script_draft_models.dart';

void main() {
  test('source and receipt round-trip preserve the frozen contract', () {
    final source = _source();
    final receipt = ScriptDraftGenerationReceipt(
      sessionId: 'session-1',
      source: source,
      createThreadIdempotencyKey: 'create-1',
      messageIdempotencyKey: 'message-1',
      cancelIdempotencyKey: 'cancel-1',
      phase: ScriptDraftGenerationPhase.streaming,
      threadId: 'thread-1',
      agentRunId: 'agent-run-1',
      afterSequence: 8,
      partialMarkdown: '只读预览',
      updatedAt: DateTime.utc(2026, 9, 4),
    );

    final decoded = ScriptDraftGenerationReceipt.fromJson(receipt.toJson());

    expect(decoded.source.identity, source.identity);
    expect(decoded.afterSequence, 8);
    expect(decoded.partialMarkdown, '只读预览');
    expect(decoded.hasAuthoritativeResult, isFalse);
    expect(
      ScriptDraftRequest(source: source).toJson(),
      containsPair('modelProfileId', 'deepseek-v4-flash-vision'),
    );
  });

  test('source identity distinguishes asset part and revision', () {
    ScriptDraftSourceSnapshot assetSource({
      required ScriptDraftAssetPart part,
      required String revision,
    }) => ScriptDraftSourceSnapshot(
      kind: ScriptDraftSourceKind.asset,
      sourceId: 'asset-1',
      title: '同一资产',
      content: '完全相同的阶段正文',
      assetPart: part,
      partRevisionId: revision,
      capturedAt: DateTime.utc(2026, 9, 4),
    );

    final raw = assetSource(part: ScriptDraftAssetPart.raw, revision: 'raw-r1');
    final outline = assetSource(
      part: ScriptDraftAssetPart.outline,
      revision: 'outline-r1',
    );
    final nextRaw = assetSource(
      part: ScriptDraftAssetPart.raw,
      revision: 'raw-r2',
    );

    expect(raw.identity, isNot(outline.identity));
    expect(raw.identity, isNot(nextRaw.identity));
  });

  test('script draft API preserves polling gap recovery details', () async {
    final api = ScriptDraftApi(
      ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: '0.1.0',
          deviceId: 'device-1',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () => 'access-token',
        ),
        transport: const _SingleResponseTransport(
          ApiTransportResponse(
            status: 409,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{
                'code': 'RUNTIME_EVENT_GAP',
                'userMessage': 'event history has a gap',
                'retryable': false,
                'details': <String, Object?>{
                  'oldestAvailableSequence': 5,
                  'latestSequence': 9,
                  'resumeAfterSequence': 4,
                },
              },
            },
          ),
        ),
      ),
    );

    try {
      await api.readEvents(agentRunId: 'run-gap', afterSequence: 1);
      fail('Expected RUNTIME_EVENT_GAP');
    } on ScriptDraftTransportException catch (error) {
      expect(error.code, 'RUNTIME_EVENT_GAP');
      expect(error.resumeAfterSequence, 4);
      expect(error.oldestAvailableSequence, 5);
      expect(error.retryable, isFalse);
    }
  });

  test(
    'script draft API distinguishes profile rejection from unknown response',
    () async {
      for (final fixture in <(String, int, bool)>[
        ('AGENT_PROFILE_NOT_SELECTABLE', 409, false),
        ('MODEL_PROFILE_NOT_SELECTABLE', 400, true),
      ]) {
        final api = ScriptDraftApi(
          _apiClientWithTransport(
            _SingleResponseTransport(
              ApiTransportResponse(
                status: fixture.$2,
                body: <String, Object?>{
                  'success': false,
                  'error': <String, Object?>{
                    'code': fixture.$1,
                    'userMessage': 'profile is not selectable',
                    'retryable': fixture.$3,
                  },
                },
              ),
            ),
          ),
        );

        await expectLater(
          api.submit(
            threadId: 'thread-profile-rejected',
            request: ScriptDraftRequest(source: _source()),
            idempotencyKey: 'message-profile-rejected',
          ),
          throwsA(
            isA<ScriptDraftTransportException>()
                .having((error) => error.code, 'code', fixture.$1)
                .having(
                  (error) => error.retryable,
                  'retryable metadata',
                  fixture.$3,
                )
                .having(
                  (error) => error.writeOutcome,
                  'write outcome',
                  ScriptDraftWriteOutcome.knownRejected,
                ),
          ),
        );
      }

      final unknownFailures = <(ScriptDraftApi, String)>[
        (
          ScriptDraftApi(
            _apiClientWithTransport(
              const _SingleResponseTransport(
                ApiTransportResponse(
                  status: 200,
                  body: <String, Object?>{
                    'success': true,
                    'data': <String, Object?>{'taskId': 'task-without-run'},
                  },
                ),
              ),
            ),
          ),
          'API_MALFORMED_ENVELOPE',
        ),
        (
          ScriptDraftApi(
            _apiClientWithTransport(
              const _SingleResponseTransport(
                ApiTransportResponse(
                  status: 200,
                  body: <String, Object?>{
                    'success': true,
                    'data': 'invalid-run-payload',
                  },
                ),
              ),
            ),
          ),
          'API_RESPONSE_INVALID',
        ),
        (
          ScriptDraftApi(_apiClientWithTransport(const _ThrowingTransport())),
          'NETWORK_REQUEST_FAILED',
        ),
      ];

      for (final fixture in unknownFailures) {
        await expectLater(
          fixture.$1.submit(
            threadId: 'thread-unknown-response',
            request: ScriptDraftRequest(source: _source()),
            idempotencyKey: 'message-unknown-response',
          ),
          throwsA(
            isA<ScriptDraftTransportException>()
                .having((error) => error.code, 'code', fixture.$2)
                .having(
                  (error) => error.writeOutcome,
                  'write outcome',
                  ScriptDraftWriteOutcome.unknown,
                ),
          ),
        );
      }
    },
  );

  test(
    'thread creation API distinguishes known rejection from unknown outcome',
    () async {
      final rejectedApi = ScriptDraftApi(
        _apiClientWithTransport(
          const _SingleResponseTransport(
            ApiTransportResponse(
              status: 409,
              body: <String, Object?>{
                'success': false,
                'error': <String, Object?>{
                  'code': 'WORKSPACE_CHAT_NOT_AVAILABLE',
                  'userMessage': 'workspace chat is not available',
                  'retryable': true,
                },
              },
            ),
          ),
        ),
      );

      await expectLater(
        rejectedApi.createThread(idempotencyKey: 'known-create-rejection'),
        throwsA(
          isA<ScriptDraftTransportException>()
              .having(
                (error) => error.code,
                'code',
                'WORKSPACE_CHAT_NOT_AVAILABLE',
              )
              .having((error) => error.retryable, 'retryable metadata', isTrue)
              .having(
                (error) => error.writeOutcome,
                'write outcome',
                ScriptDraftWriteOutcome.knownRejected,
              ),
        ),
      );

      final unknownFailures = <(ScriptDraftApi, String)>[
        (
          ScriptDraftApi(
            _apiClientWithTransport(
              const _SingleResponseTransport(
                ApiTransportResponse(
                  status: 200,
                  body: <String, Object?>{
                    'success': true,
                    'data': <String, Object?>{'taskId': 'missing-thread-id'},
                  },
                ),
              ),
            ),
          ),
          'API_MALFORMED_ENVELOPE',
        ),
        (
          ScriptDraftApi(
            _apiClientWithTransport(
              const _SingleResponseTransport(
                ApiTransportResponse(
                  status: 200,
                  body: <String, Object?>{
                    'success': true,
                    'data': 'invalid-thread-payload',
                  },
                ),
              ),
            ),
          ),
          'API_RESPONSE_INVALID',
        ),
        (
          ScriptDraftApi(_apiClientWithTransport(const _ThrowingTransport())),
          'NETWORK_REQUEST_FAILED',
        ),
      ];

      for (final fixture in unknownFailures) {
        await expectLater(
          fixture.$1.createThread(idempotencyKey: 'unknown-create-outcome'),
          throwsA(
            isA<ScriptDraftTransportException>()
                .having((error) => error.code, 'code', fixture.$2)
                .having(
                  (error) => error.writeOutcome,
                  'write outcome',
                  ScriptDraftWriteOutcome.unknown,
                ),
          ),
        );
      }
    },
  );

  test('transient write responses remain outcome unknown', () async {
    for (final fixture in <(int, String)>[
      (408, 'REQUEST_TIMEOUT'),
      (429, 'RATE_LIMITED'),
      (500, 'INTERNAL_SERVER_ERROR'),
      (503, 'API_SERVER_UNAVAILABLE'),
      (400, 'API_SERVER_UNAVAILABLE'),
    ]) {
      ScriptDraftApi api() => ScriptDraftApi(
        _apiClientWithTransport(
          _SingleResponseTransport(
            ApiTransportResponse(
              status: fixture.$1,
              body: <String, Object?>{
                'success': false,
                'error': <String, Object?>{
                  'code': fixture.$2,
                  'userMessage': 'write result is unresolved',
                  'retryable': false,
                },
              },
            ),
          ),
        ),
      );

      await expectLater(
        api().createThread(idempotencyKey: 'transient-create'),
        throwsA(
          isA<ScriptDraftTransportException>()
              .having((error) => error.code, 'code', fixture.$2)
              .having(
                (error) => error.writeOutcome,
                'write outcome',
                ScriptDraftWriteOutcome.unknown,
              ),
        ),
      );
      await expectLater(
        api().submit(
          threadId: 'transient-thread',
          request: ScriptDraftRequest(source: _source()),
          idempotencyKey: 'transient-message',
        ),
        throwsA(
          isA<ScriptDraftTransportException>()
              .having((error) => error.code, 'code', fixture.$2)
              .having(
                (error) => error.writeOutcome,
                'write outcome',
                ScriptDraftWriteOutcome.unknown,
              ),
        ),
      );
    }
  });

  test('transient create cannot be bypassed by a fresh Thread', () async {
    final transport = _RecordingResponseTransport(
      const ApiTransportResponse(
        status: 503,
        body: <String, Object?>{
          'success': false,
          'error': <String, Object?>{
            'code': 'API_SERVER_UNAVAILABLE',
            'userMessage': 'upstream unavailable',
            'retryable': false,
          },
        },
      ),
    );
    final controller = ScriptDraftController(
      ScriptDraftApi(_apiClientWithTransport(transport)),
      keyFactory: _sequentialKeys(),
      reconnectDelay: Duration.zero,
    );
    addTearDown(controller.dispose);

    expect(await controller.generateFresh(_source()), isFalse);
    final receipt = controller.receipt!;
    expect(controller.errorCode, 'SCRIPT_DRAFT_THREAD_CREATE_OUTCOME_UNKNOWN');
    expect(await controller.regenerate(), isFalse);
    expect(transport.requests, hasLength(1));
    expect(controller.receipt?.sessionId, receipt.sessionId);
    expect(
      controller.receipt?.createThreadIdempotencyKey,
      receipt.createThreadIdempotencyKey,
    );
  });

  test(
    'stream preview honors append, replace, sequence, and terminal GET',
    () async {
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          Stream<ScriptDraftStreamSignal>.fromIterable(
            const <ScriptDraftStreamSignal>[
              ScriptDraftStreamSignal.event(
                ScriptDraftRemoteEvent(
                  sequence: 1,
                  status: 'running',
                  deltaText: '草',
                ),
              ),
              ScriptDraftStreamSignal.event(
                ScriptDraftRemoteEvent(
                  sequence: 2,
                  status: 'running',
                  deltaText: '稿',
                ),
              ),
              ScriptDraftStreamSignal.event(
                ScriptDraftRemoteEvent(
                  sequence: 2,
                  status: 'running',
                  deltaText: '重复',
                ),
              ),
              ScriptDraftStreamSignal.event(
                ScriptDraftRemoteEvent(
                  sequence: 3,
                  status: 'running',
                  deltaText: '只读流式预览',
                  replace: true,
                ),
              ),
              ScriptDraftStreamSignal.event(
                ScriptDraftRemoteEvent(sequence: 4, status: 'succeeded'),
              ),
            ],
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '后端终态正文',
          ),
        ],
      );
      final saved = <ScriptDraftGenerationReceipt>[];
      final controller = ScriptDraftController(
        port,
        persistReceipt: (receipt) async => saved.add(receipt),
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(
        await controller.generateFresh(_source()),
        isTrue,
        reason: '${controller.phase} ${controller.errorCode}',
      );

      expect(controller.phase, ScriptDraftGenerationPhase.ready);
      expect(controller.state.partialMarkdown, '只读流式预览');
      expect(controller.state.finalMarkdown, '后端终态正文');
      expect(port.createdWith, <String>['create-thread-2']);
      expect(port.submittedWith.single.$1, 'thread-1');
      expect(port.submittedWith.single.$2, 'send-message-3');
      expect(port.streamAfterSequences, <int>[0]);
      expect(saved.first.phase, ScriptDraftGenerationPhase.resolving);
      expect(saved.last.phase, ScriptDraftGenerationPhase.ready);
      expect(
        saved.where((receipt) => receipt.afterSequence == 2),
        hasLength(1),
      );
    },
  );

  test(
    'a stream gap replays event pages without promoting partial text',
    () async {
      final saved = <ScriptDraftGenerationReceipt>[];
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          Stream<ScriptDraftStreamSignal>.fromIterable(
            const <ScriptDraftStreamSignal>[
              ScriptDraftStreamSignal.event(
                ScriptDraftRemoteEvent(
                  sequence: 1,
                  status: 'running',
                  deltaText: '缺口前的旧预览',
                ),
              ),
              ScriptDraftStreamSignal.gap(resumeAfterSequence: 4),
            ],
          ),
        ],
        pages: <ScriptDraftEventPage>[
          ScriptDraftEventPage(
            items: const <ScriptDraftRemoteEvent>[
              ScriptDraftRemoteEvent(
                sequence: 5,
                status: 'running',
                deltaText: '恢复后的预览',
                replace: true,
              ),
              ScriptDraftRemoteEvent(sequence: 6, status: 'succeeded'),
            ],
            nextAfterSequence: 6,
            hasMore: false,
            gap: false,
            oldestAvailableSequence: 5,
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '权威成稿',
          ),
        ],
        onReadEvents: (afterSequence) {
          expect(afterSequence, 4);
          expect(saved.last.afterSequence, 4);
          expect(saved.last.partialMarkdown, isEmpty);
          expect(saved.last.partialIsComplete, isFalse);
        },
      );
      final controller = ScriptDraftController(
        port,
        persistReceipt: (receipt) async => saved.add(receipt),
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(
        await controller.generateFresh(_source()),
        isTrue,
        reason: '${controller.phase} ${controller.errorCode}',
      );
      expect(controller.state.partialMarkdown, '恢复后的预览');
      expect(controller.state.partialIsComplete, isFalse);
      expect(controller.state.finalMarkdown, '权威成稿');
      expect(port.eventPageAfterSequences, <int>[4]);
    },
  );

  test(
    'a polling 409 checkpoints its recovery cursor before the next read',
    () async {
      final saved = <ScriptDraftGenerationReceipt>[];
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(
                sequence: 1,
                status: 'running',
                deltaText: '缺口前预览',
              ),
            ),
          ),
        ],
        readEventErrors: const <ScriptDraftTransportException>[
          ScriptDraftTransportException(
            'RUNTIME_EVENT_GAP',
            resumeAfterSequence: 4,
            oldestAvailableSequence: 5,
          ),
        ],
        pages: <ScriptDraftEventPage>[
          ScriptDraftEventPage(
            items: const <ScriptDraftRemoteEvent>[
              ScriptDraftRemoteEvent(
                sequence: 5,
                status: 'running',
                deltaText: '恢复后的预览',
                replace: true,
              ),
            ],
            nextAfterSequence: 5,
            hasMore: false,
            gap: false,
            oldestAvailableSequence: 5,
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(status: 'running'),
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '权威成稿',
          ),
        ],
        onReadEvents: (afterSequence) {
          if (afterSequence != 4) return;
          expect(saved.last.afterSequence, 4);
          expect(saved.last.partialMarkdown, isEmpty);
          expect(saved.last.partialIsComplete, isFalse);
        },
      );
      final controller = ScriptDraftController(
        port,
        persistReceipt: (receipt) async => saved.add(receipt),
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isTrue);
      expect(port.eventPageAfterSequences, <int>[1, 4]);
      expect(controller.state.partialMarkdown, '恢复后的预览');
      expect(controller.state.partialIsComplete, isFalse);
      expect(controller.state.finalMarkdown, '权威成稿');
    },
  );

  test(
    'retryable stream failure reconnects from the persisted cursor',
    () async {
      Stream<ScriptDraftStreamSignal> interruptedStream() async* {
        yield const ScriptDraftStreamSignal.event(
          ScriptDraftRemoteEvent(
            sequence: 1,
            status: 'running',
            deltaText: '已持久化',
          ),
        );
        throw const ScriptDraftTransportException(
          'SCRIPT_DRAFT_STREAM_FAILED',
          retryable: true,
        );
      }

      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          interruptedStream(),
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(sequence: 2, status: 'succeeded'),
            ),
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(status: 'running'),
          ScriptDraftRunSnapshot(status: 'running'),
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '重连后的权威终稿',
          ),
        ],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isTrue);
      expect(port.streamAfterSequences, <int>[0, 1]);
      expect(port.eventPageAfterSequences, <int>[1]);
      expect(controller.state.partialMarkdown, '已持久化');
      expect(controller.state.finalMarkdown, '重连后的权威终稿');
    },
  );

  test(
    'retryable reconcile failure reconnects SSE and reaches terminal success',
    () async {
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          const Stream<ScriptDraftStreamSignal>.empty(),
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
            ),
          ),
        ],
        getRunErrors: const <ScriptDraftTransportException>[
          ScriptDraftTransportException(
            'SCRIPT_DRAFT_RUN_READ_FAILED',
            retryable: true,
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '对账重连后的权威终稿',
          ),
        ],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isTrue);
      expect(port.streamAfterSequences, <int>[0, 0]);
      expect(port.getRunCalls, 2);
      expect(controller.state.finalMarkdown, '对账重连后的权威终稿');
    },
  );

  test('resume from a run receipt never recreates or resubmits', () async {
    final source = _source();
    final receipt = ScriptDraftGenerationReceipt(
      sessionId: 'existing-session',
      source: source,
      createThreadIdempotencyKey: 'existing-create',
      messageIdempotencyKey: 'existing-message',
      cancelIdempotencyKey: 'existing-cancel',
      phase: ScriptDraftGenerationPhase.streaming,
      threadId: 'thread-existing',
      agentRunId: 'agent-run-existing',
      afterSequence: 9,
      partialMarkdown: '已有预览',
      updatedAt: DateTime.utc(2026, 9, 4),
    );
    final port = _FakeScriptDraftPort(
      streams: <Stream<ScriptDraftStreamSignal>>[
        Stream<ScriptDraftStreamSignal>.value(
          const ScriptDraftStreamSignal.event(
            ScriptDraftRemoteEvent(sequence: 10, status: 'succeeded'),
          ),
        ),
      ],
      runs: const <ScriptDraftRunSnapshot>[
        ScriptDraftRunSnapshot(
          status: 'succeeded',
          completionMode: 'normal',
          finalAnswer: '恢复后的终稿',
        ),
      ],
    );
    final controller = ScriptDraftController(
      port,
      keyFactory: _sequentialKeys(),
      reconnectDelay: Duration.zero,
    );
    addTearDown(controller.dispose);

    expect(
      await controller.start(source: source, persistedReceipt: receipt),
      isTrue,
      reason: '${controller.phase} ${controller.errorCode}',
    );

    expect(port.createdWith, isEmpty);
    expect(port.submittedWith, isEmpty);
    expect(port.streamAfterSequences, <int>[9]);
    expect(controller.state.finalMarkdown, '恢复后的终稿');
  });

  test(
    'unknown thread creation retries its key and blocks early regeneration',
    () async {
      final port = _FakeScriptDraftPort(
        createErrors: <ScriptDraftTransportException>[
          const ScriptDraftTransportException(
            'NETWORK_UNAVAILABLE',
            retryable: true,
            writeOutcome: ScriptDraftWriteOutcome.unknown,
          ),
        ],
        streams: <Stream<ScriptDraftStreamSignal>>[
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
            ),
          ),
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
            ),
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '首次终稿',
          ),
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '重新生成终稿',
          ),
        ],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isFalse);
      final failed = controller.receipt!;
      expect(
        controller.errorCode,
        'SCRIPT_DRAFT_THREAD_CREATE_OUTCOME_UNKNOWN',
      );
      expect(controller.state.errorRetryable, isTrue);
      expect(await controller.regenerate(), isFalse);
      expect(port.createdWith, <String>[failed.createThreadIdempotencyKey]);

      expect(await controller.retryTransport(), isTrue);
      expect(port.createdWith, <String>[
        failed.createThreadIdempotencyKey,
        failed.createThreadIdempotencyKey,
      ]);
      final firstSession = controller.receipt!.sessionId;
      final firstMessageKey = controller.receipt!.messageIdempotencyKey;

      expect(await controller.regenerate(), isTrue);
      expect(controller.receipt!.sessionId, isNot(firstSession));
      expect(controller.receipt!.messageIdempotencyKey, isNot(firstMessageKey));
      expect(controller.state.finalMarkdown, '重新生成终稿');
    },
  );

  test(
    'restored unknown thread creation only retries the persisted create key',
    () async {
      final source = _source();
      final receipt = ScriptDraftGenerationReceipt(
        sessionId: 'unknown-create-session',
        source: source,
        createThreadIdempotencyKey: 'unknown-create-key',
        messageIdempotencyKey: 'unknown-create-message',
        cancelIdempotencyKey: 'unknown-create-cancel',
        phase: ScriptDraftGenerationPhase.failed,
        failureCode: 'SCRIPT_DRAFT_THREAD_CREATE_OUTCOME_UNKNOWN',
        failureRetryable: true,
        updatedAt: DateTime.utc(2026, 9, 4),
      );
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
            ),
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '恢复同键后的终稿',
          ),
        ],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(
        await controller.start(source: source, persistedReceipt: receipt),
        isFalse,
      );
      expect(await controller.regenerate(), isFalse);
      expect(port.createdWith, isEmpty);

      expect(await controller.retryTransport(), isTrue);

      expect(port.createdWith, <String>['unknown-create-key']);
      expect(controller.receipt?.sessionId, 'unknown-create-session');
      expect(controller.state.finalMarkdown, '恢复同键后的终稿');
    },
  );

  test('known thread creation rejection permits a fresh session', () async {
    final port = _FakeScriptDraftPort(
      createErrors: const <ScriptDraftTransportException>[
        ScriptDraftTransportException(
          'WORKSPACE_CHAT_NOT_AVAILABLE',
          retryable: true,
          writeOutcome: ScriptDraftWriteOutcome.knownRejected,
        ),
      ],
      streams: <Stream<ScriptDraftStreamSignal>>[
        Stream<ScriptDraftStreamSignal>.value(
          const ScriptDraftStreamSignal.event(
            ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
          ),
        ),
      ],
      runs: const <ScriptDraftRunSnapshot>[
        ScriptDraftRunSnapshot(
          status: 'succeeded',
          completionMode: 'normal',
          finalAnswer: '已知拒绝后的新会话终稿',
        ),
      ],
    );
    final controller = ScriptDraftController(
      port,
      keyFactory: _sequentialKeys(),
      reconnectDelay: Duration.zero,
    );
    addTearDown(controller.dispose);

    expect(await controller.generateFresh(_source()), isFalse);
    final rejected = controller.receipt!;
    expect(controller.errorCode, 'WORKSPACE_CHAT_NOT_AVAILABLE');
    expect(controller.state.errorRetryable, isFalse);
    expect(await controller.retryTransport(), isFalse);

    expect(await controller.regenerate(), isTrue);

    expect(port.createdWith, hasLength(2));
    expect(port.createdWith.first, rejected.createThreadIdempotencyKey);
    expect(port.createdWith.last, isNot(rejected.createThreadIdempotencyKey));
    expect(controller.receipt?.sessionId, isNot(rejected.sessionId));
    expect(controller.state.finalMarkdown, '已知拒绝后的新会话终稿');
  });

  test(
    'known profile rejection allows return and regenerates with fresh keys',
    () async {
      for (final code in <String>[
        'AGENT_PROFILE_NOT_SELECTABLE',
        'MODEL_PROFILE_NOT_SELECTABLE',
      ]) {
        final port = _FakeScriptDraftPort(
          submitErrors: <ScriptDraftTransportException>[
            ScriptDraftTransportException(
              code,
              retryable: true,
              writeOutcome: ScriptDraftWriteOutcome.knownRejected,
            ),
          ],
          streams: <Stream<ScriptDraftStreamSignal>>[
            Stream<ScriptDraftStreamSignal>.value(
              const ScriptDraftStreamSignal.event(
                ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
              ),
            ),
          ],
          runs: <ScriptDraftRunSnapshot>[
            ScriptDraftRunSnapshot(
              status: 'succeeded',
              completionMode: 'normal',
              finalAnswer: '$code 后的新会话终稿',
            ),
          ],
        );
        final controller = ScriptDraftController(
          port,
          keyFactory: _sequentialKeys(),
          reconnectDelay: Duration.zero,
        );

        expect(await controller.generateFresh(_source()), isFalse);
        final rejected = controller.receipt!;
        expect(controller.errorCode, code);
        expect(controller.state.errorRetryable, isFalse);
        expect(controller.canAbandon, isFalse);
        expect(await controller.retryTransport(), isFalse);

        expect(await controller.regenerate(), isTrue);

        expect(port.createdWith, hasLength(2));
        expect(
          port.createdWith.last,
          isNot(rejected.createThreadIdempotencyKey),
        );
        expect(port.submittedWith, hasLength(2));
        expect(port.submittedWith.first, (
          rejected.threadId!,
          rejected.messageIdempotencyKey,
        ));
        expect(port.submittedWith.last.$1, isNot(rejected.threadId));
        expect(
          port.submittedWith.last.$2,
          isNot(rejected.messageIdempotencyKey),
        );
        expect(port.cancelledWith, isEmpty);
        expect(controller.state.finalMarkdown, '$code 后的新会话终稿');
        controller.dispose();
      }
    },
  );

  test(
    'non-retryable submit failure becomes outcome-unknown and retries same key',
    () async {
      final port = _FakeScriptDraftPort(
        submitErrors: const <ScriptDraftTransportException>[
          ScriptDraftTransportException(
            'API_RESPONSE_INVALID',
            writeOutcome: ScriptDraftWriteOutcome.unknown,
          ),
        ],
        streams: <Stream<ScriptDraftStreamSignal>>[
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
            ),
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '同键解析后的权威终稿',
          ),
        ],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isFalse);
      final unknown = controller.receipt!;
      expect(controller.errorCode, 'SCRIPT_DRAFT_SUBMISSION_OUTCOME_UNKNOWN');
      expect(controller.state.errorRetryable, isTrue);
      expect(unknown.agentRunId, isNull);

      expect(await controller.retryTransport(), isTrue);

      expect(port.createdWith, hasLength(1));
      expect(port.submittedWith, <(String, String)>[
        (unknown.threadId!, unknown.messageIdempotencyKey),
        (unknown.threadId!, unknown.messageIdempotencyKey),
      ]);
      expect(controller.state.finalMarkdown, '同键解析后的权威终稿');
    },
  );

  test(
    'regeneration resolves unknown submission before creating a fresh thread',
    () async {
      final port = _FakeScriptDraftPort(
        submitErrors: const <ScriptDraftTransportException>[
          ScriptDraftTransportException(
            'API_RESPONSE_INVALID',
            writeOutcome: ScriptDraftWriteOutcome.unknown,
          ),
        ],
        streams: <Stream<ScriptDraftStreamSignal>>[
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
            ),
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '新会话权威终稿',
          ),
        ],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isFalse);
      final unknown = controller.receipt!;

      expect(await controller.regenerate(), isTrue);

      expect(port.createdWith, hasLength(2));
      expect(port.submittedWith.take(2), <(String, String)>[
        (unknown.threadId!, unknown.messageIdempotencyKey),
        (unknown.threadId!, unknown.messageIdempotencyKey),
      ]);
      expect(port.submittedWith.last.$2, isNot(unknown.messageIdempotencyKey));
      final cancellationIndex = port.operations.indexOf('cancel:agent-run-2');
      final freshThreadIndex = port.operations.lastIndexWhere(
        (operation) => operation.startsWith('create:'),
      );
      expect(cancellationIndex, lessThan(freshThreadIndex));
      expect(port.cancelledWith, <(String, String)>[
        ('agent-run-2', unknown.cancelIdempotencyKey),
      ]);
      expect(controller.state.finalMarkdown, '新会话权威终稿');
    },
  );

  test(
    'checkpoint retry resumes the submitted run without another message',
    () async {
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
            ),
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '同一 Run 恢复后的权威终稿',
          ),
        ],
      );
      var failedAfterSubmit = false;
      final persisted = <ScriptDraftGenerationReceipt>[];
      final controller = ScriptDraftController(
        port,
        persistReceipt: (receipt) async {
          if (!failedAfterSubmit && receipt.agentRunId != null) {
            failedAfterSubmit = true;
            throw StateError('checkpoint unavailable');
          }
          persisted.add(receipt);
        },
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isFalse);
      final failedReceipt = controller.receipt!;
      expect(failedReceipt.agentRunId, 'agent-run-1');
      expect(controller.errorCode, 'SCRIPT_DRAFT_RECEIPT_PERSIST_FAILED');
      expect(controller.state.errorRetryable, isTrue);
      expect(port.submittedWith, hasLength(1));

      expect(await controller.retryTransport(), isTrue);
      expect(port.submittedWith, hasLength(1));
      expect(controller.receipt!.sessionId, failedReceipt.sessionId);
      expect(
        controller.receipt!.messageIdempotencyKey,
        failedReceipt.messageIdempotencyKey,
      );
      expect(controller.state.finalMarkdown, '同一 Run 恢复后的权威终稿');
      expect(
        persisted.any((receipt) => receipt.agentRunId == 'agent-run-1'),
        isTrue,
      );
    },
  );

  test(
    'cancel persists locally, cancels the run, and ignores late events',
    () async {
      final stream = StreamController<ScriptDraftStreamSignal>();
      addTearDown(stream.close);
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[stream.stream],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      final generation = controller.generateFresh(_source());
      await _waitFor(
        () => controller.phase == ScriptDraftGenerationPhase.streaming,
      );
      final cancelKey = controller.receipt!.cancelIdempotencyKey;

      await controller.cancel();
      stream.add(
        const ScriptDraftStreamSignal.event(
          ScriptDraftRemoteEvent(
            sequence: 1,
            status: 'succeeded',
            deltaText: '晚到正文',
          ),
        ),
      );
      await generation;
      await Future<void>.delayed(Duration.zero);

      expect(controller.phase, ScriptDraftGenerationPhase.cancelled);
      expect(controller.state.partialMarkdown, isEmpty);
      expect(controller.state.finalMarkdown, isNull);
      expect(port.cancelledWith, <(String, String)>[
        ('agent-run-1', cancelKey),
      ]);
      expect(port.getRunCalls, 0);
    },
  );

  test('cancel during submit waits for and cancels the accepted run', () async {
    final submitResult = Completer<String>();
    final port = _FakeScriptDraftPort(submitResult: submitResult);
    final controller = ScriptDraftController(
      port,
      keyFactory: _sequentialKeys(),
      reconnectDelay: Duration.zero,
    );
    addTearDown(controller.dispose);

    final generation = controller.generateFresh(_source());
    await _waitFor(() => port.submittedWith.isNotEmpty);
    final cancelKey = controller.receipt!.cancelIdempotencyKey;

    final cancellation = controller.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, ScriptDraftGenerationPhase.submitting);
    submitResult.complete('agent-run-late');
    await cancellation;
    expect(await generation, isFalse);

    expect(controller.phase, ScriptDraftGenerationPhase.cancelled);
    expect(controller.receipt?.agentRunId, 'agent-run-late');
    expect(port.streamAfterSequences, isEmpty);
    expect(port.cancelledWith, <(String, String)>[
      ('agent-run-late', cancelKey),
    ]);
  });

  test(
    'cancel resolves an in-flight transport error with the same message key',
    () async {
      final submitResult = Completer<String>();
      final port = _FakeScriptDraftPort(submitResult: submitResult);
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      final generation = controller.generateFresh(_source());
      await _waitFor(() => port.submittedWith.isNotEmpty);
      final receipt = controller.receipt!;

      final cancellation = controller.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, ScriptDraftGenerationPhase.submitting);
      submitResult.completeError(
        const ScriptDraftTransportException(
          'NETWORK_REQUEST_FAILED',
          retryable: true,
          writeOutcome: ScriptDraftWriteOutcome.unknown,
        ),
      );
      await cancellation;
      expect(await generation, isFalse);

      expect(port.submittedWith, <(String, String)>[
        (receipt.threadId!, receipt.messageIdempotencyKey),
        (receipt.threadId!, receipt.messageIdempotencyKey),
      ]);
      expect(controller.phase, ScriptDraftGenerationPhase.cancelled);
      expect(controller.receipt?.agentRunId, 'agent-run-2');
      expect(port.cancelledWith, <(String, String)>[
        ('agent-run-2', receipt.cancelIdempotencyKey),
      ]);
      expect(port.streamAfterSequences, isEmpty);
    },
  );

  test(
    'persisted receipt can be attached for cancellation without generation',
    () async {
      final receipt = ScriptDraftGenerationReceipt(
        sessionId: 'restored-session',
        source: _source(),
        createThreadIdempotencyKey: 'restored-create',
        messageIdempotencyKey: 'restored-message',
        cancelIdempotencyKey: 'restored-cancel',
        phase: ScriptDraftGenerationPhase.streaming,
        threadId: 'restored-thread',
        agentRunId: 'restored-run',
        afterSequence: 3,
        partialMarkdown: '恢复中的只读预览',
        updatedAt: DateTime.utc(2026, 9, 4),
      );
      final saved = <ScriptDraftGenerationReceipt>[];
      final port = _FakeScriptDraftPort();
      final controller = ScriptDraftController(
        port,
        persistReceipt: (next) async => saved.add(next),
      );
      addTearDown(controller.dispose);

      expect(await controller.cancelPersistedReceipt(receipt), isTrue);

      expect(controller.phase, ScriptDraftGenerationPhase.cancelled);
      expect(saved.single.phase, ScriptDraftGenerationPhase.cancelled);
      expect(port.cancelledWith, <(String, String)>[
        ('restored-run', 'restored-cancel'),
      ]);
      expect(port.createdWith, isEmpty);
      expect(port.submittedWith, isEmpty);
      expect(port.streamAfterSequences, isEmpty);
      expect(port.eventPageAfterSequences, isEmpty);
      expect(port.getRunCalls, 0);
    },
  );

  test(
    'restored submitting cancellation resolves the run with the original key',
    () async {
      final receipt = ScriptDraftGenerationReceipt(
        sessionId: 'restored-submit-session',
        source: _source(),
        createThreadIdempotencyKey: 'restored-submit-create',
        messageIdempotencyKey: 'restored-submit-message',
        cancelIdempotencyKey: 'restored-submit-cancel',
        phase: ScriptDraftGenerationPhase.submitting,
        threadId: 'restored-submit-thread',
        updatedAt: DateTime.utc(2026, 9, 4),
      );
      final saved = <ScriptDraftGenerationReceipt>[];
      final port = _FakeScriptDraftPort();
      final controller = ScriptDraftController(
        port,
        persistReceipt: (next) async => saved.add(next),
      );
      addTearDown(controller.dispose);

      expect(await controller.cancelPersistedReceipt(receipt), isTrue);

      expect(port.createdWith, isEmpty);
      expect(port.submittedWith, <(String, String)>[
        ('restored-submit-thread', 'restored-submit-message'),
      ]);
      expect(port.streamAfterSequences, isEmpty);
      expect(port.eventPageAfterSequences, isEmpty);
      expect(port.getRunCalls, 0);
      expect(saved.map((item) => item.phase), <ScriptDraftGenerationPhase>[
        ScriptDraftGenerationPhase.streaming,
        ScriptDraftGenerationPhase.cancelled,
      ]);
      expect(saved.first.agentRunId, 'agent-run-1');
      expect(port.cancelledWith, <(String, String)>[
        ('agent-run-1', 'restored-submit-cancel'),
      ]);
      expect(controller.phase, ScriptDraftGenerationPhase.cancelled);
    },
  );

  test(
    'unresolved restored submission stays retryable and cannot fake cancel',
    () async {
      final receipt = ScriptDraftGenerationReceipt(
        sessionId: 'unknown-submit-session',
        source: _source(),
        createThreadIdempotencyKey: 'unknown-submit-create',
        messageIdempotencyKey: 'unknown-submit-message',
        cancelIdempotencyKey: 'unknown-submit-cancel',
        phase: ScriptDraftGenerationPhase.submitting,
        threadId: 'unknown-submit-thread',
        updatedAt: DateTime.utc(2026, 9, 4),
      );
      final saved = <ScriptDraftGenerationReceipt>[];
      final port = _FakeScriptDraftPort(
        submitErrors: const <ScriptDraftTransportException>[
          ScriptDraftTransportException(
            'NETWORK_REQUEST_FAILED',
            retryable: true,
            writeOutcome: ScriptDraftWriteOutcome.unknown,
          ),
        ],
      );
      final controller = ScriptDraftController(
        port,
        persistReceipt: (next) async => saved.add(next),
      );
      addTearDown(controller.dispose);

      expect(await controller.cancelPersistedReceipt(receipt), isFalse);
      expect(controller.phase, ScriptDraftGenerationPhase.failed);
      expect(controller.errorCode, 'SCRIPT_DRAFT_SUBMISSION_OUTCOME_UNKNOWN');
      expect(controller.state.errorRetryable, isTrue);
      expect(controller.canAbandon, isTrue);
      expect(controller.receipt?.threadId, 'unknown-submit-thread');
      expect(controller.receipt?.agentRunId, isNull);
      expect(port.cancelledWith, isEmpty);
      expect(saved.single.phase, ScriptDraftGenerationPhase.failed);

      await controller.cancel();

      expect(port.submittedWith, <(String, String)>[
        ('unknown-submit-thread', 'unknown-submit-message'),
        ('unknown-submit-thread', 'unknown-submit-message'),
      ]);
      expect(controller.phase, ScriptDraftGenerationPhase.cancelled);
      expect(port.cancelledWith, <(String, String)>[
        ('agent-run-2', 'unknown-submit-cancel'),
      ]);
    },
  );

  test(
    'retryable failed run remains abandonable and cancels its latched run',
    () async {
      final source = _source();
      final failedReceipt = ScriptDraftGenerationReceipt(
        sessionId: 'failed-session',
        source: source,
        createThreadIdempotencyKey: 'failed-create',
        messageIdempotencyKey: 'failed-message',
        cancelIdempotencyKey: 'failed-cancel',
        phase: ScriptDraftGenerationPhase.failed,
        threadId: 'failed-thread',
        agentRunId: 'failed-run',
        afterSequence: 7,
        partialMarkdown: '断线前预览',
        failureCode: 'SCRIPT_DRAFT_STREAM_INTERRUPTED',
        failureRetryable: true,
        updatedAt: DateTime.utc(2026, 9, 4),
      );
      final persisted = <ScriptDraftGenerationReceipt>[];
      final port = _FakeScriptDraftPort();
      final controller = ScriptDraftController(
        port,
        persistReceipt: (receipt) async => persisted.add(receipt),
      );
      addTearDown(controller.dispose);

      expect(
        await controller.start(source: source, persistedReceipt: failedReceipt),
        isFalse,
      );
      expect(controller.canAbandon, isTrue);
      expect(controller.state.canAbandon, isTrue);

      await controller.cancel();

      expect(controller.phase, ScriptDraftGenerationPhase.cancelled);
      expect(controller.canAbandon, isFalse);
      expect(controller.state.errorCode, isNull);
      expect(controller.state.errorRetryable, isFalse);
      expect(controller.state.partialMarkdown, '断线前预览');
      expect(persisted, hasLength(1));
      expect(persisted.single.phase, ScriptDraftGenerationPhase.cancelled);
      expect(port.cancelledWith, <(String, String)>[
        ('failed-run', 'failed-cancel'),
      ]);
    },
  );

  test(
    'cancel checkpoint failure stays visible but does not block remote cancel',
    () async {
      final source = _source();
      final failedReceipt = ScriptDraftGenerationReceipt(
        sessionId: 'failed-persist-session',
        source: source,
        createThreadIdempotencyKey: 'failed-persist-create',
        messageIdempotencyKey: 'failed-persist-message',
        cancelIdempotencyKey: 'failed-persist-cancel',
        phase: ScriptDraftGenerationPhase.failed,
        threadId: 'failed-persist-thread',
        agentRunId: 'failed-persist-run',
        failureCode: 'SCRIPT_DRAFT_STREAM_INTERRUPTED',
        failureRetryable: true,
        updatedAt: DateTime.utc(2026, 9, 4),
      );
      final attempted = <ScriptDraftGenerationReceipt>[];
      final port = _FakeScriptDraftPort();
      final controller = ScriptDraftController(
        port,
        persistReceipt: (receipt) async {
          attempted.add(receipt);
          throw StateError('injected cancellation checkpoint failure');
        },
      );
      addTearDown(controller.dispose);

      expect(
        await controller.start(source: source, persistedReceipt: failedReceipt),
        isFalse,
      );

      await controller.cancel();

      expect(attempted, hasLength(1));
      expect(attempted.single.phase, ScriptDraftGenerationPhase.cancelled);
      expect(controller.phase, ScriptDraftGenerationPhase.failed);
      expect(controller.errorCode, 'SCRIPT_DRAFT_RECEIPT_PERSIST_FAILED');
      expect(controller.receipt, same(failedReceipt));
      expect(controller.canAbandon, isTrue);
      expect(port.cancelledWith, <(String, String)>[
        ('failed-persist-run', 'failed-persist-cancel'),
      ]);
    },
  );

  test(
    'non-retryable stream failure with a run remains explicitly cancellable',
    () async {
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          _nonRetryableInvalidStream(),
        ],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isFalse);
      final failed = controller.receipt!;
      expect(controller.phase, ScriptDraftGenerationPhase.failed);
      expect(controller.state.errorRetryable, isFalse);
      expect(failed.agentRunId, 'agent-run-1');
      expect(controller.canAbandon, isTrue);

      await controller.cancel();

      expect(controller.phase, ScriptDraftGenerationPhase.cancelled);
      expect(port.cancelledWith, <(String, String)>[
        ('agent-run-1', failed.cancelIdempotencyKey),
      ]);
    },
  );

  test(
    'regeneration cancels a failed old run before submitting a new one',
    () async {
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          _nonRetryableInvalidStream(),
          Stream<ScriptDraftStreamSignal>.value(
            const ScriptDraftStreamSignal.event(
              ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
            ),
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '重新生成后的权威终稿',
          ),
        ],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isFalse);
      final oldReceipt = controller.receipt!;

      expect(await controller.regenerate(), isTrue);

      const oldCancel = 'cancel:agent-run-1';
      final secondSubmit = port.operations.lastIndexWhere(
        (operation) => operation.startsWith('submit:'),
      );
      expect(port.operations.indexOf(oldCancel), lessThan(secondSubmit));
      expect(port.cancelledWith, <(String, String)>[
        ('agent-run-1', oldReceipt.cancelIdempotencyKey),
      ]);
      expect(port.submittedWith, hasLength(2));
      expect(controller.state.finalMarkdown, '重新生成后的权威终稿');
    },
  );

  test(
    'partial output remains unavailable when durable final is empty',
    () async {
      final port = _FakeScriptDraftPort(
        streams: <Stream<ScriptDraftStreamSignal>>[
          Stream<ScriptDraftStreamSignal>.fromIterable(
            const <ScriptDraftStreamSignal>[
              ScriptDraftStreamSignal.event(
                ScriptDraftRemoteEvent(
                  sequence: 1,
                  status: 'running',
                  deltaText: '不能进入编辑器',
                ),
              ),
              ScriptDraftStreamSignal.event(
                ScriptDraftRemoteEvent(sequence: 2, status: 'succeeded'),
              ),
            ],
          ),
        ],
        runs: const <ScriptDraftRunSnapshot>[
          ScriptDraftRunSnapshot(
            status: 'succeeded',
            completionMode: 'normal',
            finalAnswer: '   ',
          ),
        ],
      );
      final controller = ScriptDraftController(
        port,
        keyFactory: _sequentialKeys(),
        reconnectDelay: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(await controller.generateFresh(_source()), isFalse);
      expect(controller.phase, ScriptDraftGenerationPhase.failed);
      expect(controller.errorCode, 'SCRIPT_DRAFT_FINAL_EMPTY');
      expect(controller.state.partialMarkdown, '不能进入编辑器');
      expect(controller.state.finalMarkdown, isNull);
    },
  );
}

Stream<ScriptDraftStreamSignal> _nonRetryableInvalidStream() async* {
  yield const ScriptDraftStreamSignal.event(
    ScriptDraftRemoteEvent(
      sequence: 1,
      status: 'running',
      deltaText: '协议失败前预览',
    ),
  );
  throw const ScriptDraftTransportException('SCRIPT_DRAFT_STREAM_INVALID');
}

ScriptDraftSourceSnapshot _source() => ScriptDraftSourceSnapshot(
  kind: ScriptDraftSourceKind.dailyRecommendation,
  sourceId: 'topic-1',
  title: '七夕约会选香',
  content: '讲清楚气味如何形成专属记忆，以及约会选香的三个关键节点。',
  capturedAt: DateTime.utc(2026, 9, 4),
);

ScriptDraftKeyFactory _sequentialKeys() {
  var sequence = 0;
  return (purpose) => '$purpose-${++sequence}';
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached');
}

final class _FakeScriptDraftPort implements ScriptDraftGenerationPort {
  _FakeScriptDraftPort({
    this.createErrors = const <ScriptDraftTransportException>[],
    this.submitErrors = const <ScriptDraftTransportException>[],
    this.streams = const <Stream<ScriptDraftStreamSignal>>[],
    this.readEventErrors = const <ScriptDraftTransportException>[],
    this.pages = const <ScriptDraftEventPage>[],
    this.getRunErrors = const <ScriptDraftTransportException>[],
    this.runs = const <ScriptDraftRunSnapshot>[],
    this.submitResult,
    this.onReadEvents,
  });

  final List<ScriptDraftTransportException> createErrors;
  final List<ScriptDraftTransportException> submitErrors;
  final List<Stream<ScriptDraftStreamSignal>> streams;
  final List<ScriptDraftTransportException> readEventErrors;
  final List<ScriptDraftEventPage> pages;
  final List<ScriptDraftTransportException> getRunErrors;
  final List<ScriptDraftRunSnapshot> runs;
  final Completer<String>? submitResult;
  final void Function(int afterSequence)? onReadEvents;

  final List<String> createdWith = <String>[];
  final List<(String, String)> submittedWith = <(String, String)>[];
  final List<int> streamAfterSequences = <int>[];
  final List<int> eventPageAfterSequences = <int>[];
  final List<(String, String)> cancelledWith = <(String, String)>[];
  final List<String> operations = <String>[];
  int _createAttempt = 0;
  int _submitAttempt = 0;
  int _streamIndex = 0;
  int _readEventErrorIndex = 0;
  int _pageIndex = 0;
  int _getRunAttempt = 0;
  int _runIndex = 0;
  int getRunCalls = 0;

  @override
  Future<String> createThread({required String idempotencyKey}) async {
    createdWith.add(idempotencyKey);
    operations.add('create:$idempotencyKey');
    if (_createAttempt < createErrors.length) {
      throw createErrors[_createAttempt++];
    }
    _createAttempt++;
    return 'thread-$_createAttempt';
  }

  @override
  Future<String> submit({
    required String threadId,
    required ScriptDraftRequest request,
    required String idempotencyKey,
  }) async {
    submittedWith.add((threadId, idempotencyKey));
    operations.add('submit:$idempotencyKey');
    expect(request.prompt, contains(request.source.content));
    if (_submitAttempt < submitErrors.length) {
      throw submitErrors[_submitAttempt++];
    }
    final attempt = _submitAttempt++;
    if (attempt == 0) {
      if (submitResult case final result?) return result.future;
    }
    return 'agent-run-${submittedWith.length}';
  }

  @override
  Future<Stream<ScriptDraftStreamSignal>> streamEvents({
    required String agentRunId,
    required int afterSequence,
  }) async {
    streamAfterSequences.add(afterSequence);
    return streams[_streamIndex++];
  }

  @override
  Future<ScriptDraftEventPage> readEvents({
    required String agentRunId,
    required int afterSequence,
  }) async {
    eventPageAfterSequences.add(afterSequence);
    onReadEvents?.call(afterSequence);
    if (_readEventErrorIndex < readEventErrors.length) {
      throw readEventErrors[_readEventErrorIndex++];
    }
    if (_pageIndex < pages.length) return pages[_pageIndex++];
    return ScriptDraftEventPage(
      items: const <ScriptDraftRemoteEvent>[],
      nextAfterSequence: afterSequence,
      hasMore: false,
      gap: false,
      oldestAvailableSequence: afterSequence,
    );
  }

  @override
  Future<ScriptDraftRunSnapshot> getRun({required String agentRunId}) async {
    getRunCalls++;
    if (_getRunAttempt < getRunErrors.length) {
      throw getRunErrors[_getRunAttempt++];
    }
    _getRunAttempt++;
    return runs[_runIndex++];
  }

  @override
  Future<void> cancelRun({
    required String agentRunId,
    required String idempotencyKey,
  }) async {
    cancelledWith.add((agentRunId, idempotencyKey));
    operations.add('cancel:$agentRunId');
  }
}

final class _SingleResponseTransport implements ApiTransport {
  const _SingleResponseTransport(this.response);

  final ApiTransportResponse response;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async =>
      response;
}

final class _RecordingResponseTransport implements ApiTransport {
  _RecordingResponseTransport(this.response);

  final ApiTransportResponse response;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return response;
  }
}

final class _ThrowingTransport implements ApiTransport {
  const _ThrowingTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) =>
      Future<ApiTransportResponse>.error(StateError('transport failed'));
}

ApiClient _apiClientWithTransport(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '0.1.0',
    deviceId: 'device-1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
  ),
  transport: transport,
);
