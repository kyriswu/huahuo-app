import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';
import '../../../core/api/upload_client.dart';
import '../domain/recording_detail.dart';

export '../domain/recording_detail.dart';

const _maxFinalTranscriptCharacters = 1000000;
const _maxAuxiliaryUserContentCharacters = 4000;

final class CreateRecordingInput {
  const CreateRecordingInput({
    required this.resource,
    required this.title,
    required this.source,
    required this.recordedAt,
    required this.idempotencyKey,
    this.contentLineId,
  });

  final ResourceIndex resource;
  final String title;
  final String source;
  final DateTime recordedAt;
  final String idempotencyKey;
  final String? contentLineId;
}

final class CreateRecordingResponse {
  const CreateRecordingResponse({required this.recording, this.asrTask});

  final RecordingAsset recording;
  final AsrTaskSnapshot? asrTask;
}

enum RecordingRetryReceiptStatus {
  queued,
  running,
  succeeded,
  failed,
  timeout,
  deadLetter,
  cancelled,
  ignored;

  bool get isAccepted =>
      this == RecordingRetryReceiptStatus.queued ||
      this == RecordingRetryReceiptStatus.running ||
      this == RecordingRetryReceiptStatus.succeeded;
}

final class RetryRecordingResponse {
  const RetryRecordingResponse({
    required this.recordingId,
    required this.stage,
    required this.status,
    this.asrTask,
    this.taskId,
  });

  final String recordingId;
  final String stage;
  final RecordingRetryReceiptStatus status;
  final AsrTaskSnapshot? asrTask;
  final String? taskId;
}

abstract interface class RecordingApiPort {
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  );

  Future<ApiResult<RecordingDetail>> getRecordingDetail(String recordingId);

  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId);

  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  });

  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  });
}

/// Compatibility transport for ASR results that still wait for a speaker
/// submission after voiceprint matching has been skipped or found no match.
abstract interface class RecordingSpeakerAutoAdvanceApiPort {
  Future<ApiResult<void>> autoAdvanceSpeakerLabels({
    required String recordingId,
    required String asrTaskId,
    required int baseAsrTaskVersion,
    required String idempotencyKey,
  });
}

