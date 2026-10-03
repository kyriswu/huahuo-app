import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../domain/assistant_runtime.dart';
import 'chat_run_tracker.dart';
import '../domain/chat_models.dart';

abstract final class ChatControllerPolicies {
  static const maxTextLength = 4000;
  static const maxVoiceDurationSeconds = 24 * 60 * 60;
  static const _deepPositioningTransportMarker = '【深度定位对话】';
  static const _deepPositioningUserMarkers = <String>['\n\n用户回答：', '\n\n用户问题：'];
  static const _deepPositioningSafePlaceholder = '已提交一条定位回答';

  static List<ChatThread> sortThreads(Iterable<ChatThread> threads) {
    final deduplicated = <String, ChatThread>{
      for (final thread in threads) thread.threadId: thread,
    }.values.toList();
    deduplicated.sort((left, right) {
      final leftValue = left.updatedAt?.microsecondsSinceEpoch ?? 0;
      final rightValue = right.updatedAt?.microsecondsSinceEpoch ?? 0;
      return rightValue.compareTo(leftValue);
    });
    return List<ChatThread>.unmodifiable(deduplicated);
  }

  static List<ChatThread> upsertThread(
    List<ChatThread> threads,
    ChatThread thread,
  ) {
    final existing = threads
        .where((current) => current.threadId == thread.threadId)
        .firstOrNull;
    final merged = existing == null
        ? thread
        : thread.copyWith(
            updatedAt: _latestTimestamp(existing.updatedAt, thread.updatedAt),
          );
    return sortThreads(<ChatThread>[
      for (final current in threads)
        if (current.threadId != thread.threadId) current,
      merged,
    ]);
  }

  static List<ChatThread> withFirstUserMessage(
    List<ChatThread> threads,
    String threadId,
    String content, {
    DateTime? updatedAt,
  }) {
    return sortThreads(<ChatThread>[
      for (final thread in threads)
        if (thread.threadId == threadId)
          thread.copyWith(
            firstUserMessageText:
                normalizeChatThreadFirstMessage(thread.firstUserMessageText) ==
                    null
                ? content
                : thread.firstUserMessageText,
            updatedAt: _latestTimestamp(thread.updatedAt, updatedAt),
          )
        else
          thread,
    ]);
  }

  static DateTime? _latestTimestamp(DateTime? left, DateTime? right) {
    if (left == null) return right;
    if (right == null) return left;
    return left.isAfter(right) ? left : right;
  }

  static bool hasUnansweredUserTurn(List<ChatMessage> messages) {
    var awaitingAssistant = false;
    for (final message in messages) {
      if (message.role == ChatMessageRole.user) {
        awaitingAssistant = true;
      } else if (message.role == ChatMessageRole.assistant) {
        awaitingAssistant = false;
      }
    }
    return awaitingAssistant;
  }

  static String? firstUserMessageText(Iterable<ChatMessage> messages) {
    for (final message in messages) {
      if (message.role != ChatMessageRole.user) continue;
      final text = message.visibleText?.trim();
      if (text != null && text.isNotEmpty) return text;
      if (message.contentType == ChatMessageContentType.voice) return '语音消息';
    }
    return null;
  }

