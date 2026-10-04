// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/recordings/application/recording_batch_transcription_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_processing_tracker.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/data/recording_batch_transcription_store.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_batch_transcription.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_transcription_receipt.dart';

void main() {
  group('RecordingBatchTranscriptionController', () {
    test(
      'freezes zero and one item before multi-file classification',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.controller.dispose);

        final empty = await fixture.controller.startSelection(const []);
        final single = await fixture.controller.startSelection(
          <RecordingTranscriptionCandidate>[_candidate('one')],
        );

        expect(empty.kind, RecordingTranscriptionDispatchKind.disabled);
        expect(single.kind, RecordingTranscriptionDispatchKind.single);
        expect(
          single.single?.classification,
          RecordingTranscriptionClassification.eligible,
        );
        expect(fixture.controller.state.batches, isEmpty);
        expect(fixture.execution.submitCalls, 0);
      },
    );

    test(
      'single retryExisting retries the original recording without a batch or upload',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.controller.dispose);

        final dispatch = await fixture.controller
            .startSelection(<RecordingTranscriptionCandidate>[
              _candidate(
                'retry-one',
                remoteRecordingId: 'remote-retry-one',
                remoteFact: RecordingTranscriptionRemoteFact.retryableFailure,
                retryable: true,
              ),
            ]);

        expect(dispatch.kind, RecordingTranscriptionDispatchKind.single);
        expect(
          dispatch.single?.classification,
          RecordingTranscriptionClassification.retryExisting,
        );
        expect(fixture.execution.retriedRemoteRecordingIds, <String>[
          'remote-retry-one',
        ]);
        expect(fixture.execution.retryCalls, 1);
        expect(fixture.execution.submitCalls, 0);
        expect(fixture.store.values, isEmpty);
        expect(fixture.controller.state.batches, isEmpty);
      },
    );

    test(
      'previews exact immutable counts without writes and starts that snapshot',
      () async {
        final now = DateTime.utc(2026, 9, 4, 8);
        final fixture = _Fixture(now: () => now);
        addTearDown(fixture.controller.dispose);
        final completedAt = now.subtract(const Duration(minutes: 1));

        final preview = await fixture.controller
            .previewSelection(<RecordingTranscriptionCandidate>[
              _candidate('new'),
              _candidate(
                'processing',
                remoteRecordingId: 'remote-processing',
                remoteFact: RecordingTranscriptionRemoteFact.processing,
              ),
              _candidate(
                'done',
                remoteRecordingId: 'remote-done',
                remoteFact: RecordingTranscriptionRemoteFact.assetReady,
                noteId: 'note-done',
                transcriptCompletedAt: completedAt,
                assetReadyAt: completedAt,
              ),
              _candidate(
                'retry',
                remoteRecordingId: 'remote-retry',
                remoteFact: RecordingTranscriptionRemoteFact.retryableFailure,
                retryable: true,
              ),
              _candidate('missing', localFileAvailable: false),
              _candidate('new'),
            ]);

        expect(preview.counts.total, 5);
        expect(preview.counts.willSubmit, 1);
        expect(preview.counts.willObserve, 1);
        expect(preview.counts.willSkip, 1);
        expect(preview.counts.needsAttention, 2);
        expect(() => preview.candidates.clear(), throwsUnsupportedError);
        expect(() => preview.items.clear(), throwsUnsupportedError);
        expect(fixture.store.values, isEmpty);
        expect(fixture.receipts.values, isEmpty);
        expect(fixture.execution.submitCalls, 0);

        fixture.receipts.save(
          RecordingTranscriptionReceipt(
            userScope: 'account-a',
            fileIdentity: 'hash-new',
            localRecordingId: 'new',
            remoteRecordingId: 'remote-new-elsewhere',
            transcriptCompletedAt: now,
            assetReadyAt: now,
            noteId: 'note-new-elsewhere',
            updatedAt: now,
          ),
        );
        final dispatch = await fixture.controller.startPreview(preview);

        expect(dispatch.kind, RecordingTranscriptionDispatchKind.batch);
        expect(
          dispatch.batch!.itemFor('new')!.status,
          RecordingBatchTranscriptionItemStatus.pending,
        );
        expect(
          dispatch.batch!.itemFor('done')!.status,
          RecordingBatchTranscriptionItemStatus.skipped,
        );
        expect(
          fixture.receipts.findByRemoteRecordingId('remote-done'),
          isNotNull,
        );
        await expectLater(
          fixture.controller.startPreview(preview),
          throwsA(
            isA<RecordingBatchTranscriptionException>().having(
              (error) => error.code,
              'code',
              'RECORDING_TRANSCRIPTION_PREVIEW_ALREADY_STARTED',
            ),
          ),
        );
      },
    );

    test('rejects a preview from another account or workspace', () async {
      final fixture = _Fixture();
      addTearDown(fixture.controller.dispose);
      final preview = await fixture.controller.previewSelection(
        <RecordingTranscriptionCandidate>[_candidate('one'), _candidate('two')],
      );
      final foreign = RecordingTranscriptionSelectionPreview(
        previewId: '${preview.previewId}-foreign',
        accountScope: preview.accountScope,
        workspaceScope: 'workspace-other',
        createdAt: preview.createdAt,
        candidates: preview.candidates,
        items: preview.items,
      );

      await expectLater(
        fixture.controller.startPreview(foreign),
        throwsA(
          isA<RecordingBatchTranscriptionException>().having(
            (error) => error.code,
            'code',
            'RECORDING_TRANSCRIPTION_PREVIEW_SCOPE_MISMATCH',
          ),
        ),
      );
      expect(fixture.store.values, isEmpty);
    });

    test('rejects a concurrent start before consuming its preview', () async {
      final fixture = _Fixture();
      addTearDown(fixture.controller.dispose);
      final first = await fixture.controller.previewSelection(
        <RecordingTranscriptionCandidate>[_candidate('one'), _candidate('two')],
      );
      final second = await fixture.controller.previewSelection(
        <RecordingTranscriptionCandidate>[_candidate('three')],
      );
      final flushGate = Completer<void>();
      fixture.store.flushGate = flushGate;

      final firstStart = fixture.controller.startPreview(first);
      await _waitFor(() => fixture.controller.state.isCreating);
      await expectLater(
        fixture.controller.startPreview(second),
        throwsA(
          isA<RecordingBatchTranscriptionException>().having(
            (error) => error.code,
            'code',
            'RECORDING_TRANSCRIPTION_START_IN_PROGRESS',
          ),
        ),
      );

      flushGate.complete();
      await firstStart;
      fixture.store.flushGate = null;
      final secondStart = await fixture.controller.startPreview(second);
      expect(secondStart.kind, RecordingTranscriptionDispatchKind.single);
    });

    test(
      'keeps multi-file routing when items become skipped or unavailable',
      () async {
        final receipts = _MemoryReceiptStore();
        final now = DateTime.utc(2026, 9, 4, 8);
        receipts.save(
          RecordingTranscriptionReceipt(
            userScope: 'account-a',
            fileIdentity: 'hash-done',
            contentHash: 'hash-done',
            localRecordingId: 'done',
            remoteRecordingId: 'remote-done',
            noteId: 'note-done',
            transcriptCompletedAt: now,
            assetReadyAt: now,
            updatedAt: now,
          ),
        );
        final fixture = _Fixture(receipts: receipts, now: () => now);
        addTearDown(fixture.controller.dispose);

        final dispatch = await fixture.controller
            .startSelection(<RecordingTranscriptionCandidate>[
              _candidate('done', contentHash: 'hash-done'),
              _candidate('missing', localFileAvailable: false),
            ]);

        expect(dispatch.kind, RecordingTranscriptionDispatchKind.batch);
        final batch = fixture.controller.state.batches.single;
        expect(
          batch.items[0].status,
          RecordingBatchTranscriptionItemStatus.skipped,
        );
        expect(
          batch.items[1].status,
          RecordingBatchTranscriptionItemStatus.failed,
        );
        expect(batch.items[1].isUnavailable, isTrue);
        expect(
          batch.status,
          RecordingBatchTranscriptionStatus.completedWithIssues,
        );
        expect(batch.counts.skipped, 1);
        expect(batch.counts.unavailable, 1);
        expect(fixture.execution.submitCalls, 0);
      },
    );

    test(
      'keeps a history-only item in a mixed batch without uploading it',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.controller.dispose);

        final preview = await fixture.controller
            .previewSelection(<RecordingTranscriptionCandidate>[
              _candidate('ordinary'),
              _candidate('history', transcriptionNotRequired: true),
            ]);

        expect(preview.counts.total, 2);
        expect(preview.counts.willSubmit, 1);
        expect(preview.counts.willSkip, 1);

        final dispatch = await fixture.controller.startPreview(preview);

        expect(dispatch.kind, RecordingTranscriptionDispatchKind.batch);
        expect(
          dispatch.batch?.itemFor('history')?.status,
          RecordingBatchTranscriptionItemStatus.skipped,
        );
        await _waitFor(() => fixture.execution.submitCalls == 1);
        expect(fixture.execution.submitCalls, 1);
      },
    );

    test('limits new submissions to two while retaining stable jobs', () async {
      final execution = _ExecutionPort(gatedSubmissions: true);
      final fixture = _Fixture(execution: execution);
      addTearDown(fixture.controller.dispose);

      final dispatch = await fixture.controller.startSelection(
        <RecordingTranscriptionCandidate>[
          _candidate('one'),
          _candidate('two'),
          _candidate('three'),
        ],
      );
      final batchId = dispatch.batch!.batchId;
      await _waitFor(() => execution.activeSubmissions == 2);
      expect(execution.maximumActiveSubmissions, 2);

      execution.release('one');
      execution.release('two');
      await _waitFor(() => execution.submitCalls == 3);
      expect(execution.maximumActiveSubmissions, 2);
      execution.release('three');
      await fixture.controller.waitUntilIdle(batchId);

      final batch = fixture.controller.state.batchFor(batchId)!;
      expect(
        batch.items.map((item) => item.status),
        everyElement(RecordingBatchTranscriptionItemStatus.processing),
      );
      expect(
        batch.items.map((item) => item.observationDeadlineAt),
        everyElement(DateTime.utc(2026, 9, 5, 8)),
      );
      expect(batch.items.map((item) => item.attemptCount), everyElement(1));
    });

    test('retries an existing remote recording then verifies it', () async {
      final now = DateTime.utc(2026, 9, 4, 8);
      final verificationGate = Completer<RecordingBatchAuthoritativeUpdate>();
      final execution = _ExecutionPort(
        verification: (item) {
          expect(
            item.waitingReason,
            RecordingBatchWaitingReason.remoteVerificationRequired,
          );
          return verificationGate.future;
        },
      );
      final fixture = _Fixture(execution: execution);
      addTearDown(fixture.controller.dispose);

      final dispatch = await fixture.controller
          .startSelection(<RecordingTranscriptionCandidate>[
            _candidate(
              'retry',
              remoteRecordingId: 'remote-retry',
              remoteFact: RecordingTranscriptionRemoteFact.retryableFailure,
              retryable: true,
            ),
            _candidate('missing', localFileAvailable: false),
          ]);
      await _waitFor(() => execution.verifyCalls == 1);
      expect(
        fixture.controller.state
            .batchFor(dispatch.batch!.batchId)!
            .itemFor('retry')!
            .waitingReason,
        RecordingBatchWaitingReason.remoteVerificationRequired,
      );
      verificationGate.complete(
        RecordingBatchAuthoritativeUpdate(
          state: RecordingBatchAuthoritativeState.processing,
          checkedAt: now,
          remoteRecordingId: 'remote-retry',
        ),
      );
      await fixture.controller.waitUntilIdle(dispatch.batch!.batchId);

      final retried = fixture.controller.state
          .batchFor(dispatch.batch!.batchId)!
          .itemFor('retry')!;
      expect(execution.retryCalls, 1);
      expect(execution.verifyCalls, 1);
      expect(execution.submitCalls, 0);
      expect(retried.remoteRecordingId, 'remote-retry');
      expect(retried.status, RecordingBatchTranscriptionItemStatus.processing);
      expect(retried.attemptCount, 1);
      expect(retried.observationDeadlineAt, DateTime.utc(2026, 9, 5, 8));
    });

    test('rejects a changed remote id from a multi-file retry', () async {
      final execution = _ExecutionPort(
        retry: (_) async => const RecordingBatchSubmissionResult.accepted(
          remoteRecordingId: 'remote-other',
        ),
      );
      final fixture = _Fixture(execution: execution);
      addTearDown(fixture.controller.dispose);

      final dispatch = await fixture.controller
          .startSelection(<RecordingTranscriptionCandidate>[
            _candidate(
              'retry',
              remoteRecordingId: 'remote-retry',
              remoteFact: RecordingTranscriptionRemoteFact.retryableFailure,
              retryable: true,
            ),
            _candidate('missing', localFileAvailable: false),
          ]);
      await fixture.controller.waitUntilIdle(dispatch.batch!.batchId);

      final retried = fixture.controller.state
          .batchFor(dispatch.batch!.batchId)!
          .itemFor('retry')!;
      expect(retried.remoteRecordingId, 'remote-retry');
      expect(retried.status, RecordingBatchTranscriptionItemStatus.failed);
      expect(
        retried.errorCode,
        'RECORDING_TRANSCRIPTION_RETRY_IDENTITY_MISMATCH',
      );
      expect(retried.retryable, isFalse);
      expect(retried.attemptCount, 0);
      expect(execution.verifyCalls, 0);
      expect(execution.submitCalls, 0);
    });

    test(
      'schedules another authority read when no tracker checkpoint owns it',
      () async {
        final now = DateTime.utc(2026, 9, 4, 8);
        var authorityReads = 0;
        final execution = _ExecutionPort(
          verification: (item) async {
            authorityReads += 1;
            if (authorityReads == 1) {
              return RecordingBatchAuthoritativeUpdate(
                state: RecordingBatchAuthoritativeState.processing,
                checkedAt: now,
                remoteRecordingId: item.remoteRecordingId,
                progress: 25,
                waitingReason:
                    RecordingBatchWaitingReason.remoteVerificationRequired,
              );
            }
            return RecordingBatchAuthoritativeUpdate(
              state: RecordingBatchAuthoritativeState.assetReady,
              checkedAt: now.add(const Duration(seconds: 1)),
              remoteRecordingId: item.remoteRecordingId,
              noteId: 'note-legacy',
              progress: 100,
              transcriptCompletedAt: now.add(const Duration(seconds: 1)),
              assetReadyAt: now.add(const Duration(seconds: 1)),
            );
          },
        );
        final fixture = _Fixture(
          execution: execution,
          now: () => now,
          remoteVerificationInterval: const Duration(milliseconds: 1),
        );
        addTearDown(fixture.controller.dispose);

        final dispatch = await fixture.controller
            .startSelection(<RecordingTranscriptionCandidate>[
              _candidate(
                'legacy',
                remoteRecordingId: 'remote-legacy',
                remoteFact: RecordingTranscriptionRemoteFact.processing,
              ),
              _candidate('missing', localFileAvailable: false),
            ]);
        await _waitFor(
          () =>
              fixture.controller.state
                  .batchFor(dispatch.batch!.batchId)
                  ?.itemFor('legacy')
                  ?.status ==
              RecordingBatchTranscriptionItemStatus.completed,
          delay: const Duration(milliseconds: 1),
        );

        expect(execution.verifyCalls, 2);
        expect(execution.submitCalls, 0);
      },
    );

    test('detects network recovery without another lifecycle event', () async {
      final now = DateTime.utc(2026, 9, 4, 8);
      var authorityReads = 0;
      final execution = _ExecutionPort(
        verification: (item) async {
          authorityReads += 1;
          if (authorityReads == 1) {
            return RecordingBatchAuthoritativeUpdate(
              state: RecordingBatchAuthoritativeState.temporarilyUnavailable,
              checkedAt: now,
              remoteRecordingId: item.remoteRecordingId,
              waitingReason: RecordingBatchWaitingReason.networkRequired,
            );
          }
          return RecordingBatchAuthoritativeUpdate(
            state: RecordingBatchAuthoritativeState.assetReady,
            checkedAt: now.add(const Duration(seconds: 1)),
            remoteRecordingId: item.remoteRecordingId,
            noteId: 'note-recovered',
            transcriptCompletedAt: now.add(const Duration(seconds: 1)),
            assetReadyAt: now.add(const Duration(seconds: 1)),
          );
        },
      );
      final fixture = _Fixture(
        execution: execution,
        now: () => now,
        remoteVerificationInterval: const Duration(milliseconds: 1),
      );
      addTearDown(fixture.controller.dispose);

      final dispatch = await fixture.controller
          .startSelection(<RecordingTranscriptionCandidate>[
            _candidate(
              'legacy',
              remoteRecordingId: 'remote-legacy',
              remoteFact: RecordingTranscriptionRemoteFact.unknown,
            ),
            _candidate('missing', localFileAvailable: false),
          ]);
      await _waitFor(
        () =>
            fixture.controller.state
                .batchFor(dispatch.batch!.batchId)
                ?.itemFor('legacy')
                ?.status ==
            RecordingBatchTranscriptionItemStatus.completed,
        delay: const Duration(milliseconds: 1),
      );

      expect(execution.verifyCalls, 2);
      expect(execution.submitCalls, 0);
    });

    test(
      'coalesces foreground recovery and only verifies existing remotes',
      () async {
        final gate = Completer<void>();
        var authorityReads = 0;
        final now = DateTime.utc(2026, 9, 4, 8);
        final execution = _ExecutionPort(
          verification: (item) async {
            authorityReads += 1;
            if (authorityReads == 1) {
              return RecordingBatchAuthoritativeUpdate(
                state: RecordingBatchAuthoritativeState.temporarilyUnavailable,
                checkedAt: now,
                remoteRecordingId: item.remoteRecordingId,
                waitingReason: RecordingBatchWaitingReason.networkRequired,
              );
            }
            await gate.future;
            return RecordingBatchAuthoritativeUpdate(
              state: RecordingBatchAuthoritativeState.processing,
              checkedAt: now.add(const Duration(minutes: 1)),
              remoteRecordingId: item.remoteRecordingId,
            );
          },
        );
        final fixture = _Fixture(execution: execution, now: () => now);
        addTearDown(fixture.controller.dispose);

        final dispatch = await fixture.controller
            .startSelection(<RecordingTranscriptionCandidate>[
              _candidate(
                'legacy',
                remoteRecordingId: 'remote-legacy',
                remoteFact: RecordingTranscriptionRemoteFact.unknown,
              ),
              _candidate('missing', localFileAvailable: false),
            ]);
        await fixture.controller.waitUntilIdle(dispatch.batch!.batchId);

        final first = fixture.controller.resumePendingRemoteVerifications();
        final second = fixture.controller.resumePendingRemoteVerifications();
        expect(identical(first, second), isTrue);
        await _waitFor(() => execution.verifyCalls == 2);
        expect(execution.submitCalls, 0);
        gate.complete();
        expect(await first, 1);
        expect(await second, 1);
      },
    );

    test(
      'joins concurrent restore and foreground verification recovery',
      () async {
        final now = DateTime.utc(2026, 9, 4, 8);
        final fixture = _Fixture(now: () => now);
        addTearDown(fixture.controller.dispose);
        fixture.store.values['restored-batch'] =
            RecordingBatchTranscriptionSnapshot(
              batchId: 'restored-batch',
              accountScope: 'account-a',
              workspaceScope: 'workspace-a',
              primaryItemId: 'legacy',
              items: <RecordingBatchTranscriptionItem>[
                _batchItem(
                  'legacy',
                  now,
                  status: RecordingBatchTranscriptionItemStatus.pending,
                  remoteRecordingId: 'remote-legacy',
                  waitingReason: RecordingBatchWaitingReason.networkRequired,
                ),
                _batchItem(
                  'missing',
                  now,
                  status: RecordingBatchTranscriptionItemStatus.failed,
                  failureCategory: RecordingBatchFailureCategory.unavailable,
                ),
              ],
              createdAt: now,
              updatedAt: now,
            );

        final firstRestore = fixture.controller.restore();
        final secondRestore = fixture.controller.restore();
        final recovered = fixture.controller.resumePendingRemoteVerifications();

        expect(identical(firstRestore, secondRestore), isTrue);
        await firstRestore;
        expect(await recovered, 1);
        expect(fixture.execution.verifyCalls, 1);
        expect(fixture.execution.submitCalls, 0);
        expect(
          fixture.controller.state
              .batchFor('restored-batch')
              ?.itemFor('legacy')
              ?.status,
          RecordingBatchTranscriptionItemStatus.processing,
        );
      },
    );

    test(
      'routes active and unsettled notification items back to batches',
      () async {
        final now = DateTime.utc(2026, 9, 4, 8);
        final fixture = _Fixture(now: () => now);
        addTearDown(fixture.controller.dispose);
        fixture.store.values.addAll(
          <String, RecordingBatchTranscriptionSnapshot>{
            'active-batch': RecordingBatchTranscriptionSnapshot(
              batchId: 'active-batch',
              accountScope: 'account-a',
              workspaceScope: 'workspace-a',
              primaryItemId: 'active-pending',
              items: <RecordingBatchTranscriptionItem>[
                _batchItem(
                  'active-completed',
                  now,
                  status: RecordingBatchTranscriptionItemStatus.completed,
                  remoteRecordingId: 'remote-active-completed',
                ),
                _batchItem(
                  'active-pending',
                  now,
                  status: RecordingBatchTranscriptionItemStatus.pending,
                  waitingReason: RecordingBatchWaitingReason.networkRequired,
                  remoteRecordingId: 'remote-active-pending',
                ),
              ],
              createdAt: now,
              updatedAt: now,
            ),
            'settled-batch': RecordingBatchTranscriptionSnapshot(
              batchId: 'settled-batch',
              accountScope: 'account-a',
              workspaceScope: 'workspace-a',
              primaryItemId: 'settled-failed',
              items: <RecordingBatchTranscriptionItem>[
                _batchItem(
                  'settled-completed',
                  now,
                  status: RecordingBatchTranscriptionItemStatus.completed,
                  remoteRecordingId: 'remote-settled-completed',
                ),
                _batchItem(
                  'settled-failed',
                  now,
                  status: RecordingBatchTranscriptionItemStatus.failed,
                  remoteRecordingId: 'remote-settled-failed',
                ),
                _batchItem(
                  'settled-timeout',
                  now,
                  status: RecordingBatchTranscriptionItemStatus.timedOut,
                  remoteRecordingId: 'remote-settled-timeout',
                ),
              ],
              createdAt: now,
              updatedAt: now,
            ),
          },
        );
        expect(
          recordingNotificationBatchContext(
            fixture.store.loadBatches(),
            'remote-active-completed',
          ),
          (batchId: 'active-batch', itemId: 'active-completed'),
        );
        await fixture.controller.restore();

        expect(
          fixture.controller.notificationBatchContextForRemoteRecording(
            'remote-active-completed',
          ),
          (batchId: 'active-batch', itemId: 'active-completed'),
        );
        expect(
          fixture.controller.notificationBatchContextForRemoteRecording(
            'remote-settled-failed',
          ),
          (batchId: 'settled-batch', itemId: 'settled-failed'),
        );
        expect(
          fixture.controller.notificationBatchContextForRemoteRecording(
            'remote-settled-timeout',
          ),
          (batchId: 'settled-batch', itemId: 'settled-timeout'),
        );
        expect(
          fixture.controller.notificationBatchContextForRemoteRecording(
            'remote-settled-completed',
          ),
          isNull,
        );
      },
    );

    test(
      'does not duplicate an unknown remote and times out only after authority check',
      () async {
        var clock = DateTime.utc(2026, 9, 4, 8);
        final receipts = _MemoryReceiptStore();
        receipts.save(
          RecordingTranscriptionReceipt(
            userScope: 'account-a',
            fileIdentity: 'hash-done',
            localRecordingId: 'done',
            remoteRecordingId: 'remote-done',
            noteId: 'note-done',
            transcriptCompletedAt: clock,
            assetReadyAt: clock,
            updatedAt: clock,
          ),
        );
        final execution = _ExecutionPort(
          verification: (item) async => RecordingBatchAuthoritativeUpdate(
            state: RecordingBatchAuthoritativeState.temporarilyUnavailable,
            checkedAt: clock,
            remoteRecordingId: item.remoteRecordingId,
            waitingReason: RecordingBatchWaitingReason.networkRequired,
          ),
        );
        final fixture = _Fixture(
          receipts: receipts,
          execution: execution,
          now: () => clock,
        );
        addTearDown(fixture.controller.dispose);

        final dispatch = await fixture.controller
            .startSelection(<RecordingTranscriptionCandidate>[
              _candidate(
                'legacy',
                remoteRecordingId: 'remote-legacy',
                remoteFact: RecordingTranscriptionRemoteFact.unknown,
              ),
              _candidate('done', contentHash: 'hash-done'),
            ]);
        final batchId = dispatch.batch!.batchId;
        await fixture.controller.waitUntilIdle(batchId);
        final waiting = fixture.controller.state.batchFor(batchId)!.items.first;
        expect(waiting.status, RecordingBatchTranscriptionItemStatus.pending);
        expect(
          waiting.waitingReason,
          RecordingBatchWaitingReason.networkRequired,
        );
        expect(waiting.observationDeadlineAt, DateTime.utc(2026, 9, 5, 8));
        expect(execution.submitCalls, 0);
        expect(execution.verifyCalls, 1);

        clock = DateTime.utc(2026, 9, 5, 9);
        await fixture.controller.applyAuthoritativeUpdate(
          batchId: batchId,
          itemId: 'legacy',
          update: RecordingBatchAuthoritativeUpdate(
            state: RecordingBatchAuthoritativeState.processing,
            checkedAt: clock,
            remoteRecordingId: 'remote-legacy',
            progress: 35,
          ),
        );

        final timedOut = fixture.controller.state
            .batchFor(batchId)!
            .items
            .first;
        expect(timedOut.status, RecordingBatchTranscriptionItemStatus.timedOut);
        expect(
          timedOut.errorCode,
          'RECORDING_TRANSCRIPTION_OBSERVATION_TIMEOUT',
        );
      },
    );

    test(
      'does not time out from a stale tracker deadline update while offline',
      () async {
        var clock = DateTime.utc(2026, 9, 4, 8);
        final execution = _ExecutionPort(
          verification: (item) async => RecordingBatchAuthoritativeUpdate(
            state: RecordingBatchAuthoritativeState.temporarilyUnavailable,
            checkedAt: clock,
            remoteRecordingId: item.remoteRecordingId,
            waitingReason: RecordingBatchWaitingReason.networkRequired,
          ),
        );
        final fixture = _Fixture(execution: execution, now: () => clock);
        addTearDown(fixture.controller.dispose);
        final dispatch = await fixture.controller.startSelection(
          <RecordingTranscriptionCandidate>[
            _candidate('one'),
            _candidate('missing', localFileAvailable: false),
          ],
        );
        final batchId = dispatch.batch!.batchId;
        await fixture.controller.waitUntilIdle(batchId);

        clock = DateTime.utc(2026, 9, 5, 8);
        final applied = await fixture.controller.applyProcessingTask(
          RecordingProcessingTask(
            draft: _draft('one', 'remote-one', clock),
            phase: RecordingProcessingPhase.transcribing,
            updatedAt: clock,
          ),
        );

        final item = fixture.controller.state
            .batchFor(batchId)!
            .itemFor('one')!;
        expect(applied, 1);
        expect(execution.verifyCalls, 1);
        expect(item.status, RecordingBatchTranscriptionItemStatus.processing);
        expect(item.waitingReason, RecordingBatchWaitingReason.networkRequired);
        expect(item.observationDeadlineAt, clock);
      },
    );

    test('continuing a timeout starts a fresh observation window', () async {
      var clock = DateTime.utc(2026, 9, 4, 8);
      final execution = _ExecutionPort(
        verification: (item) async => RecordingBatchAuthoritativeUpdate(
          state: RecordingBatchAuthoritativeState.processing,
          checkedAt: clock,
          remoteRecordingId: item.remoteRecordingId,
          progress: 40,
        ),
      );
      final fixture = _Fixture(execution: execution, now: () => clock);
      addTearDown(fixture.controller.dispose);
      final dispatch = await fixture.controller.startSelection(
        <RecordingTranscriptionCandidate>[
          _candidate('one'),
          _candidate('missing', localFileAvailable: false),
        ],
      );
      final batchId = dispatch.batch!.batchId;
      await fixture.controller.waitUntilIdle(batchId);
      final remoteId = fixture.controller.state
          .batchFor(batchId)!
          .itemFor('one')!
          .remoteRecordingId!;
      clock = DateTime.utc(2026, 9, 5, 9);
      await fixture.controller.applyAuthoritativeUpdate(
        batchId: batchId,
        itemId: 'one',
        update: RecordingBatchAuthoritativeUpdate(
          state: RecordingBatchAuthoritativeState.processing,
          checkedAt: clock,
          remoteRecordingId: remoteId,
        ),
      );
      expect(
        fixture.controller.state.batchFor(batchId)!.itemFor('one')!.status,
        RecordingBatchTranscriptionItemStatus.timedOut,
      );

      clock = clock.add(const Duration(minutes: 1));
      expect(
        await fixture.controller.resumeObservation(
          batchId: batchId,
          itemId: 'one',
        ),
        isTrue,
      );

      final resumed = fixture.controller.state
          .batchFor(batchId)!
          .itemFor('one')!;
      expect(resumed.remoteRecordingId, remoteId);
      expect(resumed.status, RecordingBatchTranscriptionItemStatus.processing);
      expect(resumed.observationStartedAt, clock);
      expect(
        resumed.observationDeadlineAt,
        clock.add(const Duration(hours: 24)),
      );
      expect(resumed.errorCode, isNull);
      expect(execution.submitCalls, 1);
    });

    test(
      'scope deactivation synchronously latches active submissions',
      () async {
        final execution = _ExecutionPort(gatedSubmissions: true);
        final fixture = _Fixture(execution: execution);
        addTearDown(fixture.controller.dispose);
        final dispatch = await fixture.controller
            .startSelection(<RecordingTranscriptionCandidate>[
              _candidate(
                'remote',
                remoteRecordingId: 'remote-existing',
                remoteFact: RecordingTranscriptionRemoteFact.processing,
              ),
              _candidate('new'),
            ]);
        final batchId = dispatch.batch!.batchId;
        await _waitFor(() => execution.activeSubmissions == 1);

        await fixture.controller.deactivateForAccountScopeChange();

        final persisted = fixture.store.values[batchId]!;
        expect(
          persisted.itemFor('new')?.status,
          RecordingBatchTranscriptionItemStatus.pending,
        );
        expect(
          persisted.itemFor('remote')?.status,
          RecordingBatchTranscriptionItemStatus.processing,
        );
        expect(
          persisted.items.map((item) => item.waitingReason),
          everyElement(RecordingBatchWaitingReason.accountScopeChanged),
        );
        execution.release('new');
        await Future<void>.delayed(Duration.zero);
        expect(
          fixture.store.values[batchId]!.items.map(
            (item) => item.waitingReason,
          ),
          everyElement(RecordingBatchWaitingReason.accountScopeChanged),
        );

        final resumedExecution = _ExecutionPort();
        final resumed = RecordingBatchTranscriptionController(
          store: fixture.store,
          receiptStore: fixture.receipts,
          executionPort: resumedExecution,
          accountScope: 'account-a',
          workspaceScope: 'workspace-a',
          now: () => DateTime.utc(2026, 9, 4, 9),
        );
        addTearDown(resumed.dispose);
        await resumed.restore();
        await resumed.waitUntilIdle(batchId);

        final restored = resumed.state.batchFor(batchId)!;
        expect(resumedExecution.submitCalls, 1);
        expect(resumedExecution.verifyCalls, 1);
        expect(restored.itemFor('new')?.remoteRecordingId, 'remote-new');
        expect(
          restored.itemFor('remote')?.remoteRecordingId,
          'remote-existing',
        );
        expect(
          restored.items.map((item) => item.waitingReason),
          everyElement(isNull),
        );
      },
    );

    test(
      'accepts late asset success and writes one completion receipt',
      () async {
        var clock = DateTime.utc(2026, 9, 4, 8);
        final receipts = _MemoryReceiptStore();
        final fixture = _Fixture(receipts: receipts, now: () => clock);
        addTearDown(fixture.controller.dispose);
        final dispatch = await fixture.controller.startSelection(
          <RecordingTranscriptionCandidate>[
            _candidate('one'),
            _candidate('two', localFileAvailable: false),
          ],
        );
        final batchId = dispatch.batch!.batchId;
        await fixture.controller.waitUntilIdle(batchId);
        final remoteId = fixture.controller.state
            .batchFor(batchId)!
            .itemFor('one')!
            .remoteRecordingId!;
        clock = DateTime.utc(2026, 9, 6, 8);
        await fixture.controller.applyAuthoritativeUpdate(
          batchId: batchId,
          itemId: 'one',
          update: RecordingBatchAuthoritativeUpdate(
            state: RecordingBatchAuthoritativeState.processing,
            checkedAt: clock,
            remoteRecordingId: remoteId,
          ),
        );
        expect(
          fixture.controller.state.batchFor(batchId)!.itemFor('one')!.status,
          RecordingBatchTranscriptionItemStatus.timedOut,
        );

        clock = clock.add(const Duration(minutes: 1));
        await fixture.controller.applyAuthoritativeUpdate(
          batchId: batchId,
          itemId: 'one',
          update: RecordingBatchAuthoritativeUpdate(
            state: RecordingBatchAuthoritativeState.assetReady,
            checkedAt: clock,
            remoteRecordingId: remoteId,
            noteId: 'note-one',
            transcriptCompletedAt: clock.subtract(const Duration(minutes: 1)),
            assetReadyAt: clock,
          ),
        );

        final completed = fixture.controller.state
            .batchFor(batchId)!
            .itemFor('one')!;
        expect(
          completed.status,
          RecordingBatchTranscriptionItemStatus.completed,
        );
        expect(receipts.findByFileIdentity('hash-one')?.noteId, 'note-one');
        expect(receipts.listReceipts(), hasLength(1));
      },
    );

    test(
      'bridges tracker and note facts with terminal outline latching',
      () async {
        final now = DateTime.utc(2026, 9, 4, 8);
        final fixture = _Fixture(now: () => now);
        addTearDown(fixture.controller.dispose);
        final dispatch = await fixture.controller.startSelection(
          <RecordingTranscriptionCandidate>[
            _candidate('one'),
            _candidate('two'),
          ],
        );
        final batchId = dispatch.batch!.batchId;
        await fixture.controller.waitUntilIdle(batchId);

        expect(
          fixture.controller.activeBatchContextForRemoteRecording('remote-one'),
          (batchId: batchId, itemId: 'one'),
        );
        final applied = await fixture.controller.applyProcessingState(
          RecordingProcessingState(
            tasks: <RecordingProcessingTask>[
              RecordingProcessingTask(
                draft: _draft('one', 'remote-one', now),
                phase: RecordingProcessingPhase.storingCloudNote,
                updatedAt: now.add(const Duration(minutes: 1)),
              ),
            ],
          ),
        );
        expect(applied, 1);
        expect(
          fixture.controller.state.batchFor(batchId)!.itemFor('one')!.phase,
          RecordingBatchTranscriptionPhase.storingAsset,
        );

        final completedAt = now.add(const Duration(minutes: 2));
        await fixture.controller.applyAuthoritativeUpdate(
          batchId: batchId,
          itemId: 'one',
          update: RecordingBatchAuthoritativeUpdate(
            state: RecordingBatchAuthoritativeState.assetReady,
            checkedAt: completedAt,
            remoteRecordingId: 'remote-one',
            noteId: 'note-one',
            transcriptCompletedAt: completedAt,
            assetReadyAt: completedAt,
          ),
        );
        expect(
          await fixture.controller.applyOutlineStatusForNote(
            noteId: 'note-one',
            status: RecordingBatchOutlineStatus.completed,
            observedAt: completedAt.add(const Duration(minutes: 1)),
          ),
          1,
        );
        expect(
          await fixture.controller.applyOutlineStatusForNote(
            noteId: 'note-one',
            status: RecordingBatchOutlineStatus.generating,
            observedAt: completedAt.add(const Duration(minutes: 2)),
          ),
          0,
        );
        expect(
          fixture.receipts.findByFileIdentity('hash-one')?.isOutlineReady,
          isTrue,
        );
      },
    );

    test('converts thrown submissions into retryable item failures', () async {
      final fixture = _Fixture(
        execution: _ExecutionPort(throwSubmissions: true),
      );
      addTearDown(fixture.controller.dispose);

      final dispatch = await fixture.controller.startSelection(
        <RecordingTranscriptionCandidate>[_candidate('one'), _candidate('two')],
      );
      await fixture.controller.waitUntilIdle(dispatch.batch!.batchId);

      final items = fixture.controller.state
          .batchFor(dispatch.batch!.batchId)!
          .items;
      expect(
        items.map((item) => item.status),
        everyElement(RecordingBatchTranscriptionItemStatus.failed),
      );
      expect(items.map((item) => item.retryable), everyElement(isTrue));
      expect(
        items.map((item) => item.errorCode),
        everyElement('RECORDING_BATCH_SUBMISSION_UNAVAILABLE'),
      );
    });
  });

  test(
    'production adapter hands off a queued checkpoint before a failed GET',
    () async {
      final database = AppDatabase();
      final draftStore = UploadDraftStore(
        database: database,
        accountScope: 'account-a',
      );
      draftStore.saveDraft(
        _draft(
          'legacy',
          'remote-legacy',
          DateTime.utc(2026, 9, 4, 8),
        ).copyWith(workspaceId: 'workspace-a'),
      );
      final recordingApi = _AdapterRecordingApi(
        ApiResult<RecordingDetail>.failure(
          error: const AppFailure(
            code: 'NETWORK_OFFLINE',
            category: AppFailureCategory.network,
            message: 'offline',
            userMessageKey: 'network.offline',
            isRetryable: true,
          ),
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      final apiClient = ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'device-1',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () => 'token',
        ),
        transport: const _NeverApiTransport(),
      );
      final processing = _ProcessingPort();
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: const UnavailableFileStoragePort(),
        accountScope: 'account-a',
      );
      final uploadController = RecordingUploadController(
        uploadClient: UploadClient(
          apiClient: apiClient,
          objectTransport: const _NeverObjectUploadTransport(),
        ),
        draftStore: draftStore,
        recordingApi: recordingApi,
        localRecordingRepository: repository,
        activeWorkspaceId: () => 'workspace-a',
        accountScope: 'account-a',
        activeAccountScope: () => 'account-a',
        processingPort: processing,
      );
      addTearDown(uploadController.dispose);
      final adapter = RecordingBatchTranscriptionExecutionAdapter(
        uploadController: uploadController,
        localRecordingRepository: repository,
        recordingApi: recordingApi,
        processingRetryPort: _ProcessingRetryPort(),
        now: () => DateTime.utc(2026, 9, 4, 8),
      );

      final update = await adapter.verifyExisting(
        _batchItem(
          'legacy',
          DateTime.utc(2026, 9, 4, 8),
          status: RecordingBatchTranscriptionItemStatus.processing,
          remoteRecordingId: 'remote-legacy',
        ),
      );

      expect(
        update.state,
        RecordingBatchAuthoritativeState.temporarilyUnavailable,
      );
      expect(update.waitingReason, RecordingBatchWaitingReason.networkRequired);
      expect(processing.tracked, hasLength(1));
      expect(processing.tracked.single.recordingId, 'remote-legacy');
      expect(recordingApi.detailCalls, 1);

      Future<RecordingBatchAuthoritativeUpdate> verifyFailure(
        AppFailure failure,
      ) {
        final api = _AdapterRecordingApi(
          ApiResult<RecordingDetail>.failure(
            error: failure,
            idempotencyStore: SubmissionKeyStore.empty,
          ),
        );
        return RecordingBatchTranscriptionExecutionAdapter(
          uploadController: uploadController,
          localRecordingRepository: repository,
          recordingApi: api,
          processingRetryPort: _ProcessingRetryPort(),
          now: () => DateTime.utc(2026, 9, 4, 8),
        ).verifyExisting(
          _batchItem(
            'legacy',
            DateTime.utc(2026, 9, 4, 8),
            status: RecordingBatchTranscriptionItemStatus.processing,
            remoteRecordingId: 'remote-legacy',
          ),
        );
      }

      final authorization = await verifyFailure(
        const AppFailure(
          code: 'AUTH_EXPIRED',
          category: AppFailureCategory.auth,
          message: 'expired',
          userMessageKey: 'auth.expired',
        ),
      );
      expect(authorization.state, RecordingBatchAuthoritativeState.failed);
      expect(
        authorization.failureCategory,
        RecordingBatchFailureCategory.authorization,
      );

      final retryableApi = await verifyFailure(
        const AppFailure(
          code: 'API_BUSY',
          category: AppFailureCategory.api,
          message: 'busy',
          userMessageKey: 'api.busy',
          isRetryable: true,
        ),
      );
      expect(
        retryableApi.state,
        RecordingBatchAuthoritativeState.temporarilyUnavailable,
      );
      expect(
        retryableApi.waitingReason,
        RecordingBatchWaitingReason.remoteVerificationRequired,
      );

      final terminalApi = await verifyFailure(
        const AppFailure(
          code: 'API_REJECTED',
          category: AppFailureCategory.api,
          message: 'rejected',
          userMessageKey: 'api.rejected',
        ),
      );
      expect(terminalApi.state, RecordingBatchAuthoritativeState.failed);
      expect(terminalApi.failureCategory, RecordingBatchFailureCategory.remote);

      final retryQueryFailure = await adapter.retryExisting(
        _batchItem(
          'legacy',
          DateTime.utc(2026, 9, 4, 8),
          status: RecordingBatchTranscriptionItemStatus.failed,
          remoteRecordingId: 'remote-legacy',
        ),
      );
      expect(retryQueryFailure.accepted, isFalse);
      expect(
        retryQueryFailure.failureCategory,
        RecordingBatchFailureCategory.remote,
      );
      expect(retryQueryFailure.retryable, isTrue);

      final retryPort = _ProcessingRetryPort();
      final retryApi = _AdapterRecordingApi(
        ApiResult<RecordingDetail>.success(
          data: _retryableDetail('remote-legacy'),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
        retryResult: ApiResult<RetryRecordingResponse>.success(
          data: const RetryRecordingResponse(
            recordingId: 'remote-legacy',
            stage: 'asr',
            status: RecordingRetryReceiptStatus.queued,
          ),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      final retryAdapter = RecordingBatchTranscriptionExecutionAdapter(
        uploadController: uploadController,
        localRecordingRepository: repository,
        recordingApi: retryApi,
        processingRetryPort: retryPort,
        now: () => DateTime.utc(2026, 9, 4, 8),
      );
      final accepted = await retryAdapter.retryExisting(
        _batchItem(
          'legacy',
          DateTime.utc(2026, 9, 4, 8),
          status: RecordingBatchTranscriptionItemStatus.failed,
          remoteRecordingId: 'remote-legacy',
        ),
      );
      expect(accepted.accepted, isTrue);
      expect(accepted.remoteRecordingId, 'remote-legacy');
      expect(retryPort.recordingIds, <String>['remote-legacy']);

      final speakerPort = _SpeakerAutoAdvancePort();
      final pendingApi = _AdapterRecordingApi(
        ApiResult<RecordingDetail>.success(
          data: _speakerPendingDetail('remote-legacy'),
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      final pendingUpdate =
          await RecordingBatchTranscriptionExecutionAdapter(
            uploadController: uploadController,
            localRecordingRepository: repository,
            recordingApi: pendingApi,
            processingRetryPort: _ProcessingRetryPort(),
            speakerAutoAdvancePort: speakerPort,
            now: () => DateTime.utc(2026, 9, 4, 8),
          ).verifyExisting(
            _batchItem(
              'legacy',
              DateTime.utc(2026, 9, 4, 8),
              status: RecordingBatchTranscriptionItemStatus.processing,
              remoteRecordingId: 'remote-legacy',
            ),
          );
      expect(pendingUpdate.state, RecordingBatchAuthoritativeState.processing);
      expect(
        pendingUpdate.waitingReason,
        RecordingBatchWaitingReason.remoteVerificationRequired,
      );
      expect(speakerPort.pendingCalls, 1);
    },
  );

  test('database batch store restores interrupted submission as pending', () {
    final database = AppDatabase();
    final store = RecordingBatchTranscriptionStore(
      database: database,
      accountScope: 'account-a',
      workspaceScope: 'workspace-a',
    );
    final now = DateTime.utc(2026, 9, 4, 8);
    store.saveBatch(
      RecordingBatchTranscriptionSnapshot(
        batchId: 'batch-a',
        accountScope: 'account-a',
        workspaceScope: 'workspace-a',
        primaryItemId: 'one',
        items: <RecordingBatchTranscriptionItem>[
          _batchItem(
            'one',
            now,
            status: RecordingBatchTranscriptionItemStatus.submitting,
          ).copyWith(
            outlineStatus: RecordingBatchOutlineStatus.failed,
            outlineErrorCode: 'WORKSPACE_NOT_READY',
            outlineTaskId: 'outline-task-current',
            supersededOutlineTaskId: 'outline-task-old',
          ),
          _batchItem(
            'two',
            now,
            status: RecordingBatchTranscriptionItemStatus.processing,
            remoteRecordingId: 'remote-two',
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),
    );

    final restored = store.loadBatches().single;
    expect(
      restored.itemFor('one')?.status,
      RecordingBatchTranscriptionItemStatus.pending,
    );
    expect(restored.itemFor('one')?.jobId, 'job-one');
    expect(
      restored.itemFor('one')?.outlineStatus,
      RecordingBatchOutlineStatus.failed,
    );
    expect(restored.itemFor('one')?.outlineErrorCode, 'WORKSPACE_NOT_READY');
    expect(restored.itemFor('one')?.outlineTaskId, 'outline-task-current');
    expect(
      restored.itemFor('one')?.supersededOutlineTaskId,
      'outline-task-old',
    );
    expect(restored.itemFor('two')?.remoteRecordingId, 'remote-two');
    expect(
      RecordingBatchTranscriptionStore(
        database: database,
        accountScope: 'account-b',
        workspaceScope: 'workspace-a',
      ).loadBatches(),
      isEmpty,
    );
  });

  test(
    'fences a new outline retry from the superseded terminal task',
    () async {
      final now = DateTime.utc(2026, 9, 4, 8);
      final fixture = _Fixture(now: () => now);
      addTearDown(fixture.controller.dispose);
      fixture.store.values['batch-outline-retry'] =
          RecordingBatchTranscriptionSnapshot(
            batchId: 'batch-outline-retry',
            accountScope: 'account-a',
            workspaceScope: 'workspace-a',
            primaryItemId: 'one',
            items: <RecordingBatchTranscriptionItem>[
              _batchItem(
                'one',
                now,
                status: RecordingBatchTranscriptionItemStatus.completed,
                remoteRecordingId: 'remote-outline-retry',
              ),
              _batchItem(
                'two',
                now,
                status: RecordingBatchTranscriptionItemStatus.completed,
                remoteRecordingId: 'remote-two',
              ),
            ],
            createdAt: now,
            updatedAt: now,
          );
      await fixture.controller.restore();

      expect(
        await fixture.controller.applyOutlineStatusForRecording(
          recordingId: 'remote-outline-retry',
          status: RecordingBatchOutlineStatus.failed,
          errorCode: 'WORKSPACE_NOT_READY',
          taskId: 'outline-task-old',
        ),
        1,
      );
      expect(
        await fixture.controller.applyOutlineStatusForRecording(
          recordingId: 'remote-outline-retry',
          status: RecordingBatchOutlineStatus.generating,
        ),
        0,
      );
      var item = fixture.controller.state
          .batchFor('batch-outline-retry')!
          .itemFor('one')!;
      expect(item.outlineStatus, RecordingBatchOutlineStatus.failed);
      expect(item.outlineErrorCode, 'WORKSPACE_NOT_READY');
      expect(item.outlineTaskId, 'outline-task-old');

      await fixture.controller.rejectOutlineRetry(
        recordingId: 'remote-outline-retry',
        errorCode: 'SERVICE_BUSY',
      );
      item = fixture.controller.state
          .batchFor('batch-outline-retry')!
          .itemFor('one')!;
      expect(item.outlineStatus, RecordingBatchOutlineStatus.failed);
      expect(item.outlineErrorCode, 'SERVICE_BUSY');

      await fixture.controller.acceptOutlineRetry(
        recordingId: 'remote-outline-retry',
        retryTaskId: 'outline-task-new',
        retryStage: 'recording_note_outline',
        supersededOutlineTaskId: 'outline-task-old',
      );
      item = fixture.controller.state
          .batchFor('batch-outline-retry')!
          .itemFor('one')!;
      expect(item.outlineStatus, RecordingBatchOutlineStatus.generating);
      expect(item.outlineErrorCode, isNull);
      expect(item.outlineTaskId, 'outline-task-new');
      expect(item.supersededOutlineTaskId, 'outline-task-old');

      expect(
        await fixture.controller.applyOutlineStatusForRecording(
          recordingId: 'remote-outline-retry',
          status: RecordingBatchOutlineStatus.failed,
          errorCode: 'WORKSPACE_NOT_READY',
          taskId: 'outline-task-old',
        ),
        0,
      );
      item = fixture.controller.state
          .batchFor('batch-outline-retry')!
          .itemFor('one')!;
      expect(item.outlineStatus, RecordingBatchOutlineStatus.generating);

      expect(
        await fixture.controller.applyOutlineStatusForRecording(
          recordingId: 'remote-outline-retry',
          status: RecordingBatchOutlineStatus.failed,
          errorCode: 'WORKSPACE_NOT_READY',
          taskId: 'outline-task-new',
        ),
        1,
      );
      await fixture.controller.rejectOutlineRetry(
        recordingId: 'remote-outline-retry',
        errorCode: 'SERVICE_BUSY',
      );
      item = fixture.controller.state
          .batchFor('batch-outline-retry')!
          .itemFor('one')!;
      expect(item.outlineStatus, RecordingBatchOutlineStatus.failed);
      expect(item.outlineErrorCode, 'SERVICE_BUSY');
      expect(item.outlineTaskId, 'outline-task-new');
      expect(item.supersededOutlineTaskId, isNull);
    },
  );

  test(
    'predecessor retry waits for a distinct outline task before terminal',
    () async {
      final now = DateTime.utc(2026, 9, 4, 8);
      final fixture = _Fixture(now: () => now);
      addTearDown(fixture.controller.dispose);
      fixture.store.values['batch-predecessor-retry'] =
          RecordingBatchTranscriptionSnapshot(
            batchId: 'batch-predecessor-retry',
            accountScope: 'account-a',
            workspaceScope: 'workspace-a',
            primaryItemId: 'one',
            items: <RecordingBatchTranscriptionItem>[
              _batchItem(
                'one',
                now,
                status: RecordingBatchTranscriptionItemStatus.completed,
                remoteRecordingId: 'remote-predecessor-retry',
              ).copyWith(
                outlineStatus: RecordingBatchOutlineStatus.failed,
                outlineErrorCode: 'RECORDING_OUTLINE_FAILED',
              ),
              _batchItem(
                'two',
                now,
                status: RecordingBatchTranscriptionItemStatus.completed,
                remoteRecordingId: 'remote-unrelated',
              ),
            ],
            createdAt: now,
            updatedAt: now,
          );
      await fixture.controller.restore();

      await fixture.controller.acceptOutlineRetry(
        recordingId: 'remote-predecessor-retry',
        retryTaskId: 'minutes-retry-task',
        retryStage: 'minutes_generation',
      );
      var item = fixture.controller.state
          .batchFor('batch-predecessor-retry')!
          .itemFor('one')!;
      expect(item.outlineStatus, RecordingBatchOutlineStatus.generating);
      expect(item.outlineTaskId, isNull);
      expect(item.supersededOutlineTaskId, 'minutes-retry-task');

      expect(
        await fixture.controller.applyOutlineStatusForRecording(
          recordingId: 'remote-predecessor-retry',
          status: RecordingBatchOutlineStatus.failed,
          errorCode: 'RECORDING_OUTLINE_FAILED',
        ),
        0,
      );
      item = fixture.controller.state
          .batchFor('batch-predecessor-retry')!
          .itemFor('one')!;
      expect(item.outlineStatus, RecordingBatchOutlineStatus.generating);
      expect(item.supersededOutlineTaskId, 'minutes-retry-task');

      expect(
        await fixture.controller.applyOutlineStatusForRecording(
          recordingId: 'remote-predecessor-retry',
          status: RecordingBatchOutlineStatus.generating,
          taskId: 'outline-task-after-retry',
        ),
        1,
      );
      item = fixture.controller.state
          .batchFor('batch-predecessor-retry')!
          .itemFor('one')!;
      expect(item.outlineTaskId, 'outline-task-after-retry');
      expect(item.supersededOutlineTaskId, isNull);
    },
  );
}

final class _Fixture {
  _Fixture({
    _MemoryReceiptStore? receipts,
    _ExecutionPort? execution,
    DateTime Function()? now,
    Duration remoteVerificationInterval = const Duration(seconds: 3),
  }) : receipts = receipts ?? _MemoryReceiptStore(),
       execution = execution ?? _ExecutionPort(),
       store = _MemoryBatchStore() {
    controller = RecordingBatchTranscriptionController(
      store: store,
      receiptStore: this.receipts,
      executionPort: this.execution,
      accountScope: 'account-a',
      workspaceScope: 'workspace-a',
      now: now ?? () => DateTime.utc(2026, 9, 4, 8),
      createBatchId: () => 'batch-a',
      remoteVerificationInterval: remoteVerificationInterval,
    );
  }

  final _MemoryReceiptStore receipts;
  final _ExecutionPort execution;
  final _MemoryBatchStore store;
  late final RecordingBatchTranscriptionController controller;
}

final class _MemoryBatchStore implements RecordingBatchTranscriptionStorePort {
  final Map<String, RecordingBatchTranscriptionSnapshot> values =
      <String, RecordingBatchTranscriptionSnapshot>{};
  Completer<void>? flushGate;

  @override
  void deleteBatch(String batchId) => values.remove(batchId);

  @override
  Future<bool> flush() async {
    final gate = flushGate;
    if (gate != null) await gate.future;
    return true;
  }

  @override
  List<RecordingBatchTranscriptionSnapshot> loadBatches() =>
      values.values.toList(growable: false);

  @override
  void saveBatch(RecordingBatchTranscriptionSnapshot batch) {
    values[batch.batchId] = batch;
  }
}

final class _MemoryReceiptStore
    implements RecordingTranscriptionReceiptStorePort {
  final Map<String, RecordingTranscriptionReceipt> values =
      <String, RecordingTranscriptionReceipt>{};
  var flushCalls = 0;
  var saveCalls = 0;

  @override
  RecordingTranscriptionReceipt? findByFileIdentity(String fileIdentity) =>
      values[fileIdentity];

  @override
  RecordingTranscriptionReceipt? findByLocalRecordingId(
    String localRecordingId,
  ) {
    return values.values
        .where((receipt) => receipt.localRecordingId == localRecordingId)
        .firstOrNull;
  }

  @override
  RecordingTranscriptionReceipt? findByRemoteRecordingId(
    String remoteRecordingId,
  ) {
    return values.values
        .where((receipt) => receipt.remoteRecordingId == remoteRecordingId)
        .firstOrNull;
  }

  @override
  Future<bool> flush() async {
    flushCalls += 1;
    return true;
  }

  @override
  List<RecordingTranscriptionReceipt> listReceipts() =>
      values.values.toList(growable: false);

  @override
  void save(RecordingTranscriptionReceipt receipt) {
    saveCalls += 1;
    values[receipt.fileIdentity] =
        values[receipt.fileIdentity]?.merge(receipt) ?? receipt;
  }
}

final class _ExecutionPort implements RecordingBatchTranscriptionExecutionPort {
  _ExecutionPort({
    this.gatedSubmissions = false,
    this.throwSubmissions = false,
    Future<RecordingBatchSubmissionResult> Function(
      RecordingBatchTranscriptionItem item,
    )?
    retry,
    Future<RecordingBatchAuthoritativeUpdate> Function(
      RecordingBatchTranscriptionItem item,
    )?
    verification,
  }) : _retry = retry,
       _verification = verification;

  final bool gatedSubmissions;
  final bool throwSubmissions;
  final Future<RecordingBatchSubmissionResult> Function(
    RecordingBatchTranscriptionItem item,
  )?
  _retry;
  final Future<RecordingBatchAuthoritativeUpdate> Function(
    RecordingBatchTranscriptionItem item,
  )?
  _verification;
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};
  int submitCalls = 0;
  int retryCalls = 0;
  int verifyCalls = 0;
  final List<String> retriedRemoteRecordingIds = <String>[];
  int activeSubmissions = 0;
  int maximumActiveSubmissions = 0;

  void release(String itemId) => _gates[itemId]?.complete();

  @override
  Future<RecordingBatchSubmissionResult> retryExisting(
    RecordingBatchTranscriptionItem item,
  ) async {
    retryCalls += 1;
    retriedRemoteRecordingIds.add(item.remoteRecordingId!);
    final retry = _retry;
    if (retry != null) return retry(item);
    return RecordingBatchSubmissionResult.accepted(
      remoteRecordingId: item.remoteRecordingId!,
    );
  }

  @override
  Future<RecordingBatchSubmissionResult> submitNew(
    RecordingBatchTranscriptionItem item,
  ) async {
    submitCalls += 1;
    if (throwSubmissions) throw StateError('network unavailable');
    activeSubmissions += 1;
    if (activeSubmissions > maximumActiveSubmissions) {
      maximumActiveSubmissions = activeSubmissions;
    }
    if (gatedSubmissions) {
      await _gates.putIfAbsent(item.itemId, Completer<void>.new).future;
    }
    activeSubmissions -= 1;
    return RecordingBatchSubmissionResult.accepted(
      remoteRecordingId: 'remote-${item.itemId}',
    );
  }

  @override
  Future<RecordingBatchAuthoritativeUpdate> verifyExisting(
    RecordingBatchTranscriptionItem item,
  ) async {
    verifyCalls += 1;
    final verification = _verification;
    if (verification != null) return verification(item);
    return RecordingBatchAuthoritativeUpdate(
      state: RecordingBatchAuthoritativeState.processing,
      checkedAt: DateTime.utc(2026, 9, 4, 8),
      remoteRecordingId: item.remoteRecordingId,
    );
  }
}

final class _ProcessingPort implements RecordingProcessingPort {
  final List<UploadDraft> tracked = <UploadDraft>[];

  @override
  Future<void> track(UploadDraft draft) async {
    tracked.add(draft);
  }
}

final class _ProcessingRetryPort implements RecordingProcessingRetryPort {
  final List<String> recordingIds = <String>[];

  @override
  Future<bool> reenrollAfterRetry(String recordingId) async {
    recordingIds.add(recordingId);
    return true;
  }
}

final class _SpeakerAutoAdvancePort implements RecordingSpeakerAutoAdvancePort {
  var pendingCalls = 0;

  @override
  Future<RecordingSpeakerAutoAdvanceOutcome> advanceSpeakerStageIfNeeded(
    RecordingDetail detail,
  ) async {
    if (detail.recording.status != RecordingRemoteStatus.speakerLabelPending) {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.notRequired,
      );
    }
    pendingCalls += 1;
    return const RecordingSpeakerAutoAdvanceOutcome(
      RecordingSpeakerAutoAdvanceStatus.submitted,
    );
  }
}

final class _AdapterRecordingApi implements RecordingApiPort {
  _AdapterRecordingApi(this.detailResult, {this.retryResult});

  final ApiResult<RecordingDetail> detailResult;
  final ApiResult<RetryRecordingResponse>? retryResult;
  var detailCalls = 0;

  @override
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  ) => throw StateError('unexpected create recording');

  @override
  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId) =>
      throw StateError('unexpected ASR task read');

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(
    String recordingId,
  ) async {
    detailCalls += 1;
    return detailResult;
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  }) => throw StateError('unexpected ASR retry');

  @override
  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) async => retryResult ?? (throw StateError('unexpected Recording retry'));
}

