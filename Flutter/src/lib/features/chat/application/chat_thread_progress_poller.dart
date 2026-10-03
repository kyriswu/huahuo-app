import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../domain/assistant_runtime.dart';

typedef ChatThreadProgressAttempt = Future<bool> Function();

final class ChatThreadProgressDelta {
  const ChatThreadProgressDelta({required this.text, required this.replace});

  final String text;
  final bool replace;
}

final class ChatThreadProgressBatch {
  const ChatThreadProgressBatch({
    required this.nextSequence,
    required this.deltas,
  });

  final int nextSequence;
  final List<ChatThreadProgressDelta> deltas;
}

Future<ChatThreadProgressBatch?> readAssistantThreadProgress({
  required AssistantThreadProgressPort progress,
  required String conversationId,
  required AssistantRunHandle runHandle,
  required int afterSequence,
}) async {
  final result = await progress.readProgress(
    conversationId: conversationId,
    afterSequence: afterSequence,
  );
  final page = result.data;
  if (!result.ok || page == null || page.conversationId != conversationId) {
    return null;
  }
  var cursor = afterSequence;
  final deltas = <ChatThreadProgressDelta>[];
  for (final event in page.events) {
    if (event.sequence <= cursor) continue;
    cursor = event.sequence;
    if (event.runHandle != runHandle.value ||
        event.type != AssistantProgressEventType.draftDelta ||
        event.deltaText == null) {
      continue;
    }
    deltas.add(
      ChatThreadProgressDelta(text: event.deltaText!, replace: event.replace),
    );
  }
  return ChatThreadProgressBatch(
    nextSequence: page.nextSequence > cursor ? page.nextSequence : cursor,
    deltas: List<ChatThreadProgressDelta>.unmodifiable(deltas),
  );
}

/// Owns shared scheduling for one controller's thread-progress fallback.
final class ChatThreadProgressPoller {
  ChatThreadProgressPoller({
    required TaskOrchestrator orchestrator,
    required RuntimeActivityMetrics activityMetrics,
    this.interval = const Duration(milliseconds: 350),
    this.maximumBackoff = const Duration(seconds: 5),
    double jitter = .15,
    double Function()? randomDouble,
  }) : // Public collaborator names intentionally omit private prefixes.
       // ignore: prefer_initializing_formals
       _orchestrator = orchestrator,
       // ignore: prefer_initializing_formals
       _activityMetrics = activityMetrics,
       // ignore: prefer_initializing_formals
       _jitter = jitter,
       // ignore: prefer_initializing_formals
       _randomDouble = randomDouble;

  final TaskOrchestrator _orchestrator;
  final RuntimeActivityMetrics _activityMetrics;
  final Duration interval;
  final Duration maximumBackoff;
  final double _jitter;
  final double Function()? _randomDouble;

  OrchestratedPoller? _poller;
  bool _disposed = false;

  void start({
    required String threadId,
    required String agentRunId,
    required ChatThreadProgressAttempt attempt,
  }) {
    if (_disposed) throw StateError('ChatThreadProgressPoller is disposed');
    stop();
    _poller = OrchestratedPoller(
      orchestrator: _orchestrator,
      // performance-rfc: unified-network-pollers
      spec: TaskSpec(
        key: _taskKey(threadId, agentRunId),
        owner: 'chat.thread-progress',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 10),
      ),
      interval: interval,
      maxBackoff: interval > maximumBackoff ? interval : maximumBackoff,
      jitter: _jitter,
      randomDouble: _randomDouble,
      activityMetrics: _activityMetrics,
      poll: (_) => attempt(),
    )..start();
  }

  void stop() {
    _poller?.dispose();
    _poller = null;
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
  }
}

String _taskKey(String threadId, String agentRunId) {
  final digest = sha256
      .convert(utf8.encode('${threadId.trim()}\u0000${agentRunId.trim()}'))
      .toString();
  return 'chat.thread-progress.${digest.substring(0, 16)}';
}
