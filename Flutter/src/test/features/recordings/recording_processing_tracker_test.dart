import 'dart:async';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/recordings/application/recording_processing_tracker.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';

void main() {
  group('RecordingProcessingTracker', () {
    test('shares one sealed lifecycle projection with recovery and UI', () {
      final draft = _draft(recordingId: 'rec-private-42');

      RecordingProcessingTask task(
        RecordingProcessingPhase phase, {
        String? errorCode,
      }) => RecordingProcessingTask(
        draft: draft,
        phase: phase,
        updatedAt: DateTime.utc(2026, 8, 31),
        errorCode: errorCode,
      );

      final processing = task(RecordingProcessingPhase.transcribing);
      final synchronizing = task(RecordingProcessingPhase.storingCloudNote);
      final completed = task(RecordingProcessingPhase.completed);
      final failed = task(
        RecordingProcessingPhase.failed,
        errorCode: 'RECORDING_TRANSCRIPTION_TIMEOUT',
      );

      expect(processing.appTaskState, isA<AppTaskRunning>());
      expect(synchronizing.appTaskState, isA<AppTaskRunning>());
      expect(completed.appTaskState, isA<AppTaskSucceeded>());
      expect(failed.appTaskState, isA<AppTaskFailed>());
      expect((failed.appTaskState as AppTaskFailed).retryable, isFalse);
      expect(processing.isActive, isTrue);
      expect(synchronizing.isActive, isTrue);
      expect(completed.isActive, isFalse);
      expect(failed.isActive, isFalse);
      expect(
        processing.appTaskProjection.spec.key,
        isNot(contains('rec-private-42')),
      );
    });

    test(
      'polls queued work through completion and checkpoints it once',
      () async {
        final database = AppDatabase();
        final store = UploadDraftStore(database: database);
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              _detailResult(_detail(status: RecordingRemoteStatus.processing)),
              _detailResult(_detail(status: RecordingRemoteStatus.completed)),
            ],
          },
        );
        final tracker = RecordingProcessingTracker(
          recordingApi: api,
          draftStore: store,
          delay: _immediateDelay,
        );

        await tracker.track(draft);

        final task = tracker.state.taskFor('rec-1');
        expect(task?.status, RecordingFileJobStatus.ready);
        expect(
          tracker.processingTaskFor('rec-1')?.detail?.recording.status,
          RecordingRemoteStatus.completed,
        );
        expect(
          store.getDraft(draft.draftId)?.stage,
          UploadDraftStage.asrCompleted,
        );
        expect(api.detailCalls, 2);
        expect(api.retryCalls, 0);
      },
    );

    test(
      'does not publish ready when its terminal checkpoint cannot persist',
      () async {
        final snapshotStore = _ToggleFailingSnapshotStore();
        final store = UploadDraftStore(
          database: AppDatabase(snapshotStore: snapshotStore),
        );
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        snapshotStore.failWrites = true;
        final tracker = RecordingProcessingTracker(
          recordingApi: _FakeRecordingApi(
            details: <String, List<ApiResult<RecordingDetail>>>{
              'rec-1': <ApiResult<RecordingDetail>>[
                _detailResult(_completedDetail()),
              ],
            },
          ),
          draftStore: store,
          delay: _immediateDelay,
        );
        addTearDown(tracker.dispose);

        await tracker.track(draft);

        final task = tracker.state.taskFor('rec-1');
        expect(task?.status, RecordingFileJobStatus.failed);
        expect(task?.phase, RecordingProcessingPhase.failed);
        expect(task?.errorCode, 'UPLOAD_DRAFT_WRITE_FAILED');
        expect(task?.draft.stage, UploadDraftStage.asrQueued);
      },
    );

    test(
      'persists a terminal remote failure without posting a retry',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              _detailResult(
                _detail(
                  status: RecordingRemoteStatus.failed,
                  retryActions: const <RecordingRetryAction>[
                    RecordingRetryAction(
                      stage: 'asr',
                      title: '重试转写',
                      allowed: true,
                    ),
                  ],
                ),
              ),
            ],
          },
        );
        final tracker = RecordingProcessingTracker(
          recordingApi: api,
          draftStore: store,
          delay: _immediateDelay,
        );

        await tracker.track(draft);

        final task = tracker.state.taskFor('rec-1');
        expect(task?.status, RecordingFileJobStatus.failed);
        expect(task?.phase, RecordingProcessingPhase.failed);
        expect(task?.errorCode, 'RECORDING_TRANSCRIPTION_FAILED');
        expect((task?.appTaskState as AppTaskFailed).retryable, isTrue);
        expect(
          store.getDraft(draft.draftId)?.stage,
          UploadDraftStage.asrFailed,
        );
        expect(api.retryCalls, 0);
      },
    );

    test('clears stale retry authority on recording mismatch', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final draft = _draft();
      expect(store.saveDraft(draft).ok, isTrue);
      final api = _FakeRecordingApi(
        details: <String, List<ApiResult<RecordingDetail>>>{
          'rec-1': <ApiResult<RecordingDetail>>[
            _detailResult(
              _detail(
                status: RecordingRemoteStatus.processing,
                retryActions: const <RecordingRetryAction>[
                  RecordingRetryAction(
                    stage: 'asr',
                    title: '重试转写',
                    allowed: true,
                  ),
                ],
              ),
            ),
            _detailResult(
              _detail(
                recordingId: 'rec-other',
                status: RecordingRemoteStatus.processing,
              ),
            ),
          ],
        },
      );
      final tracker = RecordingProcessingTracker(
        recordingApi: api,
        draftStore: store,
        delay: _immediateDelay,
      );
      addTearDown(tracker.dispose);

      await tracker.track(draft);

      final task = tracker.state.taskFor('rec-1');
      expect(task?.status, RecordingFileJobStatus.failed);
      expect(task?.errorCode, 'RECORDING_PROCESSING_RECORDING_MISMATCH');
      expect(task?.detail, isNull);
      expect((task?.appTaskState as AppTaskFailed).retryable, isFalse);
    });

    test('keeps the Raw recording ready when Outline needs a retry', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final draft = _draft();
      expect(store.saveDraft(draft).ok, isTrue);
      const detail = RecordingDetail(
        recording: RecordingAsset(
          recordingId: 'rec-1',
          title: '录音 rec-1',
          status: RecordingRemoteStatus.completed,
          transcriptStatus: 'final_transcript_generated',
          minutesStatus: 'succeeded',
          summaryStatus: 'succeeded',
        ),
        asrTask: AsrTaskSnapshot(
          asrTaskId: 'asr-rec-1',
          status: RecordingRemoteStatus.completed,
        ),
        finalTranscript: '已经完成的转写内容。',
        finalTranscriptConfirmed: true,
        noteRef: RecordingNoteRef(
          noteId: 'note-rec-1',
          rawPartRevisionId: 'raw-rec-1',
          outlinePartRevisionId: 'outline-rec-1',
        ),
        retryActions: <RecordingRetryAction>[
          RecordingRetryAction(
            stage: 'recording_note_outline',
            title: '重新生成纲要',
            allowed: true,
          ),
        ],
      );
      final api = _FakeRecordingApi(
        details: <String, List<ApiResult<RecordingDetail>>>{
          'rec-1': <ApiResult<RecordingDetail>>[_detailResult(detail)],
        },
      );
      final tracker = RecordingProcessingTracker(
        recordingApi: api,
        draftStore: store,
        delay: _immediateDelay,
      );

      await tracker.track(draft);

      final task = tracker.state.taskFor('rec-1');
      expect(task?.status, RecordingFileJobStatus.ready);
      expect(task?.phase, RecordingProcessingPhase.completed);
      expect(task?.isActive, isFalse);
      expect(task?.errorCode, isNull);
      expect(
        store.getDraft(draft.draftId)?.stage,
        UploadDraftStage.asrCompleted,
      );
      expect(api.detailCalls, 1);
      expect(api.retryCalls, 0);
    });

    test('does not classify Outline failure as Raw asset failure', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final draft = _draft();
      expect(store.saveDraft(draft).ok, isTrue);
      final outlineFailedBeforeAssetReceipt = parseRecordingDetail(
        <String, Object?>{
          'recording': <String, Object?>{
            'recordingId': 'rec-1',
            'title': '录音 rec-1',
            'status': 'failed',
            'transcriptStatus': 'final_transcript_generated',
            'minutesStatus': 'failed',
            'summaryStatus': 'failed',
          },
          'asrTask': <String, Object?>{
            'asrTaskId': 'asr-rec-1',
            'status': 'final_transcript_generated',
          },
          'transcript': <String, Object?>{'finalTranscript': '已经完成的转写内容。'},
          'subTasks': <Object?>[
            <String, Object?>{
              'recordingSubTaskId': 'outline-task-1',
              'recordingId': 'rec-1',
              'taskType': 'recording_note_outline',
              'status': 'failed',
            },
          ],
        },
      )!;
      expect(
        outlineFailedBeforeAssetReceipt.recording.status,
        RecordingRemoteStatus.failed,
      );
      expect(outlineFailedBeforeAssetReceipt.rawTerminalFailureStatus, isNull);
      final api = _FakeRecordingApi(
        details: <String, List<ApiResult<RecordingDetail>>>{
          'rec-1': <ApiResult<RecordingDetail>>[
            _detailResult(outlineFailedBeforeAssetReceipt),
            _detailResult(_completedDetail()),
          ],
        },
      );
      final tracker = RecordingProcessingTracker(
        recordingApi: api,
        draftStore: store,
        delay: _immediateDelay,
      );
      addTearDown(tracker.dispose);

      await tracker.track(draft);

      expect(api.detailCalls, 2);
      expect(
        tracker.state.taskFor('rec-1')?.status,
        RecordingFileJobStatus.ready,
      );
      expect(
        store.getDraft(draft.draftId)?.stage,
        UploadDraftStage.asrCompleted,
      );
    });

    test(
      'waits for the canonical Note before completing transcription',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        const awaitingNote = RecordingDetail(
          recording: RecordingAsset(
            recordingId: 'rec-1',
            title: '录音 rec-1',
            status: RecordingRemoteStatus.generatingMinutes,
            transcriptStatus: 'final_transcript_generated',
          ),
          asrTask: AsrTaskSnapshot(
            asrTaskId: 'asr-rec-1',
            status: RecordingRemoteStatus.completed,
          ),
          finalTranscript: '已经完成的转写内容。',
          finalTranscriptConfirmed: true,
        );
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              _detailResult(awaitingNote),
              _detailResult(_completedDetail()),
            ],
          },
        );
        final delay = _ControllableDelay();
        final tracker = RecordingProcessingTracker(
          recordingApi: api,
          draftStore: store,
          delay: delay.call,
        );

        final processing = tracker.track(draft);
        final completion = tracker.waitForTerminal('rec-1');
        await _drainMicrotasks();

        expect(
          tracker.state.taskFor('rec-1')?.status,
          RecordingFileJobStatus.processing,
        );
        expect(
          store.getDraft(draft.draftId)?.stage,
          UploadDraftStage.asrQueued,
        );
        expect(api.detailCalls, 1);

        delay.release();
        await processing;

        expect(
          (await completion).status,
          RecordingProcessingCompletionStatus.completed,
        );
        expect(
          tracker.state.taskFor('rec-1')?.status,
          RecordingFileJobStatus.ready,
        );
        expect(
          store.getDraft(draft.draftId)?.stage,
          UploadDraftStage.asrCompleted,
        );
        expect(api.detailCalls, 2);
      },
    );

    test('terminal subscribers can release only their own waiter', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final draft = _draft();
      expect(store.saveDraft(draft).ok, isTrue);
      final tracker = RecordingProcessingTracker(
        recordingApi: _FakeRecordingApi(
          details: const <String, List<ApiResult<RecordingDetail>>>{},
        ),
        draftStore: store,
        delay: _immediateDelay,
      );

      final cancelled = tracker.observeTerminal('rec-1');
      final independentlyOwned = tracker.observeTerminal('rec-1');
      cancelled.cancel();
      final cancelledResult = await cancelled.completion;

      expect(
        cancelledResult.status,
        RecordingProcessingCompletionStatus.unavailable,
      );
      expect(
        cancelledResult.errorCode,
        'RECORDING_PROCESSING_COMPLETION_CANCELLED',
      );

      tracker.dispose();
      final disposedResult = await independentlyOwned.completion;

      expect(
        disposedResult.status,
        RecordingProcessingCompletionStatus.unavailable,
      );
      expect(disposedResult.errorCode, 'RECORDING_PROCESSING_DISPOSED');
    });

    test('completes the recording job while Outline is still queued', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final draft = _draft();
      expect(store.saveDraft(draft).ok, isTrue);
      const queuedOutline = RecordingDetail(
        recording: RecordingAsset(
          recordingId: 'rec-1',
          title: '录音 rec-1',
          status: RecordingRemoteStatus.completed,
          transcriptStatus: 'final_transcript_generated',
          minutesStatus: 'succeeded',
          summaryStatus: 'succeeded',
        ),
        asrTask: AsrTaskSnapshot(
          asrTaskId: 'asr-rec-1',
          status: RecordingRemoteStatus.completed,
        ),
        finalTranscript: '已经完成的转写内容。',
        finalTranscriptConfirmed: true,
        noteRef: RecordingNoteRef(
          noteId: 'note-rec-1',
          rawPartRevisionId: 'raw-rec-1',
          outlinePartRevisionId: 'outline-rec-1',
        ),
        noteOutlineTask: RecordingNoteOutlineTask(
          taskId: 'outline-task-1',
          status: RecordingNoteOutlineTaskStatus.queued,
        ),
        hasSubTaskSnapshot: true,
        retryActions: <RecordingRetryAction>[
          RecordingRetryAction(
            stage: 'recording_note_outline',
            title: '旧失败记录',
            allowed: true,
          ),
        ],
      );
      final api = _FakeRecordingApi(
        details: <String, List<ApiResult<RecordingDetail>>>{
          'rec-1': <ApiResult<RecordingDetail>>[_detailResult(queuedOutline)],
        },
      );
      final observedOutlineStatuses = <RecordingNoteOutlineTaskStatus>[];
      final tracker = RecordingProcessingTracker(
        recordingApi: api,
        draftStore: store,
        delay: _immediateDelay,
        onDetailChanged: (detail) async {
          final status = detail.noteOutlineTask?.status;
          if (status != null) observedOutlineStatuses.add(status);
          return true;
        },
      );
      final observedPhases = <RecordingProcessingPhase>[];
      tracker.addListener(() {
        final phase = tracker.state.taskFor('rec-1')?.phase;
        if (phase != null &&
            (observedPhases.isEmpty || observedPhases.last != phase)) {
          observedPhases.add(phase);
        }
      });

      await tracker.track(draft);

      expect(api.detailCalls, 1);
      expect(
        tracker.state.taskFor('rec-1')?.status,
        RecordingFileJobStatus.ready,
      );
      expect(
        store.getDraft(draft.draftId)?.stage,
        UploadDraftStage.asrCompleted,
      );
      await _drainMicrotasks();
      expect(observedOutlineStatuses, <RecordingNoteOutlineTaskStatus>[
        RecordingNoteOutlineTaskStatus.queued,
      ]);
      expect(observedPhases, <RecordingProcessingPhase>[
        RecordingProcessingPhase.transcribing,
        RecordingProcessingPhase.storingCloudNote,
        RecordingProcessingPhase.completed,
      ]);
    });

    test('retries and latches one pending speaker version', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final draft = _draft();
      expect(store.saveDraft(draft).ok, isTrue);
      final api = _FakeRecordingApi(
        details: <String, List<ApiResult<RecordingDetail>>>{
          'rec-1': <ApiResult<RecordingDetail>>[
            _detailResult(
              _detail(
                status: RecordingRemoteStatus.speakerLabelPending,
                asrVersion: 4,
              ),
            ),
            _detailResult(
              _detail(
                status: RecordingRemoteStatus.speakerLabelPending,
                asrVersion: 4,
              ),
            ),
            _detailResult(
              _detail(
                status: RecordingRemoteStatus.speakerLabelPending,
                asrVersion: 4,
              ),
            ),
            _detailResult(_detail(status: RecordingRemoteStatus.completed)),
          ],
        },
        speakerAdvanceFailuresRemaining: 1,
      );
      final tracker = RecordingProcessingTracker(
        recordingApi: api,
        draftStore: store,
        delay: (_) async {},
      );

      await tracker.track(draft);

      expect(
        tracker.state.taskFor('rec-1')?.status,
        RecordingFileJobStatus.ready,
      );
      expect(api.detailCalls, 4);
      expect(api.speakerAdvanceCalls, hasLength(2));
      expect(
        api.speakerAdvanceCalls.map((call) => call.recordingId),
        everyElement('rec-1'),
      );
      expect(
        api.speakerAdvanceCalls.map((call) => call.asrTaskId),
        everyElement('asr-rec-1'),
      );
      expect(
        api.speakerAdvanceCalls.map((call) => call.version),
        everyElement(4),
      );
      expect(
        api.speakerAdvanceCalls.map((call) => call.idempotencyKey).toSet(),
        hasLength(1),
      );
    });

    test('recovers every persisted queued recording independently', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final first = _draft(draftId: 'upload-1', recordingId: 'rec-1');
      final second = _draft(draftId: 'upload-2', recordingId: 'rec-2');
      expect(store.saveDraft(first).ok, isTrue);
      expect(store.saveDraft(second).ok, isTrue);
      final api = _FakeRecordingApi(
        details: <String, List<ApiResult<RecordingDetail>>>{
          'rec-1': <ApiResult<RecordingDetail>>[
            _detailResult(
              _detail(
                recordingId: 'rec-1',
                status: RecordingRemoteStatus.completed,
              ),
            ),
          ],
          'rec-2': <ApiResult<RecordingDetail>>[
            _detailResult(
              _detail(
                recordingId: 'rec-2',
                status: RecordingRemoteStatus.completed,
              ),
            ),
          ],
        },
      );
      final tracker = RecordingProcessingTracker(
        recordingApi: api,
        draftStore: store,
        delay: _immediateDelay,
      );

      await tracker.recoverPending();
      await _drainMicrotasks();

      expect(
        tracker.state.taskFor('rec-1')?.status,
        RecordingFileJobStatus.ready,
      );
      expect(
        tracker.state.taskFor('rec-2')?.status,
        RecordingFileJobStatus.ready,
      );
      expect(
        store.getDraft(first.draftId)?.stage,
        UploadDraftStage.asrCompleted,
      );
      expect(
        store.getDraft(second.draftId)?.stage,
        UploadDraftStage.asrCompleted,
      );
    });

    test(
      'retries a transient detail read without issuing a backend retry',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              ApiResult<RecordingDetail>.failure(
                error: recordingApiFailure('NETWORK_REQUEST_FAILED'),
                idempotencyStore: SubmissionKeyStore.empty,
              ),
              _detailResult(_detail(status: RecordingRemoteStatus.completed)),
            ],
          },
        );
        final tracker = RecordingProcessingTracker(
          recordingApi: api,
          draftStore: store,
          delay: _immediateDelay,
        );

        await tracker.track(draft);

        expect(
          tracker.state.taskFor('rec-1')?.status,
          RecordingFileJobStatus.ready,
        );
        expect(api.detailCalls, 2);
        expect(api.retryCalls, 0);
      },
    );

    test(
      'restores terminal automatic recording tasks without a detail read',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final completed =
            _draft(
              draftId: 'completed',
              recordingId: 'rec-completed',
              workspaceId: 'workspace-a',
            ).copyWith(
              stage: UploadDraftStage.asrCompleted,
              updatedAt: DateTime.utc(2026, 8, 19, 9),
            );
        final failed =
            _draft(
              draftId: 'failed',
              recordingId: 'rec-failed',
              workspaceId: 'workspace-a',
            ).copyWith(
              stage: UploadDraftStage.asrFailed,
              lastErrorCode: 'RECORDING_PROCESSING_TIMEOUT',
              updatedAt: DateTime.utc(2026, 8, 19, 10),
            );
        expect(store.saveDraft(completed).ok, isTrue);
        expect(store.saveDraft(failed).ok, isTrue);
        final api = _FakeRecordingApi(
          details: const <String, List<ApiResult<RecordingDetail>>>{},
        );
        final tracker = _workspaceTracker(
          api: api,
          store: store,
          workspaceScope: 'workspace-a',
          activeWorkspaceScope: () => 'workspace-a',
        );

        await tracker.recoverPending();

        expect(
          tracker.state.taskFor('rec-completed')?.status,
          RecordingFileJobStatus.ready,
        );
        expect(
          tracker.state.taskFor('rec-failed')?.status,
          RecordingFileJobStatus.failed,
        );
        expect(
          tracker.state.taskFor('rec-failed')?.errorCode,
          'RECORDING_PROCESSING_TIMEOUT',
        );
        expect(api.detailCalls, 0);
      },
    );

    test(
      're-enrolls only its current-Workspace failed checkpoint after retry',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final current =
            _draft(
              draftId: 'failed-current',
              recordingId: 'rec-current',
              workspaceId: 'workspace-a',
            ).copyWith(
              stage: UploadDraftStage.asrFailed,
              lastErrorCode:
                  'RECORDING_PROCESSING_RECORDING_NOTE_OUTLINE_FAILED',
            );
        final foreign = _draft(
          draftId: 'failed-foreign',
          recordingId: 'rec-foreign',
          workspaceId: 'workspace-b',
        ).copyWith(stage: UploadDraftStage.asrFailed);
        expect(store.saveDraft(current).ok, isTrue);
        expect(store.saveDraft(foreign).ok, isTrue);
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-current': <ApiResult<RecordingDetail>>[
              _detailResult(
                _detail(
                  recordingId: 'rec-current',
                  status: RecordingRemoteStatus.processing,
                ),
              ),
              _detailResult(
                _detail(
                  recordingId: 'rec-current',
                  status: RecordingRemoteStatus.completed,
                ),
              ),
            ],
          },
        );
        final firstPollDelay = _ControllableDelay();
        final firstTracker = _workspaceTracker(
          api: api,
          store: store,
          workspaceScope: 'workspace-a',
          activeWorkspaceScope: () => 'workspace-a',
          delay: firstPollDelay.call,
        );

        expect(await firstTracker.reenrollAfterRetry('rec-current'), isTrue);
        await _drainMicrotasks();

        expect(api.recordingIds, <String>['rec-current']);
        expect(
          store.getDraft(current.draftId)?.stage,
          UploadDraftStage.asrQueued,
        );
        expect(store.getDraft(current.draftId)?.lastErrorCode, isNull);
        expect(
          firstTracker.state.taskFor('rec-current')?.status,
          RecordingFileJobStatus.processing,
        );
        expect(
          store.getDraft(foreign.draftId)?.stage,
          UploadDraftStage.asrFailed,
        );
        expect(await firstTracker.reenrollAfterRetry('rec-foreign'), isFalse);

        // The retry checkpoint is durable. A fresh app-scoped tracker must
        // continue the same server job rather than leaving it terminal when
        // the previous page/tracker instance is gone.
        firstTracker.dispose();
        firstPollDelay.release();
        final replacement = _workspaceTracker(
          api: api,
          store: store,
          workspaceScope: 'workspace-a',
          activeWorkspaceScope: () => 'workspace-a',
        );
        addTearDown(replacement.dispose);

        await replacement.recoverPending();
        await _drainMicrotasks();

        expect(api.recordingIds, <String>['rec-current', 'rec-current']);
        expect(
          replacement.state.taskFor('rec-current')?.status,
          RecordingFileJobStatus.ready,
        );
        expect(
          store.getDraft(current.draftId)?.stage,
          UploadDraftStage.asrCompleted,
        );
      },
    );

    test(
      'recovers only its frozen Workspace and cancels stale polling',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final current = _draft(
          draftId: 'current',
          recordingId: 'rec-current',
          workspaceId: 'workspace-a',
        );
        final foreign = _draft(
          draftId: 'foreign',
          recordingId: 'rec-foreign',
          workspaceId: 'workspace-b',
        );
        final legacy = _draft(draftId: 'legacy', recordingId: 'rec-legacy');
        expect(store.saveDraft(current).ok, isTrue);
        expect(store.saveDraft(foreign).ok, isTrue);
        expect(store.saveDraft(legacy).ok, isTrue);
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-current': <ApiResult<RecordingDetail>>[
              _detailResult(
                _detail(
                  recordingId: 'rec-current',
                  status: RecordingRemoteStatus.processing,
                ),
              ),
            ],
          },
        );
        final delay = _ControllableDelay();
        var activeWorkspace = 'workspace-a';
        final tracker = _workspaceTracker(
          api: api,
          store: store,
          workspaceScope: 'workspace-a',
          activeWorkspaceScope: () => activeWorkspace,
          delay: delay.call,
        );

        await tracker.recoverPending();
        await _drainMicrotasks();

        expect(api.recordingIds, <String>['rec-current']);
        expect(tracker.state.taskFor('rec-current')?.isActive, isTrue);
        expect(tracker.state.taskFor('rec-foreign'), isNull);
        expect(tracker.state.taskFor('rec-legacy'), isNull);

        activeWorkspace = 'workspace-b';
        await tracker.refreshPending();

        expect(tracker.state.tasks, isEmpty);
        delay.release();
        await _drainMicrotasks();
        expect(api.recordingIds, <String>['rec-current']);
      },
    );

    test(
      'forwards changed detail facts through the narrow projection observer',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              _detailResult(_detail(status: RecordingRemoteStatus.processing)),
              _detailResult(_detail(status: RecordingRemoteStatus.completed)),
            ],
          },
        );
        final observed = <RecordingDetail>[];
        final tracker = RecordingProcessingTracker(
          recordingApi: api,
          draftStore: store,
          delay: _immediateDelay,
          onDetailChanged: (detail) async {
            observed.add(detail);
            return true;
          },
        );

        await tracker.track(draft);
        await _drainMicrotasks();

        expect(
          observed.map((detail) => detail.recording.status),
          <RecordingRemoteStatus>[
            RecordingRemoteStatus.processing,
            RecordingRemoteStatus.completed,
          ],
        );
      },
    );

    test(
      'does not let best-effort projection block asset completion',
      () async {
        for (final throws in <bool>[false, true]) {
          final store = UploadDraftStore(database: AppDatabase());
          final draft = _draft(draftId: 'upload-$throws');
          expect(store.saveDraft(draft).ok, isTrue);
          final api = _FakeRecordingApi(
            details: <String, List<ApiResult<RecordingDetail>>>{
              'rec-1': <ApiResult<RecordingDetail>>[
                _detailResult(_completedDetail()),
              ],
            },
          );
          var projectionAttempts = 0;
          final tracker = RecordingProcessingTracker(
            recordingApi: api,
            draftStore: store,
            delay: _immediateDelay,
            onDetailChanged: (_) async {
              projectionAttempts += 1;
              if (throws) throw StateError('projection unavailable');
              return false;
            },
          );
          addTearDown(tracker.dispose);

          await tracker.track(draft);

          expect(projectionAttempts, 1, reason: 'throws=$throws');
          expect(api.detailCalls, 1, reason: 'throws=$throws');
          expect(
            tracker.state.taskFor('rec-1')?.status,
            RecordingFileJobStatus.ready,
            reason: 'throws=$throws',
          );
        }
      },
    );

    test('retries local projection after publishing Raw completion', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final draft = _draft();
      expect(store.saveDraft(draft).ok, isTrue);
      final projectionCompleted = Completer<void>();
      var projectionAttempts = 0;
      final orchestrator = TaskOrchestrator();
      final tracker = RecordingProcessingTracker(
        recordingApi: _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              _detailResult(_completedDetail()),
            ],
          },
        ),
        draftStore: store,
        pollInterval: const Duration(milliseconds: 1),
        onDetailChanged: (_) async {
          projectionAttempts += 1;
          if (projectionAttempts < 2) return false;
          if (!projectionCompleted.isCompleted) {
            projectionCompleted.complete();
          }
          return true;
        },
      );
      addTearDown(tracker.dispose);
      addTearDown(orchestrator.dispose);
      tracker.attachPollingRuntime(
        orchestrator: orchestrator,
        activityMetrics: RuntimeActivityMetrics(),
      );

      await tracker.track(draft);

      expect(
        tracker.state.taskFor('rec-1')?.status,
        RecordingFileJobStatus.ready,
      );
      await projectionCompleted.future.timeout(const Duration(seconds: 1));
      expect(projectionAttempts, 2);
      expect(
        tracker.state.taskFor('rec-1')?.status,
        RecordingFileJobStatus.ready,
      );
    });

    test(
      'stops local projection after its retry budget is exhausted',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        final exhausted = Completer<void>();
        var projectionAttempts = 0;
        final orchestrator = TaskOrchestrator();
        final tracker = RecordingProcessingTracker(
          recordingApi: _FakeRecordingApi(
            details: <String, List<ApiResult<RecordingDetail>>>{
              'rec-1': <ApiResult<RecordingDetail>>[
                _detailResult(_completedDetail()),
              ],
            },
          ),
          draftStore: store,
          pollInterval: const Duration(milliseconds: 1),
          detailProjectionRetryLimit: 2,
          onDetailChanged: (_) async {
            projectionAttempts += 1;
            if (projectionAttempts == 2 && !exhausted.isCompleted) {
              exhausted.complete();
            }
            return false;
          },
        );
        addTearDown(tracker.dispose);
        addTearDown(orchestrator.dispose);
        tracker.attachPollingRuntime(
          orchestrator: orchestrator,
          activityMetrics: RuntimeActivityMetrics(),
        );

        await tracker.track(draft);
        await exhausted.future.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(projectionAttempts, 2);
        expect(
          tracker.state.taskFor('rec-1')?.status,
          RecordingFileJobStatus.ready,
        );
      },
    );

    test('abandons one hung projection at its attempt timeout', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final draft = _draft();
      expect(store.saveDraft(draft).ok, isTrue);
      final observerResult = Completer<bool>();
      var projectionAttempts = 0;
      final orchestrator = TaskOrchestrator();
      final tracker = RecordingProcessingTracker(
        recordingApi: _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              _detailResult(_completedDetail()),
            ],
          },
        ),
        draftStore: store,
        pollInterval: const Duration(milliseconds: 1),
        detailProjectionAttemptTimeout: const Duration(milliseconds: 10),
        onDetailChanged: (_) {
          projectionAttempts += 1;
          return observerResult.future;
        },
      );
      addTearDown(tracker.dispose);
      addTearDown(orchestrator.dispose);
      tracker.attachPollingRuntime(
        orchestrator: orchestrator,
        activityMetrics: RuntimeActivityMetrics(),
      );

      await tracker.track(draft);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(projectionAttempts, 1);
      expect(orchestrator.activeByResource[TaskResource.network], isNull);
      expect(
        tracker.state.taskFor('rec-1')?.status,
        RecordingFileJobStatus.ready,
      );
      observerResult.complete(true);
    });

    test(
      'shares one unresolved projection across foreground suspension',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        final observerStarted = Completer<void>();
        final observerResult = Completer<bool>();
        var projectionAttempts = 0;
        final orchestrator = TaskOrchestrator();
        final tracker = RecordingProcessingTracker(
          recordingApi: _FakeRecordingApi(
            details: <String, List<ApiResult<RecordingDetail>>>{
              'rec-1': <ApiResult<RecordingDetail>>[
                _detailResult(_completedDetail()),
              ],
            },
          ),
          draftStore: store,
          pollInterval: const Duration(milliseconds: 1),
          onDetailChanged: (_) {
            projectionAttempts += 1;
            if (!observerStarted.isCompleted) observerStarted.complete();
            return observerResult.future;
          },
        );
        addTearDown(tracker.dispose);
        addTearDown(orchestrator.dispose);
        tracker.attachPollingRuntime(
          orchestrator: orchestrator,
          activityMetrics: RuntimeActivityMetrics(),
        );

        final tracked = tracker.track(draft);
        await observerStarted.future.timeout(const Duration(seconds: 1));
        await tracked;
        orchestrator.setForeground(false);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(orchestrator.activeByResource[TaskResource.network], isNull);
        orchestrator.setForeground(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(projectionAttempts, 1);
        observerResult.complete(true);
        await _drainMicrotasks();
        expect(projectionAttempts, 1);
        expect(
          tracker.state.taskFor('rec-1')?.status,
          RecordingFileJobStatus.ready,
        );
      },
    );

    test('does not reuse a projection generation after scope reset', () async {
      final store = UploadDraftStore(database: AppDatabase());
      final draft = _draft(workspaceId: 'workspace-a');
      expect(store.saveDraft(draft).ok, isTrue);
      final firstObserverResult = Completer<bool>();
      final secondObserverStarted = Completer<void>();
      var projectionAttempts = 0;
      var activeWorkspace = 'workspace-a';
      final orchestrator = TaskOrchestrator();
      final tracker = RecordingProcessingTracker(
        recordingApi: _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              _detailResult(_completedDetail()),
            ],
          },
        ),
        draftStore: store,
        accountScope: 'user-a',
        activeAccountScope: () => 'user-a',
        workspaceScope: 'workspace-a',
        activeWorkspaceScope: () => activeWorkspace,
        pollInterval: const Duration(milliseconds: 1),
        onDetailChanged: (_) {
          projectionAttempts += 1;
          if (projectionAttempts == 1) return firstObserverResult.future;
          if (!secondObserverStarted.isCompleted) {
            secondObserverStarted.complete();
          }
          return Future<bool>.value(true);
        },
      );
      addTearDown(tracker.dispose);
      addTearDown(orchestrator.dispose);
      tracker.attachPollingRuntime(
        orchestrator: orchestrator,
        activityMetrics: RuntimeActivityMetrics(),
      );

      await tracker.track(draft);
      expect(projectionAttempts, 1);
      activeWorkspace = 'workspace-b';
      await tracker.refreshPending();
      activeWorkspace = 'workspace-a';
      await tracker.track(draft);

      firstObserverResult.complete(true);
      await secondObserverStarted.future.timeout(const Duration(seconds: 1));

      expect(projectionAttempts, 2);
      expect(
        tracker.state.taskFor('rec-1')?.status,
        RecordingFileJobStatus.ready,
      );
    });

    test(
      'runtime polling suspends in background and redacts its task key',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final draft = _draft(recordingId: 'rec-private-42');
        expect(store.saveDraft(draft).ok, isTrue);
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-private-42': <ApiResult<RecordingDetail>>[
              _detailResult(
                _detail(
                  recordingId: 'rec-private-42',
                  status: RecordingRemoteStatus.processing,
                ),
              ),
              _detailResult(
                _detail(
                  recordingId: 'rec-private-42',
                  status: RecordingRemoteStatus.completed,
                ),
              ),
            ],
          },
        );
        final orchestrator = TaskOrchestrator()..setForeground(false);
        final metrics = RuntimeActivityMetrics();
        final tracker =
            RecordingProcessingTracker(
              recordingApi: api,
              draftStore: store,
              pollInterval: const Duration(milliseconds: 1),
            )..attachPollingRuntime(
              orchestrator: orchestrator,
              activityMetrics: metrics,
            );
        addTearDown(() {
          tracker.dispose();
          orchestrator.dispose();
          metrics.dispose();
        });

        final finished = tracker.track(draft);
        await Future<void>.delayed(Duration.zero);
        expect(api.detailCalls, 0);
        expect(metrics.current.activePollers, 0);

        orchestrator.setForeground(true);
        await finished.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);

        expect(api.detailCalls, 2);
        expect(metrics.snapshot().peakPollers, 1);
        expect(metrics.current.activePollers, 0);
        expect(
          orchestrator.snapshot.projections.every(
            (projection) => !projection.spec.key.contains('rec-private-42'),
          ),
          isTrue,
        );
      },
    );

    test(
      'runtime observation budget pauses without inventing failure',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              _detailResult(_detail(status: RecordingRemoteStatus.processing)),
              _detailResult(_completedDetail()),
            ],
          },
        );
        final orchestrator = TaskOrchestrator();
        final metrics = RuntimeActivityMetrics();
        final tracker =
            RecordingProcessingTracker(
              recordingApi: api,
              draftStore: store,
              pollInterval: const Duration(milliseconds: 1),
              maxObservationDuration: Duration.zero,
            )..attachPollingRuntime(
              orchestrator: orchestrator,
              activityMetrics: metrics,
            );
        addTearDown(() {
          tracker.dispose();
          orchestrator.dispose();
          metrics.dispose();
        });

        await tracker.track(draft).timeout(const Duration(seconds: 1));

        expect(api.detailCalls, 0);
        expect(
          tracker.state.taskFor('rec-1')?.status,
          RecordingFileJobStatus.processing,
        );
        expect(tracker.state.taskFor('rec-1')?.errorCode, isNull);
        expect(
          store.getDraft(draft.draftId)?.stage,
          UploadDraftStage.asrQueued,
        );
      },
    );

    test(
      'injected observation budget preserves its queued checkpoint',
      () async {
        final store = UploadDraftStore(database: AppDatabase());
        final draft = _draft();
        expect(store.saveDraft(draft).ok, isTrue);
        final api = _FakeRecordingApi(
          details: <String, List<ApiResult<RecordingDetail>>>{
            'rec-1': <ApiResult<RecordingDetail>>[
              _detailResult(_detail(status: RecordingRemoteStatus.processing)),
            ],
          },
        );
        final tracker = RecordingProcessingTracker(
          recordingApi: api,
          draftStore: store,
          delay: _immediateDelay,
          maxObservationDuration: Duration.zero,
        );
        addTearDown(tracker.dispose);

        await tracker.track(draft);

        expect(api.detailCalls, 0);
        expect(
          tracker.state.taskFor('rec-1')?.status,
          RecordingFileJobStatus.processing,
        );
        expect(tracker.state.taskFor('rec-1')?.errorCode, isNull);
        expect(
          store.getDraft(draft.draftId)?.stage,
          UploadDraftStage.asrQueued,
        );
      },
    );
  });
}