final class RecordingApi
    implements RecordingApiPort, RecordingSpeakerAutoAdvanceApiPort {
  const RecordingApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  ) {
    return _apiClient.request<CreateRecordingResponse>(
      ApiRequestOptions<CreateRecordingResponse>(
        endpointId: 'createRecording',
        body: <String, Object?>{
          'audioResourceId': input.resource.resourceId,
          'title': input.title,
          'source': input.source,
          'recordedAt': input.recordedAt.toIso8601String(),
          if (input.contentLineId != null) 'contentLineId': input.contentLineId,
        },
        idempotency: IdempotencyRequestContext(
          explicitKey: input.idempotencyKey,
        ),
        parseData: parseCreateRecordingResponse,
      ),
    );
  }

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(String recordingId) {
    return _apiClient.request<RecordingDetail>(
      ApiRequestOptions<RecordingDetail>(
        endpointId: 'recordingDetail',
        pathParams: <String, Object>{'recordingId': recordingId},
        parseData: parseRecordingDetail,
      ),
    );
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId) {
    return _apiClient.request<AsrTaskSnapshot>(
      ApiRequestOptions<AsrTaskSnapshot>(
        endpointId: 'asrTask',
        pathParams: <String, Object>{'asrTaskId': asrTaskId},
        parseData: parseAsrTaskSnapshot,
      ),
    );
  }

  @override
  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) {
    final safeStage = _safeRetryStage(stage);
    if (safeStage == null) {
      return Future<ApiResult<RetryRecordingResponse>>.value(
        ApiResult<RetryRecordingResponse>.failure(
          error: recordingApiFailure('RECORDING_RETRY_STAGE_INVALID'),
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
    }
    return _apiClient.request<RetryRecordingResponse>(
      ApiRequestOptions<RetryRecordingResponse>(
        endpointId: 'retryRecording',
        pathParams: <String, Object>{'recordingId': recordingId},
        body: <String, Object?>{'stage': safeStage},
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: (value) => parseRetryRecordingResponse(
          value,
          fallbackRecordingId: recordingId,
          expectedStage: safeStage,
        ),
      ),
    );
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  }) {
    return _apiClient.request<AsrTaskSnapshot>(
      ApiRequestOptions<AsrTaskSnapshot>(
        endpointId: 'retryAsrTask',
        pathParams: <String, Object>{'asrTaskId': asrTaskId},
        body: const <String, Object?>{},
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: (value) {
          final object = asObjectMap(value);
          return parseAsrTaskSnapshot(object?['asrTask'] ?? value);
        },
      ),
    );
  }

  @override
  Future<ApiResult<void>> autoAdvanceSpeakerLabels({
    required String recordingId,
    required String asrTaskId,
    required int baseAsrTaskVersion,
    required String idempotencyKey,
  }) async {
    if (!_safeOpaqueId(recordingId) ||
        !_safeOpaqueId(asrTaskId) ||
        baseAsrTaskVersion < 1 ||
        idempotencyKey.trim().isEmpty) {
      return ApiResult<void>.failure(
        error: recordingApiFailure('RECORDING_SPEAKER_AUTO_ADVANCE_INVALID'),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }

    final client = RecordingClient(_apiClient);
    final panelResult = await client.speakerPanel(recordingId);
    if (!panelResult.ok || panelResult.data == null) {
      return _recordingSpeakerFailureFrom(
        panelResult,
        fallbackCode: 'RECORDING_SPEAKER_PANEL_FAILED',
      );
    }
    final panel = panelResult.data!;
    final panelVersion = panel.asrTask.version;
    if (panel.recordingId != recordingId ||
        panel.asrTask.asrTaskId != asrTaskId ||
        panelVersion != baseAsrTaskVersion ||
        !panel.canSubmit) {
      return ApiResult<void>.failure(
        error: recordingApiFailure(
          'RECORDING_SPEAKER_PANEL_STALE',
          retryable: true,
        ),
        idempotencyStore: panelResult.idempotencyStore,
        status: panelResult.status,
        traceId: panelResult.traceId,
        responseHeaders: panelResult.responseHeaders,
      );
    }
    if (panel.speakers.isEmpty) {
      return ApiResult<void>.failure(
        error: recordingApiFailure(
          'RECORDING_SPEAKER_CANDIDATES_EMPTY',
          retryable: true,
        ),
        idempotencyStore: panelResult.idempotencyStore,
        status: panelResult.status,
        traceId: panelResult.traceId,
        responseHeaders: panelResult.responseHeaders,
      );
    }

    var anonymousIndex = 0;
    final names = <String, String>{};
    for (final speaker in panel.speakers) {
      final existingName = _firstNonEmptySpeakerName(<String?>[
        panel.speakerNameMap[speaker.speakerId],
        speaker.currentName,
      ]);
      if (existingName != null) {
        names[speaker.speakerId] = existingName;
        continue;
      }
      anonymousIndex += 1;
      names[speaker.speakerId] = '说话人 $anonymousIndex';
    }

    final speakerIds = panel.speakers
        .map((speaker) => speaker.speakerId)
        .toSet();
    var selfSpeakerId = panel.selfSpeakerId;
    if (selfSpeakerId == null || !speakerIds.contains(selfSpeakerId)) {
      for (final speaker in panel.speakers) {
        if (speaker.isSelf == true) {
          selfSpeakerId = speaker.speakerId;
          break;
        }
      }
    }
    selfSpeakerId ??= panel.speakers.first.speakerId;

    return client.submitSpeakerLabels(
      recordingId: recordingId,
      baseAsrTaskVersion: baseAsrTaskVersion,
      names: names,
      selfSpeakerId: selfSpeakerId,
      idempotencyKey: idempotencyKey,
    );
  }
}

ApiResult<void> _recordingSpeakerFailureFrom<T>(
  ApiResult<T> source, {
  required String fallbackCode,
}) {
  return ApiResult<void>.failure(
    error: source.error ?? recordingApiFailure(fallbackCode, retryable: true),
    idempotencyStore: source.idempotencyStore,
    status: source.status,
    traceId: source.traceId,
    authExpired: source.authExpired,
    retryAfterSeconds: source.retryAfterSeconds,
    responseHeaders: source.responseHeaders,
  );
}

String? _firstNonEmptySpeakerName(Iterable<String?> values) {
  for (final value in values) {
    final normalized = value?.trim();
    if (normalized != null && normalized.isNotEmpty) return normalized;
  }
  return null;
}

CreateRecordingResponse? parseCreateRecordingResponse(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final recording = parseRecordingAsset(object['recording'] ?? object);
  if (recording == null) return null;
  final asrTask = parseAsrTaskSnapshot(object['asrTask']);
  return CreateRecordingResponse(recording: recording, asrTask: asrTask);
}

RecordingDetail? parseRecordingDetail(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final recording = parseRecordingAsset(object['recording'] ?? object);
  if (recording == null) return null;
  final rawAsrTask = asObjectMap(object['asrTask']);
  final asrTask = parseAsrTaskSnapshot(rawAsrTask);
  final generatedAssets = asObjectMap(object['generatedAssets']);
  final transcript = asObjectMap(object['transcript']);
  final retryActions = _parseRetryActions(object['retryActions']);
  final noteOutlineTask = _parseNoteOutlineTask(
    object['subTasks'],
    recordingId: recording.recordingId,
  );
  final finalTranscript = _safeUserContent(
    transcript?['finalTranscript'] ?? object['finalTranscript'],
    maxCharacters: _maxFinalTranscriptCharacters,
  );
  final finalTranscriptConfirmed =
      finalTranscript != null &&
      (_recordingHasFinalTranscriptFact(recording) ||
          _asrHasFinalTranscriptFact(rawAsrTask));
  return RecordingDetail(
    recording: recording,
    asrTask: asrTask,
    noteRef: _parseRecordingNoteRef(object['noteRef']),
    finalTranscript: finalTranscriptConfirmed
        ? _normalizeAnonymousSpeakerHeaders(finalTranscript)
        : null,
    finalTranscriptConfirmed: finalTranscriptConfirmed,
    minutes: _parseRecordingMinutesDocument(generatedAssets?['minutes']),
    minutesMarkdown: _safeUserContent(
      generatedAssets?['minutesMarkdown'] ?? object['minutesMarkdown'],
    ),
    summary: _safeUserContent(generatedAssets?['summary'] ?? object['summary']),
    noteOutlineTask: noteOutlineTask,
    hasSubTaskSnapshot: object.containsKey('subTasks'),
    retryActions: retryActions,
  );
}

String _normalizeAnonymousSpeakerHeaders(String transcript) {
  final anonymousHeader = RegExp(
    r'^@(speaker[-_ ]?\d+)(?=\s|$)',
    caseSensitive: false,
    multiLine: true,
  );
  final names = <String, String>{};
  return transcript.replaceAllMapped(anonymousHeader, (match) {
    final key = match.group(1)!.toLowerCase();
    final name = names.putIfAbsent(key, () => '说话人 ${names.length + 1}');
    return '@$name';
  });
}

RecordingNoteOutlineTask? _parseNoteOutlineTask(
  Object? value, {
  required String recordingId,
}) {
  if (value is! Iterable) return null;
  RecordingNoteOutlineTask? latest;
  for (final item in value) {
    final object = asObjectMap(item);
    if (object == null || object['taskType'] != 'recording_note_outline') {
      continue;
    }
    final taskId = _safeOptionalId(
      object['recordingSubTaskId'] ?? object['taskId'],
    );
    final status = _parseNoteOutlineTaskStatus(object['status']);
    final rawTaskRecordingId = object['recordingId'];
    final taskRecordingId = _safeOptionalId(rawTaskRecordingId);
    if (taskId == null ||
        status == null ||
        (rawTaskRecordingId != null && taskRecordingId == null) ||
        (taskRecordingId != null && taskRecordingId != recordingId)) {
      continue;
    }
    // The backend lists subtasks in creation order; a later retry receipt is
    // therefore the current authority when historical attempts are present.
    latest = RecordingNoteOutlineTask(
      taskId: taskId,
      status: status,
      failureCode: _parseRecordingOutlineFailureCode(object),
    );
  }
  return latest;
}

String? _parseRecordingOutlineFailureCode(Map<String, Object?> task) {
  final payload = asObjectMap(task['payload']);
  final payloadErrorSummary = asObjectMap(payload?['errorSummary']);
  final taskErrorSummary = asObjectMap(task['errorSummary']);
  final code = _firstSafePublicFailureCode(<Object?>[
    payloadErrorSummary?['code'],
    payloadErrorSummary?['errorCode'],
    taskErrorSummary?['code'],
    taskErrorSummary?['errorCode'],
    payload?['failureCode'],
    payload?['errorCode'],
    task['failureCode'],
    task['errorCode'],
  ]);
  final workspaceNotReadyMessage =
      <Object?>[
        payloadErrorSummary?['message'],
        taskErrorSummary?['message'],
      ].any(
        (message) =>
            message is String && message.trim() == 'WORKSPACE_NOT_READY',
      );
  if (workspaceNotReadyMessage &&
      (code == null ||
          code == 'NOTE_RECORDING_OUTLINE_FAILED' ||
          code == 'RECORDING_OUTLINE_FAILED')) {
    return 'WORKSPACE_NOT_READY';
  }
  return code;
}

RecordingNoteOutlineTaskStatus? _parseNoteOutlineTaskStatus(Object? value) {
  switch (_normalizedStatus(value)) {
    case 'queued':
    case 'pending':
    case 'waiting':
      return RecordingNoteOutlineTaskStatus.queued;
    case 'running':
    case 'processing':
    case 'leased':
      return RecordingNoteOutlineTaskStatus.running;
    case 'succeeded':
    case 'success':
    case 'completed':
    case 'done':
    case 'finished':
      return RecordingNoteOutlineTaskStatus.succeeded;
    case 'failed':
    case 'error':
      return RecordingNoteOutlineTaskStatus.failed;
    case 'timeout':
    case 'timed_out':
      return RecordingNoteOutlineTaskStatus.timeout;
    case 'dead_letter':
      return RecordingNoteOutlineTaskStatus.deadLetter;
    case 'ignored':
      return RecordingNoteOutlineTaskStatus.ignored;
    case 'cancelled':
    case 'canceled':
      return RecordingNoteOutlineTaskStatus.cancelled;
    default:
      return null;
  }
}

RecordingNoteRef? _parseRecordingNoteRef(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final noteId = _safeOptionalId(object['noteId']);
  final rawPartRevisionId = _safeOptionalId(object['rawPartRevisionId']);
  final rawOutlinePartRevisionId = object['outlinePartRevisionId'];
  String? outlinePartRevisionId;
  if (rawOutlinePartRevisionId != null) {
    if (rawOutlinePartRevisionId is! String) return null;
    final normalizedOutlinePartRevisionId = rawOutlinePartRevisionId.trim();
    if (normalizedOutlinePartRevisionId.isNotEmpty) {
      outlinePartRevisionId = _safeOptionalId(normalizedOutlinePartRevisionId);
      if (outlinePartRevisionId == null) return null;
    }
  }
  if (noteId == null || rawPartRevisionId == null) return null;
  return RecordingNoteRef(
    noteId: noteId,
    rawPartRevisionId: rawPartRevisionId,
    outlinePartRevisionId: outlinePartRevisionId,
  );
}

RecordingAsset? parseRecordingAsset(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final id = asNonEmptyString(object['recordingId'] ?? object['id']);
  if (id == null || !_safeOpaqueId(id)) return null;
  final title =
      _safeStrictText(
        object['title'] ?? object['displayName'] ?? object['fileName'],
      ) ??
      '历史录音';
  return RecordingAsset(
    recordingId: id,
    title: title,
    status: _resolveRecordingStatus(object),
    asrTaskId: _safeOptionalId(object['asrTaskId']),
    noteId: _safeOptionalId(object['noteId']),
    contentLineId: _safeOptionalId(object['contentLineId']),
    recordedAt: DateTime.tryParse('${object['recordedAt'] ?? ''}'),
    transcriptStatus: _safeStatusText(object['transcriptStatus']),
    speakerLabelStatus: _safeStatusText(object['speakerLabelStatus']),
    minutesStatus: _safeStatusText(object['minutesStatus']),
    summaryStatus: _safeStatusText(object['summaryStatus']),
    depositStatus: _safeStatusText(object['depositStatus']),
  );
}

RecordingMinutesDocument? _parseRecordingMinutesDocument(Object? value) {
  final object = asObjectMap(value);
  if (object == null || object['schemaVersion'] != 'recording.minutes.v1') {
    return null;
  }
  final title = _safeUserContent(object['title'], maxCharacters: 120);
  final overview = _safeUserContent(object['overview'], maxCharacters: 600);
  final participants = _parseRecordingMinutesParticipants(
    object['participants'],
  );
  final sections = _parseRecordingMinutesSections(object['sections']);
  final decisions = _parseRecordingMinutesTextItems(
    object['decisions'],
    field: 'content',
  );
  final actionItems = _parseRecordingMinutesActionItems(object['actionItems']);
  final quoteHighlights = _parseRecordingMinutesQuoteHighlights(
    object['quoteHighlights'],
  );
  final openQuestions = _parseRecordingMinutesTextItems(
    object['openQuestions'],
    field: 'content',
  );
  if (title == null ||
      overview == null ||
      participants == null ||
      sections == null ||
      decisions == null ||
      actionItems == null ||
      quoteHighlights == null ||
      openQuestions == null) {
    return null;
  }
  return RecordingMinutesDocument(
    title: title,
    overview: overview,
    participants: List<RecordingMinutesParticipant>.unmodifiable(participants),
    sections: List<RecordingMinutesSection>.unmodifiable(sections),
    decisions: List<String>.unmodifiable(decisions),
    actionItems: List<RecordingMinutesActionItem>.unmodifiable(actionItems),
    quoteHighlights: List<RecordingMinutesQuoteHighlight>.unmodifiable(
      quoteHighlights,
    ),
    openQuestions: List<String>.unmodifiable(openQuestions),
  );
}

List<RecordingMinutesParticipant>? _parseRecordingMinutesParticipants(
  Object? value,
) {
  if (value == null) return const <RecordingMinutesParticipant>[];
  if (value is! Iterable) return null;
  final participants = <RecordingMinutesParticipant>[];
  for (final entry in value) {
    final object = asObjectMap(entry);
    final displayName = _safeUserContent(
      object?['displayName'],
      maxCharacters: 120,
    );
    final role = _safeStatusText(object?['role']);
    if (object == null || displayName == null) return null;
    participants.add(
      RecordingMinutesParticipant(displayName: displayName, role: role),
    );
  }
  return participants;
}

List<RecordingMinutesSection>? _parseRecordingMinutesSections(Object? value) {
  if (value == null) return const <RecordingMinutesSection>[];
  if (value is! Iterable) return null;
  final sections = <RecordingMinutesSection>[];
  for (final entry in value) {
    final object = asObjectMap(entry);
    final heading = _safeUserContent(object?['heading'], maxCharacters: 160);
    final summary = _safeUserContent(object?['summary'], maxCharacters: 4000);
    final points = _parseRecordingMinutesTextItems(
      object?['points'],
      field: 'text',
    );
    if (object == null ||
        heading == null ||
        summary == null ||
        points == null) {
      return null;
    }
    sections.add(
      RecordingMinutesSection(
        heading: heading,
        summary: summary,
        points: List<String>.unmodifiable(points),
      ),
    );
  }
  return sections;
}

List<String>? _parseRecordingMinutesTextItems(
  Object? value, {
  required String field,
}) {
  if (value == null) return const <String>[];
  if (value is! Iterable) return null;
  final values = <String>[];
  for (final entry in value) {
    final object = asObjectMap(entry);
    final text = _safeUserContent(object?[field], maxCharacters: 4000);
    if (object == null || text == null) return null;
    values.add(text);
  }
  return values;
}

List<RecordingMinutesActionItem>? _parseRecordingMinutesActionItems(
  Object? value,
) {
  if (value == null) return const <RecordingMinutesActionItem>[];
  if (value is! Iterable) return null;
  final actionItems = <RecordingMinutesActionItem>[];
  for (final entry in value) {
    final object = asObjectMap(entry);
    final content = _safeUserContent(object?['content'], maxCharacters: 4000);
    final ownerName = _safeUserContent(
      object?['ownerName'],
      maxCharacters: 120,
    );
    final dueDate = _safeUserContent(object?['dueDate'], maxCharacters: 80);
    final status = _safeStatusText(object?['status']);
    if (object == null || content == null) return null;
    actionItems.add(
      RecordingMinutesActionItem(
        content: content,
        ownerName: ownerName,
        dueDate: dueDate,
        status: status,
      ),
    );
  }
  return actionItems;
}

List<RecordingMinutesQuoteHighlight>? _parseRecordingMinutesQuoteHighlights(
  Object? value,
) {
  if (value == null) return const <RecordingMinutesQuoteHighlight>[];
  if (value is! Iterable) return null;
  final highlights = <RecordingMinutesQuoteHighlight>[];
  for (final entry in value) {
    final object = asObjectMap(entry);
    final text = _safeUserContent(object?['text'], maxCharacters: 4000);
    final speakerName = _safeUserContent(
      object?['speakerName'],
      maxCharacters: 120,
    );
    final reason = _safeUserContent(object?['reason'], maxCharacters: 600);
    if (object == null || text == null) return null;
    highlights.add(
      RecordingMinutesQuoteHighlight(
        text: text,
        speakerName: speakerName,
        reason: reason,
      ),
    );
  }
  return highlights;
}

AsrTaskSnapshot? parseAsrTaskSnapshot(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final id = asNonEmptyString(
    object['asrTaskId'] ?? object['taskId'] ?? object['id'],
  );
  if (id == null || !_safeOpaqueId(id)) return null;
  final progress = object['progress'];
  return AsrTaskSnapshot(
    asrTaskId: id,
    status: _parseRemoteStatus(object['status']),
    progress: _percent(progress),
    message: _safeStrictText(object['message']),
    version: _positiveInt(object['version']),
  );
}

RetryRecordingResponse? parseRetryRecordingResponse(
  Object? value, {
  required String fallbackRecordingId,
  required String expectedStage,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;

  final safeFallbackRecordingId = _safeOptionalId(fallbackRecordingId);
  final safeExpectedStage = _safeRetryStage(expectedStage);
  final responseStage = _safeRetryStage(object['stage']);
  final status = _parseRecordingRetryReceiptStatus(object['status']);
  if (safeFallbackRecordingId == null ||
      safeExpectedStage == null ||
      responseStage == null ||
      responseStage != safeExpectedStage ||
      status == null) {
    return null;
  }

  final hasRecording = object.containsKey('recording');
  final recording = parseRecordingAsset(object['recording']);
  if (hasRecording && recording == null) return null;

  final hasAsrTask = object.containsKey('asrTask');
  final asrTask = parseAsrTaskSnapshot(object['asrTask']);
  if (hasAsrTask && asrTask == null) return null;

  final hasRecordingId = object.containsKey('recordingId');
  final rawRecordingId = object['recordingId'];
  final directRecordingId = _safeOptionalId(rawRecordingId);
  if ((hasRecordingId && directRecordingId == null) ||
      (directRecordingId != null &&
          directRecordingId != safeFallbackRecordingId) ||
      (recording != null && recording.recordingId != safeFallbackRecordingId)) {
    return null;
  }

  final hasTaskId = object.containsKey('taskId');
  final hasRecordingSubTaskId = object.containsKey('recordingSubTaskId');
  final directTaskId = _safeOptionalId(object['taskId']);
  final recordingSubTaskId = _safeOptionalId(object['recordingSubTaskId']);
  if ((hasTaskId && directTaskId == null) ||
      (hasRecordingSubTaskId && recordingSubTaskId == null) ||
      (directTaskId != null &&
          recordingSubTaskId != null &&
          directTaskId != recordingSubTaskId)) {
    return null;
  }

  return RetryRecordingResponse(
    recordingId: safeFallbackRecordingId,
    stage: responseStage,
    status: status,
    asrTask: asrTask,
    taskId: directTaskId ?? recordingSubTaskId,
  );
}

RecordingRetryReceiptStatus? _parseRecordingRetryReceiptStatus(Object? value) {
  switch (_normalizedStatus(value)) {
    case 'queued':
    case 'pending':
    case 'waiting':
    case 'retry_wait':
      return RecordingRetryReceiptStatus.queued;
    case 'running':
    case 'processing':
    case 'leased':
      return RecordingRetryReceiptStatus.running;
    case 'succeeded':
    case 'success':
    case 'completed':
    case 'done':
    case 'finished':
      return RecordingRetryReceiptStatus.succeeded;
    case 'failed':
    case 'error':
      return RecordingRetryReceiptStatus.failed;
    case 'timeout':
    case 'timed_out':
      return RecordingRetryReceiptStatus.timeout;
    case 'dead_letter':
      return RecordingRetryReceiptStatus.deadLetter;
    case 'cancelled':
    case 'canceled':
      return RecordingRetryReceiptStatus.cancelled;
    case 'ignored':
      return RecordingRetryReceiptStatus.ignored;
    default:
      return null;
  }
}

AppFailure recordingApiFailure(String code, {bool retryable = false}) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.api,
    message: 'Recording API operation failed',
    userMessageKey: 'recording.api.error.$code',
    isRetryable: retryable,
    recoveryActions: retryable
        ? const <String>['retry']
        : const <String>['none'],
  );
}

