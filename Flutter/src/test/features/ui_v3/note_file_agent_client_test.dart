import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/features/ui_v3/data/automatic_outline_recovery_store.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_file_agent_client.dart';
import 'package:huahuoai_app/features/ui_v3/data/outline_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  group('NoteFileAgentClient', () {
    test(
      'writes a general_minutes outline and accepts only the read-back part',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _noteHead(),
          _run(
            status: 'running',
            selector: _generalMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
          ),
          _run(
            status: 'succeeded',
            selector: _generalMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
            outputPartRevisionId: 'outline-r2',
          ),
          _noteHead(outlineRevisionId: 'outline-r2'),
          _notePart(
            part: 'outline',
            revision: 'outline-r2',
            markdown: '# 普通纲要\n\n- 保留服务端结果',
          ),
        ]);
        final client = _client(transport);

        final result = await client.run(
          _request(
            selector: _generalMinutesSelector,
            idempotencyKey: 'general-minutes-1',
          ),
        );

        expect(result.markdown, '# 普通纲要\n\n- 保留服务端结果');
        expect(result.targetPart, NoteFileAgentPart.outline);
        expect(result.outputPartRevisionId, 'outline-r2');
        expect(result.selector.agentProfileId, 'general_minutes');
        expect(result.selector.skillProfileIds, <String>['general_minutes']);
        expect(transport.requests.map((request) => request.url.path), <String>[
          '/api/v1/workspaces/workspace-1/notes/note-1',
          '/api/v1/workspaces/workspace-1/notes/note-1/file-agent-runs',
          '/api/v1/workspaces/workspace-1/notes/note-1/file-agent-runs/run-1',
          '/api/v1/workspaces/workspace-1/notes/note-1',
          '/api/v1/workspaces/workspace-1/notes/note-1/parts/outline',
        ]);
        final create = transport.requests[1];
        expect(create.method, 'POST');
        expect(create.headers['X-Idempotency-Key'], 'general-minutes-1');
        expect(_body(create), <String, Object?>{
          'input': <String, Object?>{'part': 'raw', 'partRevisionId': 'raw-r1'},
          'target': <String, Object?>{
            'part': 'outline',
            'partRevisionId': 'outline-r1',
          },
          'instruction': 'Create a Markdown outline.',
          'agentProfileId': 'general_minutes',
          'skillProfileIds': <Object?>['general_minutes'],
        });
      },
    );

    test(
      'uses the recording postprocess selector for transcript outlines',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _noteHead(),
          _run(
            status: 'running',
            selector: _recordingMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
          ),
          _run(
            status: 'succeeded',
            selector: _recordingMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
            outputPartRevisionId: 'outline-r2',
          ),
          _noteHead(outlineRevisionId: 'outline-r2'),
          _notePart(
            part: 'outline',
            revision: 'outline-r2',
            markdown: '# 录音纪要\n\n- 服务端已写回',
          ),
        ]);
        final client = _client(transport);

        final result = await client.run(
          _request(
            selector: _recordingMinutesSelector,
            idempotencyKey: 'recording-minutes-1',
          ),
        );

        expect(result.markdown, '# 录音纪要\n\n- 服务端已写回');
        expect(
          _body(transport.requests[1])['agentProfileId'],
          'recording_postprocess_agent',
        );
        expect(_body(transport.requests[1])['skillProfileIds'], <Object?>[
          'meeting_minutes',
        ]);
        expect(
          transport.requests.where(
            (request) => request.url.path.contains('/chat/'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'treats a conflict as terminal and never reads a result part',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _noteHead(),
          _run(
            status: 'running',
            selector: _generalMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
          ),
          _run(
            status: 'conflict',
            selector: _generalMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
            failureCode: 'NOTE_PART_VERSION_CONFLICT',
          ),
        ]);
        final delays = <Duration>[];
        final client = NoteFileAgentClient(
          apiClient: _apiClient(transport),
          workspaceId: () => 'workspace-1',
          pollInterval: const Duration(milliseconds: 1),
          maxPollAttempts: 3,
          delay: (duration) async => delays.add(duration),
        );

        await expectLater(
          client.run(
            _request(
              selector: _generalMinutesSelector,
              idempotencyKey: 'general-minutes-conflict',
            ),
          ),
          throwsA(
            isA<NoteFileAgentException>().having(
              (error) => error.code,
              'code',
              'NOTE_PART_VERSION_CONFLICT',
            ),
          ),
        );

        expect(delays, <Duration>[const Duration(milliseconds: 1)]);
        expect(transport.requests, hasLength(3));
        expect(
          transport.requests.last.url.path,
          endsWith('/file-agent-runs/run-1'),
        );
      },
    );

    test('reads a public lifecycle with its output revision', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(<String, Object?>{
          'fileAgentRun': <String, Object?>{
            'fileAgentRunId': 'run-1',
            'noteId': 'note-1',
            'status': 'succeeded',
            'outputPartRevisionId': 'outline-r2',
          },
        }),
      ]);
      final client = _client(transport);

      final result = await client.getRun(
        noteId: 'note-1',
        fileAgentRunId: 'run-1',
      );

      expect(result.fileAgentRunId, 'run-1');
      expect(result.noteId, 'note-1');
      expect(result.agentRunId, isNull);
      expect(result.targetPart, isNull);
      expect(result.outputPartRevisionId, 'outline-r2');
      expect(result.isSuccessful, isTrue);
    });

    test('accepts backend-owned retry lifecycle states as nonterminal', () {
      for (final status in <String>['retry_wait', 'retry_admitting']) {
        final result = NoteFileAgentRunStatus.fromValue(<String, Object?>{
          'fileAgentRun': <String, Object?>{
            'fileAgentRunId': 'run-retry-1',
            'noteId': 'note-1',
            'status': status,
            'agentRunId': 'agent-run-retry-1',
            'targetPart': 'outline',
          },
        });

        expect(result.status, status);
        expect(result.isTerminal, isFalse);
      }
    });
  });

  group('FileAgentOutlineRepository admission', () {
    test('refuses a newer target revision and existing user Outline', () async {
      final changedTarget = _QueueTransport(<ApiTransportResponse>[
        _noteHead(outlineRevisionId: 'outline-r2'),
      ]);
      await expectLater(
        FileAgentOutlineRepository(
          _client(changedTarget),
        ).submit(_outlineNote(), operationId: 'frozen-target'),
        throwsA(
          isA<OutlineGenerationException>().having(
            (error) => error.code,
            'code',
            'OUTLINE_SOURCE_REVISION_CHANGED',
          ),
        ),
      );
      expect(changedTarget.requests, hasLength(1));

      final existingOutline = _QueueTransport(<ApiTransportResponse>[
        _noteHead(),
        _notePart(part: 'outline', revision: 'outline-r1', markdown: '# 用户纲要'),
      ]);
      await expectLater(
        FileAgentOutlineRepository(
          _client(existingOutline),
        ).submit(_outlineNote(), operationId: 'existing-outline'),
        throwsA(
          isA<OutlineGenerationException>().having(
            (error) => error.code,
            'code',
            'OUTLINE_ALREADY_EXISTS',
          ),
        ),
      );
      expect(existingOutline.requests, hasLength(2));
      expect(
        existingOutline.requests.where((request) => request.method == 'POST'),
        isEmpty,
      );
    });

    test(
      'replaces only an explicitly proven stale automatic Outline',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _noteHead(),
          _notePart(
            part: 'outline',
            revision: 'outline-r1',
            markdown: '# 上一版自动纲要',
          ),
          _noteHead(),
          _run(
            status: 'queued',
            selector: _generalMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
          ),
        ]);

        final accepted = await FileAgentOutlineRepository(_client(transport))
            .submit(
              _outlineNote(),
              operationId: 'replace-stale-auto',
              allowExistingAutomaticOutline: true,
            );

        expect(accepted.targetPartRevisionId, 'outline-r1');
        expect(transport.requests, hasLength(4));
        final create = transport.requests.last;
        expect(create.method, 'POST');
        expect(
          create.headers['X-Idempotency-Key'],
          'detail-outline-replace-stale-auto',
        );
        expect(
          (_body(create)['target'] as Map<String, dynamic>)['partRevisionId'],
          'outline-r1',
        );
      },
    );

    test('matches the backend imported-media idempotency request', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _noteHead(),
        _notePart(part: 'outline', revision: 'outline-r1', markdown: ''),
        _noteHead(),
        _run(
          status: 'queued',
          selector: _generalMinutesSelector,
          targetPart: 'outline',
          targetRevisionId: 'outline-r1',
        ),
      ]);

      await FileAgentOutlineRepository(_client(transport)).submit(
        _outlineNote(),
        operationId: 'media-outline:ingestion_backend_media_1',
      );

      final create = transport.requests.last;
      expect(
        create.headers['X-Idempotency-Key'],
        'media-outline:ingestion_backend_media_1',
      );
      expect(_body(create), <String, Object?>{
        'input': <String, Object?>{'part': 'raw', 'partRevisionId': 'raw-r1'},
        'target': <String, Object?>{
          'part': 'outline',
          'partRevisionId': 'outline-r1',
        },
        'instruction': '请根据视频或音频的完整转写内容生成准确、清晰的中文纪要，保留关键事实、观点和结论。不添加原文没有的信息。',
        'agentProfileId': 'general_minutes',
        'skillProfileIds': <Object?>['general_minutes'],
      });
    });

    test(
      'replays a persisted exact request without mutable head reads',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _run(
            status: 'queued',
            selector: _generalMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
          ),
        ]);
        const operationId = 'auto-outline-v1-persisted-exact-request';
        const request = NoteFileAgentRequest(
          noteId: 'note-1',
          inputPart: NoteFileAgentPart.raw,
          inputPartRevisionId: 'raw-r1',
          targetPart: NoteFileAgentPart.outline,
          targetPartRevisionId: 'outline-r1',
          instruction: 'Persisted exact instruction.',
          selector: _generalMinutesSelector,
          idempotencyKey: 'detail-outline-$operationId',
        );
        final admission = AutomaticOutlinePreparedAdmission(
          attemptId: automaticOutlineAttemptId(
            workspaceScope: 'workspace-1',
            remoteNoteId: request.noteId,
            inputRawRevisionId: request.inputPartRevisionId,
            targetOutlineRevisionId: request.targetPartRevisionId,
          ),
          localNoteId: 'local-note-1',
          operationId: operationId,
          request: request,
          allowExistingAutomaticOutline: false,
          createdAt: DateTime.utc(2026, 9, 15, 8),
        );

        final accepted = await FileAgentOutlineRepository(
          _client(transport),
        ).replayAutomaticAdmission(admission);

        expect(accepted.fileAgentRunId, 'run-1');
        expect(transport.requests, hasLength(1));
        final replay = transport.requests.single;
        expect(replay.method, 'POST');
        expect(replay.headers['X-Idempotency-Key'], request.idempotencyKey);
        expect(_body(replay)['instruction'], request.instruction);
      },
    );

    test('recovery persists a fresh generation before replaying it', () async {
      const operationId = 'auto-outline-v1-recovery-fresh-key';
      const request = NoteFileAgentRequest(
        noteId: 'note-1',
        inputPart: NoteFileAgentPart.raw,
        inputPartRevisionId: 'raw-r1',
        targetPart: NoteFileAgentPart.outline,
        targetPartRevisionId: 'outline-r1',
        instruction: 'Persisted exact instruction.',
        selector: _generalMinutesSelector,
        idempotencyKey: 'detail-outline-$operationId',
      );
      final admission = AutomaticOutlinePreparedAdmission(
        attemptId: automaticOutlineAttemptId(
          workspaceScope: 'workspace-1',
          remoteNoteId: request.noteId,
          inputRawRevisionId: request.inputPartRevisionId,
          targetOutlineRevisionId: request.targetPartRevisionId,
        ),
        localNoteId: 'local-note-1',
        operationId: operationId,
        request: request,
        allowExistingAutomaticOutline: false,
        createdAt: DateTime.utc(2026, 9, 15, 8),
      );
      final recovery = InMemoryAutomaticOutlineRecoveryStore(
        workspaceScope: 'workspace-1',
      );
      expect(await recovery.putPrepared(admission), isTrue);
      final transport = _QueueTransport(<ApiTransportResponse>[
        _failure('MODEL_GATEWAY_UNAVAILABLE', retryable: true),
        _run(
          status: 'queued',
          selector: _generalMinutesSelector,
          targetPart: 'outline',
          targetRevisionId: 'outline-r1',
        ),
      ]);

      final accepted = await FileAgentOutlineRepository(
        _client(transport),
        recoveryStore: recovery,
      ).replayAutomaticAdmission(admission);

      final posts = transport.requests
          .where((entry) => entry.method == 'POST')
          .toList(growable: false);
      expect(posts, hasLength(2));
      expect(posts.first.headers['X-Idempotency-Key'], request.idempotencyKey);
      expect(
        posts.last.headers['X-Idempotency-Key'],
        automaticOutlineRequestIdempotencyKey(
          operationId,
          backendAdmissionAttempt: 1,
        ),
      );
      final recovered = recovery.admissionForRemoteNote(request.noteId);
      expect(recovered?.backendAdmissionAttempt, 1);
      expect(recovered?.accepted?.fileAgentRunId, accepted.fileAgentRunId);
    });

    test('gateway failure replays the same admission key', () async {
      const operationId = 'auto-outline-v1-gateway-uncertain';
      final recovery = InMemoryAutomaticOutlineRecoveryStore(
        workspaceScope: 'workspace-1',
      );
      final transport = _QueueTransport(<ApiTransportResponse>[
        _noteHead(),
        _notePart(part: 'outline', revision: 'outline-r1', markdown: ''),
        _noteHead(),
        const ApiTransportResponse(status: 502, body: 'Bad Gateway'),
        _run(
          status: 'queued',
          selector: _generalMinutesSelector,
          targetPart: 'outline',
          targetRevisionId: 'outline-r1',
        ),
      ]);
      final repository = FileAgentOutlineRepository(
        _client(transport),
        recoveryStore: recovery,
      );

      await expectLater(
        repository.submit(_outlineNote(), operationId: operationId),
        throwsA(
          isA<OutlineGenerationException>()
              .having((error) => error.code, 'code', 'API_SERVER_UNAVAILABLE')
              .having((error) => error.isRetryable, 'isRetryable', isTrue),
        ),
      );
      expect(
        recovery.admissionForRemoteNote('note-1')?.backendAdmissionAttempt,
        0,
      );

      final accepted = await repository.submit(
        _outlineNote(),
        operationId: operationId,
      );
      final posts = transport.requests
          .where((request) => request.method == 'POST')
          .toList(growable: false);
      expect(posts, hasLength(2));
      expect(
        posts.map((request) => request.headers['X-Idempotency-Key']).toSet(),
        <String>{'detail-outline-$operationId'},
      );
      expect(
        recovery.admissionForRemoteNote('note-1')?.accepted?.fileAgentRunId,
        accepted.fileAgentRunId,
      );
    });

    test(
      'duplicate failed receipt advances only after exact recovery preflight',
      () async {
        const operationId = 'auto-outline-v1-lost-retryable-receipt';
        const request = NoteFileAgentRequest(
          noteId: 'note-1',
          inputPart: NoteFileAgentPart.raw,
          inputPartRevisionId: 'raw-r1',
          targetPart: NoteFileAgentPart.outline,
          targetPartRevisionId: 'outline-r1',
          instruction: 'Persisted exact instruction.',
          selector: _generalMinutesSelector,
          idempotencyKey: 'detail-outline-$operationId',
        );
        final admission = AutomaticOutlinePreparedAdmission(
          attemptId: automaticOutlineAttemptId(
            workspaceScope: 'workspace-1',
            remoteNoteId: request.noteId,
            inputRawRevisionId: request.inputPartRevisionId,
            targetOutlineRevisionId: request.targetPartRevisionId,
          ),
          localNoteId: 'local-note-1',
          operationId: operationId,
          request: request,
          allowExistingAutomaticOutline: false,
          createdAt: DateTime.utc(2026, 9, 15, 8),
        );
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        expect(await recovery.putPrepared(admission), isTrue);
        final transport = _QueueTransport(<ApiTransportResponse>[
          _failure(
            'SERVICE_BUSY',
            retryable: false,
            status: 409,
            message: 'previous idempotent request failed',
          ),
          _noteHead(),
          _notePart(part: 'outline', revision: 'outline-r1', markdown: ''),
          _run(
            status: 'queued',
            selector: _generalMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
          ),
        ]);

        final accepted = await FileAgentOutlineRepository(
          _client(transport),
          recoveryStore: recovery,
        ).replayAutomaticAdmission(admission);

        final posts = transport.requests
            .where((request) => request.method == 'POST')
            .toList(growable: false);
        expect(posts, hasLength(2));
        expect(
          posts.first.headers['X-Idempotency-Key'],
          request.idempotencyKey,
        );
        expect(
          posts.last.headers['X-Idempotency-Key'],
          automaticOutlineRequestIdempotencyKey(
            operationId,
            backendAdmissionAttempt: 1,
          ),
        );
        final recovered = recovery.admissionForRemoteNote(request.noteId);
        expect(recovered?.backendAdmissionAttempt, 1);
        expect(recovered?.accepted?.fileAgentRunId, accepted.fileAgentRunId);
      },
    );

    test('duplicate failed receipt cannot bypass changed revisions', () async {
      const operationId = 'auto-outline-v1-stale-failed-receipt';
      const request = NoteFileAgentRequest(
        noteId: 'note-1',
        inputPart: NoteFileAgentPart.raw,
        inputPartRevisionId: 'raw-r1',
        targetPart: NoteFileAgentPart.outline,
        targetPartRevisionId: 'outline-r1',
        instruction: 'Persisted exact instruction.',
        selector: _generalMinutesSelector,
        idempotencyKey: 'detail-outline-$operationId',
      );
      final admission = AutomaticOutlinePreparedAdmission(
        attemptId: automaticOutlineAttemptId(
          workspaceScope: 'workspace-1',
          remoteNoteId: request.noteId,
          inputRawRevisionId: request.inputPartRevisionId,
          targetOutlineRevisionId: request.targetPartRevisionId,
        ),
        localNoteId: 'local-note-1',
        operationId: operationId,
        request: request,
        allowExistingAutomaticOutline: false,
        createdAt: DateTime.utc(2026, 9, 15, 8),
      );
      final recovery = InMemoryAutomaticOutlineRecoveryStore(
        workspaceScope: 'workspace-1',
      );
      expect(await recovery.putPrepared(admission), isTrue);
      final transport = _QueueTransport(<ApiTransportResponse>[
        _failure(
          'SERVICE_BUSY',
          retryable: false,
          status: 409,
          message: 'previous idempotent request failed',
        ),
        _noteHead(rawRevisionId: 'raw-r2'),
      ]);

      await expectLater(
        FileAgentOutlineRepository(
          _client(transport),
          recoveryStore: recovery,
        ).replayAutomaticAdmission(admission),
        throwsA(
          isA<OutlineGenerationException>().having(
            (error) => error.code,
            'code',
            'OUTLINE_SOURCE_REVISION_CHANGED',
          ),
        ),
      );

      expect(
        transport.requests.where((request) => request.method == 'POST'),
        hasLength(1),
      );
      expect(
        recovery.admissionForRemoteNote('note-1')?.backendAdmissionAttempt,
        0,
      );
    });

    test(
      'rotates the backend key after authoritative retryable rejection',
      () async {
        const operationId = 'auto-outline-v1-retryable-create';
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        final transport = _QueueTransport(<ApiTransportResponse>[
          _noteHead(),
          _notePart(part: 'outline', revision: 'outline-r1', markdown: ''),
          _noteHead(),
          _failure('MODEL_GATEWAY_UNAVAILABLE', retryable: true),
          _run(
            status: 'queued',
            selector: _generalMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
          ),
        ]);
        final repository = FileAgentOutlineRepository(
          _client(transport),
          recoveryStore: recovery,
        );

        await expectLater(
          repository.submit(_outlineNote(), operationId: operationId),
          throwsA(
            isA<OutlineGenerationException>()
                .having(
                  (error) => error.code,
                  'code',
                  'MODEL_GATEWAY_UNAVAILABLE',
                )
                .having((error) => error.isRetryable, 'isRetryable', isTrue),
          ),
        );
        expect(
          repository.pendingOutlineOperationId(_outlineNote()),
          operationId,
        );
        final rotated = recovery.admissionForRemoteNote('note-1');
        expect(rotated?.backendAdmissionAttempt, 1);
        expect(
          rotated?.request.idempotencyKey,
          automaticOutlineRequestIdempotencyKey(
            operationId,
            backendAdmissionAttempt: 1,
          ),
        );
        final requestsAfterFailure = transport.requests.length;
        await expectLater(
          repository.submit(_outlineNote(), operationId: 'different-operation'),
          throwsA(
            isA<OutlineGenerationException>().having(
              (error) => error.code,
              'code',
              'OUTLINE_ADMISSION_OPERATION_CONFLICT',
            ),
          ),
        );
        expect(transport.requests, hasLength(requestsAfterFailure));

        final accepted = await repository.submit(
          _outlineNote(),
          operationId: operationId,
        );
        final creates = transport.requests
            .where((request) => request.method == 'POST')
            .toList(growable: false);
        expect(creates, hasLength(2));
        expect(
          creates.first.headers['X-Idempotency-Key'],
          'detail-outline-$operationId',
        );
        expect(
          creates.last.headers['X-Idempotency-Key'],
          startsWith('outline-retry-v1-'),
        );
        expect(
          creates.last.headers['X-Idempotency-Key'],
          isNot(creates.first.headers['X-Idempotency-Key']),
        );
        expect(creates.last.body, creates.first.body);
        expect(
          transport.requests.where(
            (request) => request.url.path.endsWith('/parts/outline'),
          ),
          hasLength(1),
        );
        expect(
          transport.requests.where(
            (request) =>
                request.method == 'GET' &&
                !request.url.path.endsWith('/parts/outline'),
          ),
          hasLength(2),
        );
        expect(
          recovery.admissionForRemoteNote('note-1')?.accepted?.fileAgentRunId,
          accepted.fileAgentRunId,
        );
        repository.markOutlineAdmissionTracked(accepted);
      },
    );

    test('replays workspace readiness rejection with the same key', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _noteHead(),
        _notePart(part: 'outline', revision: 'outline-r1', markdown: ''),
        _noteHead(),
        _failure('WORKSPACE_NOT_READY', retryable: true, status: 409),
        _run(
          status: 'queued',
          selector: _generalMinutesSelector,
          targetPart: 'outline',
          targetRevisionId: 'outline-r1',
        ),
      ]);
      final repository = FileAgentOutlineRepository(_client(transport));

      await expectLater(
        repository.submit(_outlineNote(), operationId: 'workspace-readiness'),
        throwsA(
          isA<OutlineGenerationException>()
              .having((error) => error.code, 'code', 'WORKSPACE_NOT_READY')
              .having((error) => error.isRetryable, 'isRetryable', isTrue),
        ),
      );
      final accepted = await repository.submit(
        _outlineNote(),
        operationId: 'workspace-readiness',
      );
      final posts = transport.requests
          .where((request) => request.method == 'POST')
          .toList(growable: false);
      expect(posts, hasLength(2));
      expect(
        posts.map((request) => request.headers['X-Idempotency-Key']).toSet(),
        <String>{'detail-outline-workspace-readiness'},
      );
      expect(posts.last.body, posts.first.body);
      repository.markOutlineAdmissionTracked(accepted);
    });

    test(
      'replays an uncertain POST after the remote target advances',
      () async {
        final transport = _LostAdmissionResponseTransport();
        final repository = FileAgentOutlineRepository(_client(transport));

        await expectLater(
          repository.submit(_outlineNote(), operationId: 'uncertain-create'),
          throwsA(
            isA<OutlineGenerationException>().having(
              (error) => error.isRetryable,
              'isRetryable',
              isTrue,
            ),
          ),
        );

        await expectLater(
          repository.submit(_outlineNote(), operationId: 'uncertain-create'),
          throwsA(
            isA<OutlineGenerationException>()
                .having(
                  (error) => error.code,
                  'code',
                  'OUTLINE_ADMISSION_RESPONSE_UNCERTAIN',
                )
                .having((error) => error.isRetryable, 'isRetryable', isTrue),
          ),
        );
        expect(
          repository.pendingOutlineOperationId(_outlineNote()),
          'uncertain-create',
        );

        final accepted = await repository.submit(
          _outlineNote(),
          operationId: 'uncertain-create',
        );
        final posts = transport.requests
            .where((request) => request.method == 'POST')
            .toList(growable: false);
        expect(posts, hasLength(3));
        expect(posts.map((request) => request.body).toSet(), hasLength(1));
        expect(
          posts.map((request) => request.headers['X-Idempotency-Key']).toSet(),
          <String>{'detail-outline-uncertain-create'},
        );
        expect(
          transport.requests.where((request) => request.method == 'GET'),
          hasLength(3),
        );
        expect(accepted.targetPartRevisionId, 'outline-r1');
        repository.markOutlineAdmissionTracked(accepted);
      },
    );

    test('releases a retryable failure before POST dispatch', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _noteHead(),
        _notePart(part: 'outline', revision: 'outline-r1', markdown: ''),
        _failure('NOTE_HEAD_UNAVAILABLE', retryable: true),
        _noteHead(),
        _notePart(part: 'outline', revision: 'outline-r1', markdown: ''),
        _noteHead(),
        _run(
          status: 'queued',
          selector: _generalMinutesSelector,
          targetPart: 'outline',
          targetRevisionId: 'outline-r1',
        ),
      ]);
      final repository = FileAgentOutlineRepository(_client(transport));

      await expectLater(
        repository.submit(_outlineNote(), operationId: 'preflight-failure'),
        throwsA(
          isA<OutlineGenerationException>().having(
            (error) => error.isRetryable,
            'isRetryable',
            isTrue,
          ),
        ),
      );
      expect(repository.pendingOutlineOperationId(_outlineNote()), isNull);

      final accepted = await repository.submit(
        _outlineNote(),
        operationId: 'replacement-operation',
      );
      expect(
        transport.requests.where((request) => request.method == 'POST'),
        hasLength(1),
      );
      repository.markOutlineAdmissionTracked(accepted);
    });

    test(
      'shares one admission for concurrent callers on the same operation',
      () async {
        final transport = _BlockingAdmissionTransport();
        final repository = FileAgentOutlineRepository(_client(transport));

        final first = repository.submit(
          _outlineNote(),
          operationId: 'same-revisions',
        );
        await transport.postStarted.future;

        final second = repository.submit(
          _outlineNote(),
          operationId: 'same-revisions',
        );
        await Future<void>.delayed(Duration.zero);
        expect(transport.requestCount, 4);
        transport.releasePost();

        final accepted = await Future.wait(<Future<NoteFileAgentRunSnapshot>>[
          first,
          second,
        ]);
        expect(transport.postCount, 1);
        expect(accepted[0].fileAgentRunId, 'run-1');
        expect(accepted[1].fileAgentRunId, accepted[0].fileAgentRunId);

        final replay = await repository.submit(
          _outlineNote(),
          operationId: 'same-revisions',
        );
        expect(replay.fileAgentRunId, accepted[0].fileAgentRunId);
        expect(transport.postCount, 1);
        expect(transport.requestCount, 4);

        repository.markOutlineAdmissionTracked(accepted[0]);
      },
    );

    test(
      'rejects a different operation while the same revisions are reserved',
      () async {
        final transport = _BlockingFirstPreflightTransport();
        final repository = FileAgentOutlineRepository(_client(transport));

        final first = repository.submit(
          _outlineNote(),
          operationId: 'manual-outline-operation',
        );
        await transport.preflightStarted.future;
        final conflicting = repository.submit(
          _outlineNote(),
          operationId: 'media-outline:ingestion_backend_media_conflict',
        );
        await expectLater(
          conflicting,
          throwsA(
            isA<OutlineGenerationException>()
                .having(
                  (error) => error.code,
                  'code',
                  'OUTLINE_ADMISSION_OPERATION_CONFLICT',
                )
                .having((error) => error.isRetryable, 'isRetryable', isTrue),
          ),
        );
        expect(transport.requestCount, 1);

        transport.releasePreflight();
        final accepted = await first;
        expect(transport.postCount, 1);
        repository.markOutlineAdmissionTracked(accepted);
      },
    );

    test(
      'maps one shared admission failure for every concurrent caller',
      () async {
        final transport = _BlockingAdmissionTransport(
          postResponse: _failure('MODEL_GATEWAY_UNAVAILABLE', retryable: true),
        );
        final repository = FileAgentOutlineRepository(_client(transport));

        final first = repository.submit(
          _outlineNote(),
          operationId: 'same-failure',
        );
        await transport.postStarted.future;
        final second = repository.submit(
          _outlineNote(),
          operationId: 'same-failure',
        );
        await Future<void>.delayed(Duration.zero);
        expect(transport.requestCount, 4);
        transport.releasePost();

        for (final future in <Future<NoteFileAgentRunSnapshot>>[
          first,
          second,
        ]) {
          await expectLater(
            future,
            throwsA(
              isA<OutlineGenerationException>()
                  .having(
                    (error) => error.code,
                    'code',
                    'MODEL_GATEWAY_UNAVAILABLE',
                  )
                  .having((error) => error.isRetryable, 'isRetryable', isTrue),
            ),
          );
        }
        expect(transport.postCount, 1);
      },
    );

    test(
      'terminal identity enrichment preserves the newest timestamp',
      () async {
        const operationId = 'auto-outline-v1-terminal-enrichment';
        const remoteNoteId = 'note-1';
        const rawRevisionId = 'raw-r1';
        const outlineRevisionId = 'outline-r1';
        final attemptId = automaticOutlineAttemptId(
          workspaceScope: 'workspace-1',
          remoteNoteId: remoteNoteId,
          inputRawRevisionId: rawRevisionId,
          targetOutlineRevisionId: outlineRevisionId,
        );
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        final newestTimestamp = DateTime.utc(2026, 9, 15, 10);

        expect(
          await recovery.putTerminal(
            AutomaticOutlineTerminalRecord(
              attemptId: attemptId,
              remoteNoteId: remoteNoteId,
              operationId: operationId,
              inputRawRevisionId: rawRevisionId,
              targetOutlineRevisionId: outlineRevisionId,
              status: 'failed',
              recordedAt: newestTimestamp,
            ),
          ),
          isTrue,
        );
        expect(
          await recovery.putTerminal(
            AutomaticOutlineTerminalRecord(
              attemptId: attemptId,
              remoteNoteId: remoteNoteId,
              operationId: operationId,
              inputRawRevisionId: rawRevisionId,
              targetOutlineRevisionId: outlineRevisionId,
              status: 'failed',
              fileAgentRunId: 'file-run-1',
              recordedAt: DateTime.utc(2026, 9, 15, 9),
            ),
          ),
          isTrue,
        );

        final terminal = recovery
            .terminalAttemptsForRemoteNote(remoteNoteId)
            .single;
        expect(terminal.fileAgentRunId, 'file-run-1');
        expect(terminal.recordedAt, newestTimestamp);
      },
    );
  });
}

