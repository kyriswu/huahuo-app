import '../../recordings/domain/recording_batch_transcription.dart';

enum RecordingTranscriptionProjectedMessageState {
  processing,
  succeeded,
  failed,
}

enum RecordingTranscriptionProjectedMessageKind {
  batchAggregate,
  transcriptionCompleted,
  transcriptionFailed,
  transcriptionTimedOut,
  outlineCompleted,
  outlineFailed,
}

final class RecordingTranscriptionProjectedMessage {
  const RecordingTranscriptionProjectedMessage({
    required this.kind,
    required this.taskKey,
    required this.title,
    required this.body,
    required this.state,
    required this.createdAt,
    required this.route,
    required this.targetType,
    required this.targetId,
    required this.stage,
    required this.taskId,
    this.errorCode,
  });

  final RecordingTranscriptionProjectedMessageKind kind;
  final String taskKey;
  final String title;
  final String body;
  final RecordingTranscriptionProjectedMessageState state;
  final DateTime createdAt;
  final String route;
  final String targetType;
  final String targetId;
  final String stage;
  final String taskId;
  final String? errorCode;
}

List<RecordingTranscriptionProjectedMessage>
projectRecordingTranscriptionMessages(
  Iterable<RecordingBatchTranscriptionSnapshot> batches,
) {
  final retained = batches.toList(growable: false)
    ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
  final messages = <RecordingTranscriptionProjectedMessage>[];
  final claimedJobIds = <String>{};
  for (final batch in retained) {
    final hasWorkHistory = batch.items.any(
      (item) =>
          item.status != RecordingBatchTranscriptionItemStatus.skipped &&
          !item.isUnavailable,
    );
    if (hasWorkHistory) messages.add(_aggregateMessage(batch));
    final batchIsActive =
        batch.status == RecordingBatchTranscriptionStatus.active;
    for (final item in batch.items) {
      if (!claimedJobIds.add(item.jobId)) continue;
      RecordingTranscriptionProjectedMessage? transcription;
      if (item.status == RecordingBatchTranscriptionItemStatus.completed) {
        transcription = _completedMessage(batch, item, batchIsActive);
      } else if (item.status == RecordingBatchTranscriptionItemStatus.failed &&
          !item.isUnavailable) {
        transcription = _failedMessage(batch, item);
      } else if (item.status ==
          RecordingBatchTranscriptionItemStatus.timedOut) {
        transcription = _timedOutMessage(batch, item);
      }
      if (transcription != null) messages.add(transcription);
      if (item.status != RecordingBatchTranscriptionItemStatus.completed) {
        continue;
      }
      if (item.outlineStatus == RecordingBatchOutlineStatus.completed) {
        messages.add(_outlineMessage(batch, item, failed: false));
      } else if (item.outlineStatus == RecordingBatchOutlineStatus.failed) {
        messages.add(_outlineMessage(batch, item, failed: true));
      }
    }
  }
  return List<RecordingTranscriptionProjectedMessage>.unmodifiable(messages);
}

Set<String> retainedRecordingBatchRemoteIds(
  Iterable<RecordingBatchTranscriptionSnapshot> batches,
) {
  return <String>{
    for (final batch in batches)
      for (final item in batch.items)
        if (_text(item.remoteRecordingId) case final remoteId?) remoteId,
  };
}

Set<String> retainedRecordingBatchJobIds(
  Iterable<RecordingBatchTranscriptionSnapshot> batches,
) {
  return <String>{
    for (final batch in batches)
      for (final item in batch.items) item.jobId,
  };
}

String recordingBatchTranscriptionRoute(String batchId, {String? focusItemId}) {
  final base = '/v3/feed/transcription-batches/${Uri.encodeComponent(batchId)}';
  final focus = _text(focusItemId);
  return focus == null
      ? base
      : '$base?${Uri(queryParameters: <String, String>{'focusItem': focus}).query}';
}

