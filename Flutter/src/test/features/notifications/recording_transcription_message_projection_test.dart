import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/notifications/application/recording_transcription_message_projection.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_batch_transcription.dart';

void main() {
  group('recording transcription message projection', () {
    test(
      'uses one aggregate and routes active child results to a focused batch',
      () {
        final batch = _batch(<RecordingBatchTranscriptionItem>[
          _item(
            'one',
            status: RecordingBatchTranscriptionItemStatus.completed,
            remoteRecordingId: 'remote-one',
            noteId: 'note-one',
          ),
          _item(
            'two',
            status: RecordingBatchTranscriptionItemStatus.processing,
            remoteRecordingId: 'remote-two',
          ),
        ]);

        final messages = projectRecordingTranscriptionMessages(
          <RecordingBatchTranscriptionSnapshot>[batch],
        );

        expect(messages, hasLength(2));
        final aggregate = messages.firstWhere(
          (message) =>
              message.kind ==
              RecordingTranscriptionProjectedMessageKind.batchAggregate,
        );
        final completed = messages.firstWhere(
          (message) =>
              message.kind ==
              RecordingTranscriptionProjectedMessageKind.transcriptionCompleted,
        );
        expect(
          aggregate.state,
          RecordingTranscriptionProjectedMessageState.processing,
        );
        expect(aggregate.title, '2 个录音文件正在转写并保存');
        expect(
          completed.route,
          '/v3/feed/transcription-batches/batch-a?focusItem=one',
        );
        expect(
          messages.where((message) => message.title == 'Recording two'),
          isEmpty,
        );
        expect(
          retainedRecordingBatchRemoteIds(<RecordingBatchTranscriptionSnapshot>[
            batch,
          ]),
          {'remote-one', 'remote-two'},
        );
        expect(
          retainedRecordingBatchJobIds(<RecordingBatchTranscriptionSnapshot>[
            batch,
          ]),
          {'job-one', 'job-two'},
        );
      },
    );

    test(
      'merges transcript and asset success into one terminal file message',
      () {
        final batch = _batch(<RecordingBatchTranscriptionItem>[
          _item(
            'one',
            status: RecordingBatchTranscriptionItemStatus.completed,
            remoteRecordingId: 'remote-one',
            noteId: 'note-one',
          ),
          _item(
            'two',
            status: RecordingBatchTranscriptionItemStatus.completed,
            remoteRecordingId: 'remote-two',
            noteId: 'note-two',
          ),
        ]);

        final messages = projectRecordingTranscriptionMessages(
          <RecordingBatchTranscriptionSnapshot>[batch],
        );

        expect(
          messages.where(
            (message) =>
                message.kind ==
                RecordingTranscriptionProjectedMessageKind
                    .transcriptionCompleted,
          ),
          hasLength(2),
        );
        expect(
          messages.where((message) => message.body.contains('资产已生成')),
          isEmpty,
        );
        expect(
          messages
              .firstWhere((message) => message.targetId == 'remote-one')
              .body,
          '转写完成，结果已保存到我的资产。',
        );
        expect(
          messages
              .firstWhere((message) => message.targetId == 'remote-one')
              .route,
          '/v3/feed/transcription-done/remote-one?destination=raw',
        );
        expect(
          messages
              .firstWhere(
                (message) =>
                    message.kind ==
                    RecordingTranscriptionProjectedMessageKind.batchAggregate,
              )
              .state,
          RecordingTranscriptionProjectedMessageState.succeeded,
        );
      },
    );

    test('retains identifiers after a batch reaches a terminal state', () {
      final batch = _batch(<RecordingBatchTranscriptionItem>[
        _item(
          'one',
          status: RecordingBatchTranscriptionItemStatus.completed,
          remoteRecordingId: 'remote-one',
          noteId: 'note-one',
        ),
        _item(
          'two',
          status: RecordingBatchTranscriptionItemStatus.failed,
          remoteRecordingId: 'remote-two',
        ),
      ]);

      expect(
        batch.status,
        RecordingBatchTranscriptionStatus.completedWithIssues,
      );
      expect(
        retainedRecordingBatchRemoteIds(<RecordingBatchTranscriptionSnapshot>[
          batch,
        ]),
        {'remote-one', 'remote-two'},
      );
      expect(
        retainedRecordingBatchJobIds(<RecordingBatchTranscriptionSnapshot>[
          batch,
        ]),
        {'job-one', 'job-two'},
      );
    });

    test('keeps Outline completion as an independent asset message', () {
      final batch = _batch(<RecordingBatchTranscriptionItem>[
        _item(
          'one',
          status: RecordingBatchTranscriptionItemStatus.completed,
          remoteRecordingId: 'remote-one',
          noteId: 'note-one',
          outlineStatus: RecordingBatchOutlineStatus.completed,
        ),
        _item(
          'two',
          status: RecordingBatchTranscriptionItemStatus.completed,
          remoteRecordingId: 'remote-two',
          noteId: 'note-two',
        ),
      ]);

      final messages = projectRecordingTranscriptionMessages(
        <RecordingBatchTranscriptionSnapshot>[batch],
      );
      final outline = messages.singleWhere(
        (message) =>
            message.kind ==
            RecordingTranscriptionProjectedMessageKind.outlineCompleted,
      );

      expect(outline.targetType, 'asset');
      expect(outline.targetId, 'note-one');
      expect(outline.route, '/v3/feed/items/note-one?stage=summary');
      expect(outline.stage, 'outline');
    });

    test(
      'routes a workspace outline failure to Note detail without an action',
      () {
        final batch = _batch(<RecordingBatchTranscriptionItem>[
          _item(
            'one',
            status: RecordingBatchTranscriptionItemStatus.completed,
            remoteRecordingId: 'remote-one',
            noteId: 'note-one',
            outlineStatus: RecordingBatchOutlineStatus.failed,
            outlineErrorCode: 'WORKSPACE_NOT_READY',
          ),
          _item(
            'two',
            status: RecordingBatchTranscriptionItemStatus.completed,
            remoteRecordingId: 'remote-two',
            noteId: 'note-two',
          ),
        ]);

        final outline =
            projectRecordingTranscriptionMessages(
              <RecordingBatchTranscriptionSnapshot>[batch],
            ).singleWhere(
              (message) =>
                  message.kind ==
                  RecordingTranscriptionProjectedMessageKind.outlineFailed,
            );

        expect(outline.errorCode, 'WORKSPACE_NOT_READY');
        expect(outline.body, contains('工作空间尚未准备完成'));
        expect(outline.route, '/v3/feed/items/note-one?stage=summary');
        expect(outline.stage, 'outline');
      },
    );

    test(
      'does not create an aggregate task for all skipped or unavailable results',
      () {
        final batch = _batch(<RecordingBatchTranscriptionItem>[
          _item(
            'one',
            status: RecordingBatchTranscriptionItemStatus.skipped,
            remoteRecordingId: 'remote-one',
            noteId: 'note-one',
          ),
          _item(
            'two',
            status: RecordingBatchTranscriptionItemStatus.failed,
            failureCategory: RecordingBatchFailureCategory.unavailable,
          ),
        ]);

        expect(
          projectRecordingTranscriptionMessages(
            <RecordingBatchTranscriptionSnapshot>[batch],
          ),
          isEmpty,
        );
      },
    );

    test('accounts for every active, skipped, and attention item', () {
      final batch = _batch(<RecordingBatchTranscriptionItem>[
        _item(
          'one',
          status: RecordingBatchTranscriptionItemStatus.completed,
          remoteRecordingId: 'remote-one',
          noteId: 'note-one',
        ),
        _item(
          'two',
          status: RecordingBatchTranscriptionItemStatus.processing,
          remoteRecordingId: 'remote-two',
        ),
        _item(
          'three',
          status: RecordingBatchTranscriptionItemStatus.skipped,
          remoteRecordingId: 'remote-three',
          noteId: 'note-three',
        ),
        _item('four', status: RecordingBatchTranscriptionItemStatus.failed),
      ]);

      final aggregate =
          projectRecordingTranscriptionMessages(
            <RecordingBatchTranscriptionSnapshot>[batch],
          ).firstWhere(
            (message) =>
                message.kind ==
                RecordingTranscriptionProjectedMessageKind.batchAggregate,
          );

      expect(aggregate.body, '4 个录音：1 个已完成，1 个处理中，1 个已跳过，1 个失败');
    });

    test('keeps aggregate failure categories mutually exclusive', () {
      final batch = _batch(<RecordingBatchTranscriptionItem>[
        _item(
          'completed',
          status: RecordingBatchTranscriptionItemStatus.completed,
          remoteRecordingId: 'remote-completed',
          noteId: 'note-completed',
        ),
        _item(
          'processing',
          status: RecordingBatchTranscriptionItemStatus.processing,
          remoteRecordingId: 'remote-processing',
        ),
        _item(
          'skipped',
          status: RecordingBatchTranscriptionItemStatus.skipped,
          remoteRecordingId: 'remote-skipped',
          noteId: 'note-skipped',
        ),
        _item(
          'retryable',
          status: RecordingBatchTranscriptionItemStatus.failed,
          retryable: true,
        ),
        _item(
          'timeout',
          status: RecordingBatchTranscriptionItemStatus.timedOut,
        ),
        _item(
          'unavailable',
          status: RecordingBatchTranscriptionItemStatus.failed,
          failureCategory: RecordingBatchFailureCategory.unavailable,
        ),
        _item('failed', status: RecordingBatchTranscriptionItemStatus.failed),
      ]);

      final aggregate =
          projectRecordingTranscriptionMessages(
            <RecordingBatchTranscriptionSnapshot>[batch],
          ).firstWhere(
            (message) =>
                message.kind ==
                RecordingTranscriptionProjectedMessageKind.batchAggregate,
          );

      expect(
        aggregate.body,
        '7 个录音：1 个已完成，1 个处理中，1 个已跳过，1 个需重试，1 个已超时，1 个不可用，1 个失败',
      );
    });

    test('keeps only the newest retained context for each stable job', () {
      final older = _batch(
        <RecordingBatchTranscriptionItem>[
          _item(
            'one',
            status: RecordingBatchTranscriptionItemStatus.completed,
            remoteRecordingId: 'remote-one',
            noteId: 'note-one',
            outlineStatus: RecordingBatchOutlineStatus.completed,
          ),
          _item(
            'two',
            status: RecordingBatchTranscriptionItemStatus.completed,
            remoteRecordingId: 'remote-two',
            noteId: 'note-two',
          ),
        ],
        batchId: 'batch-older',
        createdAt: DateTime.utc(2026, 9, 4, 7),
      );
      final newer = _batch(
        <RecordingBatchTranscriptionItem>[
          _item(
            'one',
            status: RecordingBatchTranscriptionItemStatus.completed,
            remoteRecordingId: 'remote-one',
            noteId: 'note-one',
            outlineStatus: RecordingBatchOutlineStatus.completed,
          ),
          _item(
            'two',
            status: RecordingBatchTranscriptionItemStatus.processing,
            remoteRecordingId: 'remote-two',
          ),
        ],
        batchId: 'batch-newer',
        createdAt: DateTime.utc(2026, 9, 4, 9),
      );

      final messages = projectRecordingTranscriptionMessages(
        <RecordingBatchTranscriptionSnapshot>[older, newer],
      );
      final fileMessages = messages.where(
        (message) =>
            message.kind ==
            RecordingTranscriptionProjectedMessageKind.transcriptionCompleted,
      );
      final outlineMessages = messages.where(
        (message) =>
            message.kind ==
            RecordingTranscriptionProjectedMessageKind.outlineCompleted,
      );

      expect(fileMessages, hasLength(1));
      expect(outlineMessages, hasLength(1));
      expect(fileMessages.single.taskKey, 'job-one:transcription');
      expect(
        fileMessages.single.route,
        '/v3/feed/transcription-batches/batch-newer?focusItem=one',
      );
    });
  });
}

