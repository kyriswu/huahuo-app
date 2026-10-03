import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_task_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  test(
    'audit: cancelled preparation cannot cancel a later selection owner',
    () async {
      final harness = _Harness();
      final sourceGate = Completer<void>();
      harness.notes.loadGate = sourceGate;
      final firstOwner = Object();
      final nextOwner = Object();
      final firstPreparation = harness.task.prepareSelection(owner: firstOwner);
      await _until(() => harness.notes.loadCalls == 1);
      harness.task.cancelSelection(owner: firstOwner);
      expect(harness.task.phase, FeedAggregationPhase.idle);
      expect(harness.task.busy, isFalse);
      final nextPreparation = harness.task.prepareSelection(owner: nextOwner);
      harness.task.cancelSelection(owner: firstOwner);
      expect(harness.task.ownsSelection(nextOwner), isTrue);
      expect(harness.task.busy, isTrue);
      sourceGate.complete();
      expect(await firstPreparation, isFalse);
      expect(await nextPreparation, isTrue);
      expect(harness.task.canConfirm, isTrue);
      harness.task.cancelSelection(owner: firstOwner);
      expect(harness.task.phase, FeedAggregationPhase.selecting);
      final response = Completer<ApiResult<TopicCollisionRun>>();
      harness.remote.onSubmit = () => response.future;
      final submitting = harness.task.confirm();
      harness.task.cancelSelection(owner: nextOwner);
      expect(harness.task.phase, FeedAggregationPhase.submitting);
      response.complete(_success(_run('queued')));
      await submitting;
      expect(harness.remote.keys, hasLength(1));
    },
  );

  for (final paused in [false, true]) {
    test(
      'audit: late success cannot cross wait ownership paused=$paused',
      () async {
        final harness = _Harness(
          maxForegroundWait: const Duration(milliseconds: 25),
        );
        harness.notes.output = _output();
        harness.remote.onSubmit = () async => _success(_run('queued'));
        final response = Completer<ApiResult<TopicCollisionRun>>();
        harness.remote.onGet = () => response.future;
        harness.task.startSelection();
        await harness.task.confirm();
        harness.attach();
        await _until(() => harness.remote.readRunIds.isNotEmpty);
        if (paused) harness.task.pause();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final expected = paused
            ? FeedAggregationPhase.queued
            : FeedAggregationPhase.blocked;
        expect(harness.task.phase, expected);
        response.complete(_success(_run('succeeded')));
        await _until(() => !harness.task.busy);
        expect(harness.task.phase, expected);
        expect(harness.task.generatedNote, isNull);
        harness.remote.onGet = () async => _success(_run('dead_letter'));
        if (paused) {
          harness.task.resume();
        } else {
          await harness.task.retry();
        }
        await _until(() => harness.task.phase == FeedAggregationPhase.failed);
        expect(harness.remote.readRunIds.toSet(), {'run-1'});
        expect(harness.remote.keys, hasLength(1));
      },
    );
  }

  test(
    'audit: queued polling still obeys its foreground wait budget',
    () async {
      final harness = _Harness(
        maxForegroundWait: const Duration(milliseconds: 25),
      );
      harness.remote.onSubmit = () async => _success(_run('queued'));
      harness.task.startSelection();
      await harness.task.confirm();
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const {TaskResource.network: 1},
      );
      final metrics = RuntimeActivityMetrics();
      addTearDown(orchestrator.dispose);
      addTearDown(metrics.dispose);
      final blocker = Completer<void>();
      final blocked = orchestrator.schedule<void>(
        TaskSpec(
          key: 'test:blocked-network',
          owner: 'test',
          priority: TaskPriority.userBlocking,
          resources: const {TaskResource.network},
        ),
        (_) => blocker.future,
      );
      harness.task.attachPollingRuntime(
        orchestrator: orchestrator,
        activityMetrics: metrics,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final phase = harness.task.phase;
      final error = harness.task.errorCode;
      final reads = harness.remote.readRunIds.length;
      harness.task.pause();
      blocker.complete();
      await blocked;
      expect(reads, 0);
      expect(phase, FeedAggregationPhase.blocked);
      expect(error, 'AGGREGATION_WAIT_PAUSED');
      expect(harness.remote.keys, hasLength(1));
    },
  );

  test(
    'audit: an unreadable current output cannot still project success',
    () async {
      final harness = _Harness();
      harness.notes.output = _output();
      harness.remote.onSubmit = () async => _success(_run('succeeded'));
      harness.task.startSelection();
      await harness.task.confirm();
      harness.library.updateNote(_output().copyWith(rawBody: ''));
      expect(
        harness.task.taskNotices.single.phase,
        FeedAggregationPhase.blocked,
      );
      expect(harness.task.taskNotices.single.note, isNull);
      expect(harness.task.hasUnresolvedTask, isFalse);
    },
  );

  test(
    'audit: recovered historical output clears obsolete sync errors',
    () async {
      final harness = _Harness(maxOutputReads: 1);
      harness.notes.output = _output();
      harness.remote.onSubmit = () async => _success(_run('succeeded'));
      harness.task.startSelection();
      await harness.task.confirm();
      harness.library.deleteNote('output-local');
      harness.notes.output = null;
      await harness.task.retry();
      expect(harness.task.errorCode, 'AGGREGATION_OUTPUT_PENDING');
      harness.task.startSelection();
      harness.library.updateNote(_output());
      final notice = harness.task.taskNotices.single;
      expect(notice.phase, FeedAggregationPhase.succeeded);
      expect(notice.errorCode, isNull);
      expect(notice.message, contains('已同步'));
    },
  );

  test(
    'task notices retain terminal history across selection and cold restore',
    () async {
      final harness = _Harness(maxOutputReads: 1);
      expect(harness.task.taskNotices, isEmpty);
      harness.task.startSelection();
      expect(harness.task.taskNotices, isEmpty);
      harness.remote.onSubmit = () async => _success(_run('succeeded'));
      final submitting = harness.task.confirm();
      final reference = harness.task.taskNotices.single.reference;
      expect(
        harness.task.taskNotices.single.phase,
        FeedAggregationPhase.submitting,
      );
      await submitting;
      expect(
        harness.task.taskNotices.single.phase,
        FeedAggregationPhase.blocked,
      );
      expect(harness.task.taskNotices.single.note, isNull);
      expect(harness.task.hasUnresolvedTask, isTrue);
      harness.notes.output = _output();
      await harness.task.retry();
      expect(harness.task.taskNotices.single.reference, reference);
      expect(
        harness.task.taskNotices.single.phase,
        FeedAggregationPhase.succeeded,
      );
      harness.task.startSelection();
      expect(harness.task.taskNotices.single.reference, reference);
      expect(harness.task.taskNotices.single.isCurrent, isFalse);
      harness.task.cancelSelection();
      expect(harness.task.taskNotices.single.note?.remoteNoteId, 'output-note');
      harness.task.startSelection();
      harness.remote.onSubmit = () async => _failure('INVALID_ARGUMENT', 400);
      await harness.task.confirm();
      expect(harness.task.taskNotices, hasLength(2));
      expect(harness.record['settledTasks'], hasLength(1));
      final restored = _Harness(database: harness.database);
      restored.library.updateNote(_output());
      expect(restored.task.taskNotices, hasLength(2));
      expect(restored.task.taskNotices.first.reference, reference);
      expect(
        restored.task.taskNotices.first.phase,
        FeedAggregationPhase.succeeded,
      );
      restored.library.deleteNote(restored.task.taskNotices.first.note!.id);
      expect(
        restored.task.taskNotices.first.phase,
        FeedAggregationPhase.blocked,
      );
      expect(
        restored.task.taskNotices.first.errorCode,
        'AGGREGATION_OUTPUT_UNAVAILABLE',
      );
      expect(restored.remote.keys, isEmpty);
      final preferences = AppPreferencesDao(harness.database);
      final saved = harness.record;
      ((saved['settledTasks']! as List).first as Map)['sources'] = [];
      preferences.upsertValue(
        preferenceKey:
            preferences.listPreferences().firstWhere(
                  (entry) => (entry['preference_key']! as String).startsWith(
                    'topic-collision-',
                  ),
                )['preference_key']!
                as String,
        value: jsonEncode(saved),
        updatedAt: harness.now.toIso8601String(),
      );
      final legacy = _Harness(database: harness.database);
      expect(legacy.task.taskNotices, hasLength(2));
      expect(legacy.task.taskNotices.first.sources, isEmpty);
      expect(legacy.task.taskNotices.first.sourceCount, 4);
      expect(legacy.remote.keys, isEmpty);
    },
  );

  test('selection reacts to library eligibility without submitting', () async {
    final harness = _Harness();
    harness.task.startSelection();
    var changes = 0;
    harness.task.addListener(() => changes++);
    expect(harness.task.canReshuffle, isFalse);
    harness.library.updateNote(_note(12));
    expect(changes, greaterThan(0));
    expect(harness.task.canReshuffle, isTrue);
    harness.library.deleteNote(harness.task.selectedNoteIds.first);
    expect(harness.task.phase, FeedAggregationPhase.failed);
    expect(harness.task.errorCode, 'AGGREGATION_SELECTION_CHANGED');
    expect(harness.task.message, contains('尚未提交'));
    await harness.task.confirm();
    expect(harness.remote.keys, isEmpty);
    expect(harness.task.startSelection(), isTrue);
    await harness.task.confirm();
    final acceptedRunId = harness.task.taskId;
    harness.library.deleteNote(harness.task.selectedNoteIds.first);
    expect(harness.task.phase, FeedAggregationPhase.running);
    expect(harness.task.taskId, acceptedRunId);
    expect(harness.remote.keys, hasLength(1));
  });

  test(
    'selection uses four unique synced public identities and rejects derived outputs',
    () {
      final harness = _Harness();
      harness.library.updateNote(_note(8).copyWith(remoteNoteId: 'remote-0'));
      harness.library.updateNote(
        _note(9).copyWith(remoteSourceKind: 'topic_collision'),
      );
      harness.library.updateNote(_note(10).copyWith(rawBody: ' '));
      harness.library.updateNote(
        _note(11).copyWith(syncState: NoteSyncState.pending),
      );
      expect(harness.task.eligibleNotes, hasLength(4));
      expect(harness.task.startSelection(), isTrue);
      expect(harness.task.canConfirm, isTrue);
      harness.task.toggleNote(harness.task.selectedNoteIds.first);
      expect(harness.task.canConfirm, isFalse);
      harness.task.cancelSelection();
      expect(harness.task.phase, FeedAggregationPhase.idle);
      expect(harness.remote.keys, isEmpty);
    },
  );

  test(
    'intent is durable before POST; double confirmation cannot submit twice',
    () async {
      final harness = _Harness();
      final gate = Completer<ApiResult<TopicCollisionRun>>();
      harness.remote.onSubmit = () async {
        final record = harness.record;
        expect(record['idempotencyKey'], harness.remote.keys.single);
        expect(record['phase'], 'submitting');
        return gate.future;
      };
      expect(harness.task.startSelection(), isTrue);
      final selected = harness.task.selectedNoteIds;
      final flight = harness.task.confirm();
      await harness.task.confirm();
      await _until(() => harness.remote.keys.isNotEmpty);
      expect(harness.task.startSelection(), isFalse);
      expect(harness.remote.keys, hasLength(1));
      expect(harness.remote.selections.single.toSet(), {
        'remote-0',
        'remote-1',
        'remote-2',
        'remote-3',
      });
      gate.complete(_success(_run('running')));
      await flight;
      expect(harness.task.phase, FeedAggregationPhase.running);
      expect(harness.task.selectedNoteIds, selected);
      expect(harness.task.run!.sources, isEmpty);
    },
  );

  test(
    'uncertain acceptance retries the same immutable intent and key',
    () async {
      final harness = _Harness();
      harness.remote.onSubmit = () async => throw TimeoutException('test');
      harness.task.startSelection();
      await harness.task.confirm();
      expect(harness.task.phase, FeedAggregationPhase.submissionUncertain);
      expect(harness.task.startSelection(), isFalse);
      harness.remote.onSubmit = () async => _success(_run('queued'));
      await harness.task.retry();
      expect(harness.remote.keys, hasLength(2));
      expect(harness.remote.keys.toSet(), hasLength(1));
      expect(harness.remote.selections[0], harness.remote.selections[1]);
      expect(harness.task.phase, FeedAggregationPhase.queued);
    },
  );

  test(
    'unparseable acceptance remains uncertain and cannot start a second intent',
    () async {
      final harness = _Harness();
      harness.remote.onSubmit = () async =>
          _failure('API_RESPONSE_INVALID', 202);
      harness.task.startSelection();
      await harness.task.confirm();
      expect(harness.task.phase, FeedAggregationPhase.submissionUncertain);
      expect(harness.task.startSelection(), isFalse);
      expect(harness.record['idempotencyKey'], isNotNull);
    },
  );

  test(
    'definite invalid arguments end only that intent and explain the sources',
    () async {
      final harness = _Harness();
      harness.remote.onSubmit = () async => _failure('INVALID_ARGUMENT', 400);
      harness.task.startSelection();
      await harness.task.confirm();
      expect(harness.task.phase, FeedAggregationPhase.failed);
      expect(harness.task.message, contains('四篇'));
      expect(harness.task.message, isNot(contains('检查网络')));
      harness.task.startSelection();
      await harness.task.confirm();
      expect(harness.remote.keys.toSet(), hasLength(2));
    },
  );

  test('each public nonterminal state maps explicitly', () async {
    for (final entry in {
      'queued': FeedAggregationPhase.queued,
      'leased': FeedAggregationPhase.leased,
      'admitting': FeedAggregationPhase.admitting,
      'running': FeedAggregationPhase.running,
      'retry_wait': FeedAggregationPhase.retryWaiting,
    }.entries) {
      final harness = _Harness();
      harness.remote.onSubmit = () async => _success(_run(entry.key));
      harness.task.startSelection();
      await harness.task.confirm();
      expect(harness.task.phase, entry.value);
      expect(harness.task.hasUnresolvedTask, isTrue);
    }
  });

  test('server terminal failures never synthesize an output', () async {
    for (final status in ['failed', 'dead_letter']) {
      final harness = _Harness();
      harness.remote.onSubmit = () async => _success(_run(status));
      harness.task.startSelection();
      await harness.task.confirm();
      expect(harness.task.phase, FeedAggregationPhase.failed);
      expect(harness.task.generatedNote, isNull);
      expect(harness.task.startSelection(), isTrue);
    }
  });

  test(
    'generated output must be readable; retry sync never submits a new run',
    () async {
      final harness = _Harness(maxOutputReads: 1);
      harness.remote.onSubmit = () async => _success(_run('succeeded'));
      harness.task.startSelection();
      await harness.task.confirm();
      expect(harness.task.phase, FeedAggregationPhase.blocked);
      expect(harness.task.errorCode, 'AGGREGATION_OUTPUT_PENDING');
      expect(harness.task.completedTaskId, isNull);
      harness.notes.output = _output();
      await harness.task.retry();
      expect(harness.task.phase, FeedAggregationPhase.succeeded);
      expect(harness.task.generatedNote!.remoteNoteId, 'output-note');
      expect(harness.remote.keys, hasLength(1));
      expect(harness.record['phase'], 'succeeded');
      harness.task.dismissCompletion();
      expect(harness.task.phase, FeedAggregationPhase.idle);
      expect(harness.record['dismissed'], isTrue);
    },
  );

  test('empty output body cannot be reported as success', () async {
    final harness = _Harness(maxOutputReads: 1);
    harness.notes.output = _output().copyWith(rawBody: ' ');
    harness.remote.onSubmit = () async => _success(_run('succeeded'));
    harness.task.startSelection();
    await harness.task.confirm();
    expect(harness.task.phase, FeedAggregationPhase.blocked);
    expect(harness.task.generatedNote, isNull);
  });

  test(
    'cold start retains uncertain submission without automatically sending it',
    () async {
      final first = _Harness();
      first.remote.onSubmit = () async => throw TimeoutException('test');
      first.task.startSelection();
      await first.task.confirm();
      final second = _Harness(database: first.database);
      expect(second.task.phase, FeedAggregationPhase.submissionUncertain);
      expect(second.remote.keys, isEmpty);
      await second.task.retry();
      expect(second.remote.keys.single, first.remote.keys.single);
    },
  );

  test(
    'cold start of accepted run reads the same task and keeps original selection',
    () async {
      final first = _Harness();
      first.task.startSelection();
      await first.task.confirm();
      final second = _Harness(database: first.database);
      second.remote.onGet = () async => _success(_run('succeeded'));
      second.notes.output = _output();
      second.attach();
      await _until(() => second.task.phase == FeedAggregationPhase.succeeded);
      expect(second.remote.keys, isEmpty);
      expect(second.remote.readRunIds.toSet(), {'run-1'});
      expect(second.task.selectedNoteIds, first.task.selectedNoteIds);
    },
  );

  test(
    'cold restoration queries every unfinished status without claiming queued',
    () async {
      for (final status in [
        'queued',
        'leased',
        'admitting',
        'running',
        'retry_wait',
      ]) {
        final first = _Harness();
        first.remote.onSubmit = () async => _success(_run(status));
        first.task.startSelection();
        await first.task.confirm();
        first.task.dispose();
        final restored = _Harness(database: first.database);
        expect(restored.task.phase, FeedAggregationPhase.restoring);
        expect(restored.task.title, '正在恢复聚合进度');
        expect(restored.task.run!.status, status);
        expect(restored.task.selectedNoteIds, first.task.selectedNoteIds);
        expect(restored.task.startSelection(), isFalse);
        restored.remote.onGet = () async => _success(_run('dead_letter'));
        restored.attach();
        await _until(() => restored.task.phase == FeedAggregationPhase.failed);
        expect(restored.remote.readRunIds.toSet(), {'run-1'});
        expect(restored.remote.keys, isEmpty);
        expect(restored.task.generatedNote, isNull);
      }
    },
  );

  test(
    'resuming a blocked task waits for GET instead of replaying cached progress',
    () async {
      final harness = _Harness(maxReadFailures: 1);
      harness.task.startSelection();
      await harness.task.confirm();
      harness.remote.onGet = () async => _failure('NETWORK_ERROR', 503);
      harness.attach();
      await _until(
        () =>
            harness.task.phase == FeedAggregationPhase.blocked &&
            !harness.task.busy,
      );
      final query = Completer<ApiResult<TopicCollisionRun>>();
      harness.remote.onGet = () => query.future;
      await harness.task.retry();
      expect(harness.task.phase, FeedAggregationPhase.restoring);
      expect(harness.task.message, contains('实际进度'));
      query.complete(_success(_run('dead_letter')));
      await _until(() => harness.task.phase == FeedAggregationPhase.failed);
      expect(harness.remote.keys, hasLength(1));
      expect(harness.remote.readRunIds.toSet(), {'run-1'});
    },
  );

  test(
    'uncertain submissions beyond the server window are not replayed',
    () async {
      final harness = _Harness();
      harness.remote.onSubmit = () async => throw TimeoutException('test');
      harness.task.startSelection();
      await harness.task.confirm();
      harness.now = harness.now.add(const Duration(hours: 24));
      await harness.task.retry();
      expect(harness.task.errorCode, 'AGGREGATION_IDEMPOTENCY_EXPIRED');
      expect(harness.task.canResume, isFalse);
      expect(harness.remote.keys, hasLength(1));
    },
  );

  test(
    'task references survive acceptance but cannot cross into a new intent',
    () async {
      final harness = _Harness();
      harness.remote.onSubmit = () async => _success(_run('dead_letter'));
      harness.task.startSelection();
      final submission = harness.task.confirm();
      final intentId = harness.task.taskId!;
      await submission;
      expect(harness.task.matchesTaskReference(intentId), isTrue);
      expect(harness.task.matchesTaskReference('run-1'), isTrue);
      expect(harness.task.matchesTaskReference(null), isFalse);
      expect(harness.task.matchesTaskReference(''), isFalse);
      expect(harness.task.startSelection(), isTrue);
      expect(harness.task.matchesTaskReference(intentId), isFalse);
      expect(harness.task.matchesTaskReference('run-1'), isFalse);
    },
  );

  test(
    'a removed active result blocks then synchronizes the same output',
    () async {
      final harness = _Harness(maxOutputReads: 1);
      harness.notes.output = _output();
      harness.remote.onSubmit = () async => _success(_run('succeeded'));
      harness.task.startSelection();
      await harness.task.confirm();
      harness.library.deleteNote('output-local');
      expect(harness.task.phase, FeedAggregationPhase.blocked);
      expect(harness.task.errorCode, 'AGGREGATION_OUTPUT_UNAVAILABLE');
      expect(harness.task.generatedNote, isNull);
      expect(harness.task.completedTaskId, isNull);
      expect(harness.task.hasUnresolvedTask, isFalse);
      await Future<void>.delayed(Duration.zero);
      await harness.task.retry();
      expect(harness.task.phase, FeedAggregationPhase.succeeded);
      expect(harness.task.generatedNote!.remoteNoteId, 'output-note');
      expect(harness.remote.keys, hasLength(1));
      harness.library.deleteNote('output-local');
      expect(harness.task.phase, FeedAggregationPhase.blocked);
      harness.notes.output = null;
      await harness.task.retry();
      expect(harness.task.errorCode, 'AGGREGATION_OUTPUT_PENDING');
      expect(harness.task.hasUnresolvedTask, isFalse);
      expect(harness.record['publishedOutputNoteId'], 'output-note');
      final restored = _Harness(database: harness.database);
      expect(restored.task.hasUnresolvedTask, isFalse);
      expect(restored.task.taskNotices.single.note, isNull);
      expect(harness.task.startSelection(), isTrue);
      expect(harness.task.taskNotices, hasLength(1));
      expect(harness.task.taskNotices.single.isCurrent, isFalse);
      expect(
        harness.task.taskNotices.single.phase,
        FeedAggregationPhase.blocked,
      );
      expect(harness.task.taskNotices.single.note, isNull);
      harness.task.cancelSelection();
      expect(harness.task.hasUnresolvedTask, isFalse);
    },
  );

  test(
    'a dismissed result can disappear without blocking new selection',
    () async {
      final harness = _Harness();
      harness.notes.output = _output();
      harness.remote.onSubmit = () async => _success(_run('succeeded'));
      harness.task.startSelection();
      await harness.task.confirm();
      harness.task.dismissCompletion();
      harness.library.deleteNote('output-local');
      expect(harness.task.phase, FeedAggregationPhase.idle);
      expect(harness.task.hasUnresolvedTask, isFalse);
    },
  );

  test(
    'late response after workspace switch cannot complete or overwrite the task',
    () async {
      final harness = _Harness();
      final gate = Completer<ApiResult<TopicCollisionRun>>();
      harness.remote.onSubmit = () => gate.future;
      harness.task.startSelection();
      final flight = harness.task.confirm();
      harness.workspace = 'other-workspace';
      gate.complete(_success(_run('succeeded')));
      await flight;
      expect(harness.task.phase, FeedAggregationPhase.blocked);
      expect(harness.task.generatedNote, isNull);
      expect(harness.task.errorCode, 'AGGREGATION_WORKSPACE_CHANGED');
    },
  );

  test(
    'read authorization errors block instead of pretending the run failed',
    () async {
      final harness = _Harness();
      harness.remote.onGet = () async => _failure('FORBIDDEN', 403);
      harness.task.startSelection();
      await harness.task.confirm();
      harness.attach();
      await _until(() => harness.task.phase == FeedAggregationPhase.blocked);
      expect(harness.task.run!.topicCollisionRunId, 'run-1');
      expect(harness.task.hasUnresolvedTask, isTrue);
      expect(harness.task.startSelection(), isFalse);
    },
  );

  test('bounded read failures pause then resume GET, never POST', () async {
    final harness = _Harness(maxReadFailures: 2);
    harness.remote.onGet = () async => _failure('NETWORK_ERROR', 503);
    harness.task.startSelection();
    await harness.task.confirm();
    harness.attach();
    await _until(() => harness.task.phase == FeedAggregationPhase.blocked);
    final reads = harness.remote.readRunIds.length;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(harness.remote.readRunIds, hasLength(reads));
    harness.remote.onGet = () async => _success(_run('succeeded'));
    harness.notes.output = _output();
    await harness.task.retry();
    await _until(() => harness.task.phase == FeedAggregationPhase.succeeded);
    expect(harness.remote.keys, hasLength(1));
  });

  test('no checkpoint storage means no request can leave the device', () {
    final harness = _Harness(withStorage: false);
    expect(harness.task.startSelection(), isFalse);
    expect(harness.task.phase, FeedAggregationPhase.blocked);
    expect(harness.task.errorCode, 'AGGREGATION_STORAGE_FAILED');
    expect(harness.remote.keys, isEmpty);
  });

  test(
    'disk write failure prevents POST until the original intent is saved',
    () async {
      final store = _FailingStore()..failWrites = true;
      final harness = _Harness(database: AppDatabase(snapshotStore: store));
      harness.task.startSelection();
      await harness.task.confirm();
      expect(harness.task.errorCode, 'AGGREGATION_STORAGE_FAILED');
      expect(harness.remote.keys, isEmpty);
      store.failWrites = false;
      await harness.task.retry();
      expect(harness.task.phase, FeedAggregationPhase.running);
      expect(harness.remote.keys, hasLength(1));
    },
  );

  test(
    'failed completion checkpoint cannot publish success or resubmit generation',
    () async {
      final store = _FailingStore()..failCompletion = true;
      final harness = _Harness(database: AppDatabase(snapshotStore: store));
      harness.notes.output = _output();
      harness.remote.onSubmit = () async => _success(_run('succeeded'));
      harness.task.startSelection();
      await harness.task.confirm();
      expect(harness.task.errorCode, 'AGGREGATION_STORAGE_FAILED');
      expect(harness.task.completedTaskId, isNull);
      store.failCompletion = false;
      await harness.task.retry();
      expect(harness.task.phase, FeedAggregationPhase.succeeded);
      expect(harness.remote.keys, hasLength(1));
    },
  );

  test(
    'persistent diagnostics identify the failed phase without private content',
    () async {
      final dao = DiagnosticLogDao(AppDatabase());
      final logger = DiagnosticLogger(dao: dao);
      addTearDown(logger.dispose);
      final harness = _Harness(logger: logger);
      harness.remote.onSubmit = () async => _failure('INVALID_ARGUMENT', 400);
      harness.task.startSelection();
      await harness.task.confirm();
      final events = dao
          .query()
          .where((event) => event.category == 'feed_ai')
          .toList();
      expect(
        events.any((event) => event.redactedMetadata['stage'] == 'submitting'),
        isTrue,
      );
      final failed = events.firstWhere(
        (event) => event.redactedMetadata['stage'] == 'failed',
      );
      expect(failed.redactedMetadata['error_code'], 'INVALID_ARGUMENT');
      expect(failed.redactedMetadata['scope_hash'], isNotNull);
      expect(failed.redactedMetadata.containsKey('workspace_id'), isFalse);
      expect(jsonEncode(failed.redactedMetadata), isNot(contains('正文')));
    },
  );
}

