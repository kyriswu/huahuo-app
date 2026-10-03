import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_chat_port.dart';
import '../domain/desktop_chat_recovery_models.dart';

/// Foreground-only task recovery for desktop Chat. System-delivery reliability
/// remains server-owned; this tracker resumes from durable public thread state
/// whenever the desktop application is running again.
final class DesktopChatTaskTracker extends ChangeNotifier {
  DesktopChatTaskTracker({
    required DesktopChatPort chatPort,
    required DesktopChatRecoveryStore store,
    this.retryDelay = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _chatPort = chatPort,
       _store = store,
       _now = now ?? DateTime.now;

  final DesktopChatPort _chatPort;
  final DesktopChatRecoveryStore _store;
  final Duration retryDelay;
  final DateTime Function() _now;
  DesktopChatSessionSnapshot _snapshot =
      const DesktopChatSessionSnapshot.empty();
  String? _userId;
  String? _workspaceId;
  int _generation = 0;
  final Set<String> _resolvingTaskKeys = <String>{};
  Future<void> _writes = Future<void>.value();
  bool _disposed = false;

  DesktopChatSessionSnapshot get snapshot => _snapshot;

  List<DesktopChatPendingTask> get tasks => _snapshot.tasks;

  List<DesktopChatPendingTask> tasksForThread(String threadId) => _snapshot
      .tasks
      .where((task) => task.threadId == threadId)
      .toList(growable: false);

  int get activeTaskCount =>
      _snapshot.tasks.where((task) => !task.isTerminal).length;

  DesktopChatThreadDetail? detailFor(String threadId) =>
      _snapshot.detailFor(threadId);

  Future<void> bindAccount({
    required String userId,
    required String workspaceId,
  }) async {
    final safeUserId = _safeIdentifier(userId);
    final safeWorkspaceId = _safeIdentifier(workspaceId);
    if (safeUserId == null || safeWorkspaceId == null) {
      await clearCurrentAccount(deletePersisted: false);
      return;
    }
    final generation = ++_generation;
    _userId = safeUserId;
    _workspaceId = safeWorkspaceId;
    final restored = await _store.load(
      userId: safeUserId,
      workspaceId: safeWorkspaceId,
    );
    if (_disposed || generation != _generation) return;
    _snapshot = restored;
    notifyListeners();
    for (final task in restored.tasks) {
      if (!task.isTerminal) unawaited(_resolve(task.taskKey, generation));
    }
  }

  Future<void> clearCurrentAccount({bool deletePersisted = true}) async {
    final userId = _userId;
    final workspaceId = _workspaceId;
    _generation += 1;
    _resolvingTaskKeys.clear();
    _userId = null;
    _workspaceId = null;
    _snapshot = const DesktopChatSessionSnapshot.empty();
    if (!_disposed) notifyListeners();
    if (deletePersisted && userId != null && workspaceId != null) {
      try {
        await _store.clear(userId: userId, workspaceId: workspaceId);
      } on Object {
        // Sign-out should not be blocked by a cache-directory failure.
      }
    }
  }

  Future<void> updateThreads(Iterable<DesktopChatThread> threads) async {
    final incoming = <String, DesktopChatThread>{
      for (final thread in threads) thread.threadId: thread,
    };
    final merged = <DesktopChatThread>[];
    final retainedIds = <String>{};
    for (final thread in _snapshot.threads) {
      final replacement = incoming.remove(thread.threadId);
      merged.add(replacement ?? thread);
      retainedIds.add(thread.threadId);
    }
    for (final thread in incoming.values) {
      if (retainedIds.add(thread.threadId)) merged.add(thread);
    }
    _snapshot = _snapshot.copyWith(threads: merged);
    await _notifyAndPersist();
  }

  Future<void> recordThreadDetail(
    DesktopChatThreadDetail detail, {
    bool activate = false,
  }) async {
    final existingThread = _threadFor(detail.thread.threadId);
    final mergedThread = DesktopChatThread(
      threadId: detail.thread.threadId,
      title: detail.thread.title == '未命名会话' && existingThread != null
          ? existingThread.title
          : detail.thread.title,
      updatedAt: detail.thread.updatedAt ?? existingThread?.updatedAt,
      agentProfileId:
          detail.thread.agentProfileId ?? existingThread?.agentProfileId,
      activeRuns: detail.thread.activeRuns.isEmpty && existingThread != null
          ? existingThread.activeRuns
          : detail.thread.activeRuns,
    );
    final messagesByThread = <String, Iterable<DesktopChatMessage>>{
      ..._snapshot.messagesByThread,
      mergedThread.threadId: _mergeMessages(
        _snapshot.messagesByThread[mergedThread.threadId] ??
            const <DesktopChatMessage>[],
        detail.messages,
      ),
    };
    _snapshot = _snapshot.copyWith(
      threads: _upsertThread(_snapshot.threads, mergedThread),
      messagesByThread: messagesByThread,
      activeThreadId: activate ? mergedThread.threadId : null,
      tasks: _snapshot.tasks,
    );
    await _notifyAndPersist();
  }

  Future<void> setActiveThread(String? threadId) async {
    final normalized = threadId == null ? null : _safeIdentifier(threadId);
    if (normalized != null &&
        !_snapshot.threads.any((thread) => thread.threadId == normalized)) {
      return;
    }
    _snapshot = _snapshot.copyWith(
      activeThreadId: normalized,
      clearActiveThreadId: normalized == null,
    );
    await _notifyAndPersist();
  }

  Future<void> registerAccepted(DesktopChatReply accepted) async {
    final threadId = _safeIdentifier(accepted.userMessage.threadId);
    final userMessageId = _safeIdentifier(accepted.userMessage.messageId);
    if (threadId == null || userMessageId == null) return;
    final existingThread = _threadFor(threadId);
    final thread =
        existingThread ??
        DesktopChatThread(
          threadId: threadId,
          title: _threadTitleFromText(accepted.userMessage.text),
        );
    final taskKey = _taskKey(accepted);
    final activeRuns = <DesktopChatActiveRun>[...thread.activeRuns];
    final agentRunId = accepted.agentRunId;
    if (agentRunId != null &&
        !activeRuns.any((run) => run.agentRunId == agentRunId)) {
      activeRuns.add(
        DesktopChatActiveRun(agentRunId: agentRunId, status: 'running'),
      );
    }
    final trackedThread = DesktopChatThread(
      threadId: thread.threadId,
      title: thread.title,
      updatedAt: _now().toUtc(),
      agentProfileId: thread.agentProfileId,
      activeRuns: activeRuns,
    );
    final messagesByThread = <String, Iterable<DesktopChatMessage>>{
      ..._snapshot.messagesByThread,
      threadId: _mergeMessages(
        _snapshot.messagesByThread[threadId] ?? const <DesktopChatMessage>[],
        <DesktopChatMessage>[
          accepted.userMessage,
          if (accepted.assistantMessage != null) accepted.assistantMessage!,
        ],
      ),
    };
    var tasks = _snapshot.tasks;
    if (taskKey != null && accepted.assistantMessage == null) {
      final task = DesktopChatPendingTask(
        taskKey: taskKey,
        acceptedReply: accepted,
        lifecycle: DesktopChatTaskLifecycle.queued,
        createdAt: _now().toUtc(),
        updatedAt: _now().toUtc(),
      );
      tasks = _replaceTask(tasks, task);
    }
    _snapshot = _snapshot.copyWith(
      threads: _upsertThread(_snapshot.threads, trackedThread),
      messagesByThread: messagesByThread,
      activeThreadId: threadId,
      tasks: tasks,
    );
    final generation = _generation;
    await _notifyAndPersist();
    if (taskKey != null && accepted.assistantMessage == null) {
      unawaited(_resolve(taskKey, generation));
    }
  }

  Future<void> acknowledgeTerminalTask(String taskKey) async {
    final task = _taskFor(taskKey);
    if (task == null || !task.isTerminal) return;
    _snapshot = _snapshot.copyWith(
      tasks: _snapshot.tasks.where((item) => item.taskKey != taskKey),
    );
    await _notifyAndPersist();
  }

  Future<void> _resolve(String taskKey, int generation) async {
    if (_disposed ||
        generation != _generation ||
        !_resolvingTaskKeys.add(taskKey)) {
      return;
    }
    try {
      final task = _taskFor(taskKey);
      if (task == null || task.isTerminal) return;
      await _replaceTaskLifecycle(
        taskKey,
        DesktopChatTaskLifecycle.running,
        clearError: true,
      );
      final result = await _resolveReply(task.acceptedReply);
      if (_disposed || generation != _generation) return;
      final current = _taskFor(taskKey);
      if (current == null || current.isTerminal) return;
      final reply = result.data;
      if (result.isSuccess && reply?.assistantMessage != null) {
        await _completeTask(taskKey, reply!);
        return;
      }
      if (result.retryable) {
        await _replaceTaskLifecycle(
          taskKey,
          DesktopChatTaskLifecycle.running,
          errorCode: result.code,
        );
        unawaited(_retryLater(taskKey, generation));
        return;
      }
      await _replaceTaskLifecycle(
        taskKey,
        DesktopChatTaskLifecycle.failed,
        errorCode: result.code,
      );
    } finally {
      _resolvingTaskKeys.remove(taskKey);
    }
  }

  Future<void> _retryLater(String taskKey, int generation) async {
    await Future<void>.delayed(
      retryDelay <= Duration.zero ? Duration.zero : retryDelay,
    );
    if (_disposed || generation != _generation) return;
    await _resolve(taskKey, generation);
  }

  Future<DesktopServiceResult<DesktopChatReply>> _resolveReply(
    DesktopChatReply accepted,
  ) async {
    final resolver = _chatPort is DesktopChatTaskResolutionPort
        ? _chatPort as DesktopChatTaskResolutionPort
        : null;
    if (resolver != null) return resolver.resolveAcceptedReply(accepted);
    final detail = await _chatPort.getThreadDetail(
      accepted.userMessage.threadId,
    );
    if (!detail.isSuccess || detail.data == null) {
      return DesktopServiceResult<DesktopChatReply>.failure(
        code: detail.code,
        message: detail.message,
        retryable: detail.retryable,
      );
    }
    final assistant = _assistantAfter(
      detail.data!.messages,
      userMessageId: accepted.userMessage.messageId,
    );
    if (assistant == null) {
      return const DesktopServiceResult<DesktopChatReply>.failure(
        code: 'DESKTOP_CHAT_REPLY_PENDING',
        message: 'AI 回复仍在生成中',
        retryable: true,
      );
    }
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

  Future<void> _completeTask(String taskKey, DesktopChatReply reply) async {
    final task = _taskFor(taskKey);
    if (task == null || reply.assistantMessage == null) return;
    final thread =
        _threadFor(task.threadId) ??
        DesktopChatThread(
          threadId: task.threadId,
          title: _threadTitleFromText(reply.userMessage.text),
        );
    final completedRunId = reply.agentRunId ?? task.acceptedReply.agentRunId;
    final refreshedThread = DesktopChatThread(
      threadId: thread.threadId,
      title: thread.title,
      updatedAt: _now().toUtc(),
      agentProfileId: thread.agentProfileId,
      activeRuns: thread.activeRuns
          .where((run) => run.agentRunId != completedRunId)
          .toList(growable: false),
    );
    _snapshot = _snapshot.copyWith(
      threads: _upsertThread(_snapshot.threads, refreshedThread),
      messagesByThread: <String, Iterable<DesktopChatMessage>>{
        ..._snapshot.messagesByThread,
        task.threadId: _mergeMessages(
          _snapshot.messagesByThread[task.threadId] ??
              const <DesktopChatMessage>[],
          <DesktopChatMessage>[reply.userMessage, reply.assistantMessage!],
        ),
      },
      tasks: _replaceTask(
        _snapshot.tasks,
        task.copyWith(
          acceptedReply: reply,
          lifecycle: DesktopChatTaskLifecycle.succeeded,
          updatedAt: _now().toUtc(),
          clearErrorCode: true,
        ),
      ),
    );
    await _notifyAndPersist();
  }

  Future<void> _replaceTaskLifecycle(
    String taskKey,
    DesktopChatTaskLifecycle lifecycle, {
    String? errorCode,
    bool clearError = false,
  }) async {
    final task = _taskFor(taskKey);
    if (task == null) return;
    _snapshot = _snapshot.copyWith(
      tasks: _replaceTask(
        _snapshot.tasks,
        task.copyWith(
          lifecycle: lifecycle,
          updatedAt: _now().toUtc(),
          errorCode: errorCode,
          clearErrorCode: clearError,
        ),
      ),
    );
    await _notifyAndPersist();
  }

  DesktopChatThread? _threadFor(String threadId) {
    for (final thread in _snapshot.threads) {
      if (thread.threadId == threadId) return thread;
    }
    return null;
  }

  DesktopChatPendingTask? _taskFor(String taskKey) {
    for (final task in _snapshot.tasks) {
      if (task.taskKey == taskKey) return task;
    }
    return null;
  }

  Future<void> _notifyAndPersist() async {
    if (!_disposed) notifyListeners();
    final userId = _userId;
    final workspaceId = _workspaceId;
    if (userId == null || workspaceId == null) return;
    final snapshot = _snapshot;
    _writes = _writes.catchError((Object _) {}).then<void>((_) async {
      try {
        await _store.save(
          userId: userId,
          workspaceId: workspaceId,
          snapshot: snapshot,
        );
      } on Object {
        // Cache writes never invalidate a visible public Chat state.
      }
    });
    await _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _resolvingTaskKeys.clear();
    super.dispose();
  }
}

List<DesktopChatThread> _upsertThread(
  Iterable<DesktopChatThread> threads,
  DesktopChatThread replacement,
) {
  final result = <DesktopChatThread>[];
  var replaced = false;
  for (final thread in threads) {
    if (thread.threadId == replacement.threadId) {
      result.add(replacement);
      replaced = true;
    } else {
      result.add(thread);
    }
  }
  if (!replaced) result.insert(0, replacement);
  return result;
}

List<DesktopChatMessage> _mergeMessages(
  Iterable<DesktopChatMessage> existing,
  Iterable<DesktopChatMessage> incoming,
) {
  final messages = <DesktopChatMessage>[];
  final indexes = <String, int>{};
  for (final message in <DesktopChatMessage>[...existing, ...incoming]) {
    final index = indexes[message.messageId];
    if (index == null) {
      indexes[message.messageId] = messages.length;
      messages.add(message);
    } else {
      messages[index] = message;
    }
  }
  return messages;
}

List<DesktopChatPendingTask> _replaceTask(
  Iterable<DesktopChatPendingTask> tasks,
  DesktopChatPendingTask replacement,
) {
  final result = <DesktopChatPendingTask>[];
  var replaced = false;
  for (final task in tasks) {
    if (task.taskKey == replacement.taskKey) {
      result.add(replacement);
      replaced = true;
    } else {
      result.add(task);
    }
  }
  if (!replaced) result.insert(0, replacement);
  return result;
}

DesktopChatMessage? _assistantAfter(
  Iterable<DesktopChatMessage> messages, {
  required String userMessageId,
}) {
  var foundUser = false;
  for (final message in messages) {
    if (message.messageId == userMessageId && message.role == 'user') {
      foundUser = true;
      continue;
    }
    if (foundUser &&
        message.role == 'assistant' &&
        (message.text.trim().isNotEmpty ||
            message.imageAttachments.isNotEmpty)) {
      return message;
    }
  }
  return null;
}

String? _taskKey(DesktopChatReply reply) {
  final candidate = reply.agentRunId ?? reply.taskId;
  return candidate == null ? null : _safeIdentifier(candidate);
}

String _threadTitleFromText(String value) {
  final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.isEmpty) return '未命名会话';
  return compact.length <= 40 ? compact : '${compact.substring(0, 40)}...';
}

String? _safeIdentifier(String value) {
  final normalized = value.trim();
  return _safeId.hasMatch(normalized) ? normalized : null;
}

final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