const _generalMinutesSelector = NoteFileAgentSelector(
  agentProfileId: 'general_minutes',
  skillProfileIds: <String>['general_minutes'],
);

const _recordingMinutesSelector = NoteFileAgentSelector(
  agentProfileId: 'recording_postprocess_agent',
  skillProfileIds: <String>['meeting_minutes'],
);

NoteFileAgentClient _client(ApiTransport transport) => NoteFileAgentClient(
  apiClient: _apiClient(transport),
  workspaceId: () => 'workspace-1',
  pollInterval: Duration.zero,
  delay: (_) async {},
);

NoteFileAgentRequest _request({
  required NoteFileAgentSelector selector,
  required String idempotencyKey,
}) => NoteFileAgentRequest(
  noteId: 'note-1',
  inputPart: NoteFileAgentPart.raw,
  inputPartRevisionId: 'raw-r1',
  targetPart: NoteFileAgentPart.outline,
  targetPartRevisionId: 'outline-r1',
  instruction: 'Create a Markdown outline.',
  selector: selector,
  idempotencyKey: idempotencyKey,
);

V3FeedItem _outlineNote() => V3FeedItem(
  id: 'local-note-1',
  title: '待生成纲要的资产',
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 9, 15),
  updatedAt: DateTime.utc(2026, 9, 15),
  rawBody: '原始内容',
  remoteNoteId: 'note-1',
  rawPartRevisionId: 'raw-r1',
  outlinePartRevisionId: 'outline-r1',
  syncState: NoteSyncState.synced,
);