final class _Harness {
  _Harness({
    AppDatabase? database,
    bool withStorage = true,
    int maxReadFailures = 5,
    int maxOutputReads = 10,
    Duration maxForegroundWait = const Duration(minutes: 10),
    DiagnosticLogger? logger,
  }) : database = database ?? AppDatabase() {
    notes = _Notes();
    library = KnowledgeLibraryController(
      initialNotes: [for (var index = 0; index < 4; index++) _note(index)],
      includeDemoFixtures: false,
      notePort: notes,
    );
    task = FeedAggregationTaskController(
      library: library,
      profileHub: ProfileHubController(referenceDay: now),
      remote: remote,
      preferences: withStorage ? AppPreferencesDao(this.database) : null,
      userScope: 'test-user',
      workspaceId: () => workspace,
      workspaceReady: () => true,
      diagnosticLogger: logger,
      now: () => now,
      random: Random(11),
      pollInterval: const Duration(milliseconds: 2),
      maxReadFailures: maxReadFailures,
      maxOutputReads: maxOutputReads,
      maxForegroundWait: maxForegroundWait,
    );
    addTearDown(() {
      task.dispose();
      library.dispose();
    });
  }
  final AppDatabase database;
  final _Remote remote = _Remote();
  late final _Notes notes;
  late final KnowledgeLibraryController library;
  late final FeedAggregationTaskController task;
  DateTime now = DateTime.utc(2026, 9, 5, 18);
  String workspace = 'workspace-test';
  Map<String, Object?> get record {
    final records = AppPreferencesDao(database).listPreferences();
    final record = records.firstWhere(
      (entry) =>
          (entry['preference_key'] as String).startsWith('topic-collision-'),
    );
    return jsonDecode(record['value']! as String) as Map<String, Object?>;
  }

