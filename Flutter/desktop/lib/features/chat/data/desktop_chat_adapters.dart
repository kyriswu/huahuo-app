import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_chat_port.dart';

final class RemoteDesktopChatPort
    implements
        DesktopChatPort,
        DesktopChatAsyncSubmissionPort,
        DesktopChatTaskResolutionPort {
  RemoteDesktopChatPort(
    ApiClient apiClient, {
    this.pollInterval = const Duration(seconds: 1),
    this.maxPollAttempts = 30,
    this.catalogCacheTtl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _apiClient = apiClient,
       _now = now ?? DateTime.now;

  final ApiClient _apiClient;
  final Duration pollInterval;
  final int maxPollAttempts;
  final Duration catalogCacheTtl;
  final DateTime Function() _now;
  final Map<String, _DesktopAgentSelection> _cachedSelections =
      <String, _DesktopAgentSelection>{};
  final Map<String, DateTime> _selectionExpiryByAgentProfileId =
      <String, DateTime>{};

  @override
  Future<DesktopServiceResult<DesktopChatThreadPage>> listThreads({
    String? cursor,
    int limit = 30,
  }) async {
    if (limit < 1 || limit > 100) {
      return const DesktopServiceResult<DesktopChatThreadPage>.failure(
        code: 'DESKTOP_CHAT_PAGE_INVALID',
        message: '聊天分页参数无效',
      );
    }
    final result = await _apiClient.request<DesktopChatThreadPage>(
      ApiRequestOptions<DesktopChatThreadPage>(
        endpointId: 'chatThreads',
        query: <String, Object?>{
          if (cursor != null) 'cursor': cursor,
          'limit': limit,
        },
        parseData: _parseThreadPage,
      ),
    );
    return result.ok
        ? DesktopServiceResult<DesktopChatThreadPage>.success(result.data!)
        : _failure(result);
  }

  @override
  Future<DesktopServiceResult<DesktopChatThread>> createThread() async {
    final result = await _apiClient.request<DesktopChatThread>(
      ApiRequestOptions<DesktopChatThread>(
        endpointId: 'createChatThread',
        body: const <String, Object?>{},
        idempotency: const IdempotencyRequestContext(
          operation: 'desktop.chat.create-thread',
        ),
        parseData: (value) {
          final json = asObjectMap(value);
          return _parseThread(json?['thread'] ?? json);
        },
      ),
    );
    return result.ok
        ? DesktopServiceResult<DesktopChatThread>.success(result.data!)
        : _failure(result);
  }

  @override
  Future<DesktopServiceResult<DesktopChatThreadDetail>> getThreadDetail(
    String threadId,
  ) async {
    final result = await _apiClient.request<DesktopChatThreadDetail>(
      ApiRequestOptions<DesktopChatThreadDetail>(
        endpointId: 'chatThreadDetail',
        pathParams: <String, Object>{'threadId': threadId},
        parseData: _parseThreadDetail,
      ),
    );
    return result.ok
        ? DesktopServiceResult<DesktopChatThreadDetail>.success(result.data!)
        : _failure(result);
  }

  @override
  Future<DesktopServiceResult<DesktopChatReply>> sendText({
    required String threadId,
    required String content,
    String? agentProfileId,
    Iterable<DesktopChatContextReference> references =
        const <DesktopChatContextReference>[],
  }) => _sendText(
    threadId: threadId,
    content: content,
    agentProfileId: agentProfileId,
    references: references,
    waitForCompletion: true,
  );

  @override
  Future<DesktopServiceResult<DesktopChatReply>> sendAcceptedText({
    required String threadId,
    required String content,
    String? agentProfileId,
    Iterable<DesktopChatContextReference> references =
        const <DesktopChatContextReference>[],
  }) => _sendText(
    threadId: threadId,
    content: content,
    agentProfileId: agentProfileId,
    references: references,
    waitForCompletion: false,
  );

  Future<DesktopServiceResult<DesktopChatReply>> _sendText({
    required String threadId,
    required String content,
    required String? agentProfileId,
    required Iterable<DesktopChatContextReference> references,
    required bool waitForCompletion,
  }) async {
    final text = content.trim();
    final boundedReferences = _deduplicateReferences(references);
    if (text.isEmpty || text.length > 12000 || boundedReferences == null) {
      return const DesktopServiceResult<DesktopChatReply>.failure(
        code: 'DESKTOP_CHAT_INPUT_INVALID',
        message: '聊天内容或上下文无效',
      );
    }
    final input = SharedAgentInput(
      content: <SharedAgentInputContent>[
        SharedAgentTextContent(text: text),
        ...boundedReferences.map(_sharedContent),
      ],
    );
    final selection = await _resolveAgentSelection(agentProfileId);
    if (!selection.isSuccess) {
      return DesktopServiceResult<DesktopChatReply>.failure(
        code: selection.code,
        message: selection.message,
        retryable: selection.retryable,
      );
    }
    final result = await _apiClient.request<DesktopChatReply>(
      ApiRequestOptions<DesktopChatReply>(
        endpointId: 'sendChatMessage',
        pathParams: <String, Object>{'threadId': threadId},
        body: <String, Object?>{
          'input': input.toJson(),
          'agentProfileId': selection.data!.agentProfileId,
        },
        idempotency: IdempotencyRequestContext(
          operation: 'desktop.chat.send-text',
          localDraftId:
              '$threadId-${DateTime.now().toUtc().microsecondsSinceEpoch}',
        ),
        parseData: (value) => _parseReply(value, threadId),
      ),
    );
    if (!result.ok || result.data == null) {
      if (result.error?.code == 'AGENT_PROFILE_NOT_SELECTABLE') {
        _invalidateAgentSelection(selection.data!.agentProfileId);
      }
      return _failure(result);
    }
    final reply = result.data!;
    final completionFailure = _completionFailure(reply.completionMode);
    if (completionFailure != null) return completionFailure;
    if (reply.assistantMessage != null) {
      return DesktopServiceResult<DesktopChatReply>.success(reply);
    }
    return waitForCompletion
        ? _waitForDurableReply(reply)
        : DesktopServiceResult<DesktopChatReply>.success(reply);
  }

  @override
  Future<DesktopServiceResult<DesktopChatReply>> resolveAcceptedReply(
    DesktopChatReply accepted,
  ) => _waitForDurableReply(accepted);

  Future<DesktopServiceResult<_DesktopAgentSelection>> _resolveAgentSelection(
    String? requestedAgentProfileId,
  ) async {
    final requested = requestedAgentProfileId?.trim();
    if (requested != null && requested.isNotEmpty) {
      if (!_safeAgentProfileId.hasMatch(requested)) {
        return const DesktopServiceResult<_DesktopAgentSelection>.failure(
          code: 'DESKTOP_CHAT_AGENT_PROFILE_INVALID',
          message: '聊天 Agent 标识无效',
        );
      }
      // A persisted thread's public Profile is already server-owned state.
      // Rechecking the catalog here would block history recovery and can never
      // authorize a hidden Skill/Model selection.
      return DesktopServiceResult<_DesktopAgentSelection>.success(
        _DesktopAgentSelection(agentProfileId: requested),
      );
    }
    final route = AgentFeatureRoutes.forFeature('chat.general');
    if (route == null) {
      return const DesktopServiceResult<_DesktopAgentSelection>.failure(
        code: 'DESKTOP_CHAT_AGENT_ROUTE_UNAVAILABLE',
        message: '普通聊天尚未配置公开 Agent',
      );
    }
    final defaultProfileId = route.agentProfileId;
    final cached = _cachedSelections[defaultProfileId];
    final expiresAt = _selectionExpiryByAgentProfileId[defaultProfileId];
    if (cached != null &&
        expiresAt != null &&
        _now().toUtc().isBefore(expiresAt)) {
      return DesktopServiceResult<_DesktopAgentSelection>.success(cached);
    }
    final catalogResult = await AgentCatalogClient(_apiClient).profiles();
    if (!catalogResult.ok || catalogResult.data == null) {
      return _failure(catalogResult);
    }
    if (!catalogResult.data!.items.any(
      (item) => item.agentProfileId == defaultProfileId,
    )) {
      return const DesktopServiceResult<_DesktopAgentSelection>.failure(
        code: 'AGENT_PROFILE_NOT_SELECTABLE',
        message: '普通聊天能力当前不可用',
      );
    }

    final selection = _DesktopAgentSelection(agentProfileId: defaultProfileId);
    _cachedSelections[defaultProfileId] = selection;
    _selectionExpiryByAgentProfileId[defaultProfileId] = _now().toUtc().add(
      catalogCacheTtl,
    );
    return DesktopServiceResult<_DesktopAgentSelection>.success(selection);
  }

  void _invalidateAgentSelection(String agentProfileId) {
    _cachedSelections.remove(agentProfileId);
    _selectionExpiryByAgentProfileId.remove(agentProfileId);
  }

  Future<DesktopServiceResult<DesktopChatReply>> _waitForDurableReply(
    DesktopChatReply accepted,
  ) async {
    if (maxPollAttempts < 1 || pollInterval.isNegative) {
      return const DesktopServiceResult<DesktopChatReply>.failure(
        code: 'DESKTOP_CHAT_POLL_CONFIGURATION_INVALID',
        message: '聊天轮询配置无效',
      );
    }
    final agentRunId = accepted.agentRunId;
    if (agentRunId == null) {
      return _pollThreadForAssistant(accepted);
    }

    final runs = AgentRunClient(_apiClient);
    for (var attempt = 0; attempt < maxPollAttempts; attempt += 1) {
      await _pollDelay(attempt);
      final result = await runs.get(agentRunId);
      if (!result.ok || result.data == null) {
        if (result.error?.isRetryable == true) continue;
        return _failure(result);
      }
      final run = result.data!;
      if (run.agentRunId != agentRunId ||
          (run.threadId != null &&
              run.threadId != accepted.userMessage.threadId)) {
        return const DesktopServiceResult<DesktopChatReply>.failure(
          code: 'DESKTOP_CHAT_AGENT_RUN_MISMATCH',
          message: '聊天任务与当前会话不匹配',
        );
      }
      if (!run.isTerminal) continue;
      if (run.status != 'succeeded') return _runFailure(run);
      final completionFailure = _completionFailure(run.completionMode);
      if (completionFailure != null) return completionFailure;
      return _pollThreadForAssistant(
        accepted,
        assistantMessageId: run.assistantMessageId,
      );
    }
    return const DesktopServiceResult<DesktopChatReply>.failure(
      code: 'DESKTOP_CHAT_AGENT_RUN_TIMEOUT',
      message: 'AI 任务仍在处理中，请稍后重试',
      retryable: true,
    );
  }

  Future<DesktopServiceResult<DesktopChatReply>> _pollThreadForAssistant(
    DesktopChatReply accepted, {
    String? assistantMessageId,
  }) async {
    for (var attempt = 0; attempt < maxPollAttempts; attempt += 1) {
      await _pollDelay(attempt);
      final detailResult = await getThreadDetail(accepted.userMessage.threadId);
      if (!detailResult.isSuccess) {
        if (detailResult.retryable) continue;
        return DesktopServiceResult<DesktopChatReply>.failure(
          code: detailResult.code,
          message: detailResult.message,
          retryable: detailResult.retryable,
        );
      }
      final assistant = _persistedAssistantAfter(
        detailResult.data!.messages,
        userMessageId: accepted.userMessage.messageId,
        assistantMessageId: assistantMessageId,
      );
      if (assistant != null) {
        return DesktopServiceResult<DesktopChatReply>.success(
          DesktopChatReply(
            userMessage: accepted.userMessage,
            assistantMessage: assistant,
            taskId: accepted.taskId,
            agentRunId: accepted.agentRunId,
            completionMode: 'normal',
          ),
        );
      }
    }
    return const DesktopServiceResult<DesktopChatReply>.failure(
      code: 'DESKTOP_CHAT_ASSISTANT_NOT_PERSISTED',
      message: 'AI 回复尚未保存到会话，请稍后重试',
      retryable: true,
    );
  }

  Future<void> _pollDelay(int attempt) {
    if (attempt == 0 || pollInterval == Duration.zero) {
      return Future<void>.value();
    }
    return Future<void>.delayed(pollInterval);
  }
}

final class _DesktopAgentSelection {
  const _DesktopAgentSelection({required this.agentProfileId});

  final String agentProfileId;
}

final class UnavailableDesktopChatPort implements DesktopChatPort {
  const UnavailableDesktopChatPort();

  static const _code = 'DESKTOP_CHAT_UNAVAILABLE';
  static const _message = '未配置后端，聊天服务暂不可用';

  @override
  Future<DesktopServiceResult<DesktopChatThreadPage>> listThreads({
    String? cursor,
    int limit = 30,
  }) async => const DesktopServiceResult<DesktopChatThreadPage>.unavailable(
    code: _code,
    message: _message,
  );

  @override
  Future<DesktopServiceResult<DesktopChatThread>> createThread() async =>
      const DesktopServiceResult<DesktopChatThread>.unavailable(
        code: _code,
        message: _message,
      );

  @override
  Future<DesktopServiceResult<DesktopChatThreadDetail>> getThreadDetail(
    String threadId,
  ) async => const DesktopServiceResult<DesktopChatThreadDetail>.unavailable(
    code: _code,
    message: _message,
  );

  @override
  Future<DesktopServiceResult<DesktopChatReply>> sendText({
    required String threadId,
    required String content,
    String? agentProfileId,
    Iterable<DesktopChatContextReference> references =
        const <DesktopChatContextReference>[],
  }) async => const DesktopServiceResult<DesktopChatReply>.unavailable(
    code: _code,
    message: _message,
  );
}

/// Available only through the explicit HUAHUO_DESKTOP_DEMO compile-time flag.
final class DemoDesktopChatPort implements DesktopDemoChatPort {
  const DemoDesktopChatPort();

  static const _thread = DesktopChatThread(
    threadId: 'demo-desktop-thread',
    title: 'Demo 对话',
  );

  @override
  Future<DesktopServiceResult<DesktopChatThreadPage>> listThreads({
    String? cursor,
    int limit = 30,
  }) async => const DesktopServiceResult<DesktopChatThreadPage>.success(
    DesktopChatThreadPage(items: <DesktopChatThread>[_thread]),
  );

  @override
  Future<DesktopServiceResult<DesktopChatThread>> createThread() async =>
      const DesktopServiceResult<DesktopChatThread>.success(_thread);

  @override
  Future<DesktopServiceResult<DesktopChatThreadDetail>> getThreadDetail(
    String threadId,
  ) async => const DesktopServiceResult<DesktopChatThreadDetail>.success(
    DesktopChatThreadDetail(thread: _thread, messages: <DesktopChatMessage>[]),
  );

  @override
  Future<DesktopServiceResult<DesktopChatReply>> sendText({
    required String threadId,
    required String content,
    String? agentProfileId,
    Iterable<DesktopChatContextReference> references =
        const <DesktopChatContextReference>[],
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 520));
    final suffix = references.isEmpty ? '' : '，并参考你选择的材料';
    return DesktopServiceResult<DesktopChatReply>.success(
      DesktopChatReply(
        userMessage: DesktopChatMessage(
          messageId: 'demo-user-message',
          threadId: threadId,
          role: 'user',
          text: content,
        ),
        assistantMessage: DesktopChatMessage(
          messageId: 'demo-assistant-message',
          threadId: threadId,
          role: 'assistant',
          text:
              '围绕“$content”$suffix，先明确读者和结论，再按场景、冲突、判断组织素材。'
              '我可以继续把它展开成提纲，或者直接写成初稿。',
        ),
      ),
    );
  }
}

List<DesktopChatContextReference>? _deduplicateReferences(
  Iterable<DesktopChatContextReference> references,
) {
  final result = <String, DesktopChatContextReference>{};
  for (final reference in references) {
    result.putIfAbsent(reference.identity, () => reference);
    if (result.length > 50) return null;
  }
  return result.values.toList(growable: false);
}

final _safeAgentProfileId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');

SharedAgentInputContent _sharedContent(DesktopChatContextReference reference) {
  final resourceId = reference.resourceId;
  if (resourceId != null) {
    return SharedAgentResourceContent(
      type: reference.resourceType!,
      resourceId: resourceId,
    );
  }
  return SharedAgentWorkspaceDocumentContent(
    ownerKind: 'hnote',
    ownerId: reference.ownerId!,
    part: reference.part!,
    partRevisionId: reference.partRevisionId!,
  );
}

DesktopChatThreadPage? _parseThreadPage(Object? value) {
  final json = asObjectMap(value);
  final rawItems = json?['items'] ?? json?['threads'];
  if (rawItems is! List) return null;
  final items = <DesktopChatThread>[];
  for (final raw in rawItems) {
    final thread = _parseThread(raw);
    if (thread == null) return null;
    items.add(thread);
  }
  final cursor = json?['nextCursor'];
  if (cursor != null && cursor is! String) return null;
  return DesktopChatThreadPage(items: items, nextCursor: cursor as String?);
}

DesktopChatThread? _parseThread(Object? value) {
  final json = asObjectMap(value);
  final threadId = json?['threadId'];
  if (threadId is! String || threadId.isEmpty) return null;
  final title = json?['title'];
  if (title != null && title is! String) return null;
  final rawUpdatedAt = json?['updatedAt'];
  final updatedAt = rawUpdatedAt == null
      ? null
      : DateTime.tryParse(rawUpdatedAt.toString())?.toUtc();
  if (rawUpdatedAt != null && updatedAt == null) return null;
  final rawAgentProfileId = json?['agentProfileId'];
  final agentProfileId = rawAgentProfileId == null
      ? null
      : _remoteIdentifier(rawAgentProfileId);
  if (rawAgentProfileId != null && agentProfileId == null) return null;
  final activeRuns = _parseThreadActiveRuns(json);
  if (activeRuns == null) return null;
  return DesktopChatThread(
    threadId: threadId,
    title: (title as String?)?.trim().isNotEmpty == true
        ? title as String
        : '未命名会话',
    updatedAt: updatedAt,
    agentProfileId: agentProfileId,
    activeRuns: activeRuns,
  );
}

List<DesktopChatActiveRun>? _parseThreadActiveRuns(Map<String, Object?>? json) {
  final raw = json?['activeRuns'];
  if (raw == null) return const <DesktopChatActiveRun>[];
  if (raw is! List) return null;
  final runs = <DesktopChatActiveRun>[];
  final identifiers = <String>{};
  for (final value in raw) {
    final entry = asObjectMap(value);
    final agentRunId = _remoteIdentifier(entry?['agentRunId']);
    final status = entry?['status'];
    if (agentRunId == null ||
        status is! String ||
        status.trim().isEmpty ||
        status.length > 64 ||
        !identifiers.add(agentRunId)) {
      return null;
    }
    runs.add(DesktopChatActiveRun(agentRunId: agentRunId, status: status));
  }
  return List<DesktopChatActiveRun>.unmodifiable(runs);
}

DesktopChatMessage? _parseMessage(Object? value, String fallbackThreadId) {
  final json = asObjectMap(value);
  final payload = asObjectMap(json?['payload']);
  final messageId = _remoteIdentifier(json?['messageId'] ?? json?['id']);
  final threadId = _remoteIdentifier(json?['threadId'] ?? fallbackThreadId);
  final role = json?['role'];
  final text = _messageText(json, payload);
  final images = _messageImages(json, payload);
  if (messageId == null ||
      threadId == null ||
      role is! String ||
      !const <String>{'user', 'assistant', 'system'}.contains(role) ||
      (text == null && images.isEmpty)) {
    return null;
  }
  return DesktopChatMessage(
    messageId: messageId,
    threadId: threadId,
    role: role,
    text: text ?? '',
    imageAttachments: images,
  );
}

String? _messageText(
  Map<String, Object?>? json,
  Map<String, Object?>? payload,
) {
  for (final value in <Object?>[
    json?['textPreview'],
    json?['transcriptText'],
    json?['text'],
    json?['contentMarkdown'],
    json?['markdown'],
    json?['content'],
    payload?['reply'],
    payload?['content'],
    payload?['text'],
    payload?['contentMarkdown'],
    payload?['markdown'],
  ]) {
    final text = _safeMessageText(value) ?? _textFromContentParts(value);
    if (text != null) return text;
  }
  return null;
}

String? _safeMessageText(Object? value) {
  if (value is! String || value.trim().isEmpty || value.length > 120000) {
    return null;
  }
  return value;
}

String? _textFromContentParts(Object? value) {
  if (value is! Iterable) return null;
  for (final raw in value) {
    final part = asObjectMap(raw);
    if (part == null || part['type'] != 'text') continue;
    final text = _safeMessageText(
      part['text'] ?? part['content'] ?? part['markdown'],
    );
    if (text != null) return text;
  }
  return null;
}

List<DesktopChatImageAttachment> _messageImages(
  Map<String, Object?>? json,
  Map<String, Object?>? payload,
) {
  final found = <String, DesktopChatImageAttachment>{};

  void add({
    required Object? resourceId,
    Object? displayName,
    Object? mimeType,
    bool requireSupportedMimeType = false,
  }) {
    final resource = _remoteIdentifier(resourceId);
    if (resource == null || found.containsKey(resource)) return;
    final mime = _safeImageMime(mimeType);
    if (requireSupportedMimeType && mime == null) return;
    found[resource] = DesktopChatImageAttachment(
      resourceId: resource,
      displayName: _safeImageDisplayName(displayName),
      mimeType: mime,
    );
  }

  void fromContentParts(Object? value) {
    if (value is! Iterable) return;
    for (final raw in value) {
      final part = asObjectMap(raw);
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

  void fromAttachments(Object? value) {
    if (value is! Iterable) return;
    for (final raw in value) {
      final attachment = asObjectMap(raw);
      if (attachment == null) continue;
      final type = attachment['kind'] ?? attachment['type'];
      if (type != 'image' || attachment['availability'] != 'available') {
        continue;
      }
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

  fromContentParts(json?['content']);
  fromContentParts(payload?['content']);
  for (final value in <Object?>[
    json?['attachments'],
    json?['outputAttachments'],
    payload?['attachments'],
    payload?['outputAttachments'],
    asObjectMap(json?['result'])?['attachments'],
    asObjectMap(payload?['result'])?['attachments'],
  ]) {
    fromAttachments(value);
  }
  return List<DesktopChatImageAttachment>.unmodifiable(found.values);
}

String? _safeImageMime(Object? value) {
  final mime = value is String ? value.trim().toLowerCase() : null;
  return const <String>{
        'image/png',
        'image/jpeg',
        'image/jpg',
        'image/gif',
        'image/webp',
      }.contains(mime)
      ? mime
      : null;
}

String? _safeImageDisplayName(Object? value) {
  if (value is! String) return null;
  final name = value.trim();
  if (name.isEmpty ||
      name.length > 160 ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('..') ||
      name.codeUnits.any((unit) => unit < 32)) {
    return null;
  }
  return name;
}

DesktopChatThreadDetail? _parseThreadDetail(Object? value) {
  final json = asObjectMap(value);
  final parsedThread = _parseThread(json?['thread'] ?? json);
  final rawMessages = json?['messages'];
  if (parsedThread == null || rawMessages is! List) return null;
  final rawLastRequestProfile = json?['lastRequestProfile'];
  final lastRequestProfile = rawLastRequestProfile == null
      ? null
      : asObjectMap(rawLastRequestProfile);
  if (rawLastRequestProfile != null && lastRequestProfile == null) return null;
  final rawHistoricalAgentProfileId = lastRequestProfile?['agentProfileId'];
  final historicalAgentProfileId = _remoteIdentifier(
    rawHistoricalAgentProfileId,
  );
  if (rawHistoricalAgentProfileId != null && historicalAgentProfileId == null) {
    return null;
  }
  if (parsedThread.agentProfileId != null &&
      historicalAgentProfileId != null &&
      parsedThread.agentProfileId != historicalAgentProfileId) {
    return null;
  }
  final thread = DesktopChatThread(
    threadId: parsedThread.threadId,
    title: parsedThread.title,
    updatedAt: parsedThread.updatedAt,
    agentProfileId: parsedThread.agentProfileId ?? historicalAgentProfileId,
    activeRuns: parsedThread.activeRuns,
  );
  final messages = <DesktopChatMessage>[];
  for (final raw in rawMessages) {
    final message = _parseMessage(raw, thread.threadId);
    if (message == null) return null;
    messages.add(message);
  }
  return DesktopChatThreadDetail(thread: thread, messages: messages);
}

DesktopChatReply? _parseReply(Object? value, String threadId) {
  final json = asObjectMap(value);
  final userMessage = _parseMessage(
    json?['userMessage'] ?? json?['message'],
    threadId,
  );
  if (userMessage == null || userMessage.role != 'user') return null;
  final rawAssistant = json?['assistantMessage'];
  final assistant = rawAssistant == null
      ? null
      : _parseMessage(rawAssistant, threadId);
  if (rawAssistant != null &&
      (assistant == null || assistant.role != 'assistant')) {
    return null;
  }
  final nextAction = asObjectMap(json?['nextAction']);
  final run = asObjectMap(json?['agentRun'] ?? json?['run']);
  final task = asObjectMap(json?['task']);
  final result = asObjectMap(run?['result']);
  final rawAgentRunId =
      json?['agentRunId'] ??
      run?['agentRunId'] ??
      (nextAction?['type'] == 'poll_agent_run'
          ? nextAction!['agentRunId'] ?? nextAction['runId']
          : null);
  final rawTaskId =
      json?['taskId'] ??
      task?['taskId'] ??
      task?['id'] ??
      (nextAction?['type'] == 'poll_task' ? nextAction!['taskId'] : null);
  final agentRunId = _remoteIdentifier(rawAgentRunId);
  final taskId = _remoteIdentifier(rawTaskId);
  if ((rawAgentRunId != null && agentRunId == null) ||
      (rawTaskId != null && taskId == null)) {
    return null;
  }
  final rawCompletionMode =
      json?['completionMode'] ??
      run?['completionMode'] ??
      result?['completionMode'];
  if (rawCompletionMode != null &&
      (rawCompletionMode is! String ||
          !_desktopCompletionModes.contains(rawCompletionMode))) {
    return null;
  }
  final completionMode = rawCompletionMode as String?;
  return DesktopChatReply(
    userMessage: userMessage,
    assistantMessage: assistant,
    taskId: taskId,
    agentRunId: agentRunId,
    completionMode: completionMode,
  );
}

DesktopChatMessage? _persistedAssistantAfter(
  List<DesktopChatMessage> messages, {
  required String userMessageId,
  String? assistantMessageId,
}) {
  if (assistantMessageId != null) {
    for (final message in messages) {
      if (message.messageId == assistantMessageId &&
          message.role == 'assistant' &&
          (message.text.trim().isNotEmpty ||
              message.imageAttachments.isNotEmpty)) {
        return message;
      }
    }
    return null;
  }
  final userIndex = messages.indexWhere(
    (message) => message.messageId == userMessageId && message.role == 'user',
  );
  if (userIndex < 0) return null;
  for (final message in messages.skip(userIndex + 1)) {
    if (message.role == 'assistant' &&
        (message.text.trim().isNotEmpty ||
            message.imageAttachments.isNotEmpty)) {
      return message;
    }
  }
  return null;
}

String? _remoteIdentifier(Object? value) {
  if (value is! String || !_desktopRemoteIdentifier.hasMatch(value)) {
    return null;
  }
  return value;
}

DesktopServiceResult<DesktopChatReply>? _completionFailure(String? mode) {
  return switch (mode) {
    null || 'normal' => null,
    'degraded' => const DesktopServiceResult<DesktopChatReply>.failure(
      code: 'DESKTOP_CHAT_DEGRADED_RESULT',
      message: 'AI 服务返回降级结果，本次回复未作为成功结果展示',
      retryable: true,
    ),
    'system_fallback' => const DesktopServiceResult<DesktopChatReply>.failure(
      code: 'DESKTOP_CHAT_SYSTEM_FALLBACK',
      message: 'AI 服务未完成本次请求，返回了系统兜底结果',
      retryable: true,
    ),
    'cancelled' => const DesktopServiceResult<DesktopChatReply>.failure(
      code: 'DESKTOP_CHAT_CANCELLED',
      message: '本次 AI 任务已取消',
    ),
    _ => const DesktopServiceResult<DesktopChatReply>.failure(
      code: 'DESKTOP_CHAT_COMPLETION_MODE_INVALID',
      message: 'AI 任务返回了无法识别的结果状态',
    ),
  };
}

DesktopServiceResult<DesktopChatReply> _runFailure(AgentRunSnapshot run) {
  final rawErrorCode = run.error?.fields['code'];
  final errorCode = rawErrorCode is String && rawErrorCode.trim().isNotEmpty
      ? rawErrorCode
      : null;
  return DesktopServiceResult<DesktopChatReply>.failure(
    code: errorCode ?? 'DESKTOP_CHAT_AGENT_RUN_${run.status.toUpperCase()}',
    message: switch (run.status) {
      'cancelled' => '本次 AI 任务已取消',
      'timeout' => 'AI 任务执行超时，请稍后重试',
      _ => 'AI 任务执行失败，请稍后重试',
    },
    retryable: run.status == 'failed' || run.status == 'timeout',
  );
}

final _desktopRemoteIdentifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
const _desktopCompletionModes = <String>{
  'normal',
  'degraded',
  'system_fallback',
  'cancelled',
};

DesktopServiceResult<T> _failure<T>(ApiResult<dynamic> result) {
  final error = result.error;
  return DesktopServiceResult<T>.failure(
    code: error?.code ?? 'DESKTOP_CHAT_REQUEST_FAILED',
    message: error?.message ?? '聊天请求失败',
    retryable: error?.isRetryable ?? false,
  );
}
