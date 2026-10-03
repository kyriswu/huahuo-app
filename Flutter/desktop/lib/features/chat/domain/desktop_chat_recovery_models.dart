import 'desktop_chat_port.dart';

enum DesktopChatTaskLifecycle {
  queued('queued'),
  running('running'),
  succeeded('succeeded'),
  failed('failed');

  const DesktopChatTaskLifecycle(this.wireValue);

  final String wireValue;

  bool get isTerminal => this == succeeded || this == failed;

  static DesktopChatTaskLifecycle? tryParse(Object? value) {
    for (final lifecycle in DesktopChatTaskLifecycle.values) {
      if (lifecycle.wireValue == value) return lifecycle;
    }
    return null;
  }
}

/// Public task state that can be recovered after the desktop foreground app is
/// restarted. The accepted turn is retained so a legacy task-only response can
/// be reconciled against the exact user message.
final class DesktopChatPendingTask {
  const DesktopChatPendingTask({
    required this.taskKey,
    required this.acceptedReply,
    required this.lifecycle,
    required this.createdAt,
    required this.updatedAt,
    this.errorCode,
  });

  final String taskKey;
  final DesktopChatReply acceptedReply;
  final DesktopChatTaskLifecycle lifecycle;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? errorCode;

  String get threadId => acceptedReply.userMessage.threadId;

  bool get isTerminal => lifecycle.isTerminal;

  DesktopChatPendingTask copyWith({
    DesktopChatReply? acceptedReply,
    DesktopChatTaskLifecycle? lifecycle,
    DateTime? updatedAt,
    String? errorCode,
    bool clearErrorCode = false,
  }) {
    return DesktopChatPendingTask(
      taskKey: taskKey,
      acceptedReply: acceptedReply ?? this.acceptedReply,
      lifecycle: lifecycle ?? this.lifecycle,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      errorCode: clearErrorCode ? null : errorCode ?? this.errorCode,
    );
  }
}

/// The only persisted desktop Chat data. Credentials, playback addresses,
/// internal Agent selection, and local file paths are intentionally absent.
final class DesktopChatSessionSnapshot {
  DesktopChatSessionSnapshot({
    Iterable<DesktopChatThread> threads = const <DesktopChatThread>[],
    Map<String, Iterable<DesktopChatMessage>> messagesByThread =
        const <String, Iterable<DesktopChatMessage>>{},
    this.activeThreadId,
    Iterable<DesktopChatPendingTask> tasks = const <DesktopChatPendingTask>[],
  }) : threads = List<DesktopChatThread>.unmodifiable(threads),
       messagesByThread = Map<String, List<DesktopChatMessage>>.unmodifiable(
         <String, List<DesktopChatMessage>>{
           for (final entry in messagesByThread.entries)
             entry.key: List<DesktopChatMessage>.unmodifiable(entry.value),
         },
       ),
       tasks = List<DesktopChatPendingTask>.unmodifiable(tasks);

  const DesktopChatSessionSnapshot.empty()
    : threads = const <DesktopChatThread>[],
      messagesByThread = const <String, List<DesktopChatMessage>>{},
      activeThreadId = null,
      tasks = const <DesktopChatPendingTask>[];

  final List<DesktopChatThread> threads;
  final Map<String, List<DesktopChatMessage>> messagesByThread;
  final String? activeThreadId;
  final List<DesktopChatPendingTask> tasks;

  DesktopChatThreadDetail? detailFor(String threadId) {
    DesktopChatThread? thread;
    for (final candidate in threads) {
      if (candidate.threadId == threadId) {
        thread = candidate;
        break;
      }
    }
    final messages = messagesByThread[threadId];
    if (thread == null || messages == null) return null;
    return DesktopChatThreadDetail(thread: thread, messages: messages);
  }

  DesktopChatSessionSnapshot copyWith({
    Iterable<DesktopChatThread>? threads,
    Map<String, Iterable<DesktopChatMessage>>? messagesByThread,
    String? activeThreadId,
    bool clearActiveThreadId = false,
    Iterable<DesktopChatPendingTask>? tasks,
  }) {
    return DesktopChatSessionSnapshot(
      threads: threads ?? this.threads,
      messagesByThread: messagesByThread ?? this.messagesByThread,
      activeThreadId: clearActiveThreadId
          ? null
          : activeThreadId ?? this.activeThreadId,
      tasks: tasks ?? this.tasks,
    );
  }
}

abstract interface class DesktopChatRecoveryStore {
  Future<DesktopChatSessionSnapshot> load({
    required String userId,
    required String workspaceId,
  });

  Future<void> save({
    required String userId,
    required String workspaceId,
    required DesktopChatSessionSnapshot snapshot,
  });

  Future<void> clear({required String userId, required String workspaceId});
}

final class UnavailableDesktopChatRecoveryStore
    implements DesktopChatRecoveryStore {
  const UnavailableDesktopChatRecoveryStore();

  @override
  Future<void> clear({required String userId, required String workspaceId}) =>
      Future<void>.value();

  @override
  Future<DesktopChatSessionSnapshot> load({
    required String userId,
    required String workspaceId,
  }) => Future<DesktopChatSessionSnapshot>.value(
    const DesktopChatSessionSnapshot.empty(),
  );

  @override
  Future<void> save({
    required String userId,
    required String workspaceId,
    required DesktopChatSessionSnapshot snapshot,
  }) => Future<void>.value();
}