List<RecordingRetryAction> _parseRetryActions(Object? value) {
  if (value is! Iterable) return const <RecordingRetryAction>[];
  final actions = <RecordingRetryAction>[];
  for (final item in value) {
    final object = asObjectMap(item);
    if (object == null) continue;
    final stage = _safeRetryStage(object['stage'] ?? object['action']);
    if (stage == null) continue;
    actions.add(
      RecordingRetryAction(
        stage: stage,
        title: _safeStrictText(object['title'] ?? object['label']) ?? '重试',
        allowed: object['allowed'] == true || object['retryable'] == true,
      ),
    );
  }
  return List<RecordingRetryAction>.unmodifiable(actions);
}

RecordingRemoteStatus _parseRemoteStatus(Object? value) {
  return _tryParseRemoteStatus(value) ?? RecordingRemoteStatus.queued;
}

RecordingRemoteStatus _resolveRecordingStatus(Map<String, Object?> object) {
  final direct = _tryParseRemoteStatus(
    object['status'] ?? object['lifecycleStatus'] ?? object['asrStatus'],
  );
  final deposit = _parseStageStatus(
    _safeStatusText(object['depositStatus']),
    pending: RecordingRemoteStatus.depositing,
    completed: RecordingRemoteStatus.deposited,
  );
  final summary = _parseStageStatus(
    _safeStatusText(object['summaryStatus']),
    pending: RecordingRemoteStatus.generatingSummary,
    completed: RecordingRemoteStatus.completed,
  );
  final minutes = _parseStageStatus(
    _safeStatusText(object['minutesStatus']),
    pending: RecordingRemoteStatus.generatingMinutes,
    completed: RecordingRemoteStatus.completed,
  );
  final speaker = _parseStageStatus(
    _safeStatusText(object['speakerLabelStatus']),
    pending: RecordingRemoteStatus.speakerLabelPending,
    completed: RecordingRemoteStatus.completed,
  );
  final transcriptStatus = _safeStatusText(object['transcriptStatus']);
  final transcript = _parseTranscriptStageStatus(transcriptStatus);
  final specialized = <RecordingRemoteStatus?>[
    deposit,
    summary,
    minutes,
    speaker,
    transcript,
  ];
  if (_isFailureOrCancelled(direct)) return direct!;
  for (final status in specialized) {
    if (_isFailureOrCancelled(status)) return status!;
  }
  if (deposit == RecordingRemoteStatus.deposited) {
    return RecordingRemoteStatus.deposited;
  }
  for (final status in specialized) {
    if (status != null &&
        status != RecordingRemoteStatus.completed &&
        status != RecordingRemoteStatus.deposited) {
      return status;
    }
  }
  if (direct != null) return direct;
  for (final status in specialized) {
    if (status != null) return status;
  }
  return RecordingRemoteStatus.queued;
}