RecordingTranscriptionProjectedMessage _aggregateMessage(
  RecordingBatchTranscriptionSnapshot batch,
) {
  final counts = batch.counts;
  final state = switch (batch.status) {
    RecordingBatchTranscriptionStatus.active =>
      RecordingTranscriptionProjectedMessageState.processing,
    RecordingBatchTranscriptionStatus.completed =>
      RecordingTranscriptionProjectedMessageState.succeeded,
    RecordingBatchTranscriptionStatus.completedWithIssues =>
      RecordingTranscriptionProjectedMessageState.failed,
  };
  final title = switch (batch.status) {
    RecordingBatchTranscriptionStatus.active => '${counts.total} 个录音文件正在转写并保存',
    RecordingBatchTranscriptionStatus.completed => '批量转写完成',
    RecordingBatchTranscriptionStatus.completedWithIssues => '批量转写需要处理',
  };
  final body = switch (batch.status) {
    RecordingBatchTranscriptionStatus.active => _countSummary(counts),
    RecordingBatchTranscriptionStatus.completed =>
      '${counts.total} 个录音处理结束，${counts.completed} 个完成，${counts.skipped} 个已跳过',
    RecordingBatchTranscriptionStatus.completedWithIssues => _countSummary(
      counts,
      processingFinished: true,
    ),
  };
  return RecordingTranscriptionProjectedMessage(
    kind: RecordingTranscriptionProjectedMessageKind.batchAggregate,
    taskKey: 'batch:${batch.batchId}',
    title: title,
    body: body,
    state: state,
    createdAt: batch.createdAt,
    route: recordingBatchTranscriptionRoute(batch.batchId),
    targetType: 'recording_batch',
    targetId: batch.batchId,
    stage: 'recording_batch_transcription',
    taskId: batch.batchId,
    errorCode:
        batch.status == RecordingBatchTranscriptionStatus.completedWithIssues
        ? 'RECORDING_BATCH_COMPLETED_WITH_ISSUES'
        : null,
  );
}

String _countSummary(
  RecordingBatchTranscriptionCounts counts, {
  bool processingFinished = false,
}) {
  final parts = <String>[
    if (counts.completed > 0) '${counts.completed} 个已完成',
    if (counts.active > 0) '${counts.active} 个处理中',
    if (counts.skipped > 0) '${counts.skipped} 个已跳过',
    if (counts.retryableFailed > 0) '${counts.retryableFailed} 个需重试',
    if (counts.timedOut > 0) '${counts.timedOut} 个已超时',
    if (counts.unavailable > 0) '${counts.unavailable} 个不可用',
    if (counts.otherFailed > 0) '${counts.otherFailed} 个失败',
  ];
  final summary = parts.isEmpty ? '暂无可执行文件' : parts.join('，');
  return processingFinished
      ? '${counts.total} 个录音处理结束：$summary'
      : '${counts.total} 个录音：$summary';
}

RecordingTranscriptionProjectedMessage _completedMessage(
  RecordingBatchTranscriptionSnapshot batch,
  RecordingBatchTranscriptionItem item,
  bool batchIsActive,
) {
  final remoteRecordingId = _text(item.remoteRecordingId);
  final useBatchRoute = batchIsActive || remoteRecordingId == null;
  return RecordingTranscriptionProjectedMessage(
    kind: RecordingTranscriptionProjectedMessageKind.transcriptionCompleted,
    taskKey: '${item.jobId}:transcription',
    title: item.title,
    body: '转写完成，结果已保存到我的资产。',
    state: RecordingTranscriptionProjectedMessageState.succeeded,
    createdAt: item.assetReadyAt ?? item.updatedAt,
    route: useBatchRoute
        ? recordingBatchTranscriptionRoute(
            batch.batchId,
            focusItemId: item.itemId,
          )
        : '/v3/feed/transcription-done/${Uri.encodeComponent(remoteRecordingId)}?destination=raw',
    targetType: remoteRecordingId == null ? 'recording_batch' : 'recording',
    targetId: remoteRecordingId ?? batch.batchId,
    stage: 'recording_processing',
    taskId: item.jobId,
  );
}

