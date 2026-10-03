import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';

final class CloudRecordingSummary {
  const CloudRecordingSummary({
    required this.recordingId,
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

  factory CloudRecordingSummary.fromValue(Object? value) {
    final object = _object(value, 'recording');
    return CloudRecordingSummary(
      recordingId: _id(object, 'recordingId'),
      title: _text(object['title'], fallback: '历史录音'),
      workspaceId: _id(object, 'workspaceId'),
      transcriptStatus: _status(object['transcriptStatus'], 'queued'),
      minutesStatus: _status(object['minutesStatus'], 'not_started'),
      summaryStatus: _status(object['summaryStatus'], 'not_started'),
      depositStatus: _status(object['depositStatus'], 'not_started'),
      asrTaskId: _optionalId(object['asrTaskId']),
      noteId: _optionalId(object['noteId']),
      recordedAt: _optionalDate(object['recordedAt']),
    );
  }

  final String recordingId;
  final String title;
  final String workspaceId;
  final String transcriptStatus;
  final String minutesStatus;
  final String summaryStatus;
  final String depositStatus;
  final String? asrTaskId;
  final String? noteId;
  final DateTime? recordedAt;
}

final class CloudRecordingPage {
  CloudRecordingPage(Iterable<CloudRecordingSummary> items)
    : items = List<CloudRecordingSummary>.unmodifiable(items);

  factory CloudRecordingPage.fromValue(Object? value, String workspaceId) {
    final object = _object(value, 'recording page');
    final rawItems = object['items'];
    if (rawItems is! List<Object?>) {
      throw const FormatException('recording page items must be a list');
    }
    return CloudRecordingPage(
      rawItems
          .map(CloudRecordingSummary.fromValue)
          .where((item) => item.workspaceId == workspaceId),
    );
  }

  final List<CloudRecordingSummary> items;
}

final class CloudAsrTask {
  const CloudAsrTask({
    required this.asrTaskId,
    required this.status,
    this.progress,
    this.message,
    this.version,
  });

  factory CloudAsrTask.fromValue(Object? value) {
    final object = _object(value, 'ASR task');
    final rawProgress = object['progress'];
    final progress = rawProgress is num ? rawProgress.round() : null;
    if (progress != null && (progress < 0 || progress > 100)) {
      throw const FormatException('ASR progress is invalid');
    }
    return CloudAsrTask(
      asrTaskId: _id(object, 'asrTaskId', alternatives: const ['taskId']),
      status: _status(object['status'], 'queued'),
      progress: progress,
      message: _optionalText(object['message']),
      version: _optionalPositiveInt(object['version']),
    );
  }

  final String asrTaskId;
  final String status;
  final int? progress;
  final String? message;
  final int? version;
}

final class CloudRecordingRetryAction {
  const CloudRecordingRetryAction({
    required this.stage,
    required this.title,
    required this.allowed,
  });

  factory CloudRecordingRetryAction.fromValue(Object? value) {
    final object = _object(value, 'retry action');
    final allowed = object['allowed'];
    if (allowed is! bool) {
      throw const FormatException('retry action allowed must be bool');
    }
    return CloudRecordingRetryAction(
      stage: _status(object['stage'], ''),
      title: _text(object['title'], fallback: '重试'),
      allowed: allowed,
    );
  }

  final String stage;
  final String title;
  final bool allowed;
}

final class CloudRecordingDetail {
  CloudRecordingDetail({
    required this.recording,
    required this.asrTask,
    required this.finalTranscript,
    required this.minutesMarkdown,
    required this.summary,
    required this.noteId,
    required Iterable<CloudRecordingRetryAction> retryActions,
  }) : retryActions = List<CloudRecordingRetryAction>.unmodifiable(
         retryActions,
       );

  factory CloudRecordingDetail.fromValue(Object? value) {
    final object = _object(value, 'recording detail');
    final generated = asObjectMap(object['generatedAssets']) ?? const {};
    final noteRef = asObjectMap(object['noteRef']);
    final rawRetryActions = object['retryActions'];
    if (rawRetryActions is! List<Object?>) {
      throw const FormatException('retryActions must be a list');
    }
    return CloudRecordingDetail(
      recording: CloudRecordingSummary.fromValue(object['recording']),
      asrTask: object['asrTask'] == null
          ? null
          : CloudAsrTask.fromValue(object['asrTask']),
      finalTranscript: _optionalText(
        generated['finalTranscript'] ?? object['finalTranscript'],
        maxLength: 1000000,
      ),
      minutesMarkdown: _optionalText(
        generated['minutesMarkdown'] ?? object['minutesMarkdown'],
        maxLength: 1000000,
      ),
      summary: _optionalText(
        generated['summary'] ?? object['summary'],
        maxLength: 1000000,
      ),
      noteId: _optionalId(noteRef?['noteId'] ?? object['noteId']),
      retryActions: rawRetryActions.map(CloudRecordingRetryAction.fromValue),
    );
  }

  final CloudRecordingSummary recording;
  final CloudAsrTask? asrTask;
  final String? finalTranscript;
  final String? minutesMarkdown;
  final String? summary;
  final String? noteId;
  final List<CloudRecordingRetryAction> retryActions;
}

final class CloudSpeakerCandidate {
  CloudSpeakerCandidate({
    required this.speakerId,
    required this.displayName,
    required this.segmentCount,
    required Iterable<String> sampleTexts,
    this.currentName,
    this.isSelf,
  }) : sampleTexts = List<String>.unmodifiable(sampleTexts);

  factory CloudSpeakerCandidate.fromValue(Object? value) {
    final object = _object(value, 'speaker');
    final rawSamples = object['sampleTexts'];
    if (rawSamples != null && rawSamples is! List<Object?>) {
      throw const FormatException('sampleTexts must be a list');
    }
    final count = object['segmentCount'];
    final isSelf = object['isSelf'];
    if (count is! num || count < 0 || (isSelf != null && isSelf is! bool)) {
      throw const FormatException('speaker metadata is invalid');
    }
    return CloudSpeakerCandidate(
      speakerId: _id(object, 'speakerId'),
      displayName: _text(object['displayName'], fallback: '说话人'),
      currentName: _optionalText(object['currentName'], maxLength: 80),
      segmentCount: count.round(),
      sampleTexts: (rawSamples as List<Object?>? ?? const [])
          .map((value) => _text(value, fallback: ''))
          .where((value) => value.isNotEmpty),
      isSelf: isSelf as bool?,
    );
  }

  final String speakerId;
  final String displayName;
  final String? currentName;
  final int segmentCount;
  final List<String> sampleTexts;
  final bool? isSelf;
}

final class CloudSpeakerSegment {
  const CloudSpeakerSegment({
    required this.speakerId,
    required this.startMs,
    required this.endMs,
    this.text,
  });

  factory CloudSpeakerSegment.fromValue(Object? value) {
    final object = _object(value, 'speaker segment');
    final start = object['startMs'];
    final end = object['endMs'];
    if (start is! num || end is! num || start < 0 || end < start) {
      throw const FormatException('speaker segment range is invalid');
    }
    return CloudSpeakerSegment(
      speakerId: _id(object, 'speakerId'),
      startMs: start.round(),
      endMs: end.round(),
      text: _optionalText(object['text'], maxLength: 20000),
    );
  }

  final String speakerId;
  final int startMs;
  final int endMs;
  final String? text;
}

final class CloudSpeakerLabelPanel {
  CloudSpeakerLabelPanel({
    required this.recordingId,
    required this.asrTask,
    required Iterable<CloudSpeakerCandidate> speakers,
    required Iterable<CloudSpeakerSegment> segments,
    required Map<String, String> speakerNameMap,
    required this.selfSpeakerId,
    required this.previewText,
    required this.canSubmit,
    required this.reason,
  }) : speakers = List<CloudSpeakerCandidate>.unmodifiable(speakers),
       segments = List<CloudSpeakerSegment>.unmodifiable(segments),
       speakerNameMap = Map<String, String>.unmodifiable(speakerNameMap);

  factory CloudSpeakerLabelPanel.fromValue(Object? value, String expectedId) {
    final object = _object(value, 'speaker label panel');
    final recording = CloudRecordingSummary.fromValue(object['recording']);
    final speakers = _list(
      object,
      'speakers',
    ).map(CloudSpeakerCandidate.fromValue).toList(growable: false);
    final segments = _list(
      object,
      'segments',
    ).map(CloudSpeakerSegment.fromValue).toList(growable: false);
    final names = _stringMap(object['speakerNameMap']);
    final speakerIds = speakers.map((speaker) => speaker.speakerId).toSet();
    final selfId = _optionalId(object['selfSpeakerId']);
    final canSubmit = object['canSubmit'];
    if (recording.recordingId != expectedId ||
        canSubmit is! bool ||
        names.keys.any((id) => !speakerIds.contains(id)) ||
        segments.any((item) => !speakerIds.contains(item.speakerId)) ||
        (selfId != null && !speakerIds.contains(selfId))) {
      throw const FormatException('speaker label panel is inconsistent');
    }
    return CloudSpeakerLabelPanel(
      recordingId: expectedId,
      asrTask: CloudAsrTask.fromValue(object['asrTask']),
      speakers: speakers,
      segments: segments,
      speakerNameMap: names,
      selfSpeakerId: selfId,
      previewText: _text(
        object['previewText'],
        fallback: '',
        maxLength: 1000000,
      ),
      canSubmit: canSubmit,
      reason: _optionalText(object['reason']),
    );
  }

  final String recordingId;
  final CloudAsrTask asrTask;
  final List<CloudSpeakerCandidate> speakers;
  final List<CloudSpeakerSegment> segments;
  final Map<String, String> speakerNameMap;
  final String? selfSpeakerId;
  final String previewText;
  final bool canSubmit;
  final String? reason;
}

final class RecordingClient {
  const RecordingClient(this._api);

  final ApiClient _api;

  Future<ApiResult<CloudRecordingPage>> list(String workspaceId) {
    final id = _checkedId(workspaceId, 'workspaceId');
    return _api.request<CloudRecordingPage>(
      ApiRequestOptions<CloudRecordingPage>(
        endpointId: 'recordings',
        query: <String, Object?>{'workspaceId': id},
        parseData: (value) => CloudRecordingPage.fromValue(value, id),
      ),
    );
  }

  Future<ApiResult<CloudRecordingDetail>> detail(String recordingId) =>
      _api.request<CloudRecordingDetail>(
        ApiRequestOptions<CloudRecordingDetail>(
          endpointId: 'recordingDetail',
          pathParams: <String, Object>{
            'recordingId': _checkedId(recordingId, 'recordingId'),
          },
          parseData: CloudRecordingDetail.fromValue,
        ),
      );

  Future<ApiResult<CloudSpeakerLabelPanel>> speakerPanel(String recordingId) {
    final id = _checkedId(recordingId, 'recordingId');
    return _api.request<CloudSpeakerLabelPanel>(
      ApiRequestOptions<CloudSpeakerLabelPanel>(
        endpointId: 'speakerLabelPanel',
        pathParams: <String, Object>{'recordingId': id},
        parseData: (value) => CloudSpeakerLabelPanel.fromValue(value, id),
      ),
    );
  }

  Future<ApiResult<void>> saveSpeakerDraft({
    required String recordingId,
    required Map<String, String> names,
    required String? selfSpeakerId,
    required String idempotencyKey,
  }) => _write(
    endpointId: 'saveSpeakerLabelDraft',
    recordingId: recordingId,
    idempotencyKey: idempotencyKey,
    body: <String, Object?>{
      'speakerNameMap': _checkedNames(names),
      if (selfSpeakerId != null)
        'selfSpeakerId': _checkedId(selfSpeakerId, 'selfSpeakerId'),
    },
  );

  Future<ApiResult<void>> submitSpeakerLabels({
    required String recordingId,
    required int baseAsrTaskVersion,
    required Map<String, String> names,
    required String selfSpeakerId,
    required String idempotencyKey,
  }) {
    if (baseAsrTaskVersion < 1) {
      throw ArgumentError.value(baseAsrTaskVersion, 'baseAsrTaskVersion');
    }
    return _write(
      endpointId: 'submitSpeakerLabels',
      recordingId: recordingId,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'baseAsrTaskVersion': baseAsrTaskVersion,
        'speakerNameMap': _checkedNames(names),
        'selfSpeakerId': _checkedId(selfSpeakerId, 'selfSpeakerId'),
      },
    );
  }

  Future<ApiResult<void>> retry({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) => _write(
    endpointId: 'retryRecording',
    recordingId: recordingId,
    idempotencyKey: idempotencyKey,
    body: <String, Object?>{'stage': _checkedStatus(stage, 'stage')},
  );

  Future<ApiResult<void>> _write({
    required String endpointId,
    required String recordingId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    final result = await _api.request<_RecordingWriteReceipt>(
      ApiRequestOptions<_RecordingWriteReceipt>(
        endpointId: endpointId,
        pathParams: <String, Object>{
          'recordingId': _checkedId(recordingId, 'recordingId'),
        },
        body: body,
        idempotency: IdempotencyRequestContext(
          explicitKey: _checkedId(idempotencyKey, 'idempotencyKey'),
        ),
        parseData: (_) => const _RecordingWriteReceipt(),
      ),
    );
    if (result.ok) {
      return ApiResult<void>.success(
        data: null,
        status: result.status ?? 200,
        traceId: result.traceId,
        idempotencyStore: result.idempotencyStore,
        responseHeaders: result.responseHeaders,
      );
    }
    return ApiResult<void>.failure(
      error: result.error!,
      status: result.status,
      traceId: result.traceId,
      authExpired: result.authExpired,
      retryAfterSeconds: result.retryAfterSeconds,
      idempotencyStore: result.idempotencyStore,
      responseHeaders: result.responseHeaders,
    );
  }
}

final class _RecordingWriteReceipt {
  const _RecordingWriteReceipt();
}

Map<String, Object?> _object(Object? value, String field) {
  final object = asObjectMap(value);
  if (object == null) throw FormatException('$field must be an object');
  return object;
}

List<Object?> _list(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value is! List<Object?>) throw FormatException('$field must be a list');
  return value;
}

Map<String, String> _stringMap(Object? value) {
  final object = asObjectMap(value);
  if (object == null) throw const FormatException('names must be an object');
  return Map<String, String>.unmodifiable(
    object.map((key, value) => MapEntry(key, _text(value, fallback: ''))),
  );
}

final _identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$');
final _statusPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

String _checkedId(String value, String field) {
  final text = value.trim();
  if (!_identifier.hasMatch(text)) throw ArgumentError.value(value, field);
  return text;
}

String _id(
  Map<String, Object?> object,
  String field, {
  List<String> alternatives = const [],
}) {
  for (final key in <String>[field, ...alternatives]) {
    final value = object[key];
    if (value is String && _identifier.hasMatch(value.trim())) {
      return value.trim();
    }
  }
  throw FormatException('$field is invalid');
}

String? _optionalId(Object? value) {
  if (value == null || value == '') return null;
  if (value is! String || !_identifier.hasMatch(value.trim())) {
    throw const FormatException('optional identifier is invalid');
  }
  return value.trim();
}

String _status(Object? value, String fallback) {
  final text = value is String ? value.trim().toLowerCase() : fallback;
  if (!_statusPattern.hasMatch(text)) {
    throw const FormatException('status is invalid');
  }
  return text;
}

String _checkedStatus(String value, String field) {
  final text = value.trim().toLowerCase();
  if (!_statusPattern.hasMatch(text)) throw ArgumentError.value(value, field);
  return text;
}

String _text(Object? value, {required String fallback, int maxLength = 4000}) {
  if (value == null) return fallback;
  if (value is! String) throw const FormatException('text is invalid');
  final text = value.trim();
  if (text.length > maxLength) throw const FormatException('text is too long');
  return text.isEmpty ? fallback : text;
}

String? _optionalText(Object? value, {int maxLength = 4000}) {
  if (value == null || value == '') return null;
  return _text(value, fallback: '', maxLength: maxLength);
}

DateTime? _optionalDate(Object? value) {
  if (value == null || value == '') return null;
  if (value is! String) throw const FormatException('date is invalid');
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const FormatException('date is invalid');
  return parsed;
}

int? _optionalPositiveInt(Object? value) {
  if (value == null) return null;
  if (value is! num || value < 1) {
    throw const FormatException('positive integer is invalid');
  }
  return value.round();
}

Map<String, String> _checkedNames(Map<String, String> names) {
  if (names.isEmpty) throw ArgumentError.value(names, 'names');
  return Map<String, String>.unmodifiable(
    names.map((key, value) {
      final name = value.trim();
      if (name.isEmpty || name.length > 80) {
        throw ArgumentError.value(value, 'names');
      }
      return MapEntry(_checkedId(key, 'speakerId'), name);
    }),
  );
}