RecordingRemoteStatus? _parseStageStatus(
  String? value, {
  required RecordingRemoteStatus pending,
  required RecordingRemoteStatus completed,
}) {
  if (value == null) return null;
  final normalized = _normalizedStatus(value);
  final parsed = _tryParseRemoteStatus(value);
  if (_isFailureOrCancelled(parsed)) return parsed;
  if (_isCompletedStatus(normalized)) return completed;
  if (parsed != null) return pending;
  if (_isActiveStatus(normalized)) return pending;
  return null;
}

RecordingRemoteStatus? _parseTranscriptStageStatus(String? value) {
  switch (value) {
    case 'speaker_labeling':
    case 'transcribed':
      return RecordingRemoteStatus.speakerLabelPending;
    case 'speaker_confirmed':
    case 'final_transcript_generated':
      return RecordingRemoteStatus.generatingMinutes;
    default:
      return _parseStageStatus(
        value,
        pending: RecordingRemoteStatus.asrRunning,
        completed: RecordingRemoteStatus.completed,
      );
  }
}

RecordingRemoteStatus? _tryParseRemoteStatus(Object? value) {
  final text = _normalizedStatus(value);
  switch (text) {
    case 'queued':
    case 'pending':
    case 'created':
    case 'waiting':
      return RecordingRemoteStatus.queued;
    case 'uploading':
      return RecordingRemoteStatus.uploading;
    case 'uploaded':
      return RecordingRemoteStatus.uploaded;
    case 'processing':
    case 'running':
      return RecordingRemoteStatus.processing;
    case 'asr_running':
    case 'asr_pending':
    case 'transcribing':
    case 'transcription_running':
      return RecordingRemoteStatus.asrRunning;
    case 'speaker_label_pending':
    case 'speaker_labeling':
    case 'labeling':
    case 'transcribed':
      return RecordingRemoteStatus.speakerLabelPending;
    case 'generating_minutes':
    case 'minutes_generation':
    case 'minutes_generating':
    case 'speaker_confirmed':
    case 'final_transcript_generated':
      return RecordingRemoteStatus.generatingMinutes;
    case 'generating_summary':
    case 'summary_generation':
    case 'summary_generating':
      return RecordingRemoteStatus.generatingSummary;
    case 'depositing':
    case 'recording_deposit':
    case 'workspace_write':
      return RecordingRemoteStatus.depositing;
    case 'deposited':
      return RecordingRemoteStatus.deposited;
    case 'completed':
    case 'succeeded':
    case 'success':
    case 'done':
    case 'finished':
      return RecordingRemoteStatus.completed;
    case 'failed':
    case 'error':
    case 'asr_failed':
      return RecordingRemoteStatus.failed;
    case 'timeout':
    case 'timed_out':
      return RecordingRemoteStatus.timeout;
    case 'cancelled':
    case 'canceled':
      return RecordingRemoteStatus.cancelled;
    default:
      return null;
  }
}

