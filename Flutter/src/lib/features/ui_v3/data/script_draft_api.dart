import 'package:huahuo_api/huahuo_api.dart';
import '../application/script_draft_controller.dart';
import '../domain/script_draft_models.dart';

final class ScriptDraftApi implements ScriptDraftGenerationPort {
  ScriptDraftApi(ApiClient apiClient)
    : this.withClients(
        chatClient: SharedChatFacadeClient(apiClient),
        agentRunClient: AgentRunClient(apiClient),
      );

  const ScriptDraftApi.withClients({
    required this._chatClient,
    required this._agentRunClient,
  });

  final SharedChatFacadeClient _chatClient;
  final AgentRunClient _agentRunClient;

  @override
  Future<String> createThread({required String idempotencyKey}) async {
    final result = await _chatClient.createThread<String>(
      request: const SharedChatThreadCreateRequest(scene: 'workspace_chat'),
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: _parseThreadId,
    );
    return _requireRemoteWriteData(result, 'SCRIPT_DRAFT_THREAD_CREATE_FAILED');
  }

  @override
  Future<String> submit({
    required String threadId,
    required ScriptDraftRequest request,
    required String idempotencyKey,
  }) async {
    final result = await _chatClient.sendTextMessage<String>(
      threadId: threadId,
      request: SharedChatTextMessageRequest(
        agentProfileId: ScriptDraftRequest.agentProfileId,
        modelProfileId: ScriptDraftRequest.modelProfileId,
        content: <SharedAgentInputContent>[
          SharedAgentTextContent(text: request.prompt),
        ],
      ),
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: _parseAgentRunId,
    );
    return _requireRemoteWriteData(
      result,
      'SCRIPT_DRAFT_MESSAGE_SUBMIT_FAILED',
    );
  }

  @override
  Future<Stream<ScriptDraftStreamSignal>> streamEvents({
    required String agentRunId,
    required int afterSequence,
  }) async {
    final result = await _agentRunClient.eventStream(
      agentRunId,
      lastEventId: '$afterSequence',
    );
    final source = _requireData(result, 'SCRIPT_DRAFT_STREAM_OPEN_FAILED');
    return _mapEventStream(source);
  }

  @override
  Future<ScriptDraftEventPage> readEvents({
    required String agentRunId,
    required int afterSequence,
  }) async {
    final result = await _agentRunClient.events(
      agentRunId,
      afterSequence: afterSequence,
    );
    final failure = result.error;
    if (!result.ok && failure?.code == 'RUNTIME_EVENT_GAP') {
      throw ScriptDraftTransportException(
        failure!.code,
        retryable: failure.isRetryable,
        resumeAfterSequence: _nonNegativeInt(
          failure.details['resumeAfterSequence'],
        ),
        oldestAvailableSequence: _nonNegativeInt(
          failure.details['oldestAvailableSequence'],
        ),
      );
    }
    final page = _requireData(result, 'SCRIPT_DRAFT_EVENTS_READ_FAILED');
    return ScriptDraftEventPage(
      items: page.items.map(_mapEvent),
      nextAfterSequence: page.nextAfterSequence,
      hasMore: page.hasMore,
      gap: page.gap,
      oldestAvailableSequence: page.oldestAvailableSequence,
    );
  }

  @override
  Future<ScriptDraftRunSnapshot> getRun({required String agentRunId}) async {
    final result = await _agentRunClient.get(agentRunId);
    final run = _requireData(result, 'SCRIPT_DRAFT_RUN_READ_FAILED');
    return ScriptDraftRunSnapshot(
      status: run.status,
      completionMode: run.completionMode,
      finalAnswer: run.result?.finalAnswer,
      errorCode: run.error?.code,
    );
  }

  @override
  Future<void> cancelRun({
    required String agentRunId,
    required String idempotencyKey,
  }) async {
    final result = await _agentRunClient.cancel(
      agentRunId,
      idempotencyKey: idempotencyKey,
    );
    _requireData(result, 'SCRIPT_DRAFT_RUN_CANCEL_FAILED');
  }
}

final class UnavailableScriptDraftGenerationPort
    implements ScriptDraftGenerationPort {
  const UnavailableScriptDraftGenerationPort();

  @override
  Future<String> createThread({required String idempotencyKey}) =>
      _scriptDraftUnavailable();

  @override
  Future<String> submit({
    required String threadId,
    required ScriptDraftRequest request,
    required String idempotencyKey,
  }) => _scriptDraftUnavailable();

  @override
  Future<Stream<ScriptDraftStreamSignal>> streamEvents({
    required String agentRunId,
    required int afterSequence,
  }) => _scriptDraftUnavailable();

  @override
  Future<ScriptDraftEventPage> readEvents({
    required String agentRunId,
    required int afterSequence,
  }) => _scriptDraftUnavailable();

  @override
  Future<ScriptDraftRunSnapshot> getRun({required String agentRunId}) =>
      _scriptDraftUnavailable();

  @override
  Future<void> cancelRun({
    required String agentRunId,
    required String idempotencyKey,
  }) => _scriptDraftUnavailable();
}

