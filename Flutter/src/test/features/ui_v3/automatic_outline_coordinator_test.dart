import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/ingestion/domain/material_ingestion.dart';
import 'package:huahuoai_app/features/ui_v3/application/automatic_outline_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/automatic_outline_recovery_store.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_file_agent_client.dart';
import 'package:huahuoai_app/features/ui_v3/data/outline_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  group('AutomaticOutlineCoordinator', () {
    test(
      'admits every ordinary Raw source once with stable identities',
      () async {
        final notes = <V3FeedItem>[
          _note('manual', V3MaterialSource.note),
          _note('chat', V3MaterialSource.chatExcerpt),
          _note('document', V3MaterialSource.documentImport),
          _note('subscription', V3MaterialSource.subscription),
          _note('link', V3MaterialSource.link),
          _note('collision', V3MaterialSource.topicCollision),
        ];
        final library = KnowledgeLibraryController(
          initialNotes: notes,
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final tracker = _DerivedTracker();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();
        await coordinator.reconcileNow();

        expect(repository.submissions, hasLength(notes.length));
        expect(
          repository.submissions.map((submission) => submission.operationId),
          everyElement(startsWith('auto-outline-v1-')),
        );
        expect(
          repository.submissions
              .map((submission) => submission.operationId)
              .toSet(),
          hasLength(notes.length),
        );
        expect(tracker.taskLedger, hasLength(notes.length));
        expect(tracker.subjects.values.toSet(), {
          for (final note in notes) note.title,
        });
        expect(coordinator.tasks, isEmpty);

        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'excludes backend recording, read-only, outlined and active assets',
      () async {
        final now = DateTime.utc(2026, 9, 15);
        final notes = <V3FeedItem>[
          _note(
            'recording',
            V3MaterialSource.recordingCard,
            recordingId: 'recording-1',
          ),
          _note(
            'readonly',
            V3MaterialSource.subscription,
            ownership: V3NoteOwnership.subscribed,
          ),
          _note('outlined', V3MaterialSource.note).copyWith(
            summaryBody: 'Existing outline',
            outlinePartRevisionId: 'outline-existing',
          ),
          _note('parsing-document', V3MaterialSource.documentImport).copyWith(
            rawBody: '该资料正在解析中。',
            summaryBody: '本地导入资料 · application/pdf',
          ),
          _note('parsing-media', V3MaterialSource.mediaImport).copyWith(
            rawBody: '媒体类型：视频\n\n解析中：内容将在资料能力接入后补充。',
            summaryBody: '本地媒体导入 · 解析中',
          ),
          _note('active', V3MaterialSource.documentImport).copyWith(
            activeDerivedTasks: const <V3ActiveDerivedTask>[
              V3ActiveDerivedTask(
                fileAgentRunId: 'file-active',
                stage: V3DerivedTaskStage.outline,
                status: 'running',
              ),
            ],
            activeDerivedTasksAuthoritative: true,
            updatedAt: now,
          ),
        ];
        final library = KnowledgeLibraryController(
          initialNotes: notes,
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();

        expect(repository.submissions, isEmpty);
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'retains an exact failed notice and does not resubmit in a loop',
      () async {
        final note = _note('failed', V3MaterialSource.documentImport);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository(
          failureCode: 'OUTLINE_RUN_SUBMIT_FAILED',
        );
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();
        await coordinator.reconcileNow();

        expect(repository.submissions, hasLength(1));
        expect(coordinator.tasks, hasLength(1));
        expect(coordinator.tasks.single.phase, AutomaticOutlinePhase.failed);
        expect(coordinator.tasks.single.subjectTitle, note.title);
        expect(coordinator.tasks.single.errorCode, 'OUTLINE_RUN_SUBMIT_FAILED');

        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'waits for a complete Outline baseline without submitting or failing',
      () async {
        final note = _note(
          'pending-projection',
          V3MaterialSource.note,
        ).copyWith(clearOutlinePartRevisionId: true);
        final library = KnowledgeLibraryController(
          initialNotes: [note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          retryBaseDelay: const Duration(hours: 1),
        );
        addTearDown(coordinator.dispose);
        addTearDown(library.dispose);
        final phases = <AutomaticOutlinePhase>[];
        coordinator.addListener(
          () => phases.addAll(coordinator.tasks.map((task) => task.phase)),
        );

        await coordinator.reconcileNow();
        final waiting = coordinator.tasks.single;
        expect(waiting.phase, AutomaticOutlinePhase.retryWaiting);
        expect(waiting.resumePhase, AutomaticOutlinePhase.waitingForProjection);
        expect(waiting.retryAt, isNotNull);
        expect(waiting.isTerminal, isFalse);
        await coordinator.reconcileNow();
        expect(repository.submissions, isEmpty);
        expect(phases, contains(AutomaticOutlinePhase.waitingForProjection));
        expect(phases, isNot(contains(AutomaticOutlinePhase.failed)));

        library.updateNote(
          note.copyWith(outlinePartRevisionId: 'outline-ready'),
        );
        await coordinator.reconcileNow();
        expect(repository.submissions, hasLength(1));
        expect(
          repository.submissions.single.note.outlinePartRevisionId,
          'outline-ready',
        );
        expect(coordinator.tasks, isEmpty);
      },
    );

    test(
      'retry wait blocks listener replay and resumes only in foreground',
      () async {
        final note = _note('paused-admission', V3MaterialSource.note);
        final library = KnowledgeLibraryController(
          initialNotes: [note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository(
          failureCode: 'WORKSPACE_NOT_READY',
          failuresBeforeSuccess: 1,
          failureRetryable: true,
        );
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          retryBaseDelay: const Duration(milliseconds: 20),
        );
        addTearDown(coordinator.dispose);
        addTearDown(library.dispose);
        final phases = <AutomaticOutlinePhase>[];
        coordinator.addListener(
          () => phases.addAll(coordinator.tasks.map((task) => task.phase)),
        );
        await coordinator.reconcileNow();
        expect(
          coordinator.tasks.single.phase,
          AutomaticOutlinePhase.retryWaiting,
        );
        final retryAt = coordinator.tasks.single.retryAt;
        await coordinator.reconcileNow();
        expect(repository.submissions, hasLength(1));
        expect(coordinator.tasks.single.retryAt, retryAt);
        coordinator.setForeground(false);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(repository.submissions, hasLength(1));
        expect(
          coordinator.tasks.single.phase,
          AutomaticOutlinePhase.retryWaiting,
        );
        coordinator.setForeground(true);
        for (
          var attempt = 0;
          attempt < 20 && coordinator.tasks.isNotEmpty;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(repository.submissions, hasLength(2));
        expect(
          repository.submissions.last.operationId,
          repository.submissions.first.operationId,
        );
        expect(phases, contains(AutomaticOutlinePhase.registeringAccepted));
        expect(phases, isNot(contains(AutomaticOutlinePhase.failed)));
        expect(coordinator.tasks, isEmpty);
      },
    );

    test(
      'a changed revision retires an old submission failure without flashing failed',
      () async {
        final original = _note('revision-race', V3MaterialSource.note);
        final library = KnowledgeLibraryController(
          initialNotes: [original],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository(
          failureCode: 'OUTLINE_SOURCE_REVISION_CHANGED',
          failuresBeforeSuccess: 1,
          beforeSubmitFailure: () async {
            library.updateNote(original.copyWith(rawPartRevisionId: 'raw-new'));
          },
        );
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
        );
        addTearDown(coordinator.dispose);
        addTearDown(library.dispose);
        final phases = <AutomaticOutlinePhase>[];
        coordinator.addListener(
          () => phases.addAll(coordinator.tasks.map((task) => task.phase)),
        );
        await coordinator.reconcileNow();
        expect(repository.submissions, hasLength(2));
        expect(repository.submissions.last.note.rawPartRevisionId, 'raw-new');
        expect(
          repository.submissions.last.operationId,
          isNot(repository.submissions.first.operationId),
        );
        expect(phases, isNot(contains(AutomaticOutlinePhase.failed)));
        expect(coordinator.tasks, isEmpty);
      },
    );

    test(
      'retries a transient submit with the same operation identity',
      () async {
        final note = _note('retry', V3MaterialSource.note);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository(
          failureCode: 'OUTLINE_RUN_SUBMIT_FAILED',
          failuresBeforeSuccess: 1,
          failureRetryable: true,
        );
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
          retryBaseDelay: const Duration(milliseconds: 1),
          retryMaximumDelay: const Duration(milliseconds: 1),
        );

        await coordinator.reconcileNow();
        for (
          var attempt = 0;
          attempt < 20 && repository.submissions.length < 2;
          attempt += 1
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }

        expect(repository.submissions, hasLength(2));
        expect(
          repository.submissions.map((submission) => submission.operationId),
          everyElement(repository.submissions.first.operationId),
        );
        expect(coordinator.tasks, isEmpty);
        coordinator.dispose();
        library.dispose();
      },
    );

    test('does not retry a non-retryable submission failure', () async {
      final note = _note('non-retryable', V3MaterialSource.note);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository(
        failureCode: 'QUOTA_INSUFFICIENT',
      );
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: repository,
        tracker: _DerivedTracker(),
        workspaceScope: 'workspace-1',
        linkBackendGrace: Duration.zero,
        retryBaseDelay: const Duration(milliseconds: 1),
        retryMaximumDelay: const Duration(milliseconds: 1),
      );

      await coordinator.reconcileNow();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(repository.submissions, hasLength(1));
      expect(coordinator.tasks.single.errorCode, 'QUOTA_INSUFFICIENT');
      coordinator.dispose();
      library.dispose();
    });

    test(
      'refreshes a failed subject and prunes it after Outline appears',
      () async {
        final note = _note('renamed-failure', V3MaterialSource.note);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: _AcceptedOutlineRepository(
            failureCode: 'OUTLINE_CAPABILITY_NOT_PUBLISHED',
          ),
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );
        await coordinator.reconcileNow();

        library.updateNote(note.copyWith(title: 'Renamed asset'));
        await coordinator.reconcileNow();
        expect(coordinator.tasks.single.subjectTitle, 'Renamed asset');

        library.updateNote(
          note.copyWith(
            title: 'Renamed asset',
            summaryBody: 'A real generated outline',
          ),
        );
        await coordinator.reconcileNow();
        expect(coordinator.tasks, isEmpty);
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'treats a legacy document description as metadata after Raw is durable',
      () async {
        final note = _note(
          'legacy-document',
          V3MaterialSource.documentImport,
        ).copyWith(summaryBody: '本地导入资料 · application/pdf');
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();

        expect(repository.submissions.single.note.id, note.id);
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'process recovery replays the same backend idempotency identity',
      () async {
        final note = _note('recovery', V3MaterialSource.chatExcerpt);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final first = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );
        await first.reconcileNow();
        first.dispose();

        final restored = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );
        await restored.reconcileNow();

        expect(repository.submissions, hasLength(2));
        expect(
          repository.submissions.first.operationId,
          repository.submissions.last.operationId,
        );

        restored.dispose();
        library.dispose();
      },
    );

    test('reuses the backend URL-media outline operation identity', () async {
      final note = _note('media-link', V3MaterialSource.link);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository();
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: repository,
        tracker: _DerivedTracker(),
        workspaceScope: 'workspace-1',
        linkBackendGrace: Duration.zero,
        linkImportHandoffFor: (_) =>
            const AutomaticOutlineLinkHandoff.backendMedia(
              'media-outline:ingestion_backend_media_1',
            ),
      );

      await coordinator.reconcileNow();

      expect(
        repository.submissions.single.operationId,
        'media-outline:ingestion_backend_media_1',
      );
      expect(coordinator.tasks, isEmpty);
      coordinator.dispose();
      library.dispose();
    });

    test('does not admit a link while local ownership is unresolved', () async {
      final note = _note('unresolved-link', V3MaterialSource.link);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository();
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: repository,
        tracker: _DerivedTracker(),
        workspaceScope: 'workspace-1',
        linkBackendGrace: Duration.zero,
        linkImportHandoffFor: (_) =>
            const AutomaticOutlineLinkHandoff.unresolved(),
      );

      await coordinator.reconcileNow();

      expect(repository.submissions, isEmpty);
      expect(
        coordinator.tasks.single.phase,
        AutomaticOutlinePhase.waitingForOwnership,
      );
      coordinator.dispose();
      library.dispose();
    });

    test(
      'refreshes unresolved ownership and continues with the resolved operation',
      () async {
        final note = _note('recovering-link-owner', V3MaterialSource.link);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        var handoff = const AutomaticOutlineLinkHandoff.unresolved();
        var refreshCalls = 0;
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
          linkOwnershipRetryBaseDelay: const Duration(milliseconds: 1),
          linkImportHandoffFor: (_) => handoff,
          refreshLinkImportHandoffFor: (_) async {
            refreshCalls += 1;
            handoff = const AutomaticOutlineLinkHandoff.backendMedia(
              'media-outline:ingestion_recovered_owner',
            );
            return true;
          },
        );

        coordinator.start();
        await coordinator.reconcileNow();
        for (
          var attempt = 0;
          attempt < 20 && repository.submissions.isEmpty;
          attempt += 1
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }

        expect(refreshCalls, 1);
        expect(
          repository.submissions.single.operationId,
          'media-outline:ingestion_recovered_owner',
        );
        expect(coordinator.tasks, isEmpty);
        coordinator.dispose();
        library.dispose();
      },
    );

    test('keeps unresolved ownership in a nonterminal retry wait', () async {
      final note = _note('unresolved-owner-failure', V3MaterialSource.link);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      var refreshCalls = 0;
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: _AcceptedOutlineRepository(),
        tracker: _DerivedTracker(),
        workspaceScope: 'workspace-1',
        linkBackendGrace: Duration.zero,
        linkOwnershipRetryBaseDelay: const Duration(milliseconds: 1),
        linkImportHandoffFor: (_) =>
            const AutomaticOutlineLinkHandoff.unresolved(),
        refreshLinkImportHandoffFor: (_) async {
          refreshCalls += 1;
          return false;
        },
      );

      coordinator.start();
      await coordinator.reconcileNow();
      for (
        var attempt = 0;
        attempt < 30 &&
            (coordinator.tasks.isEmpty ||
                coordinator.tasks.single.phase !=
                    AutomaticOutlinePhase.retryWaiting);
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      expect(refreshCalls, 3);
      expect(
        coordinator.tasks.single.phase,
        AutomaticOutlinePhase.retryWaiting,
      );
      expect(
        coordinator.tasks.single.errorCode,
        'AUTO_OUTLINE_LINK_CLASSIFICATION_UNAVAILABLE',
      );
      coordinator.dispose();
      library.dispose();
    });

    test(
      'does not reuse the import key for a newer media Raw revision',
      () async {
        final note = _note('updated-media-link', V3MaterialSource.link)
            .copyWith(
              rawPartRevisionId: 'raw-media-new',
              summaryBody: 'Outline from the imported media revision',
              outlinePartRevisionId: 'outline-media-old-output',
            );
        const operationId = 'media-outline:ingestion_backend_media_2';
        final tracker = _DerivedTracker(
          initialLedger: <AgentTaskLedgerEntry>[
            _staleLedger(
              note,
              outputRevision: 'outline-media-old-output',
              operationId: operationId,
            ),
          ],
        );
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
          linkImportHandoffFor: (_) =>
              const AutomaticOutlineLinkHandoff.backendMedia(operationId),
        );

        await coordinator.reconcileNow();

        expect(repository.submissions, hasLength(1));
        expect(
          repository.submissions.single.operationId,
          startsWith('auto-outline-v1-'),
        );
        expect(repository.submissions.single.operationId, isNot(operationId));
        expect(
          repository.submissions.single.allowExistingAutomaticOutline,
          isTrue,
        );
        coordinator.dispose();
        library.dispose();
      },
    );

    test('falls back after an expired backend-media failure notice', () async {
      var now = DateTime.utc(2026, 9, 15, 8);
      final note = _note('expired-failure-fence', V3MaterialSource.link);
      const operationId = 'media-outline:ingestion_expired_failure_fence';
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository(
        failureCode: 'OUTLINE_RUN_SUBMIT_FAILED',
        failuresBeforeSuccess: 1,
      );
      final tracker = _DerivedTracker();
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: repository,
        tracker: tracker,
        workspaceScope: 'workspace-1',
        linkBackendGrace: Duration.zero,
        terminalNoticeRetention: const Duration(minutes: 1),
        linkImportHandoffFor: (_) =>
            const AutomaticOutlineLinkHandoff.backendMedia(operationId),
        now: () => now,
      );

      await coordinator.reconcileNow();
      expect(repository.submissions, hasLength(1));
      expect(coordinator.tasks.single.phase, AutomaticOutlinePhase.failed);

      tracker.addLedgerEntry(
        _failedAutomaticLedger(note, operationId: operationId),
      );
      now = now.add(const Duration(minutes: 2));
      await coordinator.reconcileNow();

      expect(coordinator.tasks, isEmpty);
      expect(repository.submissions, hasLength(2));
      expect(
        repository.submissions.last.operationId,
        startsWith('auto-outline-v1-'),
      );
      expect(repository.submissions.last.operationId, isNot(operationId));
      coordinator.dispose();
      library.dispose();
    });

    test(
      'restores a failed automatic fence and admits only a newer Raw revision',
      () async {
        final note = _note('restored-failure-fence', V3MaterialSource.note);
        final operationId = _preparedAdmission(note).operationId;
        final tracker = _DerivedTracker(
          initialLedger: <AgentTaskLedgerEntry>[
            _failedAutomaticLedger(note, operationId: operationId),
          ],
        );
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final restoredRepository = _AcceptedOutlineRepository();
        final restored = AutomaticOutlineCoordinator(
          library: library,
          repository: restoredRepository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );

        await restored.reconcileNow();
        expect(restoredRepository.submissions, isEmpty);

        library.updateNote(
          note.copyWith(
            rawPartRevisionId: 'raw-restored-failure-fence-new',
            updatedAt: note.updatedAt.add(const Duration(minutes: 1)),
          ),
        );
        await restored.reconcileNow();

        expect(restoredRepository.submissions, hasLength(1));
        expect(
          restoredRepository.submissions.single.operationId,
          startsWith('auto-outline-v1-'),
        );
        expect(
          restoredRepository.submissions.single.operationId,
          isNot(operationId),
        );
        restored.dispose();
        library.dispose();
      },
    );

    test('waits when refresh cannot recover its target revision', () async {
      final note = _note(
        'link-missing-target',
        V3MaterialSource.link,
      ).copyWith(clearOutlinePartRevisionId: true);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository();
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: repository,
        tracker: _DerivedTracker(),
        workspaceScope: 'workspace-1',
        linkBackendGrace: const Duration(milliseconds: 1),
        linkOwnershipRetryBaseDelay: const Duration(milliseconds: 1),
        retryBaseDelay: const Duration(hours: 1),
        retryMaximumDelay: const Duration(hours: 1),
      );

      coordinator.start();
      await coordinator.reconcileNow();
      for (
        var attempt = 0;
        attempt < 40 &&
            coordinator.tasks.single.phase !=
                AutomaticOutlinePhase.retryWaiting;
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      expect(repository.submissions, isEmpty);
      expect(
        coordinator.tasks.single.phase,
        AutomaticOutlinePhase.retryWaiting,
      );
      expect(
        coordinator.tasks.single.errorCode,
        'AUTO_OUTLINE_PROJECTION_PENDING',
      );
      coordinator.dispose();
      library.dispose();
    });

    test('link grace submits the refreshed exact target revision', () async {
      final initial = _note(
        'link-refreshed-target',
        V3MaterialSource.link,
      ).copyWith(clearOutlinePartRevisionId: true);
      final refreshed = initial.copyWith(
        outlinePartRevisionId: 'outline-refreshed-target',
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[initial],
        notePort: _RefreshingNotePort(refreshed),
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository();
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: repository,
        tracker: _DerivedTracker(),
        workspaceScope: 'workspace-1',
        linkBackendGrace: const Duration(milliseconds: 1),
      );

      coordinator.start();
      await coordinator.reconcileNow();
      for (
        var attempt = 0;
        attempt < 20 && repository.submissions.isEmpty;
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      expect(repository.submissions, hasLength(1));
      expect(
        repository.submissions.single.note.outlinePartRevisionId,
        'outline-refreshed-target',
      );
      coordinator.dispose();
      library.dispose();
    });

    test(
      'retries the same accepted operation when ledger enrollment is rejected',
      () async {
        final note = _note('tracking-retry', V3MaterialSource.note);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final tracker = _DerivedTracker(rejectionsBeforeSuccess: 1);
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
          retryBaseDelay: const Duration(milliseconds: 1),
          retryMaximumDelay: const Duration(milliseconds: 1),
        );

        await coordinator.reconcileNow();
        for (
          var attempt = 0;
          attempt < 20 && tracker.taskLedger.isEmpty;
          attempt += 1
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }

        expect(repository.submissions, hasLength(1));
        expect(
          repository.submissions.map((submission) => submission.operationId),
          everyElement(repository.submissions.first.operationId),
        );
        expect(tracker.taskLedger.single.localNoteId, note.id);
        expect(repository.trackedRuns, hasLength(1));
        expect(coordinator.tasks, isEmpty);
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'hands off an accepted Run after its Outline target advances',
      () async {
        final note = _note('tracking-after-completion', V3MaterialSource.note);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final tracker = _DerivedTracker(rejectionsBeforeSuccess: 1);
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
          retryBaseDelay: const Duration(milliseconds: 20),
          retryMaximumDelay: const Duration(milliseconds: 20),
        );

        await coordinator.reconcileNow();
        library.updateNote(
          note.copyWith(
            summaryBody: '# 已生成纲要',
            outlinePartRevisionId: 'outline-completed',
            updatedAt: note.updatedAt.add(const Duration(seconds: 1)),
          ),
        );
        for (
          var attempt = 0;
          attempt < 40 && tracker.taskLedger.isEmpty;
          attempt += 1
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }

        expect(repository.submissions, hasLength(1));
        expect(tracker.taskLedger, hasLength(1));
        expect(
          tracker.taskLedger.single.targetPartRevisionId,
          note.outlinePartRevisionId,
        );
        expect(repository.trackedRuns, hasLength(1));
        expect(coordinator.tasks, isEmpty);
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'recovers an accepted handoff after coordinator reconstruction',
      () async {
        final note = _note('tracking-after-restart', V3MaterialSource.note);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final tracker = _DerivedTracker(rejectionsBeforeSuccess: 1);
        final first = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
          retryBaseDelay: const Duration(hours: 1),
          retryMaximumDelay: const Duration(hours: 1),
        );

        await first.reconcileNow();
        library.updateNote(
          note.copyWith(
            summaryBody: '# 已完成',
            outlinePartRevisionId: 'outline-after-restart',
            updatedAt: note.updatedAt.add(const Duration(seconds: 1)),
          ),
        );
        first.dispose();

        final second = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );
        await second.reconcileNow();

        expect(repository.submissions, hasLength(1));
        expect(repository.trackedRuns, hasLength(1));
        expect(tracker.taskLedger, hasLength(1));
        expect(second.tasks, isEmpty);
        second.dispose();
        library.dispose();
      },
    );

    test(
      'rejects a ledger binding with a different operation identity',
      () async {
        final note = _note(
          'tracking-operation-mismatch',
          V3MaterialSource.note,
        );
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final tracker = _DerivedTracker(
          recordedOperationOverride: 'manual-outline-operation',
        );
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();

        expect(repository.submissions, hasLength(1));
        expect(
          coordinator.tasks.single.phase,
          AutomaticOutlinePhase.retryWaiting,
        );
        expect(
          coordinator.tasks.single.errorCode,
          'AUTO_OUTLINE_TRACKING_FAILED',
        );
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'rejects a ledger binding with a different runtime Agent Run',
      () async {
        final note = _note('tracking-agent-mismatch', V3MaterialSource.note);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final tracker = _DerivedTracker(
          recordedAgentRunOverride: 'agent-run-unrelated',
        );
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();

        expect(repository.submissions, hasLength(1));
        expect(
          coordinator.tasks.single.phase,
          AutomaticOutlinePhase.retryWaiting,
        );
        expect(
          coordinator.tasks.single.errorCode,
          'AUTO_OUTLINE_TRACKING_FAILED',
        );
        coordinator.dispose();
        library.dispose();
      },
    );

    test('replaces only a provably stale automatic outline', () async {
      final stale = _note('stale', V3MaterialSource.note).copyWith(
        rawPartRevisionId: 'raw-new',
        summaryBody: 'Outline generated from old Raw',
        outlinePartRevisionId: 'outline-auto-output',
      );
      final userEdited = _note('edited', V3MaterialSource.note).copyWith(
        rawPartRevisionId: 'raw-new',
        summaryBody: 'User edited outline',
        outlinePartRevisionId: 'outline-user-edit',
      );
      final tracker = _DerivedTracker(
        initialLedger: <AgentTaskLedgerEntry>[
          _staleLedger(stale, outputRevision: 'outline-auto-output'),
          _staleLedger(userEdited, outputRevision: 'outline-auto-output'),
        ],
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[stale, userEdited],
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository();
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: repository,
        tracker: tracker,
        workspaceScope: 'workspace-1',
        linkBackendGrace: Duration.zero,
      );

      await coordinator.reconcileNow();

      expect(repository.submissions, hasLength(1));
      expect(repository.submissions.single.note.id, stale.id);

      coordinator.dispose();
      library.dispose();
    });

    test(
      'replays one prepared admission through a reconstructed repository',
      () async {
        final note = _note('prepared-recovery', V3MaterialSource.note);
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        final prepared = _preparedAdmission(note);
        expect(await recovery.putPrepared(prepared), isTrue);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final tracker = _DerivedTracker();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          recoveryStore: recovery,
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();

        expect(repository.submissions, isEmpty);
        expect(repository.replayedAdmissions, <String>[prepared.operationId]);
        expect(tracker.taskLedger, hasLength(1));
        expect(recovery.admissionForRemoteNote(note.remoteNoteId!), isNull);
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'terminalizes a non-retryable recovery and admits a newer Raw revision',
      () async {
        final note = _note('failed-recovery', V3MaterialSource.note);
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        final prepared = _preparedAdmission(note);
        expect(await recovery.putPrepared(prepared), isTrue);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository(
          replayFailureCode: 'OUTLINE_SOURCE_REVISION_CHANGED',
          replayFailuresBeforeSuccess: 1,
        );
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          recoveryStore: recovery,
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();

        expect(recovery.admissionForRemoteNote(note.remoteNoteId!), isNull);
        expect(
          recovery
              .terminalAttemptsForRemoteNote(note.remoteNoteId!)
              .single
              .status,
          'failed',
        );
        expect(
          coordinator.tasks.single.errorCode,
          'OUTLINE_SOURCE_REVISION_CHANGED',
        );
        coordinator.dispose();
        library.dispose();

        final newer = note.copyWith(
          rawBody: '${note.rawBody}\nNew source revision.',
          rawPartRevisionId: '${note.rawPartRevisionId}-new',
        );
        final newerLibrary = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[newer],
          includeDemoFixtures: false,
        );
        final newerRepository = _AcceptedOutlineRepository();
        final newerCoordinator = AutomaticOutlineCoordinator(
          library: newerLibrary,
          repository: newerRepository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          recoveryStore: recovery,
          linkBackendGrace: Duration.zero,
        );

        await newerCoordinator.reconcileNow();

        expect(newerRepository.submissions, hasLength(1));
        newerCoordinator.dispose();
        newerLibrary.dispose();
      },
    );

    test(
      'uncertain submission recovery waits without terminal failure',
      () async {
        final note = _note('uncertain-recovery', V3MaterialSource.note);
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        final prepared = _preparedAdmission(note);
        await recovery.putPrepared(prepared);
        final library = KnowledgeLibraryController(
          initialNotes: [note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository(
          replayFailureCode: 'NETWORK_FAILED',
          replayFailuresBeforeSuccess: 1,
          replayFailureRetryable: true,
        );
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          recoveryStore: recovery,
          retryBaseDelay: const Duration(hours: 1),
        );
        addTearDown(coordinator.dispose);
        addTearDown(library.dispose);
        await coordinator.reconcileNow();
        expect(
          coordinator.tasks.single.phase,
          AutomaticOutlinePhase.retryWaiting,
        );
        expect(
          coordinator.tasks.single.resumePhase,
          AutomaticOutlinePhase.recoveringSubmission,
        );
        expect(recovery.admissionForRemoteNote(note.remoteNoteId!), isNotNull);
        await coordinator.reconcileNow();
        expect(repository.replayedAdmissions, [prepared.operationId]);
        expect(repository.submissions, isEmpty);
      },
    );

    test('orphaned expired recovery releases future Raw revisions', () async {
      final note = _note('expired-recovery', V3MaterialSource.note);
      final recovery = InMemoryAutomaticOutlineRecoveryStore(
        workspaceScope: 'workspace-1',
      );
      final prepared = _preparedAdmission(
        note,
        createdAt: DateTime.utc(2026, 9, 15, 8),
      );
      expect(await recovery.putPrepared(prepared), isTrue);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository();
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: repository,
        tracker: _DerivedTracker(),
        workspaceScope: 'workspace-1',
        recoveryStore: recovery,
        linkBackendGrace: Duration.zero,
        now: () => DateTime.utc(2026, 9, 16, 9),
      );

      await coordinator.reconcileNow();

      expect(repository.replayedAdmissions, isEmpty);
      expect(recovery.admissionForRemoteNote(note.remoteNoteId!), isNull);
      expect(
        recovery
            .terminalAttemptsForRemoteNote(note.remoteNoteId!)
            .single
            .status,
        'orphaned',
      );
      expect(
        coordinator.tasks.single.errorCode,
        'AUTO_OUTLINE_RECOVERY_REQUIRED',
      );
      coordinator.dispose();
      library.dispose();
    });

    test(
      'stale recovery failure cannot clear a newer retry generation',
      () async {
        final note = _note('recovery-generation-race', V3MaterialSource.note);
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        final prepared = _preparedAdmission(note);
        expect(await recovery.putPrepared(prepared), isTrue);
        final replacement = _replacementAdmission(prepared);
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository(
          replayFailureCode: 'OUTLINE_SOURCE_REVISION_CHANGED',
          replayFailuresBeforeSuccess: 1,
          beforeReplayFailure: (admission) async {
            expect(admission.backendAdmissionAttempt, 0);
            expect(
              await recovery.replacePrepared(
                expected: admission,
                replacement: replacement,
              ),
              isTrue,
            );
          },
        );
        final tracker = _DerivedTracker();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          recoveryStore: recovery,
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();

        expect(repository.replayedAdmissions, <String>[
          prepared.operationId,
          replacement.operationId,
        ]);
        expect(repository.replayedBackendAttempts, <int>[0, 1]);
        expect(repository.submissions, isEmpty);
        expect(tracker.taskLedger, hasLength(1));
        expect(recovery.admissionForRemoteNote(note.remoteNoteId!), isNull);
        expect(
          recovery.terminalAttemptsForRemoteNote(note.remoteNoteId!),
          isEmpty,
        );
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'stale ordinary submit failure cannot clear a newer retry generation',
      () async {
        final note = _note('submit-generation-race', V3MaterialSource.note);
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _DelayedPreparedFailureRepository(recovery);
        final tracker = _DerivedTracker();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          recoveryStore: recovery,
          linkBackendGrace: Duration.zero,
        );

        final reconciliation = coordinator.reconcileNow();
        final prepared = await repository.firstPrepared;
        final replacement = _replacementAdmission(prepared);
        expect(
          await recovery.replacePrepared(
            expected: prepared,
            replacement: replacement,
          ),
          isTrue,
        );
        repository.releaseFailure();
        await reconciliation;

        expect(repository.replayedBackendAttempts, <int>[1]);
        expect(tracker.taskLedger, hasLength(1));
        expect(recovery.admissionForRemoteNote(note.remoteNoteId!), isNull);
        expect(
          recovery.terminalAttemptsForRemoteNote(note.remoteNoteId!),
          isEmpty,
        );
        expect(coordinator.tasks, isEmpty);
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'uses durable provenance after the terminal ledger is absent',
      () async {
        final note = _note('durable-stale', V3MaterialSource.note).copyWith(
          rawPartRevisionId: 'raw-durable-new',
          summaryBody: 'Outline generated from an older Raw revision',
          outlinePartRevisionId: 'outline-durable-output',
        );
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        expect(
          await recovery.putTerminal(
            AutomaticOutlineTerminalRecord(
              attemptId: automaticOutlineAttemptId(
                workspaceScope: 'workspace-1',
                remoteNoteId: note.remoteNoteId!,
                inputRawRevisionId: 'raw-durable-old',
                targetOutlineRevisionId: 'outline-durable-before',
              ),
              remoteNoteId: note.remoteNoteId!,
              operationId: 'auto-outline-v1-durable-stale-old',
              inputRawRevisionId: 'raw-durable-old',
              targetOutlineRevisionId: 'outline-durable-before',
              status: 'succeeded',
              outputOutlineRevisionId: 'outline-durable-output',
              recordedAt: DateTime.utc(2026, 9, 15, 7),
            ),
          ),
          isTrue,
        );
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: _DerivedTracker(),
          workspaceScope: 'workspace-1',
          recoveryStore: recovery,
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();

        expect(repository.submissions, hasLength(1));
        expect(
          repository.submissions.single.allowExistingAutomaticOutline,
          isTrue,
        );
        coordinator.dispose();
        library.dispose();
      },
    );

    test(
      'does not let a failed manual task suppress automatic admission',
      () async {
        final note = _note('manual-failed', V3MaterialSource.note);
        final tracker = _DerivedTracker(
          initialLedger: <AgentTaskLedgerEntry>[
            AgentTaskLedgerEntry.derivedPart(
              taskId: 'manual-failed-run',
              localNoteId: note.id,
              remoteNoteId: note.remoteNoteId,
              targetPart: NoteFileAgentPart.outline,
              status: 'failed',
              createdAt: DateTime.utc(2026, 9, 15, 7),
              inputPartRevisionId: note.rawPartRevisionId,
              targetPartRevisionId: note.outlinePartRevisionId,
              operationId: 'manual-outline-operation',
            ),
          ],
        );
        final library = KnowledgeLibraryController(
          initialNotes: <V3FeedItem>[note],
          includeDemoFixtures: false,
        );
        final repository = _AcceptedOutlineRepository();
        final coordinator = AutomaticOutlineCoordinator(
          library: library,
          repository: repository,
          tracker: tracker,
          workspaceScope: 'workspace-1',
          linkBackendGrace: Duration.zero,
        );

        await coordinator.reconcileNow();

        expect(repository.submissions, hasLength(1));
        coordinator.dispose();
        library.dispose();
      },
    );

    test('classifies a link without a local draft for client fallback', () {
      final handoff = automaticOutlineLinkHandoffForDrafts(
        _note('cross-device-link', V3MaterialSource.link),
        const <MaterialIngestionDraft>[],
      );

      expect(handoff.owner, MaterialLinkOutlineOwner.client);
      expect(handoff.operationId, isNull);
    });

    test(
      'late media terminal cannot clear a client fallback admission',
      () async {
        final note = _note('late-media-terminal', V3MaterialSource.link);
        final recovery = InMemoryAutomaticOutlineRecoveryStore(
          workspaceScope: 'workspace-1',
        );
        final fallback = _preparedAdmission(note);
        final mediaTerminal = AutomaticOutlineTerminalRecord(
          attemptId: fallback.attemptId,
          remoteNoteId: fallback.remoteNoteId,
          operationId: 'media-outline:ingestion_late_media_terminal',
          inputRawRevisionId: fallback.inputRawRevisionId,
          targetOutlineRevisionId: fallback.targetOutlineRevisionId,
          status: 'failed',
          fileAgentRunId: 'file-media-failed',
          recordedAt: DateTime.utc(2026, 9, 15, 7),
        );

        expect(await recovery.putTerminal(mediaTerminal), isTrue);
        expect(await recovery.putPrepared(fallback), isTrue);
        expect(
          await recovery.putTerminal(
            AutomaticOutlineTerminalRecord(
              attemptId: mediaTerminal.attemptId,
              remoteNoteId: mediaTerminal.remoteNoteId,
              operationId: mediaTerminal.operationId,
              inputRawRevisionId: mediaTerminal.inputRawRevisionId,
              targetOutlineRevisionId: mediaTerminal.targetOutlineRevisionId,
              status: mediaTerminal.status,
              fileAgentRunId: mediaTerminal.fileAgentRunId,
              recordedAt: DateTime.utc(2026, 9, 15, 8),
            ),
          ),
          isTrue,
        );
        expect(
          recovery.admissionForRemoteNote(note.remoteNoteId!)?.operationId,
          fallback.operationId,
        );
      },
    );
  });

  test(
    'automatic Outline recovery survives a database reopen and is scoped',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'automatic-outline-recovery-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final snapshot = File('${root.path}/local-db.json');
      final note = _note('disk-recovery', V3MaterialSource.note);
      final prepared = _preparedAdmission(note);
      final first = AutomaticOutlineRecoveryStoreRegistry(
        AppPreferencesDao(
          AppDatabase(
            snapshotStore: LocalDatabaseSnapshotStore(file: snapshot),
          ),
        ),
      ).scoped(accountScope: 'account-a', workspaceScope: 'workspace-1');

      expect(await first.putPrepared(prepared), isTrue);

      final reopenedRegistry = AutomaticOutlineRecoveryStoreRegistry(
        AppPreferencesDao(
          AppDatabase(
            snapshotStore: LocalDatabaseSnapshotStore(file: snapshot),
          ),
        ),
      );
      final reopened = reopenedRegistry.scoped(
        accountScope: 'account-a',
        workspaceScope: 'workspace-1',
      );
      final restored = reopened.admissionForRemoteNote(note.remoteNoteId!);
      expect(restored?.operationId, prepared.operationId);
      expect(restored?.request.instruction, prepared.request.instruction);
      expect(restored?.request.idempotencyKey, prepared.request.idempotencyKey);
      expect(
        reopenedRegistry
            .scoped(accountScope: 'account-a', workspaceScope: 'workspace-2')
            .admissionForRemoteNote(note.remoteNoteId!),
        isNull,
      );
      expect(
        reopenedRegistry
            .scoped(accountScope: 'account-b', workspaceScope: 'workspace-1')
            .admissionForRemoteNote(note.remoteNoteId!),
        isNull,
      );
    },
  );
}