String _normalizedStatus(Object? value) {
  return value is String
      ? value.trim().toLowerCase().replaceAll('-', '_').replaceAll(' ', '_')
      : '';
}

bool _isCompletedStatus(String value) {
  return value == 'completed' ||
      value == 'succeeded' ||
      value == 'success' ||
      value == 'done' ||
      value == 'finished' ||
      value == 'deposited';
}

bool _isActiveStatus(String value) {
  return value == 'pending' ||
      value == 'queued' ||
      value == 'uploading' ||
      value == 'uploaded' ||
      value == 'processing' ||
      value == 'running' ||
      value == 'generating' ||
      value == 'asr_running' ||
      value == 'speaker_labeling' ||
      value == 'speaker_label_pending' ||
      value == 'depositing';
}

bool _isFailureOrCancelled(RecordingRemoteStatus? status) {
  return status == RecordingRemoteStatus.failed ||
      status == RecordingRemoteStatus.timeout ||
      status == RecordingRemoteStatus.cancelled;
}

bool _recordingHasFinalTranscriptFact(RecordingAsset recording) {
  final transcriptStatus = recording.transcriptStatus;
  if (transcriptStatus != null) {
    return transcriptStatus == 'final_transcript_generated' ||
        _isCompletedStatus(transcriptStatus);
  }
  return recording.status == RecordingRemoteStatus.completed ||
      recording.status == RecordingRemoteStatus.deposited;
}

