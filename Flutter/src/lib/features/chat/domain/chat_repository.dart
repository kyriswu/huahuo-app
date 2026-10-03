import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';
import 'chat_context.dart';
import 'chat_models.dart';

enum ChatSubmissionFailureDisposition { knownRejected, outcomeUnknown }

const chatTextFailureDispositionMetadataKey =
    'chatTextSubmissionFailureDisposition';

ChatSubmissionFailureDisposition chatTextSubmissionFailureDisposition(
  ApiResult<ChatTextMutation> result,
) {
  if (result.ok) return ChatSubmissionFailureDisposition.outcomeUnknown;
  final encoded = result.error?.metadata[chatTextFailureDispositionMetadataKey];
  if (encoded == ChatSubmissionFailureDisposition.knownRejected.name) {
    return ChatSubmissionFailureDisposition.knownRejected;
  }
  if (encoded == ChatSubmissionFailureDisposition.outcomeUnknown.name) {
    return ChatSubmissionFailureDisposition.outcomeUnknown;
  }
  return chatRemoteWriteOutcomeIsUnknown(result)
      ? ChatSubmissionFailureDisposition.outcomeUnknown
      : ChatSubmissionFailureDisposition.knownRejected;
}

ChatSubmissionFailureDisposition chatThreadCreationFailureDisposition(
  ApiResult<ChatThread> result,
) {
  if (result.ok || chatRemoteWriteOutcomeIsUnknown(result)) {
    return ChatSubmissionFailureDisposition.outcomeUnknown;
  }
  return ChatSubmissionFailureDisposition.knownRejected;
}

bool _isUnparseableSubmissionFailure(AppFailure? error) =>
    error?.code == 'API_MALFORMED_ENVELOPE' ||
    error?.code == 'API_RESPONSE_INVALID';

bool chatRemoteWriteOutcomeIsUnknown<T>(ApiResult<T> result) {
  final status = result.status;
  final error = result.error;
  return status == null ||
      status == 408 ||
      status == 429 ||
      status >= 500 ||
      error == null ||
      error.category == AppFailureCategory.network ||
      error.category == AppFailureCategory.compatibility ||
      error.code == 'API_SERVER_UNAVAILABLE' ||
      _isUnparseableSubmissionFailure(error);
}

abstract interface class ChatRepository {
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  });

  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  });

  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  });

  Future<ApiResult<ChatTextMutation>> sendTextMessage({
    required String threadId,
    required ChatScene scene,
    required String content,
    String? contentLineId,
    ChatContextEnvelope? context,
    String? agentProfileId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  });

  Future<ApiResult<ChatVoiceMutation>> sendVoiceMessage({
    required String threadId,
    required ChatScene scene,
    required String audioResourceId,
    required int durationSeconds,
    String? contentLineId,
    ChatContextEnvelope? context,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  });
}

/// Optional remote metadata capability. Existing limited Chat test adapters do
/// not need to implement title or runtime-summary transport.
abstract interface class ChatThreadMetadataPort {
  Future<ApiResult<ChatThread>> updateThreadTitle({
    required String threadId,
    required ChatThreadTitleMode titleMode,
    String? title,
    required int expectedTitleVersion,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  });

  Future<ApiConditionalResult<SharedThreadRuntimeInvocation>>
  latestThreadRuntimeInvocation({
    required String threadId,
    String? ifNoneMatch,
  });
}

/// Optional durable process-history capability. Keeping this separate from
/// title/latest metadata preserves compatibility with narrow feature adapters.
abstract interface class ChatThreadRuntimeHistoryPort {
  Future<ApiConditionalResult<SharedThreadRuntimeInvocationPage>>
  threadRuntimeInvocations({
    required String threadId,
    String? cursor,
    int limit = 20,
    String? ifNoneMatch,
  });
}

abstract interface class ChatAgentCatalogPort {
  Future<ApiResult<AgentProfileCatalog>> profiles();

  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  );
}

/// Used only while app bootstrap has not resolved a stable device identity.
/// It deliberately exposes a retryable failure instead of inventing Run data.
abstract interface class ChatAgentFeatureSelectionPort {
  Future<ApiResult<AgentFeatureAvailability>> resolveFeature(String featureId);
}