  void attach() {
    final orchestrator = TaskOrchestrator();
    final metrics = RuntimeActivityMetrics();
    addTearDown(() {
      orchestrator.dispose();
      metrics.dispose();
    });
    task.attachPollingRuntime(
      orchestrator: orchestrator,
      activityMetrics: metrics,
    );
  }
}

final class _FailingStore extends LocalDatabaseSnapshotStore {
  _FailingStore() : super(file: File('/tmp/unused-aggregation-test-store'));
  bool failWrites = false;
  bool failCompletion = false;
  @override
  LocalDatabaseSnapshot? load() => null;
  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    final completed =
        (tables[LocalTableName.appPreferences]?.values ??
                <LocalDatabaseRecord>[])
            .any(
              (record) =>
                  (record['value'] as String?)?.contains(
                    '"phase":"succeeded"',
                  ) ==
                  true,
            );
    if (failWrites || (failCompletion && completed)) {
      throw const FileSystemException('test disk full');
    }
  }
}

final class _Remote implements TopicCollisionRunPort {
  final List<String> keys = [];
  final List<List<String>> selections = [];
  final List<String> readRunIds = [];
  Future<ApiResult<TopicCollisionRun>> Function()? onSubmit;
  Future<ApiResult<TopicCollisionRun>> Function()? onGet;
  @override
  Future<ApiResult<TopicCollisionRun>> submit(
    String workspaceId, {
    required List<String> noteIds,
    required String idempotencyKey,
  }) {
    keys.add(idempotencyKey);
    selections.add(List.of(noteIds));
    return onSubmit?.call() ?? Future.value(_success(_run('running')));
  }