bool _asrHasFinalTranscriptFact(Map<String, Object?>? asrTask) {
  final status = _normalizedStatus(asrTask?['status']);
  return status == 'final_transcript_generated' || _isCompletedStatus(status);
}

String? _safeStatusText(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null ||
      !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(text) ||
      _containsSecretOrPath(text)) {
    return null;
  }
  return _normalizedStatus(text);
}

String? _safeRetryStage(Object? value) {
  final stage = value is String ? value.trim() : null;
  if (stage == null ||
      !RegExp(r'^[a-z][a-z0-9_]{0,127}$').hasMatch(stage) ||
      _containsSecretOrPath(stage)) {
    return null;
  }
  return stage;
}

String? _safePublicFailureCode(Object? value) {
  final code = value is String ? value.trim() : null;
  if (code == null ||
      !RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(code) ||
      _containsSecretOrPath(code)) {
    return null;
  }
  return code;
}

String? _firstSafePublicFailureCode(Iterable<Object?> candidates) {
  for (final candidate in candidates) {
    final code = _safePublicFailureCode(candidate);
    if (code != null) return code;
  }
  return null;
}

int? _nonNegativeInt(Object? value) {
  if (value is! num ||
      !value.isFinite ||
      value < 0 ||
      value != value.roundToDouble()) {
    return null;
  }
  return value.toInt();
}

