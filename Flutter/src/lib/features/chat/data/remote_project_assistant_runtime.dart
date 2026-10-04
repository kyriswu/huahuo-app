import 'package:huahuo_api/huahuo_api.dart';
import '../domain/assistant_runtime.dart';
import '../domain/chat_models.dart';

/// Used during bootstrap before a device-scoped API client is available.
final class UnavailableAssistantRuntime implements AssistantRuntimePort {
  const UnavailableAssistantRuntime();

  @override
  Future<AssistantRuntimeRead<AssistantRunSnapshot>> readRun({
    required AssistantRunHandle handle,
  }) => Future<AssistantRuntimeRead<AssistantRunSnapshot>>.value(
    const AssistantRuntimeRead<AssistantRunSnapshot>.failure(
      'ASSISTANT_RUNTIME_UNAVAILABLE',
      outcomeUnknown: true,
    ),
  );
}

/// Maps the current project chat/agent API into the provider-neutral runtime
/// contract. OpenClaw, Coze, and Dify details must remain behind the project
/// backend and never appear in this adapter's public API.
final class RemoteProjectAssistantRuntime
    implements
        AssistantRuntimePort,
        AssistantRuntimeReadLeasePort,
        AssistantRuntimeStreamPort,
        AssistantThreadProgressPort {
  RemoteProjectAssistantRuntime(ApiClient apiClient)
    : _api = apiClient,
      _client = AgentRunClient(apiClient);

  final ApiClient _api;
  final AgentRunClient _client;

  @override
  Future<AssistantRuntimeRead<AssistantRunSnapshot>> readRun({
    required AssistantRunHandle handle,
  }) async {
    if (!_isProjectRunHandle(handle)) {
      return const AssistantRuntimeRead<AssistantRunSnapshot>.failure(
        'ASSISTANT_RUN_HANDLE_INVALID',
      );
    }
    final result = await _client.get(handle.value.trim());
    final run = result.data;
    if (!result.ok || run == null) {
      return AssistantRuntimeRead<AssistantRunSnapshot>.failure(
        result.error?.code ?? 'ASSISTANT_RUN_READ_FAILED',
        outcomeUnknown:
            result.status == null ||
            result.status == 408 ||
            result.status == 429 ||
            result.status! >= 500 ||
            result.error?.category == AppFailureCategory.network,
      );
    }
    return AssistantRuntimeRead.success(_mapSnapshot(run));
  }

  @override
  AssistantRuntimeReadLease<AssistantRunSnapshot> leaseReadRun({
    required AssistantRunHandle handle,
  }) {
    if (!_isProjectRunHandle(handle)) {
      return AssistantRuntimeReadLease<AssistantRunSnapshot>(
        result: Future<AssistantRuntimeRead<AssistantRunSnapshot>>.value(
          const AssistantRuntimeRead<AssistantRunSnapshot>.failure(
            'ASSISTANT_RUN_HANDLE_INVALID',
          ),
        ),
        cancel: _noOpCancel,
      );
    }
    final lease = _client.leaseGet(handle.value.trim());
    return AssistantRuntimeReadLease<AssistantRunSnapshot>(
      result: lease.result.then(_mapApiRunResult),
      cancel: lease.cancel,
    );
  }

  @override
  Future<AssistantRuntimeRead<Stream<AssistantStreamEvent>>> streamEvents({
    required AssistantRunHandle handle,
    String? lastEventId,
  }) async {
    if (!_isProjectRunHandle(handle)) {
      return const AssistantRuntimeRead<Stream<AssistantStreamEvent>>.failure(
        'ASSISTANT_RUN_HANDLE_INVALID',
      );
    }
    final result = await _client.eventStream(
      handle.value.trim(),
      lastEventId: lastEventId,
    );
    final source = result.data;
    if (!result.ok || source == null) {
      return AssistantRuntimeRead<Stream<AssistantStreamEvent>>.failure(
        result.error?.code ?? 'ASSISTANT_RUN_STREAM_FAILED',
        outcomeUnknown:
            result.status == null ||
            result.status == 408 ||
            result.status == 429 ||
            result.status! >= 500 ||
            result.error?.category == AppFailureCategory.network,
      );
    }
    return AssistantRuntimeRead.success(_mapStream(source));
  }

  @override
  Future<AssistantRuntimeRead<AssistantProgressPage>> readProgress({
    required String conversationId,
    required int afterSequence,
  }) async {
    if (!isSafeChatIdentifier(conversationId) || afterSequence < 0) {
      return const AssistantRuntimeRead<AssistantProgressPage>.failure(
        'ASSISTANT_PROGRESS_QUERY_INVALID',
      );
    }
    final result = await _api.request<AssistantProgressPage>(
      ApiRequestOptions<AssistantProgressPage>(
        endpointId: 'chatThreadEvents',
        pathParams: <String, Object>{'threadId': conversationId},
        query: <String, Object?>{'afterSequence': afterSequence, 'limit': 100},
        parseData: (value) =>
            _parseProgressPage(value, expectedConversationId: conversationId),
      ),
    );
    if (!result.ok || result.data == null) {
      return AssistantRuntimeRead<AssistantProgressPage>.failure(
        result.error?.code ?? 'ASSISTANT_PROGRESS_READ_FAILED',
        outcomeUnknown:
            result.status == null ||
            result.status == 408 ||
            result.status == 429 ||
            result.status! >= 500 ||
            result.error?.category == AppFailureCategory.network,
      );
    }
    return AssistantRuntimeRead.success(result.data!);
  }
}

