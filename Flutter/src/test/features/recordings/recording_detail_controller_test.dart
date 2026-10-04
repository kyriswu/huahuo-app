import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/recordings/application/recording_detail_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_processing_tracker.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';

void main() {
  group('RecordingDetailController', () {
    test('polls until terminal detail and then stops', () async {
      final api = _FakeRecordingApi(
        details: <RecordingDetail>[
          _detail(status: RecordingRemoteStatus.processing),
          _detail(
            status: RecordingRemoteStatus.completed,
            asrStatus: RecordingRemoteStatus.completed,
            transcript: '会议内容 provider 是正常用户词，不应被过滤',
          ),
        ],
      );
      final controller = RecordingDetailController(
        api: api,
        pollInterval: Duration.zero,
        delay: (_) async {},
      );

      await controller.loadAndPoll('rec-1');

      expect(controller.state.status, RecordingDetailControllerStatus.terminal);
      expect(controller.state.pollCount, 2);
      expect(api.detailCalls, 2);
      expect(
        controller.state.detail?.finalTranscript,
        contains('provider 是正常用户词'),
      );
    });

    test(
      'retryable initial detail read remains nonterminal until data arrives',
      () async {
        final api = _FakeRecordingApi(
          details: <RecordingDetail>[
            _detail(
              status: RecordingRemoteStatus.completed,
              asrStatus: RecordingRemoteStatus.completed,
              transcript: '瞬时失败后仍能显示的正式转写。',
            ),
          ],
          detailResults: <ApiResult<RecordingDetail>>[
            ApiResult<RecordingDetail>.failure(
              error: recordingApiFailure(
                'NETWORK_REQUEST_FAILED',
                retryable: true,
              ),
              idempotencyStore: SubmissionKeyStore.empty,
            ),
          ],
        );
        final controller = RecordingDetailController(
          api: api,
          pollInterval: Duration.zero,
          delay: (_) async {},
        );
        final visibleErrorCodes = <String?>[];
        controller.addListener(
          () => visibleErrorCodes.add(controller.state.lastErrorCode),
        );

        await controller.loadAndPoll('rec-1');

        expect(
          controller.state.status,
          RecordingDetailControllerStatus.terminal,
        );
        expect(controller.state.pollCount, 2);
        expect(controller.state.lastErrorCode, isNull);
        expect(visibleErrorCodes, everyElement(isNull));
        expect(controller.state.detail?.finalTranscript, '瞬时失败后仍能显示的正式转写。');
        expect(api.detailCalls, 2);
      },
    );

    test(
      'continues polling after the final transcript fact until terminal',
      () async {
        final api = _FakeRecordingApi(
          details: <RecordingDetail>[
            _detail(status: RecordingRemoteStatus.processing),
            const RecordingDetail(
              recording: RecordingAsset(
                recordingId: 'rec-1',
                title: 'Meeting',
                status: RecordingRemoteStatus.generatingMinutes,
                transcriptStatus: 'final_transcript_generated',
              ),
              asrTask: AsrTaskSnapshot(
                asrTaskId: 'asr-1',
                status: RecordingRemoteStatus.generatingMinutes,
              ),
              finalTranscript: '@王工 00:00:00\n真实最终文本。',
            ),
            _detail(
              status: RecordingRemoteStatus.completed,
              asrStatus: RecordingRemoteStatus.completed,
              transcript: '@王工 00:00:00\n真实最终文本。',
            ),
          ],
        );
        final controller = RecordingDetailController(
          api: api,
          pollInterval: Duration.zero,
          delay: (_) async {},
        );

        await controller.loadAndPoll('rec-1');

        expect(
          controller.state.status,
          RecordingDetailControllerStatus.terminal,
        );
        expect(controller.state.detail?.hasFinalTranscriptFact, isTrue);
        expect(controller.state.detail?.isTerminal, isTrue);
        expect(controller.state.pollCount, 3);
        expect(api.detailCalls, 3);
      },
    );

    test(
      'keeps polling terminal final text until noteRef is materialized',
      () async {
        final api = _FakeRecordingApi(
          details: <RecordingDetail>[
            _detail(
              status: RecordingRemoteStatus.completed,
              asrStatus: RecordingRemoteStatus.completed,
              transcript: '最终转写已经完成。',
              includeNoteRef: false,
            ),
            _detail(
              status: RecordingRemoteStatus.completed,
              asrStatus: RecordingRemoteStatus.completed,
              transcript: '最终转写已经完成。',
            ),
          ],
        );
        final controller = RecordingDetailController(
          api: api,
          pollInterval: Duration.zero,
          delay: (_) async {},
        );

        await controller.loadAndPoll('rec-1');

        expect(api.detailCalls, 2);
        expect(controller.state.pollCount, 2);
        expect(controller.state.detail?.canonicalNoteId, 'note-rec-1');
        expect(controller.state.detail?.shouldStopPolling, isTrue);
      },
    );

    test(
      'stops the recording detail at Raw while a Note-outline receipt runs',
      () async {
        const activeOutline = RecordingDetail(
          recording: RecordingAsset(
            recordingId: 'rec-1',
            title: 'Meeting',
            status: RecordingRemoteStatus.completed,
            transcriptStatus: 'final_transcript_generated',
          ),
          asrTask: AsrTaskSnapshot(
            asrTaskId: 'asr-1',
            status: RecordingRemoteStatus.completed,
          ),
          finalTranscript: '已经完成的转写内容。',
          finalTranscriptConfirmed: true,
          noteRef: RecordingNoteRef(
            noteId: 'note-rec-1',
            rawPartRevisionId: 'raw-rec-1',
            outlinePartRevisionId: null,
          ),
          noteOutlineTask: RecordingNoteOutlineTask(
            taskId: 'outline-receipt-1',
            status: RecordingNoteOutlineTaskStatus.running,
          ),
        );
        const settledOutline = RecordingDetail(
          recording: RecordingAsset(
            recordingId: 'rec-1',
            title: 'Meeting',
            status: RecordingRemoteStatus.completed,
            transcriptStatus: 'final_transcript_generated',
          ),
          asrTask: AsrTaskSnapshot(
            asrTaskId: 'asr-1',
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
            taskId: 'outline-receipt-1',
            status: RecordingNoteOutlineTaskStatus.succeeded,
          ),
        );
        final api = _FakeRecordingApi(
          details: <RecordingDetail>[activeOutline, settledOutline],
        );
        final controller = RecordingDetailController(
          api: api,
          pollInterval: Duration.zero,
          delay: (_) async {},
        );

        await controller.loadAndPoll('rec-1');

        expect(activeOutline.isTerminal, isTrue);
        expect(activeOutline.hasCloudAsset, isTrue);
        expect(activeOutline.hasCompletedProcessing, isFalse);
        expect(activeOutline.shouldStopPolling, isTrue);
        expect(
          controller.state.status,
          RecordingDetailControllerStatus.terminal,
        );
        expect(api.detailCalls, 1);
      },
    );

    test('discards an in-flight detail after the account changes', () async {
      final pending = Completer<ApiResult<RecordingDetail>>();
      final api = _FakeRecordingApi(
        details: <RecordingDetail>[
          _detail(
            status: RecordingRemoteStatus.completed,
            asrStatus: RecordingRemoteStatus.completed,
            transcript: 'Only the initiating account may receive this text.',
          ),
        ],
        deferredDetailResponse: pending.future,
      );
      var activeAccountScope = 'user-a';
      final controller = RecordingDetailController(
        api: api,
        pollInterval: Duration.zero,
        delay: (_) async {},
        accountScope: 'user-a',
        activeAccountScope: () => activeAccountScope,
      );

      final loading = controller.loadAndPoll('rec-1');
      await Future<void>.delayed(Duration.zero);
      expect(api.detailCalls, 1);

      activeAccountScope = 'user-b';
      pending.complete(
        _success(
          _detail(
            status: RecordingRemoteStatus.completed,
            asrStatus: RecordingRemoteStatus.completed,
            transcript: 'Only the initiating account may receive this text.',
          ),
        ),
      );
      await loading;

      expect(controller.state.status, RecordingDetailControllerStatus.failed);
      expect(controller.state.detail, isNull);
      expect(controller.state.accountScope, isNull);
      expect(
        controller.state.lastErrorCode,
        'RECORDING_DETAIL_ACCOUNT_CHANGED',
      );
      expect(api.detailCalls, 1);
    });

    test(
      'keeps active detail when the local polling budget is reached',
      () async {
        final api = _FakeRecordingApi(
          details: <RecordingDetail>[
            _detail(status: RecordingRemoteStatus.processing),
          ],
        );
        final controller = RecordingDetailController(
          api: api,
          pollInterval: Duration.zero,
          maxPollAttempts: 2,
          delay: (_) async {},
        );

        await controller.loadAndPoll('rec-1');

        expect(
          controller.state.status,
          RecordingDetailControllerStatus.polling,
        );
        expect(controller.state.pollCount, 2);
        expect(controller.state.detail?.isTerminal, isFalse);
        expect(controller.state.lastErrorCode, isNull);
        expect(api.detailCalls, 2);
      },
    );

    test(
      'adopts the durable tracker detail without a second GET observer',
      () async {
        final api = _FakeRecordingApi(
          details: <RecordingDetail>[
            _detail(status: RecordingRemoteStatus.completed),
          ],
        );
        final shared = _FakeProcessingObservationPort(
          _processingTask(
            _detail(status: RecordingRemoteStatus.processing),
            status: RecordingFileJobStatus.processing,
          ),
        );
        final controller = RecordingDetailController(
          api: api,
          processingObservationPort: shared,
          pollInterval: Duration.zero,
          maxPollAttempts: 1,
          delay: (_) async {},
        );
        addTearDown(controller.dispose);
        addTearDown(shared.dispose);

        await controller.loadAndPoll('rec-1');

        expect(api.detailCalls, 0);
        expect(
          controller.state.status,
          RecordingDetailControllerStatus.polling,
        );
        expect(
          controller.state.detail?.recording.status,
          RecordingRemoteStatus.processing,
        );

        shared.emit(
          _processingTask(
            _detail(status: RecordingRemoteStatus.completed),
            status: RecordingFileJobStatus.ready,
          ),
        );

        expect(api.detailCalls, 0);
        expect(
          controller.state.status,
          RecordingDetailControllerStatus.terminal,
        );
        expect(
          controller.state.detail?.recording.status,
          RecordingRemoteStatus.completed,
        );
      },
    );

    test('hands an open direct observer to a late durable tracker', () async {
      final pending = Completer<ApiResult<RecordingDetail>>();
      final api = _FakeRecordingApi(
        details: <RecordingDetail>[
          _detail(status: RecordingRemoteStatus.completed),
        ],
        deferredDetailResponse: pending.future,
      );
      final shared = _FakeProcessingObservationPort(null);
      final controller = RecordingDetailController(
        api: api,
        processingObservationPort: shared,
        pollInterval: Duration.zero,
        maxPollAttempts: 2,
        delay: (_) async {},
      );
      addTearDown(controller.dispose);
      addTearDown(shared.dispose);

      final loading = controller.loadAndPoll('rec-1');
      await Future<void>.delayed(Duration.zero);
      expect(api.detailCalls, 1);

      shared.emit(
        _processingTask(
          _detail(status: RecordingRemoteStatus.processing),
          status: RecordingFileJobStatus.processing,
        ),
      );
      expect(
        controller.state.detail?.recording.status,
        RecordingRemoteStatus.processing,
      );

      pending.complete(
        _success(_detail(status: RecordingRemoteStatus.completed)),
      );
      await loading;

      expect(api.detailCalls, 1);
      expect(
        controller.state.detail?.recording.status,
        RecordingRemoteStatus.processing,
      );
    });

    test('auto-advances pending speakers and keeps polling', () async {
      final api = _FakeRecordingApi(
        details: <RecordingDetail>[
          _detail(
            status: RecordingRemoteStatus.speakerLabelPending,
            asrStatus: RecordingRemoteStatus.speakerLabelPending,
          ),
          _detail(
            status: RecordingRemoteStatus.deposited,
            asrStatus: RecordingRemoteStatus.completed,
          ),
        ],
      );
      final speakerAdvance = _FakeSpeakerAutoAdvancePort();
      final controller = RecordingDetailController(
        api: api,
        speakerAutoAdvancePort: speakerAdvance,
        pollInterval: Duration.zero,
        delay: (_) async {},
      );

      await controller.loadAndPoll('rec-1');

      expect(controller.state.status, RecordingDetailControllerStatus.terminal);
      expect(controller.state.pollCount, 2);
      expect(api.detailCalls, 2);
      expect(speakerAdvance.pendingCalls, 1);
      expect(
        controller.state.detail?.recording.status,
        RecordingRemoteStatus.deposited,
      );
    });

    test('retries an allowed server-provided recording stage', () async {
      const retryActions = <RecordingRetryAction>[
        RecordingRetryAction(
          stage: 'recording_note_outline',
          title: '重新生成纲要',
          allowed: true,
        ),
      ];
      final api = _FakeRecordingApi(
        details: <RecordingDetail>[
          _detail(
            status: RecordingRemoteStatus.failed,
            asrStatus: RecordingRemoteStatus.failed,
            retryActions: retryActions,
          ),
          _detail(
            status: RecordingRemoteStatus.completed,
            asrStatus: RecordingRemoteStatus.completed,
            retryActions: retryActions,
          ),
        ],
        retryResult: _success(
          const RetryRecordingResponse(
            recordingId: 'rec-1',
            stage: 'recording_note_outline',
            status: RecordingRetryReceiptStatus.succeeded,
          ),
        ),
      );
      final processingRetryPort = _FakeProcessingRetryPort();
      final controller = RecordingDetailController(
        api: api,
        pollInterval: Duration.zero,
        delay: (_) async {},
        idempotencyKeyFactory: () => 'idem-retry-fixed',
        processingRetryPort: processingRetryPort,
      );

      await controller.loadAndPoll('rec-1');
      await controller.retryRecording('recording_note_outline');

      expect(api.retryStages, <String>['recording_note_outline']);
      expect(api.retryKeys, <String>['idem-retry-fixed']);
      expect(processingRetryPort.recordingIds, <String>['rec-1']);
      expect(controller.state.status, RecordingDetailControllerStatus.terminal);
      expect(
        controller.state.detail?.recording.status,
        RecordingRemoteStatus.completed,
      );
    });

    test(
      'rejects mismatched or terminal retry receipts before observation',
      () async {
        const retryActions = <RecordingRetryAction>[
          RecordingRetryAction(
            stage: 'recording_note_outline',
            title: '重新生成纲要',
            allowed: true,
          ),
        ];
        const rejectedReceipts = <RetryRecordingResponse>[
          RetryRecordingResponse(
            recordingId: 'rec-other',
            stage: 'recording_note_outline',
            status: RecordingRetryReceiptStatus.queued,
          ),
          RetryRecordingResponse(
            recordingId: 'rec-1',
            stage: 'asr',
            status: RecordingRetryReceiptStatus.queued,
          ),
          RetryRecordingResponse(
            recordingId: 'rec-1',
            stage: 'recording_note_outline',
            status: RecordingRetryReceiptStatus.failed,
          ),
        ];

        for (final receipt in rejectedReceipts) {
          final api = _FakeRecordingApi(
            details: <RecordingDetail>[
              _detail(
                status: RecordingRemoteStatus.failed,
                asrStatus: RecordingRemoteStatus.failed,
                retryActions: retryActions,
              ),
            ],
            retryResult: _success(receipt),
          );
          final processingRetryPort = _FakeProcessingRetryPort();
          final controller = RecordingDetailController(
            api: api,
            pollInterval: Duration.zero,
            delay: (_) async {},
            processingRetryPort: processingRetryPort,
          );

          await controller.loadAndPoll('rec-1');
          await controller.retryRecording('recording_note_outline');

          expect(
            controller.state.status,
            RecordingDetailControllerStatus.failed,
          );
          expect(
            controller.state.lastErrorCode,
            'RECORDING_RETRY_RESPONSE_INVALID',
          );
          expect(api.detailCalls, 1);
          expect(processingRetryPort.recordingIds, isEmpty);
          controller.dispose();
        }
      },
    );

    test(
      'refreshes after a postprocess retry instead of reusing terminal detail',
      () async {
        const retryActions = <RecordingRetryAction>[
          RecordingRetryAction(
            stage: 'recording_note_outline',
            title: '重新生成纲要',
            allowed: true,
          ),
        ];
        final stale = _detail(
          status: RecordingRemoteStatus.failed,
          asrStatus: RecordingRemoteStatus.completed,
          transcript: '已完成的原始转写',
          retryActions: retryActions,
        );
        final refreshed = _detail(
          status: RecordingRemoteStatus.completed,
          asrStatus: RecordingRemoteStatus.completed,
          transcript: '已完成的原始转写',
          retryActions: retryActions,
          noteOutlineTask: const RecordingNoteOutlineTask(
            taskId: 'outline-attempt-2',
            status: RecordingNoteOutlineTaskStatus.running,
          ),
        );
        final api = _FakeRecordingApi(details: <RecordingDetail>[refreshed]);
        final shared = _FakeProcessingObservationPort(
          _processingTask(stale, status: RecordingFileJobStatus.ready),
        );
        final processingRetryPort = _FakeProcessingRetryPort(reenrolled: false);
        final controller = RecordingDetailController(
          api: api,
          pollInterval: Duration.zero,
          maxPollAttempts: 1,
          delay: (_) async {},
          processingRetryPort: processingRetryPort,
          processingObservationPort: shared,
        );
        addTearDown(controller.dispose);
        addTearDown(shared.dispose);

        await controller.loadAndPoll('rec-1');
        expect(api.detailCalls, 0);
        await controller.retryRecording('recording_note_outline');

        expect(api.retryStages, <String>['recording_note_outline']);
        expect(api.detailCalls, 1);
        expect(
          controller.state.detail?.noteOutlineTask?.status,
          RecordingNoteOutlineTaskStatus.running,
        );
        expect(controller.state.detail?.effectiveRetryActions, isEmpty);
      },
    );

    test('does not post an unadvertised or denied retry stage', () async {
      final api = _FakeRecordingApi(
        details: <RecordingDetail>[
          _detail(
            status: RecordingRemoteStatus.failed,
            asrStatus: RecordingRemoteStatus.failed,
            retryActions: const <RecordingRetryAction>[
              RecordingRetryAction(
                stage: 'recording_note_outline',
                title: '重新生成纲要',
                allowed: false,
              ),
            ],
          ),
        ],
      );
      final processingRetryPort = _FakeProcessingRetryPort();
      final controller = RecordingDetailController(
        api: api,
        pollInterval: Duration.zero,
        delay: (_) async {},
        processingRetryPort: processingRetryPort,
      );

      await controller.loadAndPoll('rec-1');
      await controller.retryRecording('recording_note_outline');

      expect(controller.state.status, RecordingDetailControllerStatus.failed);
      expect(controller.state.lastErrorCode, 'RECORDING_RETRY_NOT_ALLOWED');
      expect(api.retryStages, isEmpty);
      expect(processingRetryPort.recordingIds, isEmpty);
    });

    test('preserves automatic speaker recognition and deposit statuses', () {
      final speakerLabels = parseRecordingAsset(<String, Object?>{
        'recordingId': 'rec-1',
        'transcriptStatus': 'speaker_labeling',
      });
      final minutes = parseRecordingAsset(<String, Object?>{
        'recordingId': 'rec-2',
        'minutesStatus': 'generating_minutes',
      });
      final transcribed = parseRecordingAsset(<String, Object?>{
        'recordingId': 'rec-3',
        'transcriptStatus': 'transcribed',
      });
      final deposited = parseRecordingAsset(<String, Object?>{
        'recordingId': 'rec-4',
        'depositStatus': 'deposited',
      });
      const asrOnlySpeakerRecognition = RecordingDetail(
        recording: RecordingAsset(
          recordingId: 'rec-5',
          title: 'Meeting',
          status: RecordingRemoteStatus.queued,
        ),
        asrTask: AsrTaskSnapshot(
          asrTaskId: 'asr-5',
          status: RecordingRemoteStatus.speakerLabelPending,
        ),
      );
      expect(speakerLabels?.status, RecordingRemoteStatus.speakerLabelPending);
      expect(minutes?.status, RecordingRemoteStatus.generatingMinutes);
      expect(transcribed?.status, RecordingRemoteStatus.speakerLabelPending);
      expect(deposited?.status, RecordingRemoteStatus.deposited);
      expect(deposited?.isTerminal, isTrue);
      expect(asrOnlySpeakerRecognition.shouldStopPolling, isFalse);
    });

    test('poll budget exhaustion preserves the active projection', () async {
      final api = _FakeRecordingApi(
        details: <RecordingDetail>[
          _detail(status: RecordingRemoteStatus.processing),
        ],
      );
      final controller = RecordingDetailController(
        api: api,
        pollInterval: Duration.zero,
        maxPollAttempts: 1,
        delay: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.loadAndPoll('rec-1');

      expect(controller.state.status, RecordingDetailControllerStatus.polling);
      expect(controller.state.lastErrorCode, isNull);
      expect(controller.state.detail, isNotNull);
      expect(controller.state.pollCount, 1);
      expect(api.detailCalls, 1);
    });
  });
}

RecordingProcessingTask _processingTask(
  RecordingDetail detail, {
  required RecordingFileJobStatus status,
}) {
  return RecordingProcessingTask(
    draft: UploadDraft(
      draftId: 'draft-rec-1',
      localRecordingId: 'local-rec-1',
      appPrivateUri: 'app-private://recordings/rec-1.m4a',
      fileName: 'rec-1.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: 1024,
      durationSeconds: 10,
      sourceScene: 'recording',
      stage: UploadDraftStage.asrQueued,
      updatedAt: DateTime.utc(2026, 9, 3),
      uploadTokenKey: 'idem-upload-rec-1',
      completeUploadKey: 'idem-complete-rec-1',
      createRecordingKey: 'idem-create-rec-1',
      recordingId: 'rec-1',
      asrTaskId: 'asr-1',
    ),
    phase: switch (status) {
      RecordingFileJobStatus.uploading || RecordingFileJobStatus.processing =>
        RecordingProcessingPhase.transcribing,
      RecordingFileJobStatus.ready => RecordingProcessingPhase.completed,
      RecordingFileJobStatus.failed => RecordingProcessingPhase.failed,
    },
    updatedAt: DateTime.utc(2026, 9, 3),
    detail: detail,
  );
}

final class _FakeProcessingObservationPort extends ChangeNotifier
    implements RecordingProcessingDetailObservationPort {
  _FakeProcessingObservationPort(this._task);

  RecordingProcessingTask? _task;

  void emit(RecordingProcessingTask task) {
    _task = task;
    notifyListeners();
  }

  @override
  RecordingProcessingTask? processingTaskFor(String recordingId) {
    final task = _task;
    return task?.draft.recordingId == recordingId ? task : null;
  }

  @override
  void addProcessingDetailListener(VoidCallback listener) {
    addListener(listener);
  }

  @override
  void removeProcessingDetailListener(VoidCallback listener) {
    removeListener(listener);
  }
}

RecordingDetail _detail({
  required RecordingRemoteStatus status,
  RecordingRemoteStatus asrStatus = RecordingRemoteStatus.processing,
  String? transcript,
  bool includeNoteRef = true,
  List<RecordingRetryAction>? retryActions,
  RecordingNoteOutlineTask? noteOutlineTask,
}) {
  return RecordingDetail(
    recording: RecordingAsset(
      recordingId: 'rec-1',
      title: 'Meeting',
      status: status,
      asrTaskId: 'asr-1',
    ),
    asrTask: AsrTaskSnapshot(asrTaskId: 'asr-1', status: asrStatus),
    noteRef: transcript != null && includeNoteRef
        ? const RecordingNoteRef(
            noteId: 'note-rec-1',
            rawPartRevisionId: 'raw-revision-rec-1',
            outlinePartRevisionId: 'outline-revision-rec-1',
          )
        : null,
    finalTranscript: transcript,
    noteOutlineTask: noteOutlineTask,
    retryActions:
        retryActions ??
        const <RecordingRetryAction>[
          RecordingRetryAction(stage: 'asr', title: '重试转写', allowed: true),
        ],
  );
}

final class _FakeRecordingApi implements RecordingApiPort {
  _FakeRecordingApi({
    required List<RecordingDetail> details,
    List<ApiResult<RecordingDetail>> detailResults = const [],
    this.deferredDetailResponse,
    this.retryResult,
  }) : _details = List<RecordingDetail>.from(details),
       _detailResults = List<ApiResult<RecordingDetail>>.from(detailResults);

  final List<RecordingDetail> _details;
  final List<ApiResult<RecordingDetail>> _detailResults;
  final Future<ApiResult<RecordingDetail>>? deferredDetailResponse;
  final ApiResult<RetryRecordingResponse>? retryResult;
  final retryStages = <String>[];
  final retryKeys = <String>[];
  int detailCalls = 0;
  int _detailSequenceReads = 0;

  @override
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId) async {
    return _success(
      AsrTaskSnapshot(
        asrTaskId: asrTaskId,
        status: RecordingRemoteStatus.processing,
      ),
    );
  }

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(
    String recordingId,
  ) async {
    detailCalls += 1;
    final deferred = deferredDetailResponse;
    if (deferred != null) return deferred;
    if (_detailResults.isNotEmpty) return _detailResults.removeAt(0);
    final index = _detailSequenceReads;
    _detailSequenceReads += 1;
    final detail =
        _details[index < _details.length ? index : _details.length - 1];
    return _success(detail);
  }

  @override
  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) async {
    retryStages.add(stage);
    retryKeys.add(idempotencyKey);
    return retryResult ??
        _success(
          RetryRecordingResponse(
            recordingId: recordingId,
            stage: stage,
            status: RecordingRetryReceiptStatus.queued,
          ),
        );
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  }) async {
    return _success(
      AsrTaskSnapshot(
        asrTaskId: asrTaskId,
        status: RecordingRemoteStatus.processing,
      ),
    );
  }
}

final class _FakeSpeakerAutoAdvancePort
    implements RecordingSpeakerAutoAdvancePort {
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

final class _FakeProcessingRetryPort implements RecordingProcessingRetryPort {
  _FakeProcessingRetryPort({this.reenrolled = true});

  final bool reenrolled;
  final List<String> recordingIds = <String>[];

  @override
  Future<bool> reenrollAfterRetry(String recordingId) async {
    recordingIds.add(recordingId);
    return reenrolled;
  }
}

ApiResult<T> _success<T>(T data) {
  return ApiResult<T>.success(
    data: data,
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}