Future<void> _immediateDelay(Duration _) async {}

Future<void> _drainMicrotasks() async {
  for (var index = 0; index < 5; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

UploadDraft _draft({
  String draftId = 'upload-1',
  String recordingId = 'rec-1',
  String? workspaceId,
}) {
  return UploadDraft(
    draftId: draftId,
    localRecordingId: 'local-$draftId',
    appPrivateUri: 'app-private://recordings/$draftId.m4a',
    fileName: '$draftId.m4a',
    mimeType: 'audio/mp4',
    sizeBytes: 1024,
    durationSeconds: 30,
    sourceScene: 'local_upload',
    workspaceId: workspaceId,
    stage: UploadDraftStage.asrQueued,
    updatedAt: DateTime.utc(2026, 8, 19, 8),
    uploadTokenKey: 'upload-$draftId',
    completeUploadKey: 'complete-$draftId',
    createRecordingKey: 'create-$draftId',
    recordingId: recordingId,
    asrTaskId: 'asr-$recordingId',
    title: '录音 $recordingId',
  );
}

RecordingProcessingTracker _workspaceTracker({
  required _FakeRecordingApi api,
  required UploadDraftStore store,
  required String workspaceScope,
  required String? Function() activeWorkspaceScope,
  RecordingProcessingDelay? delay,
}) {
  return RecordingProcessingTracker(
    recordingApi: api,
    draftStore: store,
    delay: delay ?? _immediateDelay,
    accountScope: 'user-a',
    activeAccountScope: () => 'user-a',
    workspaceScope: workspaceScope,
    activeWorkspaceScope: activeWorkspaceScope,
  );
}

final class _ControllableDelay {
  Completer<void>? _pending;

  Future<void> call(Duration _) {
    final pending = Completer<void>();
    _pending = pending;
    return pending.future;
  }

  void release() {
    final pending = _pending;
    if (pending == null || pending.isCompleted) {
      throw StateError('NO_PENDING_DELAY');
    }
    pending.complete();
  }
}

RecordingDetail _detail({
  String recordingId = 'rec-1',
  required RecordingRemoteStatus status,
  int? asrVersion,
  List<RecordingRetryAction> retryActions = const <RecordingRetryAction>[],
}) {
  final completed =
      status == RecordingRemoteStatus.completed ||
      status == RecordingRemoteStatus.deposited;
  return RecordingDetail(
    recording: RecordingAsset(
      recordingId: recordingId,
      title: '录音 $recordingId',
      status: status,
      transcriptStatus: completed
          ? 'final_transcript_generated'
          : status == RecordingRemoteStatus.speakerLabelPending
          ? 'transcribed'
          : null,
      speakerLabelStatus: status == RecordingRemoteStatus.speakerLabelPending
          ? 'pending'
          : null,
    ),
    asrTask: AsrTaskSnapshot(
      asrTaskId: 'asr-$recordingId',
      status: status,
      version: asrVersion,
    ),
    finalTranscript: completed ? '已经完成的转写内容。' : null,
    finalTranscriptConfirmed: completed ? true : null,
    noteRef: completed
        ? RecordingNoteRef(
            noteId: 'note-$recordingId',
            rawPartRevisionId: 'raw-$recordingId',
            outlinePartRevisionId: 'outline-$recordingId',
          )
        : null,
    noteOutlineTask: completed
        ? RecordingNoteOutlineTask(
            taskId: 'outline-task-$recordingId',
            status: RecordingNoteOutlineTaskStatus.succeeded,
          )
        : null,
    hasSubTaskSnapshot: completed,
    retryActions: retryActions,
  );
}

RecordingDetail _completedDetail({String recordingId = 'rec-1'}) {
  return _detail(
    recordingId: recordingId,
    status: RecordingRemoteStatus.completed,
  );
}

ApiResult<RecordingDetail> _detailResult(RecordingDetail detail) {
  return ApiResult<RecordingDetail>.success(
    data: detail,
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final class _FakeRecordingApi
    implements RecordingApiPort, RecordingSpeakerAutoAdvanceApiPort {
  _FakeRecordingApi({
    required this.details,
    this.speakerAdvanceFailuresRemaining = 0,
  });

  final Map<String, List<ApiResult<RecordingDetail>>> details;
  final Map<String, int> _readOffsets = <String, int>{};
  final List<String> recordingIds = <String>[];
  final speakerAdvanceCalls =
      <
        ({
          String recordingId,
          String asrTaskId,
          int version,
          String idempotencyKey,
        })
      >[];
  var detailCalls = 0;
  var retryCalls = 0;
  int speakerAdvanceFailuresRemaining;

  @override
  Future<ApiResult<void>> autoAdvanceSpeakerLabels({
    required String recordingId,
    required String asrTaskId,
    required int baseAsrTaskVersion,
    required String idempotencyKey,
  }) async {
    speakerAdvanceCalls.add((
      recordingId: recordingId,
      asrTaskId: asrTaskId,
      version: baseAsrTaskVersion,
      idempotencyKey: idempotencyKey,
    ));
    if (speakerAdvanceFailuresRemaining > 0) {
      speakerAdvanceFailuresRemaining -= 1;
      return ApiResult<void>.failure(
        error: recordingApiFailure(
          'RECORDING_SPEAKER_TEMPORARILY_UNAVAILABLE',
          retryable: true,
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return ApiResult<void>.success(
      data: null,
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  ) => throw UnimplementedError();

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(
    String recordingId,
  ) async {
    detailCalls += 1;
    recordingIds.add(recordingId);
    final responses =
        details[recordingId] ?? const <ApiResult<RecordingDetail>>[];
    final index = _readOffsets[recordingId] ?? 0;
    _readOffsets[recordingId] = index + 1;
    if (responses.isEmpty) {
      return ApiResult<RecordingDetail>.failure(
        error: recordingApiFailure('RECORDING_DETAIL_MISSING'),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return responses[index < responses.length ? index : responses.length - 1];
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId) =>
      throw UnimplementedError();

  @override
  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) {
    retryCalls += 1;
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  }) {
    retryCalls += 1;
    throw UnimplementedError();
  }
}

final class _ToggleFailingSnapshotStore extends LocalDatabaseSnapshotStore {
  _ToggleFailingSnapshotStore()
    : super(file: File('unused-recording-processing.json'));

  bool failWrites = false;

  @override
  LocalDatabaseSnapshot? load() => null;

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    if (failWrites) throw const FileSystemException('forced write failure');
  }
}