AssistantProgressPage _parseProgressPage(
  Object? value, {
  required String expectedConversationId,
}) {
  final object = asObjectMap(value);
  if (object == null ||
      object['threadId'] != expectedConversationId ||
      !isSafeChatIdentifier(expectedConversationId)) {
    throw const FormatException('Invalid assistant progress conversation');
  }
  final nextSequence = object['nextSequence'];
  final rawEvents = object['events'];
  if (nextSequence is! int || nextSequence < 0 || rawEvents is! Iterable) {
    throw const FormatException('Invalid assistant progress page');
  }
  final events = <AssistantProgressEvent>[];
  var previousSequence = -1;
  for (final raw in rawEvents) {
    final eventObject = asObjectMap(raw);
    final sequence = eventObject?['sequence'];
    if (eventObject == null || sequence is! int || sequence < 0) {
      throw const FormatException('Invalid assistant progress event');
    }
    if (sequence <= previousSequence) {
      throw const FormatException('Assistant progress sequence is not ordered');
    }
    previousSequence = sequence;
    final eventType = eventObject['eventType'];
    final runHandle = eventObject['runId'];
    final deltaText = eventObject['deltaText'];
    final replace = eventObject['replace'];
    final messageId = _optionalSafeIdentifier(eventObject['messageId']);
    final title = _optionalDisplayText(eventObject['title']);
    final summary = _optionalDisplayText(eventObject['summary']);
    final parsedRunHandle = _optionalSafeIdentifier(runHandle);
    final parsedDeltaText = _optionalStreamingText(deltaText);
    if (eventType is! String ||
        (runHandle != null && parsedRunHandle == null) ||
        (eventObject['messageId'] != null && messageId == null) ||
        (eventObject['title'] != null && title == null) ||
        (eventObject['summary'] != null && summary == null) ||
        (deltaText != null && parsedDeltaText == null) ||
        (replace != null && replace is! bool)) {
      throw const FormatException('Invalid assistant progress fields');
    }
    events.add(
      AssistantProgressEvent(
        sequence: sequence,
        type: _mapProgressEventType(eventType),
        runHandle: parsedRunHandle,
        messageId: messageId,
        title: title,
        summary: summary,
        deltaText: parsedDeltaText,
        replace: replace == true,
      ),
    );
  }
  if (events.isNotEmpty && nextSequence < events.last.sequence) {
    throw const FormatException('Assistant progress cursor regressed');
  }
  return AssistantProgressPage(
    conversationId: expectedConversationId,
    events: List<AssistantProgressEvent>.unmodifiable(events),
    nextSequence: nextSequence,
  );
}

AssistantProgressEventType _mapProgressEventType(String value) =>
    switch (value) {
      'draft_delta' => AssistantProgressEventType.draftDelta,
      'status' => AssistantProgressEventType.status,
      'output' => AssistantProgressEventType.output,
      _ => AssistantProgressEventType.unknown,
    };

String? _optionalSafeIdentifier(Object? value) {
  if (value == null) return null;
  final text = value is String ? value.trim() : null;
  return text != null && isSafeChatIdentifier(text) ? text : null;
}

bool _isProjectRunHandle(AssistantRunHandle handle) =>
    handle.isValid && isSafeAgentRunIdentifier(handle.value.trim());

String? _optionalDisplayText(Object? value) {
  if (value == null) return null;
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > 512) return null;
  return _containsUnsafeResponseContent(text) ? null : text;
}

String? _optionalStreamingText(Object? value) {
  if (value == null) return null;
  final text = value is String ? value : null;
  if (text == null || text.isEmpty) return null;
  return _containsUnsafeResponseContent(text.trim()) ? null : text;
}

bool _containsUnsafeResponseContent(String value) {
  return <RegExp>[
    RegExp(r'^file://', caseSensitive: false),
    RegExp(r'^[A-Za-z]:[\\/]'),
    RegExp(r'/(?:Users|home)/', caseSensitive: false),
    RegExp(r'https?://[^\s]*(?:signature|x-amz|token)=', caseSensitive: false),
    RegExp(r'(?:access|refresh)?token\s*=', caseSensitive: false),
    RegExp(r'(?:secret|apiKey|api_key)\s*=', caseSensitive: false),
  ].any((pattern) => pattern.hasMatch(value));
}