V3FeedItem _note(
  String id,
  V3MaterialSource source, {
  String? recordingId,
  V3NoteOwnership ownership = V3NoteOwnership.mine,
}) {
  final createdAt = DateTime.utc(2026, 9, 15, 8);
  return V3FeedItem(
    id: id,
    title: 'Asset $id',
    source: source,
    ownership: ownership,
    createdAt: createdAt,
    updatedAt: createdAt,
    rawBody: 'Durable original content for $id',
    recordingId: recordingId,
    remoteNoteId: 'remote-$id',
    rawPartRevisionId: 'raw-$id',
    outlinePartRevisionId: 'outline-empty-$id',
    syncState: NoteSyncState.synced,
  );
}

AgentTaskLedgerEntry _staleLedger(
  V3FeedItem note, {
  required String outputRevision,
  String? operationId,
}) => AgentTaskLedgerEntry.derivedPart(
  taskId: 'old-${note.id}',
  localNoteId: note.id,
  remoteNoteId: note.remoteNoteId,
  targetPart: NoteFileAgentPart.outline,
  status: 'succeeded',
  createdAt: DateTime.utc(2026, 9, 15, 7),
  subjectTitle: note.title,
  inputPartRevisionId: 'raw-old',
  targetPartRevisionId: 'outline-before-old-run',
  outputPartRevisionId: outputRevision,
  operationId: operationId ?? 'auto-outline-v1-old-${note.id}',
);