ApiTransportResponse _success(Map<String, Object?> data, {int status = 200}) =>
    ApiTransportResponse(
      status: status,
      body: <String, Object?>{'success': true, 'data': data},
    );

ApiTransportResponse _failure(
  String code, {
  required bool retryable,
  int status = 400,
  String? message,
}) => ApiTransportResponse(
  status: status,
  body: <String, Object?>{
    'success': false,
    'error': <String, Object?>{
      'code': code,
      'message': message ?? code,
      'retryable': retryable,
    },
  },
);

ApiTransportResponse _noteHead({
  String rawRevisionId = 'raw-r1',
  String outlineRevisionId = 'outline-r1',
  String germinationRevisionId = 'germ-r1',
}) => _success(<String, Object?>{
  'noteId': 'note-1',
  'rawPartRevisionId': rawRevisionId,
  'outlinePartRevisionId': outlineRevisionId,
  'germinationPartRevisionId': germinationRevisionId,
});

ApiTransportResponse _notePart({
  required String part,
  required String revision,
  required String markdown,
}) => _success(<String, Object?>{
  'noteId': 'note-1',
  'part': part,
  'partRevisionId': revision,
  'contentMarkdown': markdown,
  'contentSha256': 'sha-$revision',
  'etag': 'etag-$revision',
});