final class _NeverApiTransport implements ApiTransport {
  const _NeverApiTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) =>
      throw StateError('unexpected API transport');
}

final class _NeverObjectUploadTransport implements ObjectUploadTransport {
  const _NeverObjectUploadTransport();

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) =>
      throw StateError('unexpected object upload');
}

RecordingDetail _retryableDetail(String recordingId) {
  return RecordingDetail(
    recording: RecordingAsset(
      recordingId: recordingId,
      title: 'Recording $recordingId',
      status: RecordingRemoteStatus.failed,
    ),
    asrTask: AsrTaskSnapshot(
      asrTaskId: 'asr-$recordingId',
      status: RecordingRemoteStatus.failed,
    ),
    retryActions: const <RecordingRetryAction>[
      RecordingRetryAction(stage: 'asr', title: '重试转写', allowed: true),
    ],
  );
}

RecordingDetail _speakerPendingDetail(String recordingId) {
  return RecordingDetail(
    recording: RecordingAsset(
      recordingId: recordingId,
      title: 'Recording $recordingId',
      status: RecordingRemoteStatus.speakerLabelPending,
      transcriptStatus: 'transcribed',
      speakerLabelStatus: 'pending',
    ),
    asrTask: AsrTaskSnapshot(
      asrTaskId: 'asr-$recordingId',
      status: RecordingRemoteStatus.speakerLabelPending,
      version: 4,
    ),
  );
}