AgentTaskLedgerEntry _failedAutomaticLedger(
  V3FeedItem note, {
  required String operationId,
}) => AgentTaskLedgerEntry.derivedPart(
  taskId: 'failed-${note.id}',
  localNoteId: note.id,
  remoteNoteId: note.remoteNoteId,
  targetPart: NoteFileAgentPart.outline,
  status: 'failed',
  createdAt: DateTime.utc(2026, 9, 15, 7),
  failureCode: 'OUTLINE_RUN_FAILED',
  subjectTitle: note.title,
  inputPartRevisionId: note.rawPartRevisionId,
  targetPartRevisionId: note.outlinePartRevisionId,
  operationId: operationId,
);

AutomaticOutlinePreparedAdmission _preparedAdmission(
  V3FeedItem note, {
  DateTime? createdAt,
}) {
  final attemptId = automaticOutlineAttemptId(
    workspaceScope: 'workspace-1',
    remoteNoteId: note.remoteNoteId!,
    inputRawRevisionId: note.rawPartRevisionId!,
    targetOutlineRevisionId: note.outlinePartRevisionId,
  );
  final operationId = 'auto-outline-v1-${attemptId.substring(0, 48)}';
  return AutomaticOutlinePreparedAdmission(
    attemptId: attemptId,
    localNoteId: note.id,
    operationId: operationId,
    request: NoteFileAgentRequest(
      noteId: note.remoteNoteId!,
      inputPart: NoteFileAgentPart.raw,
      inputPartRevisionId: note.rawPartRevisionId!,
      targetPart: NoteFileAgentPart.outline,
      targetPartRevisionId: note.outlinePartRevisionId!,
      instruction: 'Create a faithful outline from the exact source.',
      selector: const NoteFileAgentSelector(
        agentProfileId: 'general_minutes',
        skillProfileIds: <String>['general_minutes'],
      ),
      idempotencyKey: 'detail-outline-$operationId',
    ),
    allowExistingAutomaticOutline: false,
    createdAt: createdAt ?? DateTime.now().toUtc(),
  );
}

