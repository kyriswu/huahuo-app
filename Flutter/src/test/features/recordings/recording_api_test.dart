import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';

void main() {
  group('RecordingApi creation contract', () {
    test('sends canonical audioResourceId with idempotency', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'recording': <String, Object?>{
                'recordingId': 'rec-1',
                'title': 'Team meeting',
                'status': 'processing',
                'asrTaskId': 'asr-1',
              },
              'asrTask': <String, Object?>{
                'asrTaskId': 'asr-1',
                'status': 'queued',
              },
            },
          },
        ),
      ]);

      final result = await _api(transport).createRecording(
        CreateRecordingInput(
          resource: const ResourceIndex(
            resourceId: 'resource-1',
            uploadId: 'upload-1',
            sourceScene: 'raw_material',
            mimeType: 'audio/mp4',
            sizeBytes: 2048,
            durationSeconds: 90,
          ),
          title: 'Team meeting',
          source: 'local_upload',
          recordedAt: DateTime.utc(2026, 8, 9, 9),
          idempotencyKey: 'idem-recording-create',
        ),
      );

      expect(result.ok, isTrue);
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/recordings');
      expect(request.headers['X-Idempotency-Key'], 'idem-recording-create');
      expect(_body(request)['audioResourceId'], 'resource-1');
      expect(_body(request).containsKey('resourceId'), isFalse);
    });
  });

  group('RecordingApi retry contract', () {
    test(
      'preserves and sends a safe server-authorized outline stage',
      () async {
        final parsed = parseRecordingDetail(<String, Object?>{
          'recording': <String, Object?>{
            'recordingId': 'rec-outline-retry',
            'title': 'Interview',
            'status': 'failed',
          },
          'retryActions': <Object?>[
            <String, Object?>{
              'stage': 'recording_note_outline',
              'label': '重新生成纲要',
              'retryable': true,
            },
            <String, Object?>{
              'stage': '../not-a-stage',
              'label': 'Ignore malformed action',
              'retryable': true,
            },
          ],
        });
        expect(parsed?.retryActions, hasLength(1));
        expect(parsed?.retryActions.single.stage, 'recording_note_outline');
        expect(parsed?.retryActions.single.allowed, isTrue);

        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'recordingId': 'rec-outline-retry',
                'stage': 'recording_note_outline',
                'status': 'queued',
                'taskId': 'recording-outline-task-1',
                'recordingSubTaskId': 'recording-outline-task-1',
              },
            },
          ),
        ]);

        final result = await _api(transport).retryRecording(
          recordingId: 'rec-outline-retry',
          stage: 'recording_note_outline',
          idempotencyKey: 'idem-recording-outline-retry',
        );

        expect(result.ok, isTrue);
        expect(result.data?.recordingId, 'rec-outline-retry');
        expect(result.data?.stage, 'recording_note_outline');
        expect(result.data?.status, RecordingRetryReceiptStatus.queued);
        expect(result.data?.status.isAccepted, isTrue);
        expect(result.data?.taskId, 'recording-outline-task-1');
        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/recordings/rec-outline-retry/retry');
        expect(
          request.headers['X-Idempotency-Key'],
          'idem-recording-outline-retry',
        );
        expect(_body(request), <String, Object?>{
          'stage': 'recording_note_outline',
        });
      },
    );

    test('rejects malformed retry stages before transport', () async {
      final transport = _QueueTransport(const <ApiTransportResponse>[]);

      final result = await _api(transport).retryRecording(
        recordingId: 'rec-outline-retry',
        stage: '../recording_note_outline',
        idempotencyKey: 'idem-recording-outline-retry',
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'RECORDING_RETRY_STAGE_INVALID');
      expect(transport.requests, isEmpty);
    });

    test('strictly validates retry receipt identity and optional objects', () {
      RetryRecordingResponse? parse(Map<String, Object?> value) {
        return parseRetryRecordingResponse(
          value,
          fallbackRecordingId: 'rec-outline-retry',
          expectedStage: 'recording_note_outline',
        );
      }

      final replay = parse(<String, Object?>{
        'stage': 'recording_note_outline',
        'status': 'completed',
      });
      expect(replay?.recordingId, 'rec-outline-retry');
      expect(replay?.status, RecordingRetryReceiptStatus.succeeded);
      expect(replay?.status.isAccepted, isTrue);

      final terminalFailure = parse(<String, Object?>{
        'recordingId': 'rec-outline-retry',
        'stage': 'recording_note_outline',
        'status': 'dead_letter',
      });
      expect(terminalFailure?.status, RecordingRetryReceiptStatus.deadLetter);
      expect(terminalFailure?.status.isAccepted, isFalse);

      expect(<RetryRecordingResponse?>[
        parse(<String, Object?>{
          'recordingId': 'rec-other',
          'stage': 'recording_note_outline',
          'status': 'queued',
        }),
        parse(<String, Object?>{
          'recording': <String, Object?>{'recordingId': 'rec-other'},
          'stage': 'recording_note_outline',
          'status': 'queued',
        }),
        parse(<String, Object?>{
          'recording': null,
          'stage': 'recording_note_outline',
          'status': 'queued',
        }),
        parse(<String, Object?>{
          'asrTask': <String, Object?>{'status': 'queued'},
          'stage': 'recording_note_outline',
          'status': 'queued',
        }),
        parse(<String, Object?>{'stage': 'asr', 'status': 'queued'}),
        parse(<String, Object?>{
          'stage': 'recording_note_outline',
          'status': 'unknown',
        }),
        parse(<String, Object?>{
          'stage': 'recording_note_outline',
          'status': 'queued',
          'taskId': 'outline-task-1',
          'recordingSubTaskId': 'outline-task-2',
        }),
        parse(<String, Object?>{
          'stage': 'recording_note_outline',
          'status': 'queued',
          'taskId': null,
        }),
      ], everyElement(isNull));
    });
  });

  group('RecordingApi automatic speaker advance', () {
    test('submits anonymous fallbacks for a long transcript', () async {
      final longPreview = List<String>.filled(6280, '转').join();
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'recording': <String, Object?>{
                'recordingId': 'rec-speakers',
                'title': '访谈录音',
                'workspaceId': 'workspace-1',
                'transcriptStatus': 'transcribed',
                'minutesStatus': 'not_started',
                'summaryStatus': 'not_started',
                'depositStatus': 'not_started',
              },
              'asrTask': <String, Object?>{
                'asrTaskId': 'asr-speakers',
                'status': 'transcribed',
                'version': 4,
              },
              'speakers': <Object?>[
                <String, Object?>{
                  'speakerId': 'speaker-1',
                  'displayName': 'Speaker 1',
                  'segmentCount': 2,
                  'sampleTexts': <Object?>['第一段'],
                },
                <String, Object?>{
                  'speakerId': 'speaker-2',
                  'displayName': 'Speaker 2',
                  'segmentCount': 1,
                  'sampleTexts': <Object?>['第二段'],
                },
              ],
              'segments': <Object?>[
                <String, Object?>{
                  'speakerId': 'speaker-1',
                  'startMs': 0,
                  'endMs': 1000,
                  'text': '第一段',
                },
                <String, Object?>{
                  'speakerId': 'speaker-2',
                  'startMs': 1000,
                  'endMs': 2000,
                  'text': '第二段',
                },
              ],
              'speakerNameMap': <String, Object?>{},
              'previewText': longPreview,
              'canSubmit': true,
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{'success': true, 'data': <String, Object?>{}},
        ),
      ]);

      final result = await _api(transport).autoAdvanceSpeakerLabels(
        recordingId: 'rec-speakers',
        asrTaskId: 'asr-speakers',
        baseAsrTaskVersion: 4,
        idempotencyKey: 'idem-auto-speakers-v4',
      );

      expect(
        result.ok,
        isTrue,
        reason:
            '${result.error?.code}: ${result.error?.message}; '
            '${result.error?.cause}; ${result.error?.metadata}',
      );
      expect(transport.requests, hasLength(2));
      expect(transport.requests.first.method, 'GET');
      expect(
        transport.requests.first.url.path,
        '/api/v1/recordings/rec-speakers/speaker-label-panel',
      );
      final submit = transport.requests.last;
      expect(submit.method, 'POST');
      expect(submit.url.path, '/api/v1/recordings/rec-speakers/speaker-labels');
      expect(submit.headers['X-Idempotency-Key'], 'idem-auto-speakers-v4');
      expect(_body(submit), <String, Object?>{
        'baseAsrTaskVersion': 4,
        'speakerNameMap': <String, Object?>{
          'speaker-1': '说话人 1',
          'speaker-2': '说话人 2',
        },
        'selfSpeakerId': 'speaker-1',
      });
    });
  });

  group('RecordingApi final transcript facts', () {
    test('loads top-level noteRef from the authenticated detail GET', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'recording': <String, Object?>{
                'recordingId': 'rec-detail-note-ref',
                'title': 'Uploaded recording',
                'status': 'completed',
                'transcriptStatus': 'final_transcript_generated',
              },
              'noteRef': <String, Object?>{
                'noteId': 'note-detail',
                'rawPartRevisionId': 'npart-raw-detail',
                'outlinePartRevisionId': 'npart-outline-detail',
              },
              'transcript': <String, Object?>{'finalTranscript': '正式转写正文'},
            },
          },
        ),
      ]);

      final result = await _api(
        transport,
      ).getRecordingDetail('rec-detail-note-ref');

      expect(result.ok, isTrue);
      expect(result.data?.canonicalNoteId, 'note-detail');
      expect(result.data?.noteRef?.rawPartRevisionId, 'npart-raw-detail');
      expect(
        result.data?.noteRef?.outlinePartRevisionId,
        'npart-outline-detail',
      );
      final request = transport.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/recordings/rec-detail-note-ref');
      expect(request.headers['Authorization'], 'Bearer access-token');
      expect(request.headers.containsKey('X-Idempotency-Key'), isFalse);
    });

    test('does not promote provisional text while speakers are confirmed', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-provisional',
          'title': 'Interview',
          'transcriptStatus': 'speaker_confirmed',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-provisional',
          'status': 'speaker_confirmed',
        },
        'transcript': <String, Object?>{'finalTranscript': '没有说话人标注的临时文本'},
      });

      expect(parsed, isNotNull);
      expect(parsed?.finalTranscript, isNull);
      expect(parsed?.hasFinalTranscriptFact, isFalse);
    });

    test('retains attributed text after final transcript generation', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-final',
          'title': 'Interview',
          'transcriptStatus': 'final_transcript_generated',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-final',
          'status': 'final_transcript_generated',
        },
        'transcript': <String, Object?>{
          'finalTranscript': '@谢居洋 00:00:00\n这是最终内容。',
        },
      });

      expect(parsed?.hasFinalTranscriptFact, isTrue);
      expect(parsed?.shouldStopPolling, isFalse);
      expect(parsed?.isTerminal, isFalse);
      expect(parsed?.finalTranscript, contains('@谢居洋'));
    });

    test('numbers only anonymous speaker headers by first appearance', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-anonymous-speakers',
          'title': 'Interview',
          'transcriptStatus': 'final_transcript_generated',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-anonymous-speakers',
          'status': 'final_transcript_generated',
        },
        'transcript': <String, Object?>{
          'finalTranscript':
              '@speaker_8 00:00:00\n第一段。\n\n'
              '@王工 00:00:01\n已命中声纹。\n\n'
              '@speaker-2 00:00:02\n第二段。\n\n'
              '@SPEAKER_8 00:00:03\n再次发言。',
        },
      });

      expect(
        parsed?.finalTranscript,
        '@说话人 1 00:00:00\n第一段。\n\n'
        '@王工 00:00:01\n已命中声纹。\n\n'
        '@说话人 2 00:00:02\n第二段。\n\n'
        '@说话人 1 00:00:03\n再次发言。',
      );
    });

    test('keeps the ASR final fact after a later aggregate failure', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-later-stage-failed',
          'title': 'Uploaded recording',
          'status': 'failed',
          'transcriptStatus': 'failed',
          'minutesStatus': 'queued',
          'summaryStatus': 'not_started',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-later-stage-failed',
          'rawPartRevisionId': 'raw-revision-later-stage-failed',
          'outlinePartRevisionId': 'outline-revision-later-stage-failed',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-later-stage-failed',
          'status': 'final_transcript_generated',
        },
        'transcript': <String, Object?>{
          'finalTranscript': '这段最终转写已经成功，后处理失败不能删除它。',
        },
      });

      expect(parsed?.recording.status, RecordingRemoteStatus.failed);
      expect(parsed?.finalTranscript, contains('最终转写已经成功'));
      expect(parsed?.hasFinalTranscriptFact, isTrue);
      expect(parsed?.hasCloudAsset, isTrue);
    });

    test('keeps polling Raw settlement after an Outline failure', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-awaiting-asset-binding',
          'title': 'Uploaded recording',
          'status': 'failed',
          'transcriptStatus': 'final_transcript_generated',
          'minutesStatus': 'failed',
          'summaryStatus': 'failed',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-awaiting-asset-binding',
          'status': 'final_transcript_generated',
        },
        'transcript': <String, Object?>{
          'finalTranscript': '最终转写已完成，正在等待正式资产绑定。',
        },
      });

      expect(parsed?.hasFinalTranscriptFact, isTrue);
      expect(parsed?.hasCloudAsset, isFalse);
      expect(parsed?.hasOutlineFailure, isTrue);
      expect(parsed?.rawTerminalFailureStatus, isNull);
      expect(parsed?.shouldStopPolling, isFalse);
    });

    test('continues polling a completed transcript until noteRef appears', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-completed-awaiting-note-ref',
          'title': 'Uploaded recording',
          'status': 'completed',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-completed-awaiting-note-ref',
          'status': 'completed',
        },
        'transcript': <String, Object?>{
          'finalTranscript': '最终转写已完成，正式 HNote 正在物化。',
        },
      });

      expect(parsed?.isTerminal, isTrue);
      expect(parsed?.hasFinalTranscriptFact, isTrue);
      expect(parsed?.noteRef, isNull);
      expect(parsed?.shouldStopPolling, isFalse);
    });

    test('accepts a raw-only noteRef and ignores the legacy nested noteId', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-partial-note-ref',
          'noteId': 'legacy-note-must-not-bind',
          'title': 'Uploaded recording',
          'status': 'completed',
          'transcriptStatus': 'final_transcript_generated',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-partial',
          'rawPartRevisionId': 'raw-revision-partial',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-partial-note-ref',
          'status': 'final_transcript_generated',
        },
        'transcript': <String, Object?>{
          'finalTranscript': '最终转写已完成，但正式资产引用尚不完整。',
        },
      });

      expect(parsed?.recording.noteId, 'legacy-note-must-not-bind');
      expect(parsed?.noteRef?.noteId, 'note-partial');
      expect(parsed?.noteRef?.rawPartRevisionId, 'raw-revision-partial');
      expect(parsed?.noteRef?.outlinePartRevisionId, isNull);
      expect(parsed?.canonicalNoteId, 'note-partial');
      expect(parsed?.hasCloudAsset, isTrue);
      expect(parsed?.hasCloudOutline, isFalse);
      expect(parsed?.hasCompletedProcessing, isFalse);
      expect(parsed?.shouldStopPolling, isTrue);
    });

    test('treats an empty outline revision as not generated yet', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-empty-outline-ref',
          'title': 'Uploaded recording',
          'status': 'completed',
          'transcriptStatus': 'final_transcript_generated',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-empty-outline',
          'rawPartRevisionId': 'raw-empty-outline',
          'outlinePartRevisionId': '',
        },
        'transcript': <String, Object?>{'finalTranscript': '正式转写正文'},
      });

      expect(parsed?.hasCloudAsset, isTrue);
      expect(parsed?.noteRef?.outlinePartRevisionId, isNull);
    });

    test('rejects a malformed non-empty outline revision', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-malformed-outline-ref',
          'title': 'Uploaded recording',
          'status': 'completed',
          'transcriptStatus': 'final_transcript_generated',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-malformed-outline',
          'rawPartRevisionId': 'raw-malformed-outline',
          'outlinePartRevisionId': '../outline',
        },
        'transcript': <String, Object?>{'finalTranscript': '正式转写正文'},
      });

      expect(parsed?.noteRef, isNull);
      expect(parsed?.hasCloudAsset, isFalse);
    });

    test('exposes the canonical raw asset before outline generation', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-raw-cloud-note',
          'title': 'Interview',
          'transcriptStatus': 'final_transcript_generated',
          'minutesStatus': 'queued',
          'summaryStatus': 'not_started',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-raw-cloud-recording',
          'rawPartRevisionId': 'raw-revision-raw-cloud-recording',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-raw-cloud-note',
          'status': 'generating_minutes',
        },
        'transcript': <String, Object?>{
          'finalTranscript': '@谢居洋 00:00:00\n这是最终内容。',
        },
      });

      expect(parsed?.hasFinalTranscriptFact, isTrue);
      expect(parsed?.hasGeneratedOutline, isFalse);
      expect(parsed?.hasCloudAsset, isTrue);
      expect(parsed?.hasCloudOutline, isFalse);
      expect(parsed?.shouldStopPolling, isTrue);
    });

    test('keeps the raw cloud asset when a retryable outline task fails', () {
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-outline-failed',
          'title': 'Interview',
          'transcriptStatus': 'final_transcript_generated',
          'minutesStatus': 'failed',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-outline-failed',
          'rawPartRevisionId': 'raw-revision-outline-failed',
          'outlinePartRevisionId': 'outline-revision-outline-failed',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-outline-failed',
          'status': 'completed',
        },
        'transcript': <String, Object?>{'finalTranscript': '已确认的原始转写。'},
        'retryActions': <Object?>[
          <String, Object?>{
            'stage': 'minutes_generation',
            'title': '重新生成纲要',
            'allowed': true,
          },
        ],
      });

      expect(parsed?.hasCloudAsset, isTrue);
      expect(parsed?.hasOutlineFailure, isTrue);
      expect(parsed?.canRetryOutline, isTrue);
      expect(parsed?.hasCompletedProcessing, isFalse);
      expect(parsed?.shouldStopPolling, isTrue);
    });

    test(
      'uses an allowed outline-subtask retry when aggregate stages succeeded',
      () {
        final parsed = parseRecordingDetail(<String, Object?>{
          'recording': <String, Object?>{
            'recordingId': 'rec-outline-subtask-failed',
            'title': 'Interview',
            'transcriptStatus': 'final_transcript_generated',
            'minutesStatus': 'succeeded',
            'summaryStatus': 'succeeded',
          },
          'noteRef': <String, Object?>{
            'noteId': 'note-outline-subtask-failed',
            'rawPartRevisionId': 'raw-revision-outline-subtask-failed',
            'outlinePartRevisionId': 'outline-revision-outline-subtask-failed',
          },
          'asrTask': <String, Object?>{
            'asrTaskId': 'asr-outline-subtask-failed',
            'status': 'completed',
          },
          'transcript': <String, Object?>{'finalTranscript': '已确认的原始转写。'},
          'retryActions': <Object?>[
            <String, Object?>{
              'stage': 'recording_note_outline',
              'title': '重新生成纲要',
              'allowed': true,
            },
          ],
        });

        expect(parsed?.hasCloudAsset, isTrue);
        expect(parsed?.hasOutlineFailure, isTrue);
        expect(parsed?.canRetryOutline, isTrue);
        expect(parsed?.retryActions.single.stage, 'recording_note_outline');
      },
    );

    test('completes only after the current Note outline receipt succeeds', () {
      final queued = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-outline-receipt',
          'title': 'Interview',
          'status': 'completed',
          'minutesStatus': 'succeeded',
          'summaryStatus': 'succeeded',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-outline-receipt',
          'status': 'completed',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-outline-receipt',
          'rawPartRevisionId': 'raw-outline-receipt',
          'outlinePartRevisionId': 'outline-outline-receipt',
        },
        'transcript': <String, Object?>{'finalTranscript': '已确认的原始转写。'},
        'subTasks': <Object?>[
          <String, Object?>{
            'recordingSubTaskId': 'subtask-outline-receipt',
            'recordingId': 'rec-outline-receipt',
            'taskType': 'recording_note_outline',
            'status': 'queued',
          },
          <String, Object?>{
            'recordingSubTaskId': 'subtask-unrelated',
            'recordingId': 'rec-outline-receipt',
            'taskType': 'recording_deposit',
            'status': 'failed',
          },
        ],
        'retryActions': <Object?>[
          <String, Object?>{'stage': 'recording_note_outline', 'allowed': true},
        ],
      });

      expect(queued?.noteOutlineTask?.taskId, 'subtask-outline-receipt');
      expect(
        queued?.noteOutlineTask?.status,
        RecordingNoteOutlineTaskStatus.queued,
      );
      expect(queued?.hasCompletedProcessing, isFalse);
      expect(queued?.shouldStopPolling, isTrue);
      expect(queued?.hasOutlineFailure, isFalse);
      expect(queued?.canRetryOutline, isFalse);
      expect(queued?.effectiveRetryActions, isEmpty);

      final succeeded = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-outline-receipt',
          'title': 'Interview',
          'status': 'completed',
          'transcriptStatus': 'final_transcript_generated',
          'minutesStatus': 'succeeded',
          'summaryStatus': 'succeeded',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-outline-receipt',
          'status': 'completed',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-outline-receipt',
          'rawPartRevisionId': 'raw-outline-receipt',
          'outlinePartRevisionId': 'outline-outline-receipt',
        },
        'transcript': <String, Object?>{'finalTranscript': '已确认的原始转写。'},
        'subTasks': <Object?>[
          <String, Object?>{
            'recordingSubTaskId': 'subtask-outline-receipt',
            'recordingId': 'rec-outline-receipt',
            'taskType': 'recording_note_outline',
            'status': 'succeeded',
          },
        ],
        'retryActions': <Object?>[
          <String, Object?>{'stage': 'recording_note_outline', 'allowed': true},
        ],
      });

      expect(
        succeeded?.noteOutlineTask?.status,
        RecordingNoteOutlineTaskStatus.succeeded,
      );
      expect(succeeded?.hasCompletedProcessing, isTrue);
      expect(succeeded?.shouldStopPolling, isTrue);
      expect(succeeded?.hasOutlineFailure, isFalse);
      expect(succeeded?.canRetryOutline, isFalse);
      expect(succeeded?.effectiveRetryActions, isEmpty);

      final incompleteSnapshot = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-outline-receipt',
          'title': 'Interview',
          'status': 'completed',
          'transcriptStatus': 'final_transcript_generated',
          'minutesStatus': 'succeeded',
          'summaryStatus': 'succeeded',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-outline-receipt',
          'status': 'completed',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-outline-receipt',
          'rawPartRevisionId': 'raw-outline-receipt',
          'outlinePartRevisionId': 'outline-outline-receipt',
        },
        'transcript': <String, Object?>{'finalTranscript': '已确认的原始转写。'},
        'subTasks': <Object?>[
          <String, Object?>{
            'recordingSubTaskId': 'subtask-unrelated',
            'recordingId': 'rec-outline-receipt',
            'taskType': 'recording_final_transcript',
            'status': 'succeeded',
          },
        ],
      });
      expect(incompleteSnapshot?.hasSubTaskSnapshot, isTrue);
      expect(incompleteSnapshot?.noteOutlineTask, isNull);
      expect(incompleteSnapshot?.hasCompletedProcessing, isFalse);
      expect(incompleteSnapshot?.shouldStopPolling, isTrue);

      final legacy = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-outline-receipt',
          'title': 'Interview',
          'status': 'completed',
          'minutesStatus': 'succeeded',
          'summaryStatus': 'succeeded',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-outline-receipt',
          'status': 'completed',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-outline-receipt',
          'rawPartRevisionId': 'raw-outline-receipt',
          'outlinePartRevisionId': 'outline-outline-receipt',
        },
        'transcript': <String, Object?>{'finalTranscript': '已确认的原始转写。'},
      });
      expect(legacy?.hasSubTaskSnapshot, isFalse);
      expect(legacy?.hasCompletedProcessing, isTrue);
      expect(legacy?.shouldStopPolling, isTrue);
    });

    test('retains only safe failure identity from the latest outline task', () {
      Map<String, Object?> payload(List<Object?> subTasks) => <String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-outline-failure-code',
          'title': 'Interview',
          'status': 'completed',
          'transcriptStatus': 'final_transcript_generated',
          'minutesStatus': 'succeeded',
          'summaryStatus': 'succeeded',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-outline-failure-code',
          'status': 'completed',
        },
        'noteRef': <String, Object?>{
          'noteId': 'note-outline-failure-code',
          'rawPartRevisionId': 'raw-outline-failure-code',
        },
        'transcript': <String, Object?>{'finalTranscript': '已确认的原始转写。'},
        'subTasks': subTasks,
      };

      final canonical = parseRecordingDetail(
        payload(<Object?>[
          <String, Object?>{
            'recordingSubTaskId': 'outline-failure-canonical',
            'recordingId': 'rec-outline-failure-code',
            'taskType': 'recording_note_outline',
            'status': 'failed',
            'payload': <String, Object?>{
              'errorSummary': <String, Object?>{
                'code': 'WORKSPACE_NOT_READY',
                'retryable': true,
              },
            },
          },
        ]),
      );
      expect(canonical?.noteOutlineTask?.failureCode, 'WORKSPACE_NOT_READY');
      expect(canonical?.outlineFailureCode, 'WORKSPACE_NOT_READY');

      final safeLaterAlias = parseRecordingDetail(
        payload(<Object?>[
          <String, Object?>{
            'recordingSubTaskId': 'outline-failure-safe-later-alias',
            'recordingId': 'rec-outline-failure-code',
            'taskType': 'recording_note_outline',
            'status': 'failed',
            'payload': <String, Object?>{
              'errorSummary': <String, Object?>{
                'code': '../../private/error',
                'errorCode': 'WORKSPACE_NOT_READY',
              },
            },
          },
        ]),
      );
      expect(safeLaterAlias?.outlineFailureCode, 'WORKSPACE_NOT_READY');

      final safeTopLevelSummary = parseRecordingDetail(
        payload(<Object?>[
          <String, Object?>{
            'recordingSubTaskId': 'outline-failure-top-level-summary',
            'recordingId': 'rec-outline-failure-code',
            'taskType': 'recording_note_outline',
            'status': 'failed',
            'payload': <String, Object?>{
              'errorSummary': <String, Object?>{'code': ''},
            },
            'errorSummary': <String, Object?>{'code': 'WORKSPACE_NOT_READY'},
          },
        ]),
      );
      expect(safeTopLevelSummary?.outlineFailureCode, 'WORKSPACE_NOT_READY');

      final deployedCompatibility = parseRecordingDetail(
        payload(<Object?>[
          <String, Object?>{
            'recordingSubTaskId': 'outline-failure-compatibility',
            'recordingId': 'rec-outline-failure-code',
            'taskType': 'recording_note_outline',
            'status': 'failed',
            'errorSummary': <String, Object?>{
              'errorCode': 'NOTE_RECORDING_OUTLINE_FAILED',
              'message': 'WORKSPACE_NOT_READY',
            },
          },
        ]),
      );
      expect(deployedCompatibility?.outlineFailureCode, 'WORKSPACE_NOT_READY');

      final unsafe = parseRecordingDetail(
        payload(<Object?>[
          <String, Object?>{
            'recordingSubTaskId': 'outline-failure-unsafe',
            'recordingId': 'rec-outline-failure-code',
            'taskType': 'recording_note_outline',
            'status': 'failed',
            'payload': <String, Object?>{
              'errorSummary': <String, Object?>{
                'code': '../../private/error',
                'message': 'database host and internal stack',
              },
            },
          },
        ]),
      );
      expect(unsafe?.noteOutlineTask?.failureCode, isNull);
      expect(unsafe?.outlineFailureCode, 'RECORDING_OUTLINE_FAILED');

      final retried = parseRecordingDetail(
        payload(<Object?>[
          <String, Object?>{
            'recordingSubTaskId': 'outline-failure-old',
            'recordingId': 'rec-outline-failure-code',
            'taskType': 'recording_note_outline',
            'status': 'failed',
            'errorSummary': <String, Object?>{'code': 'WORKSPACE_NOT_READY'},
          },
          <String, Object?>{
            'recordingSubTaskId': 'outline-retry-current',
            'recordingId': 'rec-outline-failure-code',
            'taskType': 'recording_note_outline',
            'status': 'queued',
          },
        ]),
      );
      expect(retried?.noteOutlineTask?.taskId, 'outline-retry-current');
      expect(retried?.outlineFailureCode, isNull);
      expect(retried?.hasOutlineFailure, isFalse);
    });

    test('retains long final transcripts beyond the generic preview bound', () {
      final transcript = List<String>.filled(5000, '转').join();
      final parsed = parseRecordingDetail(<String, Object?>{
        'recording': <String, Object?>{
          'recordingId': 'rec-long-final',
          'title': 'Long interview',
          'transcriptStatus': 'final_transcript_generated',
        },
        'asrTask': <String, Object?>{
          'asrTaskId': 'asr-long-final',
          'status': 'final_transcript_generated',
        },
        'transcript': <String, Object?>{'finalTranscript': transcript},
      });

      expect(parsed?.finalTranscript, transcript);
    });

    test(
      'parses the structured outline and canonical Workspace note binding',
      () {
        final parsed = parseRecordingDetail(<String, Object?>{
          'recording': <String, Object?>{
            'recordingId': 'rec-cloud-note',
            'title': '客户访谈',
            'transcriptStatus': 'final_transcript_generated',
          },
          'noteRef': <String, Object?>{
            'noteId': 'note-cloud-recording',
            'rawPartRevisionId': 'raw-revision-cloud-recording',
            'outlinePartRevisionId': 'outline-revision-cloud-recording',
          },
          'asrTask': <String, Object?>{
            'asrTaskId': 'asr-cloud-note',
            'status': 'completed',
          },
          'transcript': <String, Object?>{'finalTranscript': '这是已经确认的最终转写。'},
          'generatedAssets': <String, Object?>{
            'minutes': <String, Object?>{
              'schemaVersion': 'recording.minutes.v1',
              'title': '客户访谈纲要',
              'overview': '客户确认当前需求并约定下周演示。',
              'participants': <Object?>[
                <String, Object?>{'displayName': '客户', 'role': 'other'},
              ],
              'sections': <Object?>[
                <String, Object?>{
                  'heading': '关键需求',
                  'summary': '需要先验证团队协作能力。',
                  'points': <Object?>[
                    <String, Object?>{'text': '下周安排产品演示。'},
                  ],
                },
              ],
              'decisions': <Object?>[
                <String, Object?>{'content': '先提供演示环境。'},
              ],
              'actionItems': <Object?>[
                <String, Object?>{
                  'content': '发送演示邀请',
                  'ownerName': '小周',
                  'dueDate': '2026-08-12',
                  'status': 'open',
                },
              ],
              'quoteHighlights': <Object?>[
                <String, Object?>{'speakerName': '客户', 'text': '团队协作最重要。'},
              ],
              'openQuestions': <Object?>[
                <String, Object?>{'content': '演示需要覆盖哪些角色？'},
              ],
            },
            'minutesMarkdown': '# 不应作为主数据反解析',
            'summary': '本次重点是验证协作流程。',
          },
        });

        expect(parsed?.canonicalNoteId, 'note-cloud-recording');
        expect(
          parsed?.noteRef?.rawPartRevisionId,
          'raw-revision-cloud-recording',
        );
        expect(
          parsed?.noteRef?.outlinePartRevisionId,
          'outline-revision-cloud-recording',
        );
        expect(parsed?.hasCloudAsset, isTrue);
        expect(parsed?.minutes?.title, '客户访谈纲要');
        expect(parsed?.minutes?.sections.single.points, <String>['下周安排产品演示。']);
        expect(parsed?.minutes?.actionItems.single.ownerName, '小周');
      },
    );
  });
}

RecordingApi _api(_QueueTransport transport) {
  return RecordingApi(
    apiClient: ApiClient(
      config: ApiClientConfig(
        baseUrl: Uri.parse('https://api.example.test'),
        clientVersion: 'test',
        deviceId: 'device-1',
        platform: 'ios',
        locale: 'zh-CN',
        getAccessToken: () => 'access-token',
      ),
      transport: transport,
    ),
  );
}

Map<String, Object?> _body(ApiTransportRequest request) {
  final decoded = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

final class _QueueTransport implements ApiTransport {
  _QueueTransport(List<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.from(responses);

  final List<ApiTransportResponse> _responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('unexpected API request');
    return _responses.removeAt(0);
  }
}