RecordingBatchTranscriptionSnapshot _batch(
  List<RecordingBatchTranscriptionItem> items, {
  String batchId = 'batch-a',
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime.utc(2026, 9, 4, 8);
  return RecordingBatchTranscriptionSnapshot(
    batchId: batchId,
    accountScope: 'account-a',
    workspaceScope: 'workspace-a',
    primaryItemId: items.first.itemId,
    items: items,
    createdAt: now,
    updatedAt: now,
  );
}

RecordingBatchTranscriptionItem _item(
  String id, {
  required RecordingBatchTranscriptionItemStatus status,
  String? remoteRecordingId,
  String? noteId,
  RecordingBatchOutlineStatus outlineStatus =
      RecordingBatchOutlineStatus.notStarted,
  String? outlineErrorCode,
  RecordingBatchFailureCategory? failureCategory,
  bool retryable = false,
}) {
  final now = DateTime.utc(2026, 9, 4, 8);
  final completed = status == RecordingBatchTranscriptionItemStatus.completed;
  return RecordingBatchTranscriptionItem(
    itemId: id,
    title: 'Recording $id',
    fileIdentity: 'hash-$id',
    localRecordingId: id,
    jobId: 'job-$id',
    remoteRecordingId: remoteRecordingId,
    noteId: noteId,
    status: status,
    phase: completed ? RecordingBatchTranscriptionPhase.assetReady : null,
    outlineStatus: outlineStatus,
    progress: completed ? 100 : null,
    retryable: retryable,
    attemptCount: 1,
    errorCode: failureCategory == null ? null : 'RECORDING_FILE_UNAVAILABLE',
    outlineErrorCode: outlineErrorCode,
    failureCategory: failureCategory,
    transcriptCompletedAt: completed ? now : null,
    assetReadyAt: completed ? now : null,
    createdAt: now,
    updatedAt: now,
  );
}