AutomaticOutlinePreparedAdmission _replacementAdmission(
  AutomaticOutlinePreparedAdmission admission,
) {
  final nextAttempt = admission.backendAdmissionAttempt + 1;
  final request = admission.request;
  return AutomaticOutlinePreparedAdmission(
    attemptId: admission.attemptId,
    localNoteId: admission.localNoteId,
    operationId: admission.operationId,
    request: NoteFileAgentRequest(
      noteId: request.noteId,
      inputPart: request.inputPart,
      inputPartRevisionId: request.inputPartRevisionId,
      targetPart: request.targetPart,
      targetPartRevisionId: request.targetPartRevisionId,
      instruction: request.instruction,
      selector: request.selector,
      idempotencyKey: automaticOutlineRequestIdempotencyKey(
        admission.operationId,
        backendAdmissionAttempt: nextAttempt,
      )!,
      modelProfileId: request.modelProfileId,
    ),
    allowExistingAutomaticOutline: admission.allowExistingAutomaticOutline,
    createdAt: admission.createdAt,
    backendAdmissionAttempt: nextAttempt,
  );
}

final class _AcceptedOutlineRepository
    implements
        AcceptedOutlineRunRepository,
        AutomaticOutlineAdmissionReplayPort,
        OutlineAdmissionTrackingPort,
        PendingOutlineAdmissionPort {
  _AcceptedOutlineRepository({
    this.failureCode,
    this.failuresBeforeSuccess = -1,
    this.failureRetryable = false,
    this.replayFailureCode,
    this.replayFailuresBeforeSuccess = 0,
    this.replayFailureRetryable = false,
    this.beforeReplayFailure,
    this.beforeSubmitFailure,
  });

  final String? failureCode;
  final Future<void> Function()? beforeSubmitFailure;
  final bool failureRetryable;
  int failuresBeforeSuccess;
  final String? replayFailureCode;
  final bool replayFailureRetryable;
  int replayFailuresBeforeSuccess;
  final Future<void> Function(AutomaticOutlinePreparedAdmission admission)?
  beforeReplayFailure;
  final List<
    ({V3FeedItem note, String operationId, bool allowExistingAutomaticOutline})
  >
  submissions = [];
  final List<NoteFileAgentRunSnapshot> trackedRuns =
      <NoteFileAgentRunSnapshot>[];
  final List<String> replayedAdmissions = <String>[];
  final List<int> replayedBackendAttempts = <int>[];
  PendingOutlineAdmission? _pendingAdmission;

  @override
  void markOutlineAdmissionTracked(NoteFileAgentRunSnapshot accepted) {
    trackedRuns.add(accepted);
    if (_pendingAdmission?.accepted?.fileAgentRunId ==
        accepted.fileAgentRunId) {
      _pendingAdmission = null;
    }
  }

  @override
  PendingOutlineAdmission? pendingOutlineAdmission(V3FeedItem note) =>
      _pendingAdmission;

  @override
  String? pendingOutlineOperationId(V3FeedItem note) =>
      _pendingAdmission?.operationId;

  @override
  Future<NoteFileAgentRunSnapshot> replayAutomaticAdmission(
    AutomaticOutlinePreparedAdmission admission,
  ) async {
    replayedAdmissions.add(admission.operationId);
    replayedBackendAttempts.add(admission.backendAdmissionAttempt);
    if (replayFailureCode case final code?
        when replayFailuresBeforeSuccess != 0) {
      if (replayFailuresBeforeSuccess > 0) replayFailuresBeforeSuccess -= 1;
      await beforeReplayFailure?.call(admission);
      throw OutlineGenerationException(
        code,
        isRetryable: replayFailureRetryable,
        recoveryAdmission: admission,
      );
    }
    final accepted = NoteFileAgentRunSnapshot(
      fileAgentRunId: 'file-${admission.operationId}',
      noteId: admission.remoteNoteId,
      status: 'queued',
      agentRunId: 'agent-run-${admission.operationId}',
      inputPart: NoteFileAgentPart.raw,
      inputPartRevisionId: admission.inputRawRevisionId,
      targetPart: NoteFileAgentPart.outline,
      targetPartRevisionId: admission.targetOutlineRevisionId,
    );
    _pendingAdmission = PendingOutlineAdmission(
      operationId: admission.operationId,
      accepted: accepted,
    );
    return accepted;
  }

  @override
  Future<NoteFileAgentRunSnapshot> submit(
    V3FeedItem note, {
    required String operationId,
    bool allowExistingAutomaticOutline = false,
  }) async {
    submissions.add((
      note: note,
      operationId: operationId,
      allowExistingAutomaticOutline: allowExistingAutomaticOutline,
    ));
    if (failureCode case final code?
        when failuresBeforeSuccess < 0 || failuresBeforeSuccess > 0) {
      if (failuresBeforeSuccess > 0) failuresBeforeSuccess -= 1;
      await beforeSubmitFailure?.call();
      throw OutlineGenerationException(code, isRetryable: failureRetryable);
    }
    final accepted = NoteFileAgentRunSnapshot(
      fileAgentRunId: 'file-$operationId',
      noteId: note.remoteNoteId!,
      status: 'queued',
      agentRunId: 'agent-run-$operationId',
      inputPart: NoteFileAgentPart.raw,
      inputPartRevisionId: note.rawPartRevisionId!,
      targetPart: NoteFileAgentPart.outline,
      targetPartRevisionId:
          note.outlinePartRevisionId ?? 'outline-empty-${note.id}',
    );
    _pendingAdmission = PendingOutlineAdmission(
      operationId: operationId,
      accepted: accepted,
    );
    return accepted;
  }
}

