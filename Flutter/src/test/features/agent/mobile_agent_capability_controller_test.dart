import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/agent/application/mobile_agent_capability_controller.dart';
import 'package:huahuoai_app/features/agent/data/mobile_agent_capability_port.dart';

void main() {
  test(
    'resuming rejects another completed run and still cancels the original',
    () async {
      const policy = MobileAgentRunPollingPolicy(maxAttempts: 1);
      final port = _AgentPortFake()
        ..createResponses.add(Future.value(_ok(_run(status: 'running'))))
        ..pollResponses.add(Future.value(_ok(_run(status: 'running'))));
      final controller = _controller(port);
      addTearDown(controller.dispose);
      await controller.execute(_command(), pollingPolicy: policy);
      port.pollResponses.add(
        Future.value(
          _ok(_run(runId: 'other-run', status: 'succeeded', terminal: true)),
        ),
      );
      final resumed = await controller.execute(
        _command(),
        pollingPolicy: policy,
      );
      expect(resumed.errorCode, 'AGENT_RUN_POLL_MISMATCH');
      expect(resumed.run?.agentRunId, 'run-1');
      expect(port.createRequests, hasLength(1));
      await controller.cancelOperation('operation-1');
      expect(port.cancelledRunIds, ['run-1']);
    },
  );

  test(
    'Canvas observation covers slow runs without changing default polling',
    () async {
      final port = _AgentPortFake()
        ..createResponses.add(Future.value(_ok(_run(status: 'running'))))
        ..pollResponses.addAll(
          List.generate(60, (_) => Future.value(_ok(_run(status: 'running')))),
        );
      final delays = <Duration>[];
      final controller = MobileAgentCapabilityController(
        port: port,
        identity: _identity('user-a', 'workspace-a'),
        delay: (duration) async {
          delays.add(duration);
        },
      );
      addTearDown(controller.dispose);
      final progress = <String>[];
      final result = await controller.execute(
        _command(),
        pollingPolicy: const MobileAgentRunPollingPolicy(),
        onProgress: (run) => progress.add(run.status),
      );
      expect(result.succeeded, isTrue);
      expect(port.createRequests, hasLength(1));
      expect(port.pollRunIds, hasLength(61));
      expect(delays.first, const Duration(milliseconds: 750));
      expect(delays.last, const Duration(seconds: 3));
      expect(
        delays.fold(Duration.zero, (total, duration) => total + duration),
        greaterThan(const Duration(seconds: 91)),
      );
      expect(progress, ['running', 'succeeded']);
    },
  );

  test(
    'Canvas observation resumes a known run with GET and keeps cancellation',
    () async {
      const policy = MobileAgentRunPollingPolicy(maxAttempts: 1);
      final port = _AgentPortFake()
        ..createResponses.add(Future.value(_ok(_run(status: 'running'))))
        ..pollResponses.add(Future.value(_ok(_run(status: 'running'))));
      final controller = _controller(port);
      addTearDown(controller.dispose);
      final first = await controller.execute(_command(), pollingPolicy: policy);
      expect(first.errorCode, 'AGENT_RUN_POLL_TIMEOUT');
      port.pollResponses.add(
        Future.value(_failure('OFFLINE', retryable: false)),
      );
      final offline = await controller.execute(
        _command(),
        pollingPolicy: policy,
      );
      expect(offline.run?.agentRunId, 'run-1');
      expect(offline.errorCode, 'OFFLINE');
      final resumed = await controller.execute(
        _command(),
        pollingPolicy: policy,
      );
      expect(resumed.succeeded, isTrue);
      expect(port.createRequests, hasLength(1));
      expect(port.pollRunIds, ['run-1', 'run-1', 'run-1']);
    },
  );

  test(
    'Canvas resume mismatches do not discard the original cancellation handle',
    () async {
      const policy = MobileAgentRunPollingPolicy(maxAttempts: 1);
      final port = _AgentPortFake()
        ..createResponses.add(Future.value(_ok(_run(status: 'running'))))
        ..pollResponses.add(Future.value(_ok(_run(status: 'running'))));
      final controller = _controller(port);
      addTearDown(controller.dispose);
      await controller.execute(_command(), pollingPolicy: policy);
      final mismatch = await controller.execute(
        MobileAgentRunCommand(
          operationId: 'operation-1',
          featureId: 'workbench.persona',
          visibleText: 'changed',
          threadId: 'thread-1',
        ),
        pollingPolicy: policy,
      );
      expect(mismatch.errorCode, 'AGENT_RUN_RESUME_MISMATCH');
      expect(port.createRequests, hasLength(1));
      expect(await controller.cancelOperation('operation-1'), isTrue);
      expect(port.cancelledRunIds, ['run-1']);
    },
  );

  group('MobileAgentCapabilityController catalog binding', () {
    test(
      'logged-in workspace recovery is not reported as a missing login',
      () async {
        final port = _AgentPortFake();
        final controller = MobileAgentCapabilityController(
          port: port,
          identity: const MobileAgentRuntimeIdentity(
            userId: 'user-a',
            workspaceId: null,
            workspaceRecoveryRequired: true,
            locale: 'zh-CN',
            timezone: 'Asia/Shanghai',
          ),
          delay: (_) async {},
        );

        final access = await controller.ensureFeature('workbench.persona');

        expect(access.isAvailable, isFalse);
        expect(access.errorCode, 'AGENT_WORKSPACE_RECOVERY_REQUIRED');
        expect(port.profileCalls, 0);
      },
    );

    test('cache is bound to account, workspace, and catalog version', () async {
      final port = _AgentPortFake();
      final controller = _controller(port);

      final first = await controller.ensureFeature('workbench.persona');
      final cached = await controller.ensureFeature('workbench.persona');

      expect(first.isAvailable, isTrue);
      expect(cached.isAvailable, isTrue);
      expect(controller.catalogVersion, 'catalog-v1');
      expect(port.profileCalls, 1);
      expect(port.skillCalls, 0);
      expect(port.modelCalls, 0);
      expect(port.installationWorkspaces, isEmpty);

      controller.bindIdentity(_identity('user-b', 'workspace-b'));
      final rebound = await controller.ensureFeature('workbench.persona');

      expect(rebound.isAvailable, isTrue);
      expect(port.profileCalls, 2);
      expect(port.installationWorkspaces, isEmpty);

      port.catalogVersion = 'catalog-v2';
      final refreshed = await controller.ensureFeature(
        'workbench.persona',
        forceRefresh: true,
      );
      expect(refreshed.catalogVersion, 'catalog-v2');
      expect(controller.catalogVersion, 'catalog-v2');
      expect(port.profileCalls, 3);
    });

    test(
      'restores only a fresh public catalog for the same account scope',
      () async {
        final preferences = AppPreferencesDao(AppDatabase());
        var now = DateTime.utc(2026, 8, 14, 8);
        final firstPort = _AgentPortFake();
        final first = MobileAgentCapabilityController(
          port: firstPort,
          identity: _identity('user-a', 'workspace-a'),
          preferences: preferences,
          catalogCacheTtlResolver: () => const Duration(minutes: 5),
          now: () => now,
          delay: (_) async {},
        );

        expect(
          (await first.ensureFeature('workbench.persona')).isAvailable,
          isTrue,
        );
        expect(firstPort.profileCalls, 1);
        final stored = preferences.listPreferences().single['value'] as String;
        expect(stored, contains('renshe_content'));
        expect(stored, isNot(contains('skillProfile')));
        expect(stored, isNot(contains('modelProfile')));
        expect(stored, isNot(contains('runtime')));

        final restoredPort = _AgentPortFake();
        final restored = MobileAgentCapabilityController(
          port: restoredPort,
          identity: _identity('user-a', 'workspace-a'),
          preferences: preferences,
          catalogCacheTtlResolver: () => const Duration(minutes: 5),
          now: () => now,
          delay: (_) async {},
        );
        final cached = await restored.ensureFeature('workbench.persona');

        expect(cached.isAvailable, isTrue);
        expect(restoredPort.profileCalls, 0);

        await restored.ensureFeature('workbench.persona', forceRefresh: true);
        expect(restoredPort.profileCalls, 1);

        now = now.add(const Duration(minutes: 6));
        final expiredPort = _AgentPortFake();
        final expired = MobileAgentCapabilityController(
          port: expiredPort,
          identity: _identity('user-a', 'workspace-a'),
          preferences: preferences,
          catalogCacheTtlResolver: () => const Duration(minutes: 5),
          now: () => now,
          delay: (_) async {},
        );
        await expired.ensureFeature('workbench.persona');
        expect(expiredPort.profileCalls, 1);

        final otherAccountPort = _AgentPortFake();
        final otherAccount = MobileAgentCapabilityController(
          port: otherAccountPort,
          identity: _identity('user-b', 'workspace-a'),
          preferences: preferences,
          catalogCacheTtlResolver: () => const Duration(minutes: 5),
          now: () => now,
          delay: (_) async {},
        );
        await otherAccount.ensureFeature('workbench.persona');
        expect(otherAccountPort.profileCalls, 1);
      },
    );

    test(
      'explicit invalidation removes only the current catalog cache',
      () async {
        final preferences = AppPreferencesDao(AppDatabase());
        final firstPort = _AgentPortFake();
        final first = MobileAgentCapabilityController(
          port: firstPort,
          identity: _identity('user-a', 'workspace-a'),
          preferences: preferences,
          delay: (_) async {},
        );
        final secondPort = _AgentPortFake();
        final second = MobileAgentCapabilityController(
          port: secondPort,
          identity: _identity('user-b', 'workspace-a'),
          preferences: preferences,
          delay: (_) async {},
        );
        await first.ensureFeature('workbench.persona');
        await second.ensureFeature('workbench.persona');
        expect(preferences.listPreferences(), hasLength(2));

        first.invalidateCatalogCache();
        expect(preferences.listPreferences(), hasLength(1));

        final reloadedPort = _AgentPortFake();
        final reloaded = MobileAgentCapabilityController(
          port: reloadedPort,
          identity: _identity('user-a', 'workspace-a'),
          preferences: preferences,
          delay: (_) async {},
        );
        await reloaded.ensureFeature('workbench.persona');
        expect(reloadedPort.profileCalls, 1);

        final preservedPort = _AgentPortFake();
        final preserved = MobileAgentCapabilityController(
          port: preservedPort,
          identity: _identity('user-b', 'workspace-a'),
          preferences: preferences,
          delay: (_) async {},
        );
        await preserved.ensureFeature('workbench.persona');
        expect(preservedPort.profileCalls, 0);
      },
    );

    test(
      'only a missing public Agent profile blocks feature admission',
      () async {
        final port = _AgentPortFake();
        final unavailable = await _controller(
          port,
        ).ensureFeature('chat.general');
        expect(unavailable.isAvailable, isFalse);
        expect(unavailable.errorCode, 'AGENT_PROFILE_NOT_SELECTABLE');
        expect(port.skillCalls, 0);
        expect(port.modelCalls, 0);
        expect(port.installationWorkspaces, isEmpty);
      },
    );

    test('force refresh supersedes a stale catalog response', () async {
      final firstProfiles = Completer<ApiResult<AgentProfileCatalog>>();
      final port = _AgentPortFake()..profileResponses.add(firstProfiles.future);
      final controller = _controller(port);

      final staleFuture = controller.ensureFeature('workbench.persona');
      await Future<void>.delayed(Duration.zero);
      port.catalogVersion = 'catalog-v2';
      final current = await controller.ensureFeature(
        'workbench.persona',
        forceRefresh: true,
      );
      firstProfiles.complete(_ok(port.profilesFor('catalog-v1')));
      final stale = await staleFuture;

      expect(current.isAvailable, isTrue);
      expect(current.catalogVersion, 'catalog-v2');
      expect(stale.errorCode, 'AGENT_CATALOG_REQUEST_SUPERSEDED');
      expect(controller.catalogVersion, 'catalog-v2');
      expect(
        controller.accessFor('workbench.persona').catalogVersion,
        'catalog-v2',
      );
    });
  });

  group('MobileAgentCapabilityController runs', () {
    test(
      'uses public IDs, exact HNote revision, stable retry, and API 27 usage',
      () async {
        final supplemental = List<String>.filled(400, '动态上下文').join();
        final port = _AgentPortFake()
          ..createResponses.add(
            Future<ApiResult<AgentRunSnapshot>>.value(
              _failure<AgentRunSnapshot>('RUNTIME_BUSY', retryable: true),
            ),
          )
          ..createResponses.add(
            Future<ApiResult<AgentRunSnapshot>>.value(
              _ok(_run(status: 'queued')),
            ),
          )
          ..pollResponses.add(
            Future<ApiResult<AgentRunSnapshot>>.value(
              _ok(_run(status: 'succeeded', terminal: true)),
            ),
          );
        final controller = _controller(port);
        final outcome = await controller.execute(
          MobileAgentRunCommand(
            operationId: 'operation-1',
            featureId: 'workbench.persona',
            visibleText: '请根据引用笔记生成一份人设内容方案。',
            additionalText: '仅处理这一段 Markdown。',
            supplementalText: supplemental,
            threadId: 'thread-1',
            references: <MobileAgentInputReference>[
              MobileAgentHNoteReference(
                noteId: 'note-2',
                part: 'raw',
                partRevisionId: 'part-revision-2',
              ),
              MobileAgentHNoteReference(
                noteId: 'note-1',
                part: 'outline',
                partRevisionId: 'part-revision-1',
              ),
            ],
          ),
        );

        expect(outcome.succeeded, isTrue);
        expect(outcome.outputMarkdown, '生成结果');
        expect(outcome.usage?.runId, 'run-1');
        expect(port.createRequests, hasLength(2));
        expect(port.idempotencyKeys[0], port.idempotencyKeys[1]);
        expect(port.idempotencyKeys.singleOrNull, isNull);
        expect(port.idempotencyKeys.first, isNot(contains('user-a')));
        expect(port.idempotencyKeys.first, isNot(contains('workspace-a')));

        final request = port.createRequests.first;
        expect(request.agentProfileId, 'renshe_content');
        expect(request.skillProfileIds, isEmpty);
        expect(request.modelProfileId, isNull);
        expect(request.threadId, 'thread-1');
        expect(request.workspaceId, 'workspace-a');
        final body = request.toJson();
        expect(body, isNot(contains('taskType')));
        expect(body, isNot(contains('skillProfileIds')));
        expect(body, isNot(contains('modelProfileId')));
        expect(body, isNot(contains('prompt')));
        expect(body, isNot(contains('runtimeProfileId')));
        final content =
            (body['input']! as Map<String, Object?>)['content']! as List;
        expect((content[0] as Map)['type'], 'text');
        expect((content[1] as Map)['type'], 'text');
        expect((content[1] as Map)['text'], '仅处理这一段 Markdown。');
        expect((content[2] as Map)['type'], 'text');
        expect((content[2] as Map)['text'], supplemental);
        expect(
          ((content[3] as Map)['source'] as Map)['partRevisionId'],
          'part-revision-2',
        );
        expect(
          ((content[4] as Map)['source'] as Map)['partRevisionId'],
          'part-revision-1',
        );
        expect(body.toString().toLowerCase(), isNot(contains('file://')));
        expect(body.toString().toLowerCase(), isNot(contains('/users/')));
        expect(port.pollRunIds, <String>['run-1']);
        expect(port.usageRunIds, <String>['run-1']);
      },
    );

    test(
      'cancel dispatches for a known run and ignores duplicate requests',
      () async {
        final pollStarted = Completer<void>();
        final releasePoll = Completer<void>();
        final port = _AgentPortFake()
          ..createResponses.add(
            Future<ApiResult<AgentRunSnapshot>>.value(
              _ok(_run(status: 'queued')),
            ),
          );
        final controller = MobileAgentCapabilityController(
          port: port,
          identity: _identity('user-a', 'workspace-a'),
          pollInterval: Duration.zero,
          retryInterval: Duration.zero,
          maxPollAttempts: 4,
          delay: (_) {
            if (!pollStarted.isCompleted) pollStarted.complete();
            return releasePoll.future;
          },
        );
        final pending = controller.execute(_command());
        await pollStarted.future;

        await controller.cancelOperation('operation-1');
        await controller.cancelOperation('operation-1');
        expect(controller.running, isFalse);
        expect(port.cancelledRunIds, <String>['run-1']);
        expect(port.cancelIdempotencyKeys, hasLength(1));
        expect(
          port.cancelIdempotencyKeys.single,
          startsWith('mobile-agent-cancel:'),
        );
        expect(port.cancelIdempotencyKeys.single, isNot(contains('user-a')));
        expect(
          port.cancelIdempotencyKeys.single,
          isNot(contains('workspace-a')),
        );

        releasePoll.complete();
        final outcome = await pending;
        expect(outcome.status, MobileAgentRunStatus.superseded);
        expect(port.pollRunIds, isEmpty);
      },
    );

    test('cancel catches an AgentRun receipt that arrives late', () async {
      final create = Completer<ApiResult<AgentRunSnapshot>>();
      final port = _AgentPortFake()..createResponses.add(create.future);
      final controller = _controller(port);
      final pending = controller.execute(_command());
      while (port.createRequests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }

      final cancelling = controller.cancelOperation('operation-1');
      expect(port.cancelledRunIds, isEmpty);
      create.complete(_ok(_run(status: 'queued')));

      expect(await cancelling, isTrue);

      final outcome = await pending;
      expect(outcome.status, MobileAgentRunStatus.superseded);
      expect(port.cancelledRunIds, <String>['run-1']);
      expect(port.pollRunIds, isEmpty);
    });

    test('cancel reconciles an unknown create with the original key', () async {
      final port = _AgentPortFake()
        ..createResponses.addAll(<Future<ApiResult<AgentRunSnapshot>>>[
          Future<ApiResult<AgentRunSnapshot>>.value(
            _failure<AgentRunSnapshot>('NETWORK_UNAVAILABLE'),
          ),
          Future<ApiResult<AgentRunSnapshot>>.value(
            _ok(_run(status: 'queued')),
          ),
        ]);
      final controller = _controller(port);

      final outcome = await controller.execute(_command());
      expect(outcome.status, MobileAgentRunStatus.failed);

      expect(await controller.cancelOperation('operation-1'), isTrue);
      expect(port.createRequests, hasLength(2));
      expect(port.idempotencyKeys.toSet(), hasLength(1));
      expect(port.cancelledRunIds, <String>['run-1']);
    });

    test(
      'transient HTTP create failures reconcile with the original key',
      () async {
        for (final fixture in <(int, String)>[
          (408, 'REQUEST_TIMEOUT'),
          (429, 'RATE_LIMITED'),
          (500, 'INTERNAL_SERVER_ERROR'),
          (503, 'API_SERVER_UNAVAILABLE'),
          (400, 'API_SERVER_UNAVAILABLE'),
        ]) {
          final port = _AgentPortFake()
            ..createResponses.addAll(<Future<ApiResult<AgentRunSnapshot>>>[
              Future<ApiResult<AgentRunSnapshot>>.value(
                _httpFailure<AgentRunSnapshot>(fixture.$1, fixture.$2),
              ),
              Future<ApiResult<AgentRunSnapshot>>.value(
                _ok(_run(status: 'queued')),
              ),
            ]);
          final controller = _controller(port);

          final outcome = await controller.execute(_command());
          expect(
            outcome.status,
            MobileAgentRunStatus.failed,
            reason: '${fixture.$1} ${fixture.$2}',
          );
          expect(await controller.cancelOperation('operation-1'), isTrue);
          expect(port.createRequests, hasLength(2));
          expect(port.idempotencyKeys.toSet(), hasLength(1));
          expect(port.cancelledRunIds, <String>['run-1']);
          controller.dispose();
        }
      },
    );

    test('nonterminal polling failure remains cancellable', () async {
      final port = _AgentPortFake()
        ..createResponses.add(
          Future<ApiResult<AgentRunSnapshot>>.value(
            _ok(_run(status: 'queued')),
          ),
        )
        ..pollResponses.add(
          Future<ApiResult<AgentRunSnapshot>>.value(
            _failure<AgentRunSnapshot>('POLL_REJECTED'),
          ),
        );
      final controller = _controller(port);

      final outcome = await controller.execute(_command());
      expect(outcome.status, MobileAgentRunStatus.failed);
      expect(outcome.run?.isTerminal, isFalse);

      expect(await controller.cancelOperation('operation-1'), isTrue);
      expect(port.cancelledRunIds, <String>['run-1']);
    });

    test(
      'degraded and fallback terminal runs never become successful',
      () async {
        for (final expectation in <(String, String)>[
          ('degraded', 'AGENT_RUN_DEGRADED'),
          ('system_fallback', 'AGENT_RUN_SYSTEM_FALLBACK'),
        ]) {
          final port = _AgentPortFake()
            ..createResponses.add(
              Future<ApiResult<AgentRunSnapshot>>.value(
                _ok(
                  _run(
                    status: 'succeeded',
                    terminal: true,
                    completionMode: expectation.$1,
                  ),
                ),
              ),
            );
          final outcome = await _controller(port).execute(_command());

          expect(outcome.succeeded, isFalse);
          expect(outcome.errorCode, expectation.$2);
          expect(port.usageRunIds, isEmpty);
        }
      },
    );

    test(
      'idempotency is stable for an operation and changes across owners',
      () async {
        final port = _AgentPortFake();
        final controller = _controller(port);

        await controller.execute(_command());
        await controller.execute(
          MobileAgentRunCommand(
            operationId: 'operation-1',
            featureId: 'workbench.persona',
            visibleText: '同一操作重试时可见文案发生变化。',
            threadId: 'thread-1',
            references: <MobileAgentInputReference>[
              MobileAgentHNoteReference(
                noteId: 'note-1',
                part: 'raw',
                partRevisionId: 'part-revision-1',
              ),
            ],
          ),
        );
        controller.bindIdentity(
          _identity('private-user-b', 'private-workspace-b'),
        );
        await controller.execute(_command());

        expect(port.idempotencyKeys, hasLength(3));
        expect(port.idempotencyKeys[1], port.idempotencyKeys[0]);
        expect(port.idempotencyKeys[2], isNot(port.idempotencyKeys[0]));
        for (final key in port.idempotencyKeys) {
          expect(key, isNot(contains('user-a')));
          expect(key, isNot(contains('workspace-a')));
          expect(key, isNot(contains('private-user-b')));
          expect(key, isNot(contains('private-workspace-b')));
        }
      },
    );

    test(
      'thrown catalog, create, and poll exceptions become typed failures',
      () async {
        final catalogPort = _AgentPortFake()..profileThrows = 1;
        final catalogController = _controller(catalogPort);
        final catalog = await catalogController.ensureFeature(
          'workbench.persona',
        );
        expect(catalog.status, MobileAgentFeatureStatus.failed);
        expect(catalog.errorCode, 'AGENT_PROFILE_CATALOG_FAILED');
        expect(
          catalogController.accessFor('workbench.persona').status,
          MobileAgentFeatureStatus.failed,
        );

        final createPort = _AgentPortFake()..createThrows = 2;
        final createController = _controller(createPort);
        final create = await createController.execute(_command());
        expect(create.errorCode, 'AGENT_RUN_CREATE_FAILED');
        expect(createController.running, isFalse);

        final pollPort = _AgentPortFake()
          ..pollThrows = 3
          ..createResponses.add(
            Future<ApiResult<AgentRunSnapshot>>.value(
              _ok(_run(status: 'queued')),
            ),
          );
        final pollController = _controller(pollPort);
        final poll = await pollController.execute(_command());
        expect(poll.errorCode, 'AGENT_RUN_POLL_FAILED');
        expect(pollController.running, isFalse);
      },
    );

    test('prohibited Work AI and Feed AI never touch the port', () async {
      for (final featureId in <String>['work_ai.topic', 'feed-ai.retry']) {
        final port = _AgentPortFake();
        final controller = _controller(port);
        final access = await controller.ensureFeature(featureId);
        final outcome = await controller.execute(
          MobileAgentRunCommand(
            operationId: 'blocked-operation',
            featureId: featureId,
            visibleText: '禁止请求',
          ),
        );

        expect(access.errorCode, 'AGENT_FEATURE_PROHIBITED');
        expect(outcome.errorCode, 'AGENT_FEATURE_PROHIBITED');
        expect(port.totalCalls, 0);
      }
    });

    test(
      'thread mismatch and account switch reject stale run results',
      () async {
        final mismatchPort = _AgentPortFake()
          ..createResponses.add(
            Future<ApiResult<AgentRunSnapshot>>.value(
              _ok(_run(status: 'queued', threadId: 'other-thread')),
            ),
          );
        final mismatch = await _controller(mismatchPort).execute(_command());
        expect(mismatch.errorCode, 'AGENT_RUN_WORKSPACE_MISMATCH');

        final pollMismatchPort = _AgentPortFake()
          ..createResponses.add(
            Future<ApiResult<AgentRunSnapshot>>.value(
              _ok(_run(status: 'queued')),
            ),
          )
          ..pollResponses.add(
            Future<ApiResult<AgentRunSnapshot>>.value(
              _ok(
                _run(
                  status: 'succeeded',
                  terminal: true,
                  threadId: 'other-thread',
                ),
              ),
            ),
          );
        final pollMismatch = await _controller(
          pollMismatchPort,
        ).execute(_command());
        expect(pollMismatch.errorCode, 'AGENT_RUN_POLL_MISMATCH');

        final pendingCreate = Completer<ApiResult<AgentRunSnapshot>>();
        final racePort = _AgentPortFake()
          ..createResponses.add(pendingCreate.future);
        final controller = _controller(racePort);
        final pending = controller.execute(_command());
        while (racePort.createRequests.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        controller.bindIdentity(_identity('user-b', 'workspace-b'));
        pendingCreate.complete(_ok(_run(status: 'queued')));
        final stale = await pending;

        expect(stale.status, MobileAgentRunStatus.superseded);
        expect(controller.lastOutcome, isNull);
        expect(controller.running, isFalse);
      },
    );

    test(
      'local paths and incomplete HNote identities are rejected locally',
      () {
        expect(
          () => MobileAgentRunCommand(
            operationId: 'unsafe',
            featureId: 'chat.general',
            visibleText: '读取 file:///Users/example/private.md',
          ),
          throwsArgumentError,
        );
        expect(
          () => MobileAgentHNoteReference(
            noteId: 'note-1',
            part: 'raw',
            partRevisionId: '',
          ),
          throwsArgumentError,
        );
      },
    );
  });
}

MobileAgentCapabilityController _controller(_AgentPortFake port) =>
    MobileAgentCapabilityController(
      port: port,
      identity: _identity('user-a', 'workspace-a'),
      pollInterval: Duration.zero,
      retryInterval: Duration.zero,
      maxPollAttempts: 4,
      delay: (_) async {},
    );

MobileAgentRuntimeIdentity _identity(String userId, String workspaceId) =>
    MobileAgentRuntimeIdentity(
      userId: userId,
      workspaceId: workspaceId,
      locale: 'zh-CN',
      timezone: 'Asia/Shanghai',
    );

MobileAgentRunCommand _command() => MobileAgentRunCommand(
  operationId: 'operation-1',
  featureId: 'workbench.persona',
  visibleText: '请生成内容方案。',
  threadId: 'thread-1',
  references: <MobileAgentInputReference>[
    MobileAgentHNoteReference(
      noteId: 'note-1',
      part: 'raw',
      partRevisionId: 'part-revision-1',
    ),
  ],
);

final class _AgentPortFake
    implements MobileAgentCapabilityPort, MobileAgentRunCancellationPort {
  String catalogVersion = 'catalog-v1';
  String skillInstallation = 'enabled';
  String installedState = 'enabled';
  int profileCalls = 0;
  int profileThrows = 0;
  int skillCalls = 0;
  int modelCalls = 0;
  int createThrows = 0;
  int pollThrows = 0;
  final List<String> installationWorkspaces = <String>[];
  final List<AgentRunRequest> createRequests = <AgentRunRequest>[];
  final List<String> idempotencyKeys = <String>[];
  final List<String> pollRunIds = <String>[];
  final List<String> usageRunIds = <String>[];
  final List<String> cancelledRunIds = <String>[];
  final List<String> cancelIdempotencyKeys = <String>[];
  final List<Future<ApiResult<AgentProfileCatalog>>> profileResponses =
      <Future<ApiResult<AgentProfileCatalog>>>[];
  final List<Future<ApiResult<AgentRunSnapshot>>> createResponses =
      <Future<ApiResult<AgentRunSnapshot>>>[];
  final List<Future<ApiResult<AgentRunSnapshot>>> pollResponses =
      <Future<ApiResult<AgentRunSnapshot>>>[];

  int get totalCalls =>
      profileCalls +
      skillCalls +
      modelCalls +
      installationWorkspaces.length +
      createRequests.length +
      pollRunIds.length +
      usageRunIds.length;

  AgentProfileCatalog profilesFor(String version) => AgentProfileCatalog(
    catalogVersion: version,
    items: const <AgentProfileCatalogItem>[
      AgentProfileCatalogItem(
        agentProfileId: 'renshe_content',
        displayName: '人设内容',
      ),
      AgentProfileCatalogItem(
        agentProfileId: 'self_media_creation',
        displayName: '自媒体创作',
      ),
    ],
  );

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() {
    profileCalls += 1;
    if (profileThrows > 0) {
      profileThrows -= 1;
      throw StateError('catalog unavailable');
    }
    if (profileResponses.isNotEmpty) return profileResponses.removeAt(0);
    return Future<ApiResult<AgentProfileCatalog>>.value(
      _ok(profilesFor(catalogVersion)),
    );
  }

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) async {
    skillCalls += 1;
    return _ok(<SkillProfileCatalogItem>[
      SkillProfileCatalogItem(
        skillProfileId: 'renshe_content_creation',
        displayName: '人设内容创作',
        installation: skillInstallation,
      ),
    ]);
  }

  @override
  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  ) async {
    modelCalls += 1;
    return _ok(const <ModelProfileCatalogItem>[
      ModelProfileCatalogItem(
        modelProfileId: 'model-a',
        displayName: 'Model A',
      ),
    ]);
  }

  @override
  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  ) async {
    installationWorkspaces.add(workspaceId);
    return _ok(
      SharedSkillInstallationList(
        items: <SharedSkillInstallation>[
          SharedSkillInstallation(
            skillProfileId: 'renshe_content_creation',
            state: installedState,
            installMode: 'system_managed',
            installedAt: DateTime.utc(2026, 8, 1),
            updatedAt: DateTime.utc(2026, 8, 7),
          ),
        ],
      ),
    );
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> createRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) {
    createRequests.add(request);
    idempotencyKeys.add(idempotencyKey);
    if (createThrows > 0) {
      createThrows -= 1;
      throw StateError('create unavailable');
    }
    if (createResponses.isNotEmpty) return createResponses.removeAt(0);
    return Future<ApiResult<AgentRunSnapshot>>.value(
      _ok(_run(status: 'succeeded', terminal: true)),
    );
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> run(String agentRunId) {
    pollRunIds.add(agentRunId);
    if (pollThrows > 0) {
      pollThrows -= 1;
      throw StateError('poll unavailable');
    }
    if (pollResponses.isNotEmpty) return pollResponses.removeAt(0);
    return Future<ApiResult<AgentRunSnapshot>>.value(
      _ok(_run(status: 'succeeded', terminal: true)),
    );
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> cancelRun(
    String agentRunId, {
    required String idempotencyKey,
  }) async {
    cancelledRunIds.add(agentRunId);
    cancelIdempotencyKeys.add(idempotencyKey);
    return _ok(_run(status: 'cancelled', terminal: true));
  }

  @override
  Future<ApiResult<SharedRunUsage>> runUsage(String agentRunId) async {
    usageRunIds.add(agentRunId);
    return _ok(
      const SharedRunUsage(
        runId: 'run-1',
        policyVersion: 'credit-policy-v1',
        rawInputTokens: 10,
        rawOutputTokens: 20,
        accountedCredits: 30,
        settlementStatus: 'settled',
        assistantResultPersisted: true,
        measurements: <SharedRunUsageMeasurement>[],
      ),
    );
  }
}

ApiResult<T> _ok<T>(T data) => ApiResult<T>.success(
  data: data,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);

ApiResult<T> _failure<T>(String code, {bool retryable = false}) =>
    ApiResult<T>.failure(
      error: AppFailure(
        code: code,
        category: AppFailureCategory.network,
        message: code,
        userMessageKey: 'error.test',
        isRetryable: retryable,
        recoveryActions: const <String>['retry'],
      ),
      idempotencyStore: SubmissionKeyStore.empty,
    );

ApiResult<T> _httpFailure<T>(int status, String code) => ApiResult<T>.failure(
  error: AppFailure(
    code: code,
    category: AppFailureCategory.api,
    message: code,
    userMessageKey: 'error.test',
  ),
  status: status,
  idempotencyStore: SubmissionKeyStore.empty,
);

AgentRunSnapshot _run({
  String runId = 'run-1',
  required String status,
  bool terminal = false,
  String completionMode = 'normal',
  String threadId = 'thread-1',
}) => AgentRunSnapshot.fromValue(<String, Object?>{
  'agentRunId': runId,
  'workspaceId': 'workspace-a',
  'threadId': threadId,
  'status': status,
  'workspaceVersion': 4,
  'workspaceBindingVersion': 2,
  'contextGeneration': 7,
  if (terminal)
    'result': <String, Object?>{
      'finalAnswer': '生成结果',
      'assistantMessageId': 'message-1',
      'completionMode': completionMode,
    },
  if (terminal) 'assistantMessageId': 'message-1',
  if (terminal) 'completionMode': completionMode,
  'usage': <String, Object?>{
    'measurementStatus': terminal ? 'measured' : 'pending',
    'inputTokens': terminal ? 10 : null,
    'outputTokens': terminal ? 20 : null,
    'imageCount': null,
    'videoSeconds': null,
    'accountedCredits': terminal ? 30 : null,
    'policyVersion': terminal ? 'credits-v1' : null,
  },
  'toolTrace': const <Object?>[],
  'createdAt': '2026-08-07T10:00:00Z',
  'updatedAt': '2026-08-07T10:00:03Z',
});
