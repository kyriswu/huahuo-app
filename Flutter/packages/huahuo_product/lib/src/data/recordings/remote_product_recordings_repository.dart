import 'package:huahuo_api/huahuo_api.dart';

import '../../domain/product_result.dart';
import '../../domain/recordings/product_recording.dart';

final class RemoteProductRecordingsRepository
    implements ProductRecordingsRepository {
  RemoteProductRecordingsRepository(ApiClient apiClient)
    : _client = RecordingClient(apiClient);

  final RecordingClient _client;

  @override
  Future<ProductResult<List<ProductRecording>>> list(String workspaceId) async {
    try {
      final result = await _client.list(workspaceId);
      final page = result.data;
      if (!result.ok || page == null) return _failure(result);
      return ProductResult<List<ProductRecording>>.success(
        List<ProductRecording>.unmodifiable(page.items.map(_recording)),
      );
    } on ArgumentError {
      return _invalid();
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<ProductRecordingDetail>> detail(
    String recordingId,
  ) async {
    try {
      final result = await _client.detail(recordingId);
      final detail = result.data;
      if (!result.ok || detail == null) return _failure(result);
      return ProductResult<ProductRecordingDetail>.success(
        ProductRecordingDetail(
          recording: _recording(detail.recording),
          asrTask: detail.asrTask == null ? null : _asr(detail.asrTask!),
          transcript: detail.finalTranscript,
          minutesMarkdown: detail.minutesMarkdown,
          summary: detail.summary,
          noteId: detail.noteId,
          retryActions: detail.retryActions
              .where((action) => action.allowed)
              .map(
                (action) => ProductRecordingRetryAction(
                  stage: action.stage,
                  title: action.title,
                ),
              ),
        ),
      );
    } on ArgumentError {
      return _invalid();
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<ProductSpeakerPanel>> speakerPanel(
    String recordingId,
  ) async {
    try {
      final result = await _client.speakerPanel(recordingId);
      final panel = result.data;
      if (!result.ok || panel == null) return _failure(result);
      return ProductResult<ProductSpeakerPanel>.success(
        ProductSpeakerPanel(
          recordingId: panel.recordingId,
          asrTask: _asr(panel.asrTask),
          speakers: panel.speakers.map(
            (speaker) => ProductSpeakerCandidate(
              id: speaker.speakerId,
              displayName: speaker.displayName,
              currentName: speaker.currentName,
              segmentCount: speaker.segmentCount,
              samples: speaker.sampleTexts,
              isSelf: speaker.isSelf,
            ),
          ),
          segments: panel.segments.map(
            (segment) => ProductSpeakerSegment(
              speakerId: segment.speakerId,
              startMs: segment.startMs,
              endMs: segment.endMs,
              text: segment.text,
            ),
          ),
          names: panel.speakerNameMap,
          selfSpeakerId: panel.selfSpeakerId,
          previewText: panel.previewText,
          canSubmit: panel.canSubmit,
          reason: panel.reason,
        ),
      );
    } on ArgumentError {
      return _invalid();
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<void>> retryStage({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) => _mutation(
    () => _client.retry(
      recordingId: recordingId,
      stage: stage,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<void>> saveSpeakerDraft({
    required String recordingId,
    required Map<String, String> names,
    required String? selfSpeakerId,
    required String idempotencyKey,
  }) => _mutation(
    () => _client.saveSpeakerDraft(
      recordingId: recordingId,
      names: names,
      selfSpeakerId: selfSpeakerId,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<void>> submitSpeakerLabels({
    required String recordingId,
    required int baseAsrTaskVersion,
    required Map<String, String> names,
    required String selfSpeakerId,
    required String idempotencyKey,
  }) => _mutation(
    () => _client.submitSpeakerLabels(
      recordingId: recordingId,
      baseAsrTaskVersion: baseAsrTaskVersion,
      names: names,
      selfSpeakerId: selfSpeakerId,
      idempotencyKey: idempotencyKey,
    ),
  );

  Future<ProductResult<void>> _mutation(
    Future<ApiResult<void>> Function() action,
  ) async {
    try {
      final result = await action();
      return result.ok
          ? const ProductResult<void>.success(null)
          : _failure(result);
    } on ArgumentError {
      return _invalid();
    } on Object {
      return _unexpected();
    }
  }
}

ProductRecording _recording(CloudRecordingSummary source) => ProductRecording(
  id: source.recordingId,
  title: source.title,
  workspaceId: source.workspaceId,
  transcriptStatus: source.transcriptStatus,
  minutesStatus: source.minutesStatus,
  summaryStatus: source.summaryStatus,
  depositStatus: source.depositStatus,
  asrTaskId: source.asrTaskId,
  noteId: source.noteId,
  recordedAt: source.recordedAt,
);

ProductAsrTask _asr(CloudAsrTask source) => ProductAsrTask(
  id: source.asrTaskId,
  status: source.status,
  progress: source.progress,
  message: source.message,
  version: source.version,
);

ProductResult<T> _failure<T>(ApiResult<Object?> result) =>
    ProductResult.failure(
      code: result.error?.code ?? 'PRODUCT_RECORDINGS_RESPONSE_INVALID',
      message: result.error?.message ?? '录音服务响应无效',
      retryable: result.error?.isRetryable ?? false,
    );

ProductResult<T> _invalid<T>() => const ProductResult.failure(
  code: 'PRODUCT_RECORDINGS_INPUT_INVALID',
  message: '录音操作参数无效',
);

ProductResult<T> _unexpected<T>() => const ProductResult.failure(
  code: 'PRODUCT_RECORDINGS_UNEXPECTED',
  message: '录音服务暂时不可用',
  retryable: true,
);