  @override
  Future<ApiResult<TopicCollisionRun>> get(String workspaceId, String runId) {
    readRunIds.add(runId);
    return onGet?.call() ?? Future.value(_success(_run('running')));
  }
}

final class _Notes implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  V3FeedItem? output;
  Completer<void>? loadGate;
  int loadCalls = 0;
  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() async {
    loadCalls++;
    await loadGate?.future;
    return KnowledgeNoteRemoteLoadResult.success([
      for (var index = 0; index < 4; index++) _note(index),
      if (output != null) output!,
    ]);
  }

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

V3FeedItem _note(int index) => V3FeedItem(
  id: 'local-$index',
  remoteNoteId: 'remote-$index',
  remoteSourceKind: 'manual',
  rawPartRevisionId: 'raw-$index',
  title: '来源 $index',
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 9, 5),
  rawBody: '正文 $index',
);
V3FeedItem _output() => V3FeedItem(
  id: 'output-local',
  remoteNoteId: 'output-note',
  remoteSourceKind: 'topic_collision',
  rawPartRevisionId: 'raw-output',
  title: '聚合结果',
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 9, 5),
  rawBody: '# 云端输出\n\n正式结果',
);
TopicCollisionRun _run(String status) => TopicCollisionRun(
  topicCollisionRunId: 'run-1',
  workspaceId: 'workspace-test',
  stage: status,
  status: status,
  selectedNoteCount: 4,
  outputNoteId: status == 'succeeded' ? 'output-note' : null,
  failureCode: status == 'failed' || status == 'dead_letter'
      ? 'PROVIDER_FAILED'
      : null,
);
ApiResult<TopicCollisionRun> _success(TopicCollisionRun run) =>
    ApiResult.success(
      data: run,
      status: 202,
      idempotencyStore: SubmissionKeyStore.empty,
    );
ApiResult<TopicCollisionRun> _failure(String code, int status) =>
    ApiResult.failure(
      status: status,
      error: AppFailure(
        code: code,
        category: AppFailureCategory.api,
        message: code,
        userMessageKey: 'error.test',
      ),
      idempotencyStore: SubmissionKeyStore.empty,
    );
Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 80 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue);
}