UploadDraft _draft(String itemId, String remoteRecordingId, DateTime now) {
  return UploadDraft(
    draftId: 'job-$itemId',
    localRecordingId: itemId,
    appPrivateUri: 'app-private-media://recordings/$itemId.m4a',
    fileName: '$itemId.m4a',
    mimeType: 'audio/mp4',
    sizeBytes: 128,
    durationSeconds: 10,
    sourceScene: 'raw_material',
    stage: UploadDraftStage.asrQueued,
    updatedAt: now,
    uploadTokenKey: 'upload-$itemId',
    completeUploadKey: 'complete-$itemId',
    createRecordingKey: 'create-$itemId',
    recordingId: remoteRecordingId,
  );
}

RecordingTranscriptionCandidate _candidate(
  String id, {
  String? contentHash,
  String? remoteRecordingId,
  RecordingTranscriptionRemoteFact remoteFact =
      RecordingTranscriptionRemoteFact.none,
  bool localFileAvailable = true,
  bool transcriptionNotRequired = false,
  bool retryable = false,
  String? noteId,
  DateTime? transcriptCompletedAt,
  DateTime? assetReadyAt,
}) {
  return RecordingTranscriptionCandidate(
    itemId: id,
    title: 'Recording $id',
    fileIdentity: contentHash ?? 'hash-$id',
    localRecordingId: id,
    jobId: 'job-$id',
    contentHash: contentHash ?? 'hash-$id',
    remoteRecordingId: remoteRecordingId,
    remoteFact: remoteFact,
    transcriptionNotRequired: transcriptionNotRequired,
    localFileAvailable: localFileAvailable,
    retryable: retryable,
    noteId: noteId,
    transcriptCompletedAt: transcriptCompletedAt,
    assetReadyAt: assetReadyAt,
  );
}

RecordingBatchTranscriptionItem _batchItem(
  String id,
  DateTime now, {
  required RecordingBatchTranscriptionItemStatus status,
  String? remoteRecordingId,
  RecordingBatchWaitingReason? waitingReason,
  RecordingBatchFailureCategory? failureCategory,
}) {
  return RecordingBatchTranscriptionItem(
    itemId: id,
    title: 'Recording $id',
    fileIdentity: 'hash-$id',
    localRecordingId: id,
    jobId: 'job-$id',
    status: status,
    phase: RecordingBatchTranscriptionPhase.transcribing,
    outlineStatus: RecordingBatchOutlineStatus.notStarted,
    retryable: false,
    attemptCount: 1,
    remoteRecordingId: remoteRecordingId,
    waitingReason: waitingReason,
    failureCategory: failureCategory,
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration delay = Duration.zero,
}) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(delay);
  }
  fail('Condition was not reached');
}
