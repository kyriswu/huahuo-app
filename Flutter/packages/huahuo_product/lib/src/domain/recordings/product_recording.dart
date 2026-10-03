import '../product_result.dart';

final class ProductRecording {
  const ProductRecording({
    required this.id,
    required this.title,
    required this.workspaceId,
    required this.transcriptStatus,
    required this.minutesStatus,
    required this.summaryStatus,
    required this.depositStatus,
    this.asrTaskId,
    this.noteId,
    this.recordedAt,
  });

  final String id;
  final String title;
  final String workspaceId;
  final String transcriptStatus;
  final String minutesStatus;
  final String summaryStatus;
  final String depositStatus;
  final String? asrTaskId;
  final String? noteId;
  final DateTime? recordedAt;

  bool get requiresSpeakerLabels => const <String>{
    'speaker_label_pending',
    'speaker_labeling',
    'transcribed',
  }.contains(transcriptStatus);

  bool get isTerminal => const <String>{
    'completed',
    'succeeded',
    'failed',
    'timeout',
    'cancelled',
    'canceled',
  }.contains(transcriptStatus);
}

final class ProductAsrTask {
  const ProductAsrTask({
    required this.id,
    required this.status,
    this.progress,
    this.message,
    this.version,
  });

  final String id;
  final String status;
  final int? progress;
  final String? message;
  final int? version;
}

final class ProductRecordingRetryAction {
  const ProductRecordingRetryAction({required this.stage, required this.title});

  final String stage;
  final String title;
}

final class ProductRecordingDetail {
  ProductRecordingDetail({
    required this.recording,
    required this.asrTask,
    required this.transcript,
    required this.minutesMarkdown,
    required this.summary,
    required this.noteId,
    required Iterable<ProductRecordingRetryAction> retryActions,
  }) : retryActions = List<ProductRecordingRetryAction>.unmodifiable(
         retryActions,
       );

  final ProductRecording recording;
  final ProductAsrTask? asrTask;
  final String? transcript;
  final String? minutesMarkdown;
  final String? summary;
  final String? noteId;
  final List<ProductRecordingRetryAction> retryActions;

  bool get hasGeneratedContent =>
      transcript?.isNotEmpty == true ||
      minutesMarkdown?.isNotEmpty == true ||
      summary?.isNotEmpty == true;
}

final class ProductSpeakerCandidate {
  ProductSpeakerCandidate({
    required this.id,
    required this.displayName,
    required this.segmentCount,
    required Iterable<String> samples,
    this.currentName,
    this.isSelf,
  }) : samples = List<String>.unmodifiable(samples);

  final String id;
  final String displayName;
  final String? currentName;
  final int segmentCount;
  final List<String> samples;
  final bool? isSelf;
}

final class ProductSpeakerSegment {
  const ProductSpeakerSegment({
    required this.speakerId,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final String speakerId;
  final int startMs;
  final int endMs;
  final String? text;
}

final class ProductSpeakerPanel {
  ProductSpeakerPanel({
    required this.recordingId,
    required this.asrTask,
    required Iterable<ProductSpeakerCandidate> speakers,
    required Iterable<ProductSpeakerSegment> segments,
    required Map<String, String> names,
    required this.selfSpeakerId,
    required this.previewText,
    required this.canSubmit,
    required this.reason,
  }) : speakers = List<ProductSpeakerCandidate>.unmodifiable(speakers),
       segments = List<ProductSpeakerSegment>.unmodifiable(segments),
       names = Map<String, String>.unmodifiable(names);

  final String recordingId;
  final ProductAsrTask asrTask;
  final List<ProductSpeakerCandidate> speakers;
  final List<ProductSpeakerSegment> segments;
  final Map<String, String> names;
  final String? selfSpeakerId;
  final String previewText;
  final bool canSubmit;
  final String? reason;

  ProductSpeakerPanel copyWith({
    Map<String, String>? names,
    String? selfSpeakerId,
    bool clearSelfSpeaker = false,
  }) => ProductSpeakerPanel(
    recordingId: recordingId,
    asrTask: asrTask,
    speakers: speakers,
    segments: segments,
    names: names ?? this.names,
    selfSpeakerId: clearSelfSpeaker
        ? null
        : selfSpeakerId ?? this.selfSpeakerId,
    previewText: previewText,
    canSubmit: canSubmit,
    reason: reason,
  );

  bool get isComplete =>
      canSubmit &&
      selfSpeakerId != null &&
      speakers.isNotEmpty &&
      speakers.every((speaker) => names[speaker.id]?.trim().isNotEmpty == true);
}

abstract interface class ProductRecordingsRepository {
  Future<ProductResult<List<ProductRecording>>> list(String workspaceId);

  Future<ProductResult<ProductRecordingDetail>> detail(String recordingId);

  Future<ProductResult<ProductSpeakerPanel>> speakerPanel(String recordingId);

  Future<ProductResult<void>> saveSpeakerDraft({
    required String recordingId,
    required Map<String, String> names,
    required String? selfSpeakerId,
    required String idempotencyKey,
  });

  Future<ProductResult<void>> submitSpeakerLabels({
    required String recordingId,
    required int baseAsrTaskVersion,
    required Map<String, String> names,
    required String selfSpeakerId,
    required String idempotencyKey,
  });

  Future<ProductResult<void>> retryStage({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  });
}

final class UnavailableProductRecordingsRepository
    implements ProductRecordingsRepository {
  const UnavailableProductRecordingsRepository();

  static const _failure = ProductResult<void>.failure(
    code: 'PRODUCT_RECORDINGS_UNAVAILABLE',
    message: '录音服务尚未配置',
  );

  @override
  Future<ProductResult<ProductRecordingDetail>> detail(
    String recordingId,
  ) async => const ProductResult<ProductRecordingDetail>.failure(
    code: 'PRODUCT_RECORDINGS_UNAVAILABLE',
    message: '录音服务尚未配置',
  );

  @override
  Future<ProductResult<List<ProductRecording>>> list(
    String workspaceId,
  ) async => const ProductResult<List<ProductRecording>>.failure(
    code: 'PRODUCT_RECORDINGS_UNAVAILABLE',
    message: '录音服务尚未配置',
  );

  @override
  Future<ProductResult<ProductSpeakerPanel>> speakerPanel(
    String recordingId,
  ) async => const ProductResult<ProductSpeakerPanel>.failure(
    code: 'PRODUCT_RECORDINGS_UNAVAILABLE',
    message: '录音服务尚未配置',
  );

  @override
  Future<ProductResult<void>> retryStage({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) async => _failure;

  @override
  Future<ProductResult<void>> saveSpeakerDraft({
    required String recordingId,
    required Map<String, String> names,
    required String? selfSpeakerId,
    required String idempotencyKey,
  }) async => _failure;

  @override
  Future<ProductResult<void>> submitSpeakerLabels({
    required String recordingId,
    required int baseAsrTaskVersion,
    required Map<String, String> names,
    required String selfSpeakerId,
    required String idempotencyKey,
  }) async => _failure;
}
