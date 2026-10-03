import 'package:flutter/foundation.dart';

import '../domain/chat_models.dart';

enum ChatTurnPhase {
  settled,
  submittingUser,
  waitingForAssistant,
  streamingAssistant,
  reconcilingAssistant,
  failed,
}

@immutable
final class ChatTurnState {
  const ChatTurnState({
    required this.phase,
    this.userMessageId,
    this.assistantMessageId,
    this.agentRunId,
  });

  const ChatTurnState.settled() : this(phase: ChatTurnPhase.settled);

  final ChatTurnPhase phase;
  final String? userMessageId;
  final String? assistantMessageId;
  final String? agentRunId;

  bool get acceptsUserTurn =>
      phase == ChatTurnPhase.settled || phase == ChatTurnPhase.failed;

  bool get isActive => switch (phase) {
    ChatTurnPhase.submittingUser ||
    ChatTurnPhase.waitingForAssistant ||
    ChatTurnPhase.streamingAssistant ||
    ChatTurnPhase.reconcilingAssistant => true,
    ChatTurnPhase.settled || ChatTurnPhase.failed => false,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatTurnState &&
          phase == other.phase &&
          userMessageId == other.userMessageId &&
          assistantMessageId == other.assistantMessageId &&
          agentRunId == other.agentRunId;

  @override
  int get hashCode =>
      Object.hash(phase, userMessageId, assistantMessageId, agentRunId);
}

abstract final class ChatTurnStateMachine {
  static List<ChatMessage> normalizeTimeline(Iterable<ChatMessage> messages) {
    final byId = <String, _IndexedChatMessage>{};
    var index = 0;
    for (final message in messages) {
      final existing = byId[message.messageId];
      byId[message.messageId] = _IndexedChatMessage(
        message: message,
        index: existing?.index ?? index,
      );
      index += 1;
    }
    final entries = byId.values.toList(growable: false);
    if (entries.every((entry) => entry.message.createdAt != null)) {
      entries.sort((left, right) {
        final timestampOrder = left.message.createdAt!.toUtc().compareTo(
          right.message.createdAt!.toUtc(),
        );
        if (timestampOrder != 0) return timestampOrder;
        final roleOrder = _roleOrder(
          left.message.role,
        ).compareTo(_roleOrder(right.message.role));
        return roleOrder != 0 ? roleOrder : left.index.compareTo(right.index);
      });
    } else {
      entries.sort((left, right) => left.index.compareTo(right.index));
    }

    final ordered = entries.map((entry) => entry.message).toList();
    final firstUserIndex = ordered.indexWhere(
      (message) => message.role == ChatMessageRole.user,
    );
    if (firstUserIndex < 0) {
      return List<ChatMessage>.unmodifiable(ordered);
    }
    final leadingAssistants = <ChatMessage>[
      for (final message in ordered.take(firstUserIndex))
        if (message.role == ChatMessageRole.assistant) message,
    ];
    if (leadingAssistants.isEmpty) {
      return List<ChatMessage>.unmodifiable(ordered);
    }
    return List<ChatMessage>.unmodifiable(<ChatMessage>[
      for (final message in ordered.take(firstUserIndex))
        if (message.role != ChatMessageRole.assistant) message,
      ordered[firstUserIndex],
      ...leadingAssistants,
      ...ordered.skip(firstUserIndex + 1),
    ]);
  }

  static List<ChatMessage> displayTimeline(Iterable<ChatMessage> messages) {
    final normalized = normalizeTimeline(messages);
    if (normalized.any((message) => message.role == ChatMessageRole.user)) {
      return normalized;
    }
    return List<ChatMessage>.unmodifiable(
      normalized.where((message) => message.role != ChatMessageRole.assistant),
    );
  }

  static ChatTurnState reduce({
    required List<ChatMessage> messages,
    required bool assistantExpected,
    required bool terminalReadbackPending,
    required bool turnFailed,
    String? agentRunId,
  }) {
    final latestUserIndex = messages.lastIndexWhere(
      (message) => message.role == ChatMessageRole.user,
    );
    if (latestUserIndex < 0) return const ChatTurnState.settled();

    final user = messages[latestUserIndex];
    final assistantsAfterUser = <ChatMessage>[
      for (final message in messages.skip(latestUserIndex + 1))
        if (message.role == ChatMessageRole.assistant) message,
    ];
    final matchingAssistants = agentRunId == null
        ? assistantsAfterUser
        : assistantsAfterUser
              .where((message) => _belongsToRun(message, agentRunId))
              .toList(growable: false);
    final latestAssistant = matchingAssistants.lastOrNull;
    final resolvedRunId = latestAssistant?.agentRunId ?? agentRunId;

    if (user.localDelivery == ChatLocalDeliveryState.pending) {
      return ChatTurnState(
        phase: ChatTurnPhase.submittingUser,
        userMessageId: user.messageId,
      );
    }
    if (user.localDelivery == ChatLocalDeliveryState.failed) {
      return ChatTurnState(
        phase: ChatTurnPhase.failed,
        userMessageId: user.messageId,
      );
    }
    if (latestAssistant != null && !_isProvisionalAssistant(latestAssistant)) {
      return ChatTurnState(
        phase: ChatTurnPhase.settled,
        userMessageId: user.messageId,
        assistantMessageId: latestAssistant.messageId,
        agentRunId: resolvedRunId,
      );
    }
    if (turnFailed) {
      return ChatTurnState(
        phase: ChatTurnPhase.failed,
        userMessageId: user.messageId,
        assistantMessageId: latestAssistant?.messageId,
        agentRunId: resolvedRunId,
      );
    }
    if (terminalReadbackPending) {
      return ChatTurnState(
        phase: ChatTurnPhase.reconcilingAssistant,
        userMessageId: user.messageId,
        agentRunId: agentRunId,
      );
    }
    if (latestAssistant != null) {
      return ChatTurnState(
        phase: ChatTurnPhase.streamingAssistant,
        userMessageId: user.messageId,
        assistantMessageId: latestAssistant.messageId,
        agentRunId: resolvedRunId,
      );
    }
    if (assistantExpected) {
      return ChatTurnState(
        phase: ChatTurnPhase.waitingForAssistant,
        userMessageId: user.messageId,
        agentRunId: agentRunId,
      );
    }
    return ChatTurnState(
      phase: ChatTurnPhase.settled,
      userMessageId: user.messageId,
    );
  }

  static bool _isProvisionalAssistant(ChatMessage message) =>
      message.status == 'streaming' ||
      message.localDelivery == ChatLocalDeliveryState.pending;

  static bool _belongsToRun(ChatMessage message, String agentRunId) =>
      message.agentRunId == agentRunId;

  static int _roleOrder(ChatMessageRole role) => switch (role) {
    ChatMessageRole.user => 0,
    ChatMessageRole.system => 1,
    ChatMessageRole.assistant => 2,
  };
}

final class _IndexedChatMessage {
  const _IndexedChatMessage({required this.message, required this.index});

  final ChatMessage message;
  final int index;
}