int? _positiveInt(Object? value) {
  final parsed = _nonNegativeInt(value);
  return parsed != null && parsed > 0 ? parsed : null;
}

int? _percent(Object? value) {
  final parsed = _nonNegativeInt(value);
  if (parsed == null) return null;
  return parsed.clamp(0, 100).toInt();
}

String? _safeOptionalId(Object? value) {
  final id = asNonEmptyString(value);
  return id != null && _safeOpaqueId(id) ? id : null;
}

bool _safeOpaqueId(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value) &&
      !_containsSecretOrPath(value);
}

String? _safeStrictText(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > 160) return null;
  if (_containsSecretOrPath(text) || _containsInternalWords(text)) return null;
  return text;
}

String? _safeUserContent(
  Object? value, {
  int maxCharacters = _maxAuxiliaryUserContentCharacters,
}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty) return null;
  if (_containsSecretOrPath(text)) return null;
  return text.length > maxCharacters ? text.substring(0, maxCharacters) : text;
}

bool _containsInternalWords(String text) {
  return <RegExp>[
    RegExp('provider', caseSensitive: false),
    RegExp('runtime', caseSensitive: false),
    RegExp('workspace.*path', caseSensitive: false),
  ].any((pattern) => pattern.hasMatch(text));
}

bool _containsSecretOrPath(String text) {
  return <RegExp>[
    RegExp(r'^file://', caseSensitive: false),
    RegExp(r'[\/]Users[\/]', caseSensitive: false),
    RegExp(r'^[A-Za-z]:[\\/]', caseSensitive: false),
    RegExp(r'https?://[^\s]*(signature|x-amz|token)=', caseSensitive: false),
    RegExp(r'(access|refresh)?token\s*=', caseSensitive: false),
    RegExp(r'(secret|apiKey|api_key)\s*=', caseSensitive: false),
  ].any((pattern) => pattern.hasMatch(text));
}
