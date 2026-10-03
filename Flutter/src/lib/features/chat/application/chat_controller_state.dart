import '../../../core/api/api_client.dart';
import 'chat_turn_state_machine.dart';
import '../domain/assistant_runtime.dart';
import '../domain/chat_models.dart';

enum ChatControllerStatus { idle, loading, ready, sending, failed }

final class ChatControllerState {
  const ChatControllerState({
    required this.scene,
    required this.status,
    required this.threads,
    required this.messages,
    this.activeThreadId,
    this.nextCursor,
    this.nextAction = const ChatNextAction.none(),
    this.agentRunStatus,
    this.assistantToolTrace = const <AssistantToolTrace>[],
    this.agentToolTrace = const <AgentRunToolTrace>[],
    this.turnState = const ChatTurnState.settled(),
    this.lastErrorCode,
  });

  factory ChatControllerState.initial(ChatScene scene) {
    return ChatControllerState(
      scene: scene,
      status: ChatControllerStatus.idle,
      threads: const <ChatThread>[],
      messages: const <ChatMessage>[],
    );
  }

  final ChatScene scene;
  final ChatControllerStatus status;
  final List<ChatThread> threads;
  final List<ChatMessage> messages;
  final String? activeThreadId;
  final String? nextCursor;
  final ChatNextAction nextAction;
  final String? agentRunStatus;
  final List<AssistantToolTrace> assistantToolTrace;
  @Deprecated('Use assistantToolTrace.')
  final List<AgentRunToolTrace> agentToolTrace;
  final ChatTurnState turnState;
  final String? lastErrorCode;

  bool get isLoading => status == ChatControllerStatus.loading;
  bool get isSending => status == ChatControllerStatus.sending;
  bool get hasActiveThread => activeThreadId != null;
  bool get canSubmitUserTurn => !isLoading && turnState.acceptsUserTurn;
  bool get isAwaitingAssistant => turnState.isActive;
  List<ChatMessage> get displayMessages =>
      ChatTurnStateMachine.displayTimeline(messages);

  ChatControllerState copyWith({
    ChatControllerStatus? status,
    List<ChatThread>? threads,
    List<ChatMessage>? messages,
    String? activeThreadId,
    bool clearActiveThreadId = false,
    String? nextCursor,
    bool clearNextCursor = false,
    ChatNextAction? nextAction,
    String? agentRunStatus,
    List<AssistantToolTrace>? assistantToolTrace,
    List<AgentRunToolTrace>? agentToolTrace,
    bool clearAgentActivity = false,
    ChatTurnState? turnState,
    String? lastErrorCode,
    bool clearError = false,
  }) {
    return ChatControllerState(
      scene: scene,
      status: status ?? this.status,
      threads: List<ChatThread>.unmodifiable(threads ?? this.threads),
      messages: List<ChatMessage>.unmodifiable(messages ?? this.messages),
      activeThreadId: clearActiveThreadId
          ? null
          : activeThreadId ?? this.activeThreadId,
      nextCursor: clearNextCursor ? null : nextCursor ?? this.nextCursor,
      nextAction: nextAction ?? this.nextAction,
      agentRunStatus: clearAgentActivity
          ? null
          : agentRunStatus ?? this.agentRunStatus,
      assistantToolTrace: List<AssistantToolTrace>.unmodifiable(
        clearAgentActivity
            ? const <AssistantToolTrace>[]
            : assistantToolTrace ?? this.assistantToolTrace,
      ),
      agentToolTrace: List<AgentRunToolTrace>.unmodifiable(
        clearAgentActivity
            ? const <AgentRunToolTrace>[]
            : agentToolTrace ?? this.agentToolTrace,
      ),
      turnState: turnState ?? this.turnState,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
    );
  }
}

enum ChatRouteScene { workAi, feedAi }

final class ChatRouteController {
  const ChatRouteController();

  ChatRouteState resolve({
    required ChatRouteScene scene,
    required String threadId,
  }) {
    final safeThreadId = _isSafeThreadId(threadId) ? threadId : null;
    return ChatRouteState(
      scene: scene,
      threadId: safeThreadId,
      isSafe: safeThreadId != null,
    );
  }
}

bool _isSafeThreadId(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
}

final class ChatRouteState {
  const ChatRouteState({
    required this.scene,
    required this.threadId,
    required this.isSafe,
  });

  final ChatRouteScene scene;
  final String? threadId;
  final bool isSafe;
}