final class _DelayedPreparedFailureRepository
    implements
        AcceptedOutlineRunRepository,
        AutomaticOutlineAdmissionReplayPort {
  _DelayedPreparedFailureRepository(this.recoveryStore);

  final AutomaticOutlineRecoveryStorePort recoveryStore;
  final Completer<AutomaticOutlinePreparedAdmission> _firstPrepared =
      Completer<AutomaticOutlinePreparedAdmission>();
  final Completer<void> _releaseFailure = Completer<void>();
  final List<int> replayedBackendAttempts = <int>[];

  Future<AutomaticOutlinePreparedAdmission> get firstPrepared =>
      _firstPrepared.future;

  void releaseFailure() {
    if (!_releaseFailure.isCompleted) _releaseFailure.complete();
  }

  @override
  Future<NoteFileAgentRunSnapshot> submit(
    V3FeedItem note, {
    required String operationId,
    bool allowExistingAutomaticOutline = false,
  }) async {
    final prepared = _preparedAdmission(note);
    expect(prepared.operationId, operationId);
    expect(await recoveryStore.putPrepared(prepared), isTrue);
    if (!_firstPrepared.isCompleted) _firstPrepared.complete(prepared);
    await _releaseFailure.future;
    throw OutlineGenerationException(
      'OUTLINE_SOURCE_REVISION_CHANGED',
      recoveryAdmission: prepared,
    );
  }

  @override
  Future<NoteFileAgentRunSnapshot> replayAutomaticAdmission(
    AutomaticOutlinePreparedAdmission admission,
  ) async {
    replayedBackendAttempts.add(admission.backendAdmissionAttempt);
    return NoteFileAgentRunSnapshot(
      fileAgentRunId: 'file-${admission.operationId}-retry',
      noteId: admission.remoteNoteId,
      status: 'queued',
      agentRunId: 'agent-run-${admission.operationId}-retry',
      inputPart: NoteFileAgentPart.raw,
      inputPartRevisionId: admission.inputRawRevisionId,
      targetPart: NoteFileAgentPart.outline,
      targetPartRevisionId: admission.targetOutlineRevisionId,
    );
  }
}