ApiTransportResponse _run({
  required String status,
  required NoteFileAgentSelector selector,
  required String targetPart,
  required String targetRevisionId,
  String? outputPartRevisionId,
  String? failureCode,
}) => _success(<String, Object?>{
  'fileAgentRun': <String, Object?>{
    'fileAgentRunId': 'run-1',
    'noteId': 'note-1',
    'status': status,
    'input': <String, Object?>{'part': 'raw', 'partRevisionId': 'raw-r1'},
    'target': <String, Object?>{
      'part': targetPart,
      'partRevisionId': targetRevisionId,
    },
    'selector': <String, Object?>{
      'agentProfileId': selector.agentProfileId,
      'skillProfileIds': selector.skillProfileIds,
    },
    'agentRunId': 'agent-run-1',
    if (outputPartRevisionId != null)
      'outputPartRevisionId': outputPartRevisionId,
    if (failureCode != null) 'failure': <String, Object?>{'code': failureCode},
  },
});

ApiClient _apiClient(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '0.1.0',
    deviceId: 'device-1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
    traceIdFactory: () => 'trace-file-agent',
  ),
  transport: transport,
);

Map<String, Object?> _body(ApiTransportRequest request) {
  final body = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return body.cast<String, Object?>();
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

final class _BlockingAdmissionTransport implements ApiTransport {
  _BlockingAdmissionTransport({ApiTransportResponse? postResponse})
    : _resolvedPostResponse =
          postResponse ??
          _run(
            status: 'queued',
            selector: _generalMinutesSelector,
            targetPart: 'outline',
            targetRevisionId: 'outline-r1',
          );

  final Completer<void> postStarted = Completer<void>();
  final Completer<ApiTransportResponse> _postResponse =
      Completer<ApiTransportResponse>();
  final ApiTransportResponse _resolvedPostResponse;

  int requestCount = 0;
  int postCount = 0;

  void releasePost() {
    _postResponse.complete(_resolvedPostResponse);
  }

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requestCount += 1;
    if (request.method == 'POST') {
      postCount += 1;
      if (!postStarted.isCompleted) postStarted.complete();
      return _postResponse.future;
    }
    if (request.url.path.endsWith('/parts/outline')) {
      return _notePart(part: 'outline', revision: 'outline-r1', markdown: '');
    }
    return _noteHead();
  }
}