RecordingTranscriptionProjectedMessage _failedMessage(
  RecordingBatchTranscriptionSnapshot batch,
  RecordingBatchTranscriptionItem item,
) {
  return RecordingTranscriptionProjectedMessage(
    kind: RecordingTranscriptionProjectedMessageKind.transcriptionFailed,
    taskKey: '${item.jobId}:transcription',
    title: item.title,
    body: item.retryable ? '转写并保存到我的资产失败，可打开批次重试。' : '转写并保存到我的资产失败，请打开批次查看详情。',
    state: RecordingTranscriptionProjectedMessageState.failed,
    createdAt: item.updatedAt,
    route: recordingBatchTranscriptionRoute(
      batch.batchId,
      focusItemId: item.itemId,
    ),
    targetType: _text(item.remoteRecordingId) == null
        ? 'recording_batch'
        : 'recording',
    targetId: _text(item.remoteRecordingId) ?? batch.batchId,
    stage: 'recording_processing',
    taskId: item.jobId,
    errorCode: item.errorCode ?? 'RECORDING_TRANSCRIPTION_FAILED',
  );
}

RecordingTranscriptionProjectedMessage _timedOutMessage(
  RecordingBatchTranscriptionSnapshot batch,
  RecordingBatchTranscriptionItem item,
) {
  return RecordingTranscriptionProjectedMessage(
    kind: RecordingTranscriptionProjectedMessageKind.transcriptionTimedOut,
    taskKey: '${item.jobId}:transcription',
    title: item.title,
    body: '转写并保存等待时间较长，可打开批次恢复观察。',
    state: RecordingTranscriptionProjectedMessageState.failed,
    createdAt: item.updatedAt,
    route: recordingBatchTranscriptionRoute(
      batch.batchId,
      focusItemId: item.itemId,
    ),
    targetType: _text(item.remoteRecordingId) == null
        ? 'recording_batch'
        : 'recording',
    targetId: _text(item.remoteRecordingId) ?? batch.batchId,
    stage: 'recording_processing',
    taskId: item.jobId,
    errorCode: item.errorCode ?? 'RECORDING_TRANSCRIPTION_OBSERVATION_TIMEOUT',
  );
}

RecordingTranscriptionProjectedMessage _outlineMessage(
  RecordingBatchTranscriptionSnapshot batch,
  RecordingBatchTranscriptionItem item, {
  required bool failed,
}) {
  final noteId = _text(item.noteId);
  final errorCode = failed
      ? item.outlineErrorCode ?? 'RECORDING_OUTLINE_FAILED'
      : null;
  return RecordingTranscriptionProjectedMessage(
    kind: failed
        ? RecordingTranscriptionProjectedMessageKind.outlineFailed
        : RecordingTranscriptionProjectedMessageKind.outlineCompleted,
    taskKey: '${item.jobId}:outline',
    title: '《${item.title}》纲要',
    body: failed ? _outlineFailureBody(errorCode!) : '纲要已生成。',
    state: failed
        ? RecordingTranscriptionProjectedMessageState.failed
        : RecordingTranscriptionProjectedMessageState.succeeded,
    createdAt: item.updatedAt,
    route: noteId == null
        ? recordingBatchTranscriptionRoute(
            batch.batchId,
            focusItemId: item.itemId,
          )
        : '/v3/feed/items/${Uri.encodeComponent(noteId)}?stage=summary',
    targetType: noteId == null ? 'recording_batch' : 'asset',
    targetId: noteId ?? batch.batchId,
    stage: 'outline',
    taskId: '${item.jobId}:outline',
    errorCode: errorCode,
  );
}

String _outlineFailureBody(String errorCode) => switch (errorCode) {
  'WORKSPACE_NOT_READY' => '工作空间尚未准备完成，原始转写已保留。请打开笔记详情稍后重试。',
  _ => '纲要生成失败，转写结果仍然可用。请打开笔记详情查看。',
};

String? _text(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