final class _RefreshingNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  const _RefreshingNotePort(this.note);

  final V3FeedItem note;

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() async =>
      KnowledgeNoteRemoteLoadResult.success(<V3FeedItem>[note]);

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

final class _DerivedTracker
    implements
        DerivedPartRunTrackingPort,
        AgentTaskLedgerPort,
        AgentTaskSubjectMetadataPort {
  _DerivedTracker({
    List<AgentTaskLedgerEntry> initialLedger = const [],
    this.rejectionsBeforeSuccess = 0,
    this.recordedOperationOverride,
    this.recordedAgentRunOverride,
  }) : _ledger = <AgentTaskLedgerEntry>[...initialLedger];

  final List<AgentTaskLedgerEntry> _ledger;
  final Map<String, String> subjects = <String, String>{};
  int rejectionsBeforeSuccess;
  final String? recordedOperationOverride;
  final String? recordedAgentRunOverride;

  void addLedgerEntry(AgentTaskLedgerEntry entry) {
    _ledger.removeWhere((current) => current.taskId == entry.taskId);
    _ledger.add(entry);
  }

  @override
  List<AgentTaskLedgerEntry> get taskLedger =>
      List<AgentTaskLedgerEntry>.unmodifiable(_ledger);

  @override
  DerivedPartRunCompletion? get lastDerivedCompletion => null;

  @override
  List<AgentRunToolTrace> derivedPartToolTrace(
    String localNoteId,
    NoteFileAgentPart targetPart,
  ) => const <AgentRunToolTrace>[];

  @override
  String? derivedPartStatus(String localNoteId, NoteFileAgentPart targetPart) =>
      null;

  @override
  bool isDerivedPartPending(String localNoteId, NoteFileAgentPart targetPart) =>
      _ledger.any(
        (entry) =>
            entry.localNoteId == localNoteId &&
            entry.targetPart == targetPart &&
            !entry.isTerminal,
      );

  @override
  Future<void> rememberChatThreadSubject({
    required String threadId,
    required String subjectTitle,
  }) async {}

  @override
  Future<void> rememberKnowledgeAssetSubject({
    required String localNoteId,
    required String subjectTitle,
  }) async {
    subjects[localNoteId] = subjectTitle;
  }

  @override
  Future<void> trackDerivedPart({
    required String fileAgentRunId,
    String? agentRunId,
    String? status,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {
    if (rejectionsBeforeSuccess > 0) {
      rejectionsBeforeSuccess -= 1;
      return;
    }
    _ledger.removeWhere((entry) => entry.taskId == fileAgentRunId);
    _ledger.add(
      AgentTaskLedgerEntry.derivedPart(
        taskId: fileAgentRunId,
        agentRunId: recordedAgentRunOverride ?? agentRunId,
        localNoteId: localNoteId,
        remoteNoteId: remoteNoteId,
        targetPart: targetPart,
        status: status ?? 'queued',
        createdAt: DateTime.utc(2026, 9, 15, 8),
        subjectTitle: subjects[localNoteId],
        inputPartRevisionId: inputPartRevisionId,
        targetPartRevisionId: targetPartRevisionId,
        operationId: recordedOperationOverride ?? operationId,
      ),
    );
  }
}