final class _BlockingFirstPreflightTransport implements ApiTransport {
  final Completer<void> preflightStarted = Completer<void>();
  final Completer<void> _preflightRelease = Completer<void>();

  int requestCount = 0;
  int postCount = 0;

  void releasePreflight() => _preflightRelease.complete();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requestCount += 1;
    if (requestCount == 1) {
      preflightStarted.complete();
      await _preflightRelease.future;
    }
    if (request.method == 'POST') {
      postCount += 1;
      return _run(
        status: 'queued',
        selector: _generalMinutesSelector,
        targetPart: 'outline',
        targetRevisionId: 'outline-r1',
      );
    }
    if (request.url.path.endsWith('/parts/outline')) {
      return _notePart(part: 'outline', revision: 'outline-r1', markdown: '');
    }
    return _noteHead();
  }
}

final class _LostAdmissionResponseTransport implements ApiTransport {
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];
  int _postCount = 0;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (request.method == 'POST') {
      _postCount += 1;
      if (_postCount == 1) throw StateError('Admission response was lost');
      if (_postCount == 2) {
        return _success(<String, Object?>{
          'status': 'processing',
          'targetType': '',
          'targetId': '',
        }, status: 202);
      }
      return _run(
        status: 'queued',
        selector: _generalMinutesSelector,
        targetPart: 'outline',
        targetRevisionId: 'outline-r1',
      );
    }
    if (request.url.path.endsWith('/parts/outline')) {
      return _notePart(part: 'outline', revision: 'outline-r1', markdown: '');
    }
    return _noteHead(
      outlineRevisionId: _postCount == 0 ? 'outline-r1' : 'outline-r2',
    );
  }
}