  static List<ChatMessage> mergeServerAndLocalMessages(
    List<ChatMessage> serverMessages,
    List<ChatMessage> currentMessages,
    String threadId,
    ChatScene scene, {
    Map<String, String> terminalAssistantMessageIdsByRunId =
        const <String, String>{},
  }) {
    // The public detail projection can lag an accepted user turn or Assistant
    // writeback. Chat has no message-deletion contract, so retain the bounded
    // cache and let any live message with the same ID replace it. Older
    // acknowledgement rows can use a different ID for the same user turn.
    final runIdByAssistantMessageId = _uniqueRunIdByAssistantMessageId(
      terminalAssistantMessageIdsByRunId,
    );
    final canonicalServerMessages = <ChatMessage>[
      for (final message in serverMessages)
        if (message.role == ChatMessageRole.assistant &&
            message.agentRunId == null &&
            runIdByAssistantMessageId.containsKey(message.messageId))
          message.copyWith(
            agentRunId: runIdByAssistantMessageId[message.messageId],
          )
        else
          message,
    ];
    final durableAssistantRunIds = <String>{};
    for (final message in canonicalServerMessages) {
      final runId = _messageRunIdentity(message);
      if (message.role != ChatMessageRole.assistant) continue;
      if (runId != null) durableAssistantRunIds.add(runId);
    }
    final cached = <ChatMessage>[
      for (final message in currentMessages)
        if (message.threadId == threadId &&
            message.scene == scene &&
            _shouldRetainCachedMessage(message, durableAssistantRunIds))
          message,
    ];
    final cachedIds = cached.map((message) => message.messageId).toSet();
    final serverIds = canonicalServerMessages
        .map((message) => message.messageId)
        .toSet();
    final unmatchedServerUserTurns = <String, int>{};
    final cachedAssetReferencesById = <String, List<ChatAssetReference>>{
      for (final message in cached)
        if (message.assetReferences.isNotEmpty)
          message.messageId: message.assetReferences,
    };
    final cachedAssetReferencesByTurn =
        <String, List<List<ChatAssetReference>>>{};
    for (final message in cached) {
      if (message.assetReferences.isEmpty ||
          serverIds.contains(message.messageId)) {
        continue;
      }
      final fingerprint = _userTurnFingerprint(message);
      if (fingerprint == null) continue;
      cachedAssetReferencesByTurn
          .putIfAbsent(fingerprint, () => <List<ChatAssetReference>>[])
          .add(message.assetReferences);
    }
    for (final message in canonicalServerMessages) {
      if (cachedIds.contains(message.messageId)) continue;
      final fingerprint = _confirmedUserTurnFingerprint(message);
      if (fingerprint == null) continue;
      unmatchedServerUserTurns.update(
        fingerprint,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }

    final merged = <String, ChatMessage>{};
    for (final message in cached) {
      if (serverIds.contains(message.messageId)) continue;
      final fingerprint = _confirmedUserTurnFingerprint(message);
      final matchingServerCount = fingerprint == null
          ? null
          : unmatchedServerUserTurns[fingerprint];
      if (matchingServerCount != null && matchingServerCount > 0) {
        unmatchedServerUserTurns[fingerprint!] = matchingServerCount - 1;
        continue;
      }
      merged[message.messageId] = message;
    }
    for (final message in canonicalServerMessages) {
      var projected = message;
      if (message.role == ChatMessageRole.user &&
          message.assetReferences.isEmpty) {
        final exact = cachedAssetReferencesById[message.messageId];
        final fingerprint = _userTurnFingerprint(message);
        final candidates = fingerprint == null
            ? null
            : cachedAssetReferencesByTurn[fingerprint];
        final retained =
            exact ??
            (candidates == null || candidates.isEmpty
                ? null
                : candidates.removeAt(0));
        if (retained != null) {
          projected = message.copyWith(assetReferences: retained);
        }
      }
      merged[message.messageId] = projected;
    }
    return List<ChatMessage>.unmodifiable(merged.values);
  }

  static Map<String, String> _uniqueRunIdByAssistantMessageId(
    Map<String, String> assistantMessageIdsByRunId,
  ) {
    final result = <String, String>{};
    final ambiguousMessageIds = <String>{};
    for (final entry in assistantMessageIdsByRunId.entries) {
      final runId = entry.key.trim();
      final messageId = entry.value.trim();
      if (runId.isEmpty ||
          messageId.isEmpty ||
          ambiguousMessageIds.contains(messageId)) {
        continue;
      }
      final existingRunId = result[messageId];
      if (existingRunId == null || existingRunId == runId) {
        result[messageId] = runId;
      } else {
        result.remove(messageId);
        ambiguousMessageIds.add(messageId);
      }
    }
    return result;
  }

  static String? _confirmedUserTurnFingerprint(ChatMessage message) {
    if (message.localDelivery != ChatLocalDeliveryState.server ||
        message.role != ChatMessageRole.user) {
      return null;
    }
    return _userTurnFingerprint(message);
  }

  static String? _userTurnFingerprint(ChatMessage message) {
    if (message.role != ChatMessageRole.user) return null;
    var visibleText = message.visibleText?.trim() ?? '';
    final imageIds =
        message.imageAttachments
            .map((attachment) => attachment.resourceId)
            .toList(growable: false)
          ..sort();
    final resourceIds =
        message.resourceAttachments
            .map((attachment) => attachment.resourceId)
            .toList(growable: false)
          ..sort();
    if ((imageIds.isNotEmpty || resourceIds.isNotEmpty) &&
        (visibleText == '已发送 ${imageIds.length} 张图片' ||
            RegExp(r'^已发送 \d+ 项资料$').hasMatch(visibleText))) {
      visibleText = '';
    }
    if (visibleText.isEmpty && imageIds.isEmpty && resourceIds.isEmpty) {
      return null;
    }
    return '${message.contentType.apiValue}:$visibleText:'
        'images=${imageIds.join(',')}:resources=${resourceIds.join(',')}';
  }

  static List<ChatMessage> dedupeMessages(List<ChatMessage> messages) {
    final byId = <String, ChatMessage>{};
    for (final message in messages) {
      byId[message.messageId] = message;
    }
    return List<ChatMessage>.unmodifiable(byId.values);
  }

  static bool isAgentProgressMessage(ChatMessage message) =>
      message.role == ChatMessageRole.assistant &&
      message.status == 'streaming' &&
      message.messageId.startsWith('stream-');

  static String deepPositioningDisplayContent(String transportContent) {
    final normalized = transportContent.trim();
    if (!normalized.contains(_deepPositioningTransportMarker)) {
      return normalized.length <= maxTextLength
          ? normalized
          : normalized.substring(0, maxTextLength);
    }
    var markerIndex = -1;
    var markerLength = 0;
    for (final marker in _deepPositioningUserMarkers) {
      final index = normalized.lastIndexOf(marker);
      if (index > markerIndex) {
        markerIndex = index;
        markerLength = marker.length;
      }
    }
    if (markerIndex < 0) return _deepPositioningSafePlaceholder;
    final answer = normalized.substring(markerIndex + markerLength).trim();
    if (answer.isEmpty || answer.contains(_deepPositioningTransportMarker)) {
      return _deepPositioningSafePlaceholder;
    }
    return answer.length <= maxTextLength
        ? answer
        : answer.substring(0, maxTextLength);
  }

  static String? agentRunTerminalFailureCode(AgentRunSnapshot run) {
    if (!run.isTerminal) return null;
    if (run.status == 'failed') {
      return _safeAgentRunPublicFailureCode(run.error?.code) ??
          'CHAT_AGENT_RUN_FAILED';
    }
    if (run.status == 'timeout') return 'CHAT_AGENT_RUN_TIMEOUT';
    if (run.status == 'orphaned') return 'CHAT_AGENT_RUN_ORPHANED';
    if (run.status == 'cancelled' || run.completionMode == 'cancelled') {
      return 'CHAT_AGENT_RUN_CANCELLED';
    }
    if (run.status != 'succeeded') return 'CHAT_AGENT_RUN_RESULT_INVALID';
    return switch (run.completionMode) {
      'normal' => null,
      'degraded' => 'CHAT_AGENT_RUN_DEGRADED',
      'system_fallback' => 'CHAT_AGENT_RUN_SYSTEM_FALLBACK',
      _ => 'CHAT_AGENT_RUN_RESULT_INVALID',
    };
  }

  /// Applies the same public failure semantics to the provider-neutral run
  /// projection. Provider adapters must map their wire status before this
  /// policy is called.
  static String? assistantRunTerminalFailureCode(
    AssistantRunSnapshot run,
  ) {
    if (!run.isTerminal) return null;
    if (run.status == AssistantRunStatus.failed) {
      return _safeAgentRunPublicFailureCode(run.failure?.code) ??
          'CHAT_AGENT_RUN_FAILED';
    }
    if (run.status == AssistantRunStatus.timedOut) {
      return 'CHAT_AGENT_RUN_TIMEOUT';
    }
    if (run.status == AssistantRunStatus.orphaned) {
      return 'CHAT_AGENT_RUN_ORPHANED';
    }
    if (run.status == AssistantRunStatus.cancelled ||
        run.completionQuality == AssistantCompletionQuality.cancelled) {
      return 'CHAT_AGENT_RUN_CANCELLED';
    }
    if (run.status != AssistantRunStatus.succeeded) {
      return 'CHAT_AGENT_RUN_RESULT_INVALID';
    }
    return switch (run.completionQuality) {
      AssistantCompletionQuality.normal => null,
      AssistantCompletionQuality.degraded => 'CHAT_AGENT_RUN_DEGRADED',
      AssistantCompletionQuality.fallback => 'CHAT_AGENT_RUN_SYSTEM_FALLBACK',
      AssistantCompletionQuality.cancelled => 'CHAT_AGENT_RUN_CANCELLED',
      AssistantCompletionQuality.unknown => 'CHAT_AGENT_RUN_RESULT_INVALID',
    };
  }

  static String? chatRunCompletionFailureCode(ChatRunCompletion completion) {
    if (completion.status == 'failed') {
      return _safeAgentRunPublicFailureCode(completion.failureCode) ??
          'CHAT_AGENT_RUN_FAILED';
    }
    if (completion.status == 'timeout') return 'CHAT_AGENT_RUN_TIMEOUT';
    if (completion.status == 'orphaned') return 'CHAT_AGENT_RUN_ORPHANED';
    if (completion.status == 'cancelled' ||
        completion.completionMode == 'cancelled') {
      return 'CHAT_AGENT_RUN_CANCELLED';
    }
    if (completion.status != 'succeeded') {
      return 'CHAT_AGENT_RUN_RESULT_INVALID';
    }
    return switch (completion.completionMode) {
      'normal' => null,
      'degraded' => 'CHAT_AGENT_RUN_DEGRADED',
      'system_fallback' => 'CHAT_AGENT_RUN_SYSTEM_FALLBACK',
      _ => 'CHAT_AGENT_RUN_RESULT_INVALID',
    };
  }

  static void debugTerminalReadback(
    String stage,
    ChatRunCompletion completion, {
    int? attempt,
    String? code,
  }) {
    if (!kDebugMode) return;
    debugPrint(
      '[ChatTransport] operation=terminal-readback stage=$stage '
      'run=${completion.agentRunId} thread=${completion.threadId} '
      'status=${completion.status} attempt=${attempt ?? '-'} '
      'code=${code ?? '-'}',
    );
  }

  static String? _safeAgentRunPublicFailureCode(String? value) {
    final code = value?.trim();
    return code != null && isSafeChatIdentifier(code) ? code : null;
  }

  static void debugTransport<T>(String operation, ApiResult<T> result) {
    if (!kDebugMode) return;
    debugPrint(
      '[ChatTransport] operation=$operation ok=${result.ok} '
      'status=${result.status ?? '-'} code=${result.error?.code ?? '-'} '
      'trace=${result.traceId ?? '-'}',
    );
  }

  static void debugAgentRun(AgentRunSnapshot run) {
    if (!kDebugMode) return;
    debugPrint(
      '[ChatTransport] operation=agent-run-terminal '
      'run=${run.agentRunId} status=${run.status} '
      'completion=${run.completionMode ?? '-'} '
      'code=${run.error?.code ?? '-'}',
    );
  }

  static void debugAcceptedAgentRun(ChatNextAction action) {
    if (!kDebugMode || action.type != ChatNextActionType.pollAgentRun) return;
    final agentRunId = action.agentRunId;
    if (agentRunId == null) return;
    debugPrint('[ChatTransport] operation=agent-run-accepted run=$agentRunId');
  }

  static void debugPollFailure(
    ChatNextAction action,
    String code,
    AppFailure? failure,
  ) {
    if (!kDebugMode) return;
    const safeReasons = <String>{
      'notObject',
      'missingSuccess',
      'missingData',
      'invalidData',
      'missingError',
    };
    final rawReason = failure?.metadata['reason'];
    final reason = rawReason is String && safeReasons.contains(rawReason)
        ? rawReason
        : '-';
    debugPrint(
      '[ChatTransport] operation=poll-failure action=${action.type.name} '
      'code=$code reason=$reason',
    );
  }

  static bool awaitsAssistant(ChatNextAction action) =>
      action.type == ChatNextActionType.pollTask ||
      action.type == ChatNextActionType.pollAgentRun ||
      action.type == ChatNextActionType.pollThread;

  static bool isAudioMimeType(String value) =>
      RegExp(r'^audio/[A-Za-z0-9.+-]+$').hasMatch(value.trim());
}

String? _messageRunIdentity(ChatMessage message) {
  final agentRunId = message.agentRunId?.trim();
  return agentRunId == null || agentRunId.isEmpty ? null : agentRunId;
}

bool _shouldRetainCachedMessage(
  ChatMessage message,
  Set<String> durableAssistantRunIds,
) {
  if (!ChatControllerPolicies.isAgentProgressMessage(message)) return true;
  final runId = _messageRunIdentity(message);
  return runId != null && !durableAssistantRunIds.contains(runId);
}