String? _parseThreadId(Object? value) {
  final root = ApiContractObject.fromValue(value);
  final rawThread = root.fields['thread'];
  final thread = rawThread == null
      ? root
      : ApiContractObject.fromValue(rawThread);
  return thread.optionalString('threadId') ?? thread.optionalString('id');
}

String? _parseAgentRunId(Object? value) {
  final root = ApiContractObject.fromValue(value);
  final direct = root.optionalString('agentRunId');
  if (direct != null) return direct;
  final rawRun = root.fields['agentRun'] ?? root.fields['run'];
  if (rawRun != null) {
    final run = ApiContractObject.fromValue(rawRun);
    final nested =
        run.optionalString('agentRunId') ??
        run.optionalString('runId') ??
        run.optionalString('id');
    if (nested != null) return nested;
  }
  final rawNextAction = root.fields['nextAction'];
  if (rawNextAction == null) return null;
  return ApiContractObject.fromValue(
    rawNextAction,
  ).optionalString('agentRunId');
}

Stream<ScriptDraftStreamSignal> _mapEventStream(
  Stream<ApiServerSentEvent<AgentRunStreamPayload>> source,
) async* {
  try {
    await for (final envelope in source) {
      final payload = envelope.data;
      if (payload == null) continue;
      switch (payload.kind) {
        case AgentRunStreamPayloadKind.event:
          final event = payload.item;
          if (event != null) {
            yield ScriptDraftStreamSignal.event(_mapEvent(event));
          }
        case AgentRunStreamPayloadKind.gap:
          yield ScriptDraftStreamSignal.gap(
            resumeAfterSequence: payload.resumeAfterSequence ?? 0,
          );
        case AgentRunStreamPayloadKind.capacityError:
          yield const ScriptDraftStreamSignal.capacityUnavailable();
      }
    }
  } on ScriptDraftTransportException {
    rethrow;
  } on FormatException {
    throw const ScriptDraftTransportException('SCRIPT_DRAFT_STREAM_INVALID');
  } catch (_) {
    throw const ScriptDraftTransportException(
      'SCRIPT_DRAFT_STREAM_FAILED',
      retryable: true,
    );
  }
}

ScriptDraftRemoteEvent _mapEvent(AgentRunEventItem event) {
  final data = event.data;
  return ScriptDraftRemoteEvent(
    sequence: event.sequence,
    status: data?.status ?? event.status,
    deltaText: data?.deltaText,
    replace: data?.replace == true,
  );
}

int? _nonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

T _requireData<T>(ApiResult<T> result, String fallbackCode) {
  final data = result.data;
  if (result.ok && data != null) return data;
  throw ScriptDraftTransportException(
    result.error?.code ?? fallbackCode,
    retryable: result.error?.isRetryable == true,
  );
}

T _requireRemoteWriteData<T>(ApiResult<T> result, String fallbackCode) {
  final data = result.data;
  if (result.ok && data != null) return data;
  final failure = result.error;
  final code = failure?.code ?? fallbackCode;
  final hasExplicitFailureEnvelope =
      !result.ok && !_remoteWriteOutcomeIsUnknown(result);
  throw ScriptDraftTransportException(
    code,
    retryable: failure?.isRetryable == true,
    writeOutcome: hasExplicitFailureEnvelope
        ? ScriptDraftWriteOutcome.knownRejected
        : ScriptDraftWriteOutcome.unknown,
  );
}

bool _remoteWriteOutcomeIsUnknown<T>(ApiResult<T> result) {
  final status = result.status;
  final failure = result.error;
  return status == null ||
      status == 408 ||
      status == 429 ||
      status >= 500 ||
      failure == null ||
      failure.category == AppFailureCategory.network ||
      failure.category == AppFailureCategory.compatibility ||
      failure.code == 'API_SERVER_UNAVAILABLE' ||
      failure.code == 'API_MALFORMED_ENVELOPE' ||
      failure.code == 'API_RESPONSE_INVALID';
}

Future<T> _scriptDraftUnavailable<T>() => Future<T>.error(
  const ScriptDraftTransportException('SCRIPT_DRAFT_BACKEND_UNAVAILABLE'),
);
