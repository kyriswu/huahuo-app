import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/foundation.dart';

import '../domain/chat_repository.dart';
import '../domain/chat_models.dart';
import '../domain/chat_context.dart';

final class ChatImagePlayback {
  const ChatImagePlayback({
    required this.resourceId,
    required this.url,
    required this.mimeType,
    required this.displayName,
  });

  final String resourceId;
  final Uri url;
  final String mimeType;
  final String displayName;
}

final class ChatImageBytes {
  const ChatImageBytes({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

final class ChatImageDownloadException implements Exception {
  const ChatImageDownloadException(this.code, {this.isRetryable = false});

  final String code;
  final bool isRetryable;

  @override
  String toString() => code;
}

/// Resolves a server-owned chat image without retaining signed URLs in state.
final class ChatImagePlaybackClient {
  ChatImagePlaybackClient(
    this._apiClient, {
    this.downloadTimeout = const Duration(seconds: 30),
  }) {
    if (downloadTimeout <= Duration.zero) {
      throw ArgumentError.value(downloadTimeout, 'downloadTimeout');
    }
  }

  static const maxImageBytes = 50 * 1024 * 1024;

  final ApiClient _apiClient;
  final Duration downloadTimeout;
  HttpClient? _httpClient;
  bool _disposed = false;

  HttpClient get _client => _httpClient ??= (HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..maxConnectionsPerHost = 4);

  Future<ApiResult<ChatImagePlayback>> resolve(String resourceId) {
    _throwIfDisposed();
    if (!isSafeChatContextIdentifier(resourceId)) {
      return Future<ApiResult<ChatImagePlayback>>.value(
        _invalidResult<ChatImagePlayback>('CHAT_IMAGE_RESOURCE_ID_INVALID'),
      );
    }
    return _apiClient.request<ChatImagePlayback>(
      ApiRequestOptions<ChatImagePlayback>(
        endpointId: 'mediaResourcePlayback',
        pathParams: <String, Object>{'resourceId': resourceId},
        parseData: (value) => _parseChatImagePlayback(value, resourceId),
      ),
    );
  }

  Future<ChatImageBytes> download(ChatImagePlayback playback) async {
    _throwIfDisposed();
    HttpClientRequest? request;
    StreamIterator<List<int>>? chunks;
    var expired = false;
    var consumed = false;

    Future<ChatImageBytes> read() async {
      final activeRequest = await _client.getUrl(playback.url);
      request = activeRequest;
      _throwIfDisposed();
      if (expired) {
        throw const ChatImageDownloadException('CHAT_IMAGE_DOWNLOAD_TIMEOUT');
      }
      final response = await activeRequest.close();
      chunks = StreamIterator<List<int>>(response);
      _throwIfDisposed();
      if (expired) {
        throw const ChatImageDownloadException('CHAT_IMAGE_DOWNLOAD_TIMEOUT');
      }
      final status = response.statusCode;
      if (status < 200 || status >= 300) {
        throw ChatImageDownloadException(
          'CHAT_IMAGE_DOWNLOAD_HTTP_$status',
          isRetryable:
              status == 401 ||
              status == 403 ||
              status == 408 ||
              status == 429 ||
              status >= 500,
        );
      }
      if (response.contentLength > maxImageBytes) {
        throw const ChatImageDownloadException('CHAT_IMAGE_SIZE_INVALID');
      }
      final declaredMime = response.headers.contentType?.mimeType.toLowerCase();
      final mimeType = _isSupportedResourceImageMimeType(declaredMime)
          ? declaredMime!
          : playback.mimeType;
      if (!_isSupportedResourceImageMimeType(mimeType)) {
        throw const ChatImageDownloadException('CHAT_IMAGE_MIME_UNSUPPORTED');
      }
      final builder = BytesBuilder(copy: false);
      while (await chunks!.moveNext()) {
        builder.add(chunks!.current);
        if (builder.length > maxImageBytes) {
          throw const ChatImageDownloadException('CHAT_IMAGE_SIZE_INVALID');
        }
      }
      consumed = true;
      _throwIfDisposed();
      final bytes = builder.takeBytes();
      if (bytes.isEmpty || !_hasChatImageSignature(bytes, mimeType)) {
        throw const ChatImageDownloadException('CHAT_IMAGE_BYTES_INVALID');
      }
      return ChatImageBytes(bytes: bytes, mimeType: mimeType);
    }

    Future<ChatImageBytes> readAndRelease() async {
      try {
        return await read();
      } finally {
        if (!consumed) request?.abort();
        await chunks?.cancel();
      }
    }

    try {
      return await readAndRelease().timeout(
        downloadTimeout,
        onTimeout: () {
          expired = true;
          request?.abort();
          unawaited(chunks?.cancel());
          throw const ChatImageDownloadException(
            'CHAT_IMAGE_DOWNLOAD_TIMEOUT',
            isRetryable: true,
          );
        },
      );
    } on ChatImageDownloadException {
      rethrow;
    } on TimeoutException {
      throw const ChatImageDownloadException(
        'CHAT_IMAGE_DOWNLOAD_TIMEOUT',
        isRetryable: true,
      );
    } on SocketException {
      throw const ChatImageDownloadException(
        'CHAT_IMAGE_NETWORK_UNAVAILABLE',
        isRetryable: true,
      );
    } on HttpException {
      throw const ChatImageDownloadException(
        'CHAT_IMAGE_TRANSFER_INTERRUPTED',
        isRetryable: true,
      );
    } finally {
      if (!consumed) request?.abort();
    }
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw const ChatImageDownloadException('CHAT_IMAGE_CLIENT_DISPOSED');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _httpClient?.close(force: true);
  }
}

final class SharedChatAgentCatalog implements ChatAgentCatalogPort {
  const SharedChatAgentCatalog(this._client);

  final AgentCatalogClient _client;

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() => _client.profiles();

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) => _client.skills(agentProfileId);
}

final class RemoteProjectChatRepository
    implements
        ChatRepository,
        ChatThreadMetadataPort,
        ChatThreadRuntimeHistoryPort {
  RemoteProjectChatRepository({
    required ApiClient apiClient,
    ChatAgentCatalogPort? agentCatalog,
    ChatAgentFeatureSelectionPort? agentFeatures,
  }) : _apiClient = apiClient,
       _chatClient = SharedChatFacadeClient(apiClient),
       _metadataClient = ChatThreadMetadataClient(apiClient),
       _agentCatalog =
           agentCatalog ??
           SharedChatAgentCatalog(AgentCatalogClient(apiClient)),
       // ignore: prefer_initializing_formals
       _agentFeatures = agentFeatures;

  final ApiClient _apiClient;
  final SharedChatFacadeClient _chatClient;
  final ChatThreadMetadataClient _metadataClient;
  final ChatAgentCatalogPort _agentCatalog;
  final ChatAgentFeatureSelectionPort? _agentFeatures;

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) {
    if (cursor != null && !isSafeChatIdentifier(cursor)) {
      return Future<ApiResult<ChatThreadPage>>.value(
        _invalidResult<ChatThreadPage>('CHAT_CURSOR_INVALID'),
      );
    }
    if (limit != null && (limit < 1 || limit > 100)) {
      return Future<ApiResult<ChatThreadPage>>.value(
        _invalidResult<ChatThreadPage>('CHAT_LIST_LIMIT_INVALID'),
      );
    }
    return _apiClient.request<ChatThreadPage>(
      ApiRequestOptions<ChatThreadPage>(
        endpointId: 'chatThreads',
        query: <String, Object?>{
          'scene': purpose.historyScene,
          if (cursor != null) 'cursor': cursor,
          if (limit != null) 'limit': limit,
        },
        parseData: (value) {
          final page = parseChatThreadPage(value, scene: scene);
          if (page == null) return null;
          return ChatThreadPage(
            items: List<ChatThread>.unmodifiable(
              page.items.map((thread) => thread.copyWith(purpose: purpose)),
            ),
            nextCursor: page.nextCursor,
          );
        },
      ),
    );
  }

  @override
  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    if (contentLineId != null && !isSafeChatIdentifier(contentLineId)) {
      return Future<ApiResult<ChatThread>>.value(
        _invalidResult<ChatThread>('CHAT_CONTENT_LINE_ID_INVALID'),
      );
    }
    return _chatClient.createThread<ChatThread>(
      request: SharedChatThreadCreateRequest(
        scene: purpose == ChatConversationPurpose.general
            ? 'self_media_creation_standard'
            : null,
        creativePositioningId: contentLineId,
      ),
      idempotency: idempotency,
      idempotencyStore: idempotencyStore,
      parseData: (value) =>
          parseCreateChatThread(value, scene: scene, purpose: purpose),
    );
  }

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) {
    if (!isSafeChatIdentifier(threadId)) {
      return Future<ApiResult<ChatThreadDetail>>.value(
        _invalidResult<ChatThreadDetail>('CHAT_THREAD_ID_INVALID'),
      );
    }
    return _chatClient.getThreadDetail<ChatThreadDetail>(
      threadId: threadId,
      parseData: (value) {
        final detail = parseChatThreadDetail(value);
        _chatThreadDetailParseDebug(value, detail);
        return detail;
      },
    );
  }

  @override
  Future<ApiResult<ChatThread>> updateThreadTitle({
    required String threadId,
    required ChatThreadTitleMode titleMode,
    String? title,
    required int expectedTitleVersion,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    if (!isSafeChatIdentifier(threadId) || expectedTitleVersion < 1) {
      return _invalidResult<ChatThread>('CHAT_THREAD_TITLE_INVALID');
    }
    final normalized = title?.trim();
    if (titleMode == ChatThreadTitleMode.custom &&
        (normalized == null ||
            normalized.isEmpty ||
            normalized.runes.length > 60)) {
      return _invalidResult<ChatThread>('CHAT_THREAD_TITLE_INVALID');
    }
    final result = await _metadataClient.updateTitle(
      threadId: threadId,
      titleMode: titleMode == ChatThreadTitleMode.custom
          ? SharedChatThreadTitleMode.custom
          : SharedChatThreadTitleMode.auto,
      title: normalized,
      expectedTitleVersion: expectedTitleVersion,
      idempotency: idempotency,
      idempotencyStore: idempotencyStore,
    );
    final metadata = result.data;
    if (!result.ok || metadata == null) {
      return ApiResult<ChatThread>.failure(
        error: result.error!,
        status: result.status,
        traceId: result.traceId,
        authExpired: result.authExpired,
        retryAfterSeconds: result.retryAfterSeconds,
        idempotencyStore: result.idempotencyStore,
        responseHeaders: result.responseHeaders,
      );
    }
    return ApiResult<ChatThread>.success(
      data: ChatThread(
        threadId: metadata.threadId,
        scene: ChatScene.feedAi,
        title: metadata.title,
        titleMode: metadata.titleMode == SharedChatThreadTitleMode.custom
            ? ChatThreadTitleMode.custom
            : ChatThreadTitleMode.auto,
        titleVersion: metadata.titleVersion,
      ),
      status: result.status ?? 200,
      traceId: result.traceId,
      idempotencyStore: result.idempotencyStore,
      responseHeaders: result.responseHeaders,
    );
  }

  @override
  Future<ApiConditionalResult<SharedThreadRuntimeInvocation>>
  latestThreadRuntimeInvocation({
    required String threadId,
    String? ifNoneMatch,
  }) {
    if (!isSafeChatIdentifier(threadId)) {
      return Future<ApiConditionalResult<SharedThreadRuntimeInvocation>>.value(
        ApiConditionalResult<SharedThreadRuntimeInvocation>.fromApiResult(
          _invalidResult<SharedThreadRuntimeInvocation>(
            'CHAT_THREAD_ID_INVALID',
          ),
        ),
      );
    }
    return _metadataClient.latestInvocation(
      threadId: threadId,
      ifNoneMatch: ifNoneMatch,
    );
  }

  @override
  Future<ApiConditionalResult<SharedThreadRuntimeInvocationPage>>
  threadRuntimeInvocations({
    required String threadId,
    String? cursor,
    int limit = 20,
    String? ifNoneMatch,
  }) {
    if (!isSafeChatIdentifier(threadId) ||
        limit < 1 ||
        limit > 50 ||
        !_isSafeRuntimeInvocationCursor(cursor)) {
      return Future<
        ApiConditionalResult<SharedThreadRuntimeInvocationPage>
      >.value(
        ApiConditionalResult<SharedThreadRuntimeInvocationPage>.fromApiResult(
          _invalidResult<SharedThreadRuntimeInvocationPage>(
            'CHAT_RUNTIME_INVOCATION_HISTORY_INVALID',
          ),
        ),
      );
    }
    return _metadataClient.listInvocations(
      threadId: threadId,
      cursor: cursor,
      limit: limit,
      ifNoneMatch: ifNoneMatch,
    );
  }

  @override
  Future<ApiResult<ChatTextMutation>> sendTextMessage({
    required String threadId,
    required ChatScene scene,
    required String content,
    String? contentLineId,
    ChatContextEnvelope? context,
    String? agentProfileId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    final trimmed = content.trim();
    if (!isSafeChatIdentifier(threadId)) {
      return _withTextSubmissionFailureDisposition(
        _invalidResult<ChatTextMutation>('CHAT_THREAD_ID_INVALID'),
        ChatSubmissionFailureDisposition.knownRejected,
      );
    }
    final references = context?.references ?? const <ChatContextReference>[];
    if ((trimmed.isEmpty && !references.any(_isCanonicalChatInputReference)) ||
        trimmed.length > _maxOutgoingMessageLength) {
      return _withTextSubmissionFailureDisposition(
        _invalidResult<ChatTextMutation>('CHAT_TEXT_INVALID'),
        ChatSubmissionFailureDisposition.knownRejected,
      );
    }
    if (contentLineId != null && !isSafeChatIdentifier(contentLineId)) {
      return _withTextSubmissionFailureDisposition(
        _invalidResult<ChatTextMutation>('CHAT_CONTENT_LINE_ID_INVALID'),
        ChatSubmissionFailureDisposition.knownRejected,
      );
    }
    final lockedProfile = _safeAgentProfileId(agentProfileId);
    final selection = lockedProfile == null
        ? await _resolveAgentSelection(
            context?.purpose,
            idempotencyStore: idempotencyStore,
          )
        : ApiResult<_ChatAgentSelection>.success(
            data: _ChatAgentSelection(agentProfileId: lockedProfile),
            status: 200,
            idempotencyStore: idempotencyStore,
          );
    if (!selection.ok || selection.data == null) {
      return _withTextSubmissionFailureDisposition(
        ApiResult<ChatTextMutation>.failure(
          error:
              selection.error ??
              chatApiFailure('CHAT_AGENT_CATALOG_UNAVAILABLE', retryable: true),
          status: selection.status,
          traceId: selection.traceId,
          authExpired: selection.authExpired,
          retryAfterSeconds: selection.retryAfterSeconds,
          idempotencyStore: idempotencyStore,
        ),
        ChatSubmissionFailureDisposition.knownRejected,
      );
    }
    final selected = selection.data!;
    final result = await _chatClient.sendTextMessage<ChatTextMutation>(
      threadId: threadId,
      request: SharedChatTextMessageRequest(
        agentProfileId: selected.agentProfileId,
        content: _canonicalTextInputContent(
          trimmed,
          references,
          localDraftSnapshot: context?.localDraftSnapshot,
        ),
      ),
      idempotency: idempotency,
      idempotencyStore: idempotencyStore,
      parseData: (value) {
        final mutation = parseChatTextMutation(
          value,
          fallbackThreadId: threadId,
          fallbackScene: scene,
          requestedContext: null,
        );
        _chatTextResponseDebug(value, mutation);
        return mutation;
      },
    );
    if (!result.ok) {
      return _withTextSubmissionFailureDisposition(
        result,
        chatRemoteWriteOutcomeIsUnknown(result)
            ? ChatSubmissionFailureDisposition.outcomeUnknown
            : ChatSubmissionFailureDisposition.knownRejected,
      );
    }
    if (!_requiresCanonicalRunReceipt(context?.purpose) ||
        result.data?.nextAction.type == ChatNextActionType.pollAgentRun) {
      return result;
    }
    return _withTextSubmissionFailureDisposition(
      ApiResult<ChatTextMutation>.failure(
        error: chatApiFailure(
          'CHAT_AGENT_RUN_RECEIPT_REQUIRED',
          retryable: true,
        ),
        status: result.status,
        traceId: result.traceId,
        authExpired: result.authExpired,
        retryAfterSeconds: result.retryAfterSeconds,
        idempotencyStore: result.idempotencyStore,
      ),
      ChatSubmissionFailureDisposition.outcomeUnknown,
    );
  }

  Future<ApiResult<_ChatAgentSelection>> _resolveAgentSelection(
    ChatContextPurpose? purpose, {
    required SubmissionKeyStore idempotencyStore,
  }) async {
    final featureId = _chatFeatureId(purpose);
    final route = featureId == null
        ? null
        : AgentFeatureRoutes.forFeature(featureId);
    if (route == null) {
      return ApiResult<_ChatAgentSelection>.failure(
        error: chatApiFailure('CHAT_AGENT_ROUTE_UNAVAILABLE'),
        idempotencyStore: idempotencyStore,
      );
    }
    if (purpose == null || purpose == ChatContextPurpose.general) {
      // The ordinary Chat facade must follow the direct, verified message flow.
      return ApiResult<_ChatAgentSelection>.success(
        data: _ChatAgentSelection(agentProfileId: route.agentProfileId),
        status: 200,
        idempotencyStore: idempotencyStore,
      );
    }
    final featurePort = _agentFeatures;
    if (featurePort != null) {
      final resolved = await featurePort.resolveFeature(featureId!);
      if (!resolved.ok || resolved.data == null) {
        return _catalogFailure<_ChatAgentSelection>(
          resolved,
          idempotencyStore: idempotencyStore,
        );
      }
      final availability = resolved.data!;
      if (!availability.isAvailable || availability.route == null) {
        return ApiResult<_ChatAgentSelection>.failure(
          error: chatApiFailure(
            availability.reasonCode ?? 'CHAT_AGENT_ROUTE_UNAVAILABLE',
          ),
          idempotencyStore: idempotencyStore,
        );
      }
      return ApiResult<_ChatAgentSelection>.success(
        data: _ChatAgentSelection(
          agentProfileId: availability.route!.agentProfileId,
        ),
        status: 200,
        idempotencyStore: idempotencyStore,
      );
    }
    final profiles = await _agentCatalog.profiles();
    if (!profiles.ok || profiles.data == null) {
      return _catalogFailure<_ChatAgentSelection>(
        profiles,
        idempotencyStore: idempotencyStore,
      );
    }
    if (!profiles.data!.items.any(
      (item) => item.agentProfileId == route.agentProfileId,
    )) {
      return ApiResult<_ChatAgentSelection>.failure(
        error: chatApiFailure('AGENT_PROFILE_NOT_SELECTABLE'),
        idempotencyStore: idempotencyStore,
      );
    }
    return ApiResult<_ChatAgentSelection>.success(
      data: _ChatAgentSelection(agentProfileId: route.agentProfileId),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }

  @override
  Future<ApiResult<ChatVoiceMutation>> sendVoiceMessage({
    required String threadId,
    required ChatScene scene,
    required String audioResourceId,
    required int durationSeconds,
    String? contentLineId,
    ChatContextEnvelope? context,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    if (!isSafeChatIdentifier(threadId)) {
      return Future<ApiResult<ChatVoiceMutation>>.value(
        _invalidResult<ChatVoiceMutation>('CHAT_THREAD_ID_INVALID'),
      );
    }
    if (!isSafeChatIdentifier(audioResourceId)) {
      return Future<ApiResult<ChatVoiceMutation>>.value(
        _invalidResult<ChatVoiceMutation>('CHAT_VOICE_RESOURCE_ID_INVALID'),
      );
    }
    if (durationSeconds < 1 || durationSeconds > _maxVoiceDurationSeconds) {
      return Future<ApiResult<ChatVoiceMutation>>.value(
        _invalidResult<ChatVoiceMutation>('CHAT_VOICE_DURATION_INVALID'),
      );
    }
    if (contentLineId != null && !isSafeChatIdentifier(contentLineId)) {
      return Future<ApiResult<ChatVoiceMutation>>.value(
        _invalidResult<ChatVoiceMutation>('CHAT_CONTENT_LINE_ID_INVALID'),
      );
    }
    return _apiClient.request<ChatVoiceMutation>(
      ApiRequestOptions<ChatVoiceMutation>(
        endpointId: 'sendVoiceMessage',
        pathParams: <String, Object>{'threadId': threadId},
        body: <String, Object?>{
          'audioResourceId': audioResourceId,
          'durationSeconds': durationSeconds,
          if (contentLineId != null) 'creativePositioningId': contentLineId,
        },
        idempotency: idempotency,
        idempotencyStore: idempotencyStore,
        parseData: (value) => parseChatVoiceMutation(
          value,
          fallbackThreadId: threadId,
          fallbackScene: scene,
          requestedContext: null,
        ),
      ),
    );
  }
}

/// Compatibility alias while consumers migrate from the old generic name.

final class _ChatAgentSelection {
  const _ChatAgentSelection({required this.agentProfileId});

  final String agentProfileId;
}

String? _chatFeatureId(ChatContextPurpose? purpose) => switch (purpose) {
  null || ChatContextPurpose.general => 'chat.general',
  ChatContextPurpose.persona => 'workbench.persona',
  ChatContextPurpose.lead => 'workbench.lead_content',
  ChatContextPurpose.visualDesign => 'visual.chat',
  ChatContextPurpose.masterpiece => 'book.writing',
  ChatContextPurpose.deepPositioning => 'positioning.initial',
  ChatContextPurpose.socialPositioning => 'deep_positioning',
  ChatContextPurpose.videoAnalysis => 'video_analysis',
};

ApiResult<T> _catalogFailure<T>(
  ApiResult<dynamic> result, {
  required SubmissionKeyStore idempotencyStore,
}) {
  return ApiResult<T>.failure(
    error:
        result.error ??
        chatApiFailure('CHAT_AGENT_CATALOG_UNAVAILABLE', retryable: true),
    status: result.status,
    traceId: result.traceId,
    authExpired: result.authExpired,
    retryAfterSeconds: result.retryAfterSeconds,
    idempotencyStore: idempotencyStore,
  );
}

ChatThreadPage? parseChatThreadPage(Object? value, {ChatScene? scene}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final rawItems = _firstList(object, const <String>[
    'items',
    'threads',
    'list',
    'records',
  ]);
  if (rawItems == null) return null;
  final items = <ChatThread>[];
  for (final rawItem in rawItems) {
    final item = parseChatThread(rawItem, fallbackScene: scene);
    if (item == null) return null;
    items.add(scene == null ? item : item.copyWith(scene: scene));
  }
  final nextCursor = _safeOptionalIdentifier(
    object['nextCursor'] ?? object['cursor'] ?? object['next'],
  );
  return ChatThreadPage(
    items: List<ChatThread>.unmodifiable(items),
    nextCursor: nextCursor,
  );
}

ChatThread? parseCreateChatThread(
  Object? value, {
  required ChatScene scene,
  ChatConversationPurpose purpose = ChatConversationPurpose.general,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final thread = parseChatThread(
    object['thread'] ?? object,
    fallbackScene: scene,
  );
  return thread?.copyWith(scene: scene, purpose: purpose);
}

ChatThreadDetail? parseChatThreadDetail(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final parsedThread = parseChatThread(
    object['thread'] ?? object,
    fallbackScene: ChatScene.feedAi,
  );
  if (parsedThread == null) return null;
  final rawLastRequestProfile = object['lastRequestProfile'];
  final lastRequestProfile = rawLastRequestProfile == null
      ? null
      : asObjectMap(rawLastRequestProfile);
  if (rawLastRequestProfile != null && lastRequestProfile == null) return null;
  final rawHistoricalAgentProfileId = lastRequestProfile?['agentProfileId'];
  final historicalAgentProfileId = _safeAgentProfileId(
    rawHistoricalAgentProfileId,
  );
  if (rawHistoricalAgentProfileId != null && historicalAgentProfileId == null) {
    return null;
  }
  final directAgentProfileId = parsedThread.agentProfileId;
  if (directAgentProfileId != null &&
      historicalAgentProfileId != null &&
      directAgentProfileId != historicalAgentProfileId) {
    return null;
  }
  final taskActiveRuns = _parseThreadDetailTaskActiveRuns(
    object['tasks'],
    threadId: parsedThread.threadId,
  );
  if (taskActiveRuns == null) return null;
  final thread = parsedThread.copyWith(
    agentProfileId: directAgentProfileId ?? historicalAgentProfileId,
    activeRuns: _mergeThreadActiveRuns(parsedThread.activeRuns, taskActiveRuns),
  );
  final rawMessages = object['messages'];
  if (rawMessages != null && rawMessages is! Iterable) return null;
  final messages = <ChatMessage>[];
  for (final rawMessage in rawMessages as Iterable? ?? const <Object?>[]) {
    if (_isStructuredChatEvent(rawMessage) || _isSystemChatEvent(rawMessage)) {
      continue;
    }
    final message = parseChatMessage(
      rawMessage,
      fallbackThreadId: thread.threadId,
      fallbackScene: thread.scene,
    );
    if (message == null) {
      if (_isUnrenderableChatProjection(rawMessage)) continue;
      return null;
    }
    if (message.threadId == thread.threadId && message.scene == thread.scene) {
      messages.add(message);
    }
  }
  return ChatThreadDetail(
    thread: thread.copyWith(
      firstUserMessageText: _firstUserMessageText(messages),
    ),
    messages: List<ChatMessage>.unmodifiable(messages),
  );
}

void _chatThreadDetailParseDebug(Object? value, ChatThreadDetail? detail) {
  if (!kDebugMode || detail != null) return;
  debugPrint(
    '[ChatTransport] operation=thread-detail-parse '
    'reason=${_chatThreadDetailParseReason(value)}',
  );
}

String _chatThreadDetailParseReason(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return 'not_object';
  final thread = parseChatThread(
    object['thread'] ?? object,
    fallbackScene: ChatScene.feedAi,
  );
  if (thread == null) return 'thread';
  if (_parseThreadDetailTaskActiveRuns(
        object['tasks'],
        threadId: thread.threadId,
      ) ==
      null) {
    return 'tasks';
  }
  final rawMessages = object['messages'];
  if (rawMessages != null && rawMessages is! Iterable) return 'messages';
  for (final rawMessage in rawMessages as Iterable? ?? const <Object?>[]) {
    if (_isStructuredChatEvent(rawMessage)) continue;
    if (parseChatMessage(
          rawMessage,
          fallbackThreadId: thread.threadId,
          fallbackScene: thread.scene,
        ) ==
        null) {
      return _chatMessageParseReason(rawMessage);
    }
  }
  return 'unknown';
}

String _chatMessageParseReason(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return 'message_object';
  if (_safeOptionalIdentifier(object['messageId'] ?? object['id']) == null) {
    return 'message_id';
  }
  if (ChatMessageRole.tryParse(object['role']) == null) {
    return 'message_role';
  }
  final rawContentType = object['contentType'] ?? object['messageType'];
  if (ChatMessageContentType.tryParse(rawContentType) == null) {
    return 'message_content_type';
  }
  if (_safeDisplayText(object['status']) == null) return 'message_status';
  return 'message_unknown';
}

ChatTextMutation? parseChatTextMutation(
  Object? value, {
  required String fallbackThreadId,
  required ChatScene fallbackScene,
  ChatContextEnvelope? requestedContext,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final rawMessage = object['message'] ?? object['userMessage'];
  final message = rawMessage == null
      ? null
      : parseChatMessage(
          rawMessage,
          fallbackThreadId: fallbackThreadId,
          fallbackScene: fallbackScene,
          fallbackRole: ChatMessageRole.user,
          fallbackContentType: ChatMessageContentType.text,
          fallbackStatus: 'sent',
        );
  if (rawMessage != null &&
      (message == null || message.threadId != fallbackThreadId)) {
    return null;
  }
  final rawAssistant = object['assistantMessage'];
  final assistant = rawAssistant == null
      ? null
      : parseChatMessage(
          rawAssistant,
          fallbackThreadId: fallbackThreadId,
          fallbackScene: fallbackScene,
          fallbackRole: ChatMessageRole.assistant,
          fallbackContentType: ChatMessageContentType.text,
          fallbackStatus: 'sent',
        );
  if (rawAssistant != null &&
      (assistant == null ||
          assistant.threadId != fallbackThreadId ||
          assistant.scene != fallbackScene ||
          assistant.role != ChatMessageRole.assistant)) {
    return null;
  }
  final acceptedContext = object['acceptedContext'] == null
      ? null
      : ChatAcceptedContext.tryParse(object['acceptedContext']);
  if (requestedContext != null &&
      (acceptedContext == null || !acceptedContext.accepts(requestedContext))) {
    return null;
  }
  final nextAction = _chatReplyNextAction(object, assistant: assistant);
  if (message == null && nextAction.type != ChatNextActionType.pollAgentRun) {
    return null;
  }
  return ChatTextMutation(
    message: message,
    assistantMessage: assistant,
    nextAction: nextAction,
    acceptedContext: acceptedContext,
    receiptThreadId: _safeOptionalIdentifier(object['threadId']),
    receiptMessageId:
        _safeOptionalIdentifier(object['messageId']) ?? message?.messageId,
    receiptStatus: _safeDisplayText(object['status']),
  );
}

void _chatTextResponseDebug(Object? value, ChatTextMutation? mutation) {
  if (!kDebugMode) return;
  final object = asObjectMap(value);
  if (object == null) {
    debugPrint('[ChatTransport] operation=text-response shape=invalid');
    return;
  }
  const receiptFields = <String>[
    'message',
    'userMessage',
    'assistantMessage',
    'agentRunId',
    'agentRun',
    'run',
    'task',
    'taskId',
    'nextAction',
  ];
  final present = <String>[
    for (final field in receiptFields)
      if (object[field] != null) field,
  ];
  debugPrint(
    '[ChatTransport] operation=text-response '
    'parsed=${mutation != null} '
    'next=${mutation?.nextAction.type.name ?? '-'} '
    'hasRun=${mutation?.nextAction.agentRunId != null} '
    'fields=${present.join(',')}',
  );
}

ChatVoiceMutation? parseChatVoiceMutation(
  Object? value, {
  required String fallbackThreadId,
  required ChatScene fallbackScene,
  ChatContextEnvelope? requestedContext,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final rawMessage =
      object['voiceMessage'] ??
      object['message'] ??
      object['userMessage'] ??
      object;
  if (_hasMalformedChatMessageFields(rawMessage) ||
      _hasUnexpectedContentType(rawMessage, ChatMessageContentType.voice)) {
    return null;
  }
  final message = parseChatMessage(
    rawMessage,
    fallbackThreadId: fallbackThreadId,
    fallbackScene: fallbackScene,
    fallbackRole: ChatMessageRole.user,
    fallbackContentType: ChatMessageContentType.voice,
    fallbackStatus: 'sent',
  );
  if (message == null ||
      message.threadId != fallbackThreadId ||
      message.scene != fallbackScene ||
      message.role != ChatMessageRole.user ||
      message.contentType != ChatMessageContentType.voice) {
    return null;
  }
  final rawAssistant = object['assistantMessage'];
  if (rawAssistant != null &&
      (_hasMalformedChatMessageFields(rawAssistant) ||
          _hasUnsupportedContentType(rawAssistant))) {
    return null;
  }
  final assistant = rawAssistant == null
      ? null
      : parseChatMessage(
          rawAssistant,
          fallbackThreadId: fallbackThreadId,
          fallbackScene: fallbackScene,
          fallbackRole: ChatMessageRole.assistant,
          fallbackStatus: 'sent',
        );
  if (rawAssistant != null &&
      (assistant == null ||
          assistant.threadId != fallbackThreadId ||
          assistant.scene != fallbackScene ||
          assistant.role != ChatMessageRole.assistant)) {
    return null;
  }
  final acceptedContext = object['acceptedContext'] == null
      ? null
      : ChatAcceptedContext.tryParse(object['acceptedContext']);
  if (requestedContext != null &&
      (acceptedContext == null || !acceptedContext.accepts(requestedContext))) {
    return null;
  }
  return ChatVoiceMutation(
    message: message,
    assistantMessage: assistant,
    nextAction: _chatReplyNextAction(object, assistant: assistant),
    acceptedContext: acceptedContext,
  );
}

ChatThread? parseChatThread(
  Object? value, {
  required ChatScene? fallbackScene,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final threadId = _safeOptionalIdentifier(object['threadId'] ?? object['id']);
  final rawScene = object['scene'];
  final scene = rawScene == null
      ? fallbackScene
      : ChatScene.tryParse(rawScene) ?? fallbackScene;
  final purpose = object['purpose'] == null
      ? ChatConversationPurpose.general
      : ChatConversationPurpose.tryParseApi(object['purpose']) ??
            ChatConversationPurpose.general;
  if (threadId == null || scene == null) return null;
  final rawWorkspaceId = object['workspaceId'];
  final workspaceId = _safeOptionalIdentifier(rawWorkspaceId);
  if (rawWorkspaceId != null && workspaceId == null) return null;
  final rawAgentProfileId = object['agentProfileId'];
  final agentProfileId = _safeAgentProfileId(rawAgentProfileId);
  if (rawAgentProfileId != null && agentProfileId == null) return null;
  final titleVersion = object['titleVersion'];
  final activeRuns = _parseActiveChatRuns(
    object['activeRuns'] ?? object['pendingRuns'],
  );
  if ((object['activeRuns'] ?? object['pendingRuns']) != null &&
      activeRuns == null) {
    return null;
  }
  return ChatThread(
    threadId: threadId,
    scene: scene,
    workspaceId: workspaceId,
    title: _safeDisplayText(object['title']),
    titleMode: switch (object['titleMode']) {
      'custom' => ChatThreadTitleMode.custom,
      _ => ChatThreadTitleMode.auto,
    },
    titleVersion: titleVersion is int && titleVersion > 0 ? titleVersion : 1,
    updatedAt: _safeDate(object['updatedAt'] ?? object['updated_at']),
    firstUserMessageText: _threadFirstMessagePreview(object),
    purpose: purpose,
    agentProfileId: agentProfileId,
    activeRuns: activeRuns ?? const <ChatActiveRun>[],
  );
}

List<ChatActiveRun>? _parseActiveChatRuns(Object? value) {
  if (value == null) return const <ChatActiveRun>[];
  if (value is! Iterable) return null;
  final parsed = <ChatActiveRun>[];
  for (final raw in value) {
    final object = asObjectMap(raw);
    final runId = _safeAgentRunIdentifier(
      object?['agentRunId'] ?? object?['runId'],
    );
    final status = object?['status'];
    if (runId == null ||
        status is! String ||
        !_publicAgentRunStatuses.contains(status.trim())) {
      return null;
    }
    parsed.add(ChatActiveRun(agentRunId: runId, status: status.trim()));
  }
  return List<ChatActiveRun>.unmodifiable(parsed);
}

List<ChatActiveRun>? _parseThreadDetailTaskActiveRuns(
  Object? value, {
  required String threadId,
}) {
  if (value == null) return const <ChatActiveRun>[];
  if (value is! Iterable) return null;
  final newestFirst = <ChatActiveRun>[];
  final seenRunIds = <String>{};
  for (final raw in value) {
    final task = asObjectMap(raw);
    final rawStatus = task?['status'];
    final status = rawStatus is String ? rawStatus.trim() : null;
    if (status != 'queued' && status != 'running') continue;
    final rawAgentRunId = task?['agentRunId'];
    if (rawAgentRunId == null) continue;
    final agentRunId = _safeAgentRunIdentifier(rawAgentRunId);
    if (agentRunId == null) return null;
    final rawTaskThreadId = task?['threadId'];
    if (rawTaskThreadId != null) {
      final taskThreadId = _safeOptionalIdentifier(rawTaskThreadId);
      if (taskThreadId == null || taskThreadId != threadId) return null;
    }
    if (seenRunIds.add(agentRunId)) {
      newestFirst.add(ChatActiveRun(agentRunId: agentRunId, status: status!));
    }
  }
  return List<ChatActiveRun>.unmodifiable(newestFirst.reversed);
}

List<ChatActiveRun> _mergeThreadActiveRuns(
  List<ChatActiveRun> projectedRuns,
  List<ChatActiveRun> taskRuns,
) {
  final merged = <ChatActiveRun>[...projectedRuns];
  final projectedRunIds = <String>{
    for (final run in projectedRuns) run.agentRunId,
  };
  for (final run in taskRuns) {
    if (projectedRunIds.add(run.agentRunId)) merged.add(run);
  }
  return List<ChatActiveRun>.unmodifiable(merged);
}

String? _safeAgentProfileId(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null &&
          RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(text)
      ? text
      : null;
}

const _publicAgentRunStatuses = <String>{
  'resolving',
  'planning',
  'awaiting_confirmation',
  'queued',
  'running',
  'aborting',
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'orphaned',
};

ChatMessage? parseChatMessage(
  Object? value, {
  String? fallbackThreadId,
  ChatScene? fallbackScene,
  ChatMessageRole? fallbackRole,
  ChatMessageContentType? fallbackContentType,
  String? fallbackStatus,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final payload = asObjectMap(object['payload']);
  final messageId = _safeOptionalIdentifier(
    object['messageId'] ?? object['id'],
  );
  final threadId =
      _safeOptionalIdentifier(object['threadId']) ?? fallbackThreadId;
  final scene = fallbackScene ?? ChatScene.tryParse(object['scene']);
  final role = ChatMessageRole.tryParse(object['role']) ?? fallbackRole;
  final rawContentType = object['contentType'] ?? object['messageType'];
  final taskId = _safeOptionalIdentifier(
    object['taskId'] ?? payload?['taskId'],
  );
  final agentRunIdentity = _consistentAgentRunIdentifier(<Object?>[
    object['agentRunId'],
    payload?['agentRunId'],
    payload?['runId'],
  ]);
  if (!agentRunIdentity.isValid) return null;
  final agentRunId = agentRunIdentity.value;
  final textPreview = _chatMessageText(object, payload);
  final imageAttachments = _chatMessageImageAttachments(object, payload);
  final resourceAttachments = _chatMessageResourceAttachments(
    object,
    payload,
    imageResourceIds: imageAttachments
        .map((attachment) => attachment.resourceId)
        .toSet(),
  );
  final contentType =
      ChatMessageContentType.tryParse(rawContentType) ??
      _contentTypeForCompatibility(
        role: role,
        textPreview: textPreview,
        imageAttachments: imageAttachments,
        resourceAttachments: resourceAttachments,
      ) ??
      fallbackContentType;
  final status = _safeDisplayText(object['status']) ?? fallbackStatus;
  if (messageId == null ||
      threadId == null ||
      scene == null ||
      role == null ||
      contentType == null ||
      status == null) {
    return null;
  }
  return ChatMessage(
    messageId: messageId,
    threadId: threadId,
    scene: scene,
    role: role,
    contentType: contentType,
    status: status,
    taskId: taskId,
    agentRunId: agentRunId,
    textPreview: textPreview,
    transcriptText: _safeMessageText(
      object['transcriptText'] ??
          payload?['transcriptText'] ??
          payload?['transcript'],
    ),
    imageAttachments: imageAttachments,
    resourceAttachments: resourceAttachments,
    createdAt: _safeDate(
      object['createdAt'] ??
          object['created_at'] ??
          object['sentAt'] ??
          object['sent_at'] ??
          object['timestamp'],
    ),
  );
}

ChatMessageContentType? _contentTypeForCompatibility({
  required ChatMessageRole? role,
  required String? textPreview,
  required List<ChatImageAttachment> imageAttachments,
  required List<ChatResourceAttachment> resourceAttachments,
}) {
  if (role != ChatMessageRole.user && role != ChatMessageRole.assistant) {
    return null;
  }
  if (textPreview != null) return ChatMessageContentType.text;
  if (imageAttachments.isNotEmpty) return ChatMessageContentType.image;
  if (resourceAttachments.isEmpty) return null;
  return switch (resourceAttachments.first.kind) {
    ChatResourceAttachmentKind.image => ChatMessageContentType.image,
    ChatResourceAttachmentKind.video => ChatMessageContentType.video,
    ChatResourceAttachmentKind.audio => ChatMessageContentType.audio,
    ChatResourceAttachmentKind.file => ChatMessageContentType.file,
  };
}

String? _chatMessageText(
  Map<String, Object?> object,
  Map<String, Object?>? payload,
) {
  final directContent =
      _safeMessageText(object['content']) ??
      _safeContentPartText(object['content']);
  if (directContent != null) return directContent;
  for (final value in <Object?>[
    payload?['reply'],
    payload?['content'],
    payload?['text'],
    object['text'],
    object['textPreview'],
    object['contentMarkdown'],
    object['markdown'],
    payload?['summary'],
    payload?['contentMarkdown'],
    payload?['markdown'],
  ]) {
    final text = _safeMessageText(value);
    if (text != null) return text;
  }
  return _safeContentPartText(object['content']) ??
      _safeContentPartText(payload?['content']);
}

String? _safeContentPartText(Object? value) {
  if (value is! Iterable) return null;
  final parts = <String>[];
  for (final part in value) {
    final object = asObjectMap(part);
    if (object == null || object['type'] != 'text') continue;
    final text = _safeMessageText(
      object['text'] ?? object['content'] ?? object['markdown'],
    );
    if (text != null) parts.add(text);
  }
  return parts.isEmpty ? null : parts.join('\n\n');
}

List<ChatImageAttachment> _chatMessageImageAttachments(
  Map<String, Object?> object,
  Map<String, Object?>? payload,
) {
  final found = <String, ChatImageAttachment>{};

  void add({
    required Object? resourceId,
    Object? displayName,
    Object? mimeType,
    bool requireSupportedMimeType = false,
  }) {
    final safeResourceId = _safeOptionalIdentifier(resourceId);
    if (safeResourceId == null || found.containsKey(safeResourceId)) return;
    final safeMimeType = _safeChatImageMimeType(mimeType);
    if (requireSupportedMimeType && safeMimeType == null) return;
    found[safeResourceId] = ChatImageAttachment(
      resourceId: safeResourceId,
      displayName: _safeChatImageDisplayName(displayName),
      mimeType: safeMimeType,
    );
  }

  void fromPartList(Object? value) {
    if (value is! Iterable) return;
    for (final candidate in value) {
      final part = asObjectMap(candidate);
      if (part == null || part['type'] != 'image') continue;
      final source = asObjectMap(part['source']);
      if (source != null && source['kind'] != 'resource') continue;
      final resource = asObjectMap(part['resource']);
      add(
        resourceId:
            part['resourceId'] ??
            source?['resourceId'] ??
            resource?['resourceId'],
        displayName:
            part['displayName'] ??
            part['fileName'] ??
            resource?['displayName'] ??
            resource?['fileName'],
        mimeType: part['mimeType'] ?? resource?['mimeType'],
      );
    }
  }

  void fromAttachmentList(Object? value) {
    if (value is! Iterable) return;
    for (final candidate in value) {
      final attachment = asObjectMap(candidate);
      if (attachment == null) continue;
      final type = attachment['kind'] ?? attachment['type'];
      if (type != 'image') continue;
      if (attachment['availability'] != 'available') continue;
      final source = asObjectMap(attachment['source']);
      if (source != null && source['kind'] != 'resource') continue;
      final resource = asObjectMap(attachment['resource']);
      add(
        resourceId:
            attachment['resourceId'] ??
            source?['resourceId'] ??
            resource?['resourceId'],
        displayName:
            attachment['displayName'] ??
            attachment['fileName'] ??
            attachment['name'] ??
            resource?['displayName'] ??
            resource?['fileName'],
        mimeType: attachment['mimeType'] ?? resource?['mimeType'],
        requireSupportedMimeType: true,
      );
    }
  }

  fromPartList(object['content']);
  fromPartList(payload?['content']);
  for (final value in <Object?>[
    object['attachments'],
    object['outputAttachments'],
    payload?['attachments'],
    payload?['outputAttachments'],
    asObjectMap(object['result'])?['attachments'],
    asObjectMap(payload?['result'])?['attachments'],
  ]) {
    fromAttachmentList(value);
  }
  return List<ChatImageAttachment>.unmodifiable(found.values);
}

List<ChatResourceAttachment> _chatMessageResourceAttachments(
  Map<String, Object?> object,
  Map<String, Object?>? payload, {
  required Set<String> imageResourceIds,
}) {
  final found = <String, ChatResourceAttachment>{};

  void add({
    required Object? kind,
    required Object? resourceId,
    Object? displayName,
    Object? mimeType,
    Object? sizeBytes,
  }) {
    final safeKind = ChatResourceAttachmentKind.tryParse(kind);
    final safeResourceId = _safeOptionalIdentifier(resourceId);
    if (safeKind == null ||
        safeResourceId == null ||
        imageResourceIds.contains(safeResourceId) ||
        found.containsKey(safeResourceId)) {
      return;
    }
    found[safeResourceId] = ChatResourceAttachment(
      kind: safeKind,
      resourceId: safeResourceId,
      displayName: _safeChatResourceDisplayName(displayName),
      mimeType: _safeChatResourceMimeType(mimeType),
      sizeBytes: sizeBytes is int && sizeBytes > 0 ? sizeBytes : null,
    );
  }

  void fromPartList(Object? value) {
    if (value is! Iterable) return;
    for (final candidate in value) {
      final part = asObjectMap(candidate);
      if (part == null) continue;
      final source = asObjectMap(part['source']);
      if (source != null && source['kind'] != 'resource') continue;
      final resource = asObjectMap(part['resource']);
      add(
        kind: part['kind'] ?? part['type'],
        resourceId:
            part['resourceId'] ??
            source?['resourceId'] ??
            resource?['resourceId'],
        displayName:
            part['displayName'] ??
            part['fileName'] ??
            part['name'] ??
            resource?['displayName'] ??
            resource?['fileName'],
        mimeType: part['mimeType'] ?? resource?['mimeType'],
        sizeBytes: part['sizeBytes'] ?? resource?['sizeBytes'],
      );
    }
  }

  void fromAttachmentList(Object? value) {
    if (value is! Iterable) return;
    for (final candidate in value) {
      final attachment = asObjectMap(candidate);
      if (attachment == null || attachment['availability'] != 'available') {
        continue;
      }
      final source = asObjectMap(attachment['source']);
      if (source != null && source['kind'] != 'resource') continue;
      final resource = asObjectMap(attachment['resource']);
      add(
        kind: attachment['kind'] ?? attachment['type'],
        resourceId:
            attachment['resourceId'] ??
            source?['resourceId'] ??
            resource?['resourceId'],
        displayName:
            attachment['displayName'] ??
            attachment['fileName'] ??
            attachment['name'] ??
            resource?['displayName'] ??
            resource?['fileName'],
        mimeType: attachment['mimeType'] ?? resource?['mimeType'],
        sizeBytes: attachment['sizeBytes'] ?? resource?['sizeBytes'],
      );
    }
  }

  fromPartList(object['content']);
  fromPartList(payload?['content']);
  for (final value in <Object?>[
    object['attachments'],
    object['outputAttachments'],
    payload?['attachments'],
    payload?['outputAttachments'],
    asObjectMap(object['result'])?['attachments'],
    asObjectMap(payload?['result'])?['attachments'],
  ]) {
    fromAttachmentList(value);
  }
  return List<ChatResourceAttachment>.unmodifiable(found.values);
}

String? _safeChatImageMimeType(Object? value) {
  final mimeType = value is String ? value.trim().toLowerCase() : null;
  return _isSupportedChatImageMimeType(mimeType) ? mimeType : null;
}

String? _safeChatImageDisplayName(Object? value) {
  return _safeChatResourceDisplayName(value);
}

String? _safeChatResourceDisplayName(Object? value) {
  final name = _safeDisplayText(value);
  if (name == null ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('..') ||
      name.codeUnits.any((unit) => unit < 32)) {
    return null;
  }
  return name;
}

String? _safeChatResourceMimeType(Object? value) {
  final mimeType = value is String ? value.trim().toLowerCase() : null;
  if (mimeType == null ||
      mimeType.length > 127 ||
      !RegExp(
        r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$',
      ).hasMatch(mimeType)) {
    return null;
  }
  return mimeType;
}

bool _isUnrenderableChatProjection(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return false;
  if (_safeOptionalIdentifier(object['messageId'] ?? object['id']) == null ||
      _safeDisplayText(object['status']) == null) {
    return false;
  }
  return true;
}

String? _threadFirstMessagePreview(Map<String, Object?> object) {
  final direct = _safeMessageText(
    object['firstUserMessagePreview'] ??
        object['firstUserMessageText'] ??
        object['firstMessageText'] ??
        object['firstMessagePreview'],
  );
  if (direct != null) return direct;
  final firstMessage = asObjectMap(
    object['firstUserMessage'] ?? object['firstMessage'],
  );
  if (firstMessage == null) return null;
  final role = firstMessage['role'];
  if (role != null && role != ChatMessageRole.user.apiValue) return null;
  return _safeMessageText(
    firstMessage['textPreview'] ??
        firstMessage['text'] ??
        firstMessage['content'] ??
        asObjectMap(firstMessage['payload'])?['text'],
  );
}

String? _firstUserMessageText(Iterable<ChatMessage> messages) {
  for (final message in messages) {
    if (message.role != ChatMessageRole.user) continue;
    final text = message.visibleText?.trim();
    if (text != null && text.isNotEmpty) return text;
    if (message.imageAttachments.isNotEmpty) return '图片消息';
    if (message.contentType == ChatMessageContentType.voice) return '语音消息';
  }
  return null;
}

ChatNextAction parseChatNextAction(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return const ChatNextAction.none();
  switch (object['type']) {
    case 'open_task_panel':
      return const ChatNextAction(type: ChatNextActionType.openTaskPanel);
    case 'poll_task':
      final taskId = _safeOptionalIdentifier(object['taskId']);
      return taskId == null
          ? const ChatNextAction.none()
          : ChatNextAction(type: ChatNextActionType.pollTask, taskId: taskId);
    case 'poll_agent_run':
      final agentRunId = _safeAgentRunIdentifier(
        object['agentRunId'] ?? object['runId'],
      );
      final taskId = _safeOptionalIdentifier(object['taskId']);
      return agentRunId == null
          ? const ChatNextAction.none()
          : ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: agentRunId,
              taskId: taskId,
            );
    case 'poll_asr':
      final asrTaskId = _safeOptionalIdentifier(object['asrTaskId']);
      return asrTaskId == null
          ? const ChatNextAction.none()
          : ChatNextAction(
              type: ChatNextActionType.pollAsr,
              asrTaskId: asrTaskId,
            );
    case 'quota_insufficient':
      return ChatNextAction(
        type: ChatNextActionType.quotaInsufficient,
        userMessage: _safeDisplayText(object['userMessage']) ?? '额度不足，请稍后重试。',
      );
    case 'retry_asr':
      final asrTaskId = _safeOptionalIdentifier(object['asrTaskId']);
      return asrTaskId == null
          ? const ChatNextAction.none()
          : ChatNextAction(
              type: ChatNextActionType.retryAsr,
              asrTaskId: asrTaskId,
            );
    default:
      return const ChatNextAction.none();
  }
}

ChatNextAction _chatReplyNextAction(
  Map<String, Object?> object, {
  required ChatMessage? assistant,
}) {
  final explicit = parseChatNextAction(object['nextAction']);
  final run = asObjectMap(object['agentRun'] ?? object['run']);
  final task = asObjectMap(object['task']);
  final taskId =
      explicit.taskId ??
      _safeOptionalIdentifier(
        object['taskId'] ?? task?['taskId'] ?? task?['id'] ?? run?['taskId'],
      );
  final agentRunId = _safeAgentRunIdentifier(
    object['agentRunId'] ??
        run?['agentRunId'] ??
        run?['runId'] ??
        run?['id'] ??
        task?['agentRunId'],
  );
  if (agentRunId != null &&
      (explicit.type == ChatNextActionType.none ||
          _awaitsChatReply(explicit))) {
    return ChatNextAction(
      type: ChatNextActionType.pollAgentRun,
      agentRunId: agentRunId,
      taskId: taskId,
    );
  }

  if (explicit.type == ChatNextActionType.pollAgentRun) return explicit;

  if (assistant != null && _awaitsChatReply(explicit)) {
    return const ChatNextAction.none();
  }
  if (explicit.type != ChatNextActionType.none) return explicit;
  if (assistant != null) return const ChatNextAction.none();

  if (taskId != null) {
    return ChatNextAction(type: ChatNextActionType.pollTask, taskId: taskId);
  }

  return const ChatNextAction(type: ChatNextActionType.pollThread);
}

bool _awaitsChatReply(ChatNextAction action) =>
    action.type == ChatNextActionType.pollTask ||
    action.type == ChatNextActionType.pollAgentRun ||
    action.type == ChatNextActionType.pollThread;

bool _requiresCanonicalRunReceipt(ChatContextPurpose? purpose) =>
    purpose == ChatContextPurpose.deepPositioning ||
    purpose == ChatContextPurpose.socialPositioning;

bool _isCanonicalChatInputReference(ChatContextReference reference) =>
    (reference.type == ChatContextReferenceType.material &&
        reference.revision != null) ||
    reference.type == ChatContextReferenceType.file ||
    reference.type == ChatContextReferenceType.image;

List<SharedAgentInputContent> _canonicalTextInputContent(
  String text,
  Iterable<ChatContextReference> references, {
  ChatLocalDraftSnapshot? localDraftSnapshot,
}) {
  final content = <SharedAgentInputContent>[
    if (text.isNotEmpty) SharedAgentTextContent(text: text),
  ];
  for (final reference in references) {
    if (reference.type == ChatContextReferenceType.material &&
        reference.revision != null) {
      content.add(
        SharedAgentWorkspaceDocumentContent(
          ownerKind: 'hnote',
          ownerId: reference.id,
          part: 'raw',
          partRevisionId: reference.revision!,
        ),
      );
    } else if (reference.type == ChatContextReferenceType.file) {
      content.add(
        SharedAgentResourceContent(
          type: 'file',
          resourceId: reference.id,
          usage: 'reference',
        ),
      );
    } else if (reference.type == ChatContextReferenceType.image) {
      content.add(
        SharedAgentResourceContent(
          type: 'image',
          resourceId: reference.id,
          usage: 'primary_input',
        ),
      );
    }
  }
  if (localDraftSnapshot != null) {
    content.add(
      SharedAgentTextContent(text: localDraftSnapshot.toAgentTextPart()),
    );
  }
  return content;
}

ChatImagePlayback _parseChatImagePlayback(Object? value, String resourceId) {
  final root = asObjectMap(value);
  final resource = asObjectMap(root?['resource']);
  final returnedResourceId = _safeOptionalIdentifier(
    root?['resourceId'] ?? resource?['resourceId'],
  );
  if (root == null ||
      (returnedResourceId != null && returnedResourceId != resourceId)) {
    throw const FormatException('CHAT_IMAGE_PLAYBACK_RESPONSE_INVALID');
  }
  final url = _safeChatImagePlaybackUrl(root['url'] ?? resource?['url']);
  final rawMimeType = root['mimeType'] ?? resource?['mimeType'];
  final mimeType = rawMimeType is String
      ? rawMimeType.trim().toLowerCase()
      : null;
  if (url == null || !_isSupportedResourceImageMimeType(mimeType)) {
    throw const FormatException('CHAT_IMAGE_PLAYBACK_RESPONSE_INVALID');
  }
  final extension = switch (mimeType) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    _ => throw const FormatException('CHAT_IMAGE_PLAYBACK_RESPONSE_INVALID'),
  };
  return ChatImagePlayback(
    resourceId: resourceId,
    url: url,
    mimeType: mimeType!,
    displayName:
        _safeChatImageDisplayName(
          root['fileName'] ??
              root['displayName'] ??
              resource?['displayName'] ??
              resource?['fileName'],
        ) ??
        'chat-image.$extension',
  );
}

Uri? _safeChatImagePlaybackUrl(Object? value) {
  final raw = value is String ? value.trim() : null;
  if (raw == null || raw.isEmpty || raw.length > 4096) return null;
  final url = Uri.tryParse(raw);
  if (url == null ||
      (url.scheme != 'https' && url.scheme != 'http') ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty) {
    return null;
  }
  return url;
}

bool _isSupportedChatImageMimeType(String? value) =>
    value != null &&
    const <String>{'image/jpeg', 'image/png', 'image/webp'}.contains(value);

bool _isSupportedResourceImageMimeType(String? value) =>
    _isSupportedChatImageMimeType(value) || value == 'image/gif';

bool _hasChatImageSignature(Uint8List bytes, String mimeType) =>
    switch (mimeType) {
      'image/gif' =>
        bytes.length >= 6 &&
            bytes[0] == 0x47 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x38 &&
            (bytes[4] == 0x37 || bytes[4] == 0x39) &&
            bytes[5] == 0x61,
      'image/jpeg' =>
        bytes.length >= 3 &&
            bytes[0] == 0xff &&
            bytes[1] == 0xd8 &&
            bytes[2] == 0xff,
      'image/png' =>
        bytes.length >= 8 &&
            bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4e &&
            bytes[3] == 0x47 &&
            bytes[4] == 0x0d &&
            bytes[5] == 0x0a &&
            bytes[6] == 0x1a &&
            bytes[7] == 0x0a,
      'image/webp' =>
        bytes.length >= 12 &&
            bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46 &&
            bytes[8] == 0x57 &&
            bytes[9] == 0x45 &&
            bytes[10] == 0x42 &&
            bytes[11] == 0x50,
      _ => false,
    };

ApiResult<T> _withTextSubmissionFailureDisposition<T>(
  ApiResult<T> result,
  ChatSubmissionFailureDisposition disposition,
) {
  final error = result.error;
  if (result.ok || error == null) return result;
  return ApiResult<T>.failure(
    error: error.copyWith(
      metadata: <String, Object?>{
        ...error.metadata,
        chatTextFailureDispositionMetadataKey: disposition.name,
      },
    ),
    status: result.status,
    traceId: result.traceId,
    authExpired: result.authExpired,
    retryAfterSeconds: result.retryAfterSeconds,
    idempotencyStore: result.idempotencyStore,
    responseHeaders: result.responseHeaders,
  );
}

ApiResult<T> _invalidResult<T>(String code) {
  return ApiResult<T>.failure(
    error: chatApiFailure(code),
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

AppFailure chatApiFailure(String code, {bool retryable = false}) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.api,
    message: 'Chat API operation failed',
    userMessageKey: 'chat.api.error.$code',
    isRetryable: retryable,
    recoveryActions: retryable
        ? const <String>['retry']
        : const <String>['none'],
  );
}

Iterable<Object?>? _firstList(Map<String, Object?> object, List<String> keys) {
  for (final key in keys) {
    final value = object[key];
    if (value is Iterable) return value.cast<Object?>();
  }
  return null;
}

bool _isStructuredChatEvent(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return false;
  final type = object['contentType'] ?? object['messageType'];
  return type == 'deposit_tip' ||
      type == 'task_card' ||
      type == 'task_result' ||
      type == 'result_card';
}

bool _isSystemChatEvent(Object? value) =>
    asObjectMap(value)?['role'] == ChatMessageRole.system.apiValue;

bool _hasUnexpectedContentType(Object? value, ChatMessageContentType expected) {
  final object = asObjectMap(value);
  if (object == null) return true;
  final rawContentType = object['contentType'] ?? object['messageType'];
  return rawContentType != null && rawContentType != expected.apiValue;
}

bool _hasUnsupportedContentType(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return true;
  final rawContentType = object['contentType'] ?? object['messageType'];
  return rawContentType != null &&
      ChatMessageContentType.tryParse(rawContentType) == null;
}

bool _hasMalformedChatMessageFields(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return true;
  final messageId = object['messageId'] ?? object['id'];
  if (_safeOptionalIdentifier(messageId) == null) return true;
  if (object.containsKey('threadId') &&
      _safeOptionalIdentifier(object['threadId']) == null) {
    return true;
  }
  if (object.containsKey('scene') &&
      ChatScene.tryParse(object['scene']) == null) {
    return true;
  }
  if (object.containsKey('role') &&
      ChatMessageRole.tryParse(object['role']) == null) {
    return true;
  }
  final rawContentType = object['contentType'] ?? object['messageType'];
  if (rawContentType != null &&
      ChatMessageContentType.tryParse(rawContentType) == null) {
    return true;
  }
  if (object.containsKey('status') &&
      _safeDisplayText(object['status']) == null) {
    return true;
  }
  return false;
}

String? _safeOptionalIdentifier(Object? value) {
  final text = asNonEmptyString(value)?.trim();
  return text != null && isSafeChatIdentifier(text) ? text : null;
}

String? _safeAgentRunIdentifier(Object? value) {
  final text = asNonEmptyString(value)?.trim();
  return text != null && isSafeAgentRunIdentifier(text) ? text : null;
}

({bool isValid, String? value}) _consistentAgentRunIdentifier(
  Iterable<Object?> declarations,
) {
  String? resolved;
  for (final declaration in declarations) {
    if (declaration == null ||
        (declaration is String && declaration.trim().isEmpty)) {
      continue;
    }
    final candidate = _safeAgentRunIdentifier(declaration);
    if (candidate == null || (resolved != null && resolved != candidate)) {
      return (isValid: false, value: null);
    }
    resolved = candidate;
  }
  return (isValid: true, value: resolved);
}

bool _isSafeRuntimeInvocationCursor(String? value) {
  if (value == null) return true;
  return value.isNotEmpty &&
      value.length <= 1024 &&
      value.trim() == value &&
      !value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);
}

String? _safeDisplayText(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > _maxDisplayLength) {
    return null;
  }
  return _containsUnsafeResponseContent(text) ? null : text;
}

String? _safeMessageText(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty) return null;
  if (_containsUnsafeResponseContent(text)) return null;
  return text;
}

DateTime? _safeDate(Object? value) {
  final text = _safeDisplayText(value);
  return text == null ? null : DateTime.tryParse(text)?.toUtc();
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

const _maxDisplayLength = 240;
const _maxOutgoingMessageLength = 4000;
const _maxVoiceDurationSeconds = 24 * 60 * 60;