Stream<AssistantStreamEvent> _mapStream(
  Stream<ApiServerSentEvent<AgentRunStreamPayload>> source,
) async* {
  await for (final event in source) {
    final payload = event.data;
    if (payload == null) continue;
    switch (payload.kind) {
      case AgentRunStreamPayloadKind.event:
        final item = payload.item;
        if (item == null) continue;
        final data = item.data;
        yield AssistantStreamEvent(
          kind: AssistantStreamEventKind.update,
          type: _mapEventType(item.eventType),
          status: _mapStatus(item.status),
          sequence: item.sequence,
          createdAt: item.createdAt,
          deltaText: data?.deltaText,
          replace: data?.replace == true,
          invocationId: data?.invocationId,
          toolName: data?.toolName,
          toolState: data?.state,
          outcome: data?.outcome,
          outputFiles: data == null
              ? const <AssistantOutputFile>[]
              : data.outputFiles.map(_mapOutputFile).toList(growable: false),
        );
      case AgentRunStreamPayloadKind.gap:
        yield AssistantStreamEvent(
          kind: AssistantStreamEventKind.gap,
          resumeAfterSequence: payload.resumeAfterSequence,
          errorCode: payload.errorCode,
          retryable: payload.retryable,
        );
      case AgentRunStreamPayloadKind.capacityError:
        yield AssistantStreamEvent(
          kind: AssistantStreamEventKind.capacityUnavailable,
          errorCode: payload.errorCode,
          retryable: payload.retryable,
        );
    }
  }
}

AssistantStreamEventType _mapEventType(String value) => switch (value) {
  'draft_delta' => AssistantStreamEventType.draftDelta,
  'tool_invocation' => AssistantStreamEventType.toolInvocation,
  'status' => AssistantStreamEventType.status,
  'output' => AssistantStreamEventType.output,
  _ => AssistantStreamEventType.unknown,
};

AssistantOutputFile _mapOutputFile(AgentRunOutputFile file) =>
    AssistantOutputFile(
      resourceId: file.resourceId,
      fileName: file.fileName,
      mimeType: file.mimeType,
      sizeBytes: file.sizeBytes,
    );

AssistantRunSnapshot _mapSnapshot(AgentRunSnapshot run) {
  return AssistantRunSnapshot(
    handle: AssistantRunHandle(run.agentRunId),
    workspaceId: run.workspaceId,
    conversationId: run.threadId,
    correlationId: run.taskId,
    status: _mapStatus(run.status),
    output: run.result == null
        ? null
        : AssistantRunOutput(
            messageId: run.result!.assistantMessageId,
            text: run.result!.finalAnswer,
          ),
    failure: run.error == null
        ? null
        : AssistantRunFailure(
            code: run.error!.code,
            retryable: run.error!.retryable ?? false,
          ),
    toolTrace: run.toolTrace.map(_mapToolTrace).toList(growable: false),
    completionQuality: _mapCompletionQuality(run.completionMode),
    createdAt: run.createdAt,
    updatedAt: run.updatedAt,
  );
}

Future<AssistantRuntimeRead<AssistantRunSnapshot>> _mapApiRunResult(
  ApiResult<AgentRunSnapshot> result,
) async {
  final run = result.data;
  if (!result.ok || run == null) {
    return AssistantRuntimeRead<AssistantRunSnapshot>.failure(
      result.error?.code ?? 'ASSISTANT_RUN_READ_FAILED',
      outcomeUnknown:
          result.status == null ||
          result.status == 408 ||
          result.status == 429 ||
          result.status! >= 500 ||
          result.error?.category == AppFailureCategory.network,
    );
  }
  return AssistantRuntimeRead.success(_mapSnapshot(run));
}

AssistantToolTrace _mapToolTrace(AgentRunToolTrace trace) => AssistantToolTrace(
  invocationId: trace.invocationId,
  toolName: trace.toolName,
  state: trace.state,
  outcome: trace.outcome,
  createdAt: trace.createdAt,
  completedAt: trace.completedAt,
  outputFiles: trace.outputFiles.map(_mapOutputFile).toList(growable: false),
  inputSummary: trace.inputSummary,
);

void _noOpCancel() {}

AssistantRunStatus _mapStatus(String value) => switch (value) {
  'resolving' => AssistantRunStatus.resolving,
  'planning' => AssistantRunStatus.planning,
  'awaiting_confirmation' => AssistantRunStatus.waitingForInput,
  'queued' => AssistantRunStatus.queued,
  'running' => AssistantRunStatus.running,
  'aborting' => AssistantRunStatus.stopping,
  'succeeded' => AssistantRunStatus.succeeded,
  'failed' => AssistantRunStatus.failed,
  'timeout' => AssistantRunStatus.timedOut,
  'cancelled' => AssistantRunStatus.cancelled,
  'orphaned' => AssistantRunStatus.orphaned,
  _ => AssistantRunStatus.unknown,
};

AssistantCompletionQuality _mapCompletionQuality(String? value) =>
    switch (value) {
      'normal' => AssistantCompletionQuality.normal,
      'degraded' => AssistantCompletionQuality.degraded,
      'system_fallback' => AssistantCompletionQuality.fallback,
      'cancelled' => AssistantCompletionQuality.cancelled,
      _ => AssistantCompletionQuality.unknown,
    };
