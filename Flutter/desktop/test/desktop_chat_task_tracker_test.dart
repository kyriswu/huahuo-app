import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/chat/application/desktop_chat_task_tracker.dart';
import 'package:huahuo_desktop/features/chat/data/desktop_chat_recovery_store.dart';
import 'package:huahuo_desktop/features/chat/domain/desktop_chat_port.dart';
import 'package:huahuo_desktop/features/chat/domain/desktop_chat_recovery_models.dart';
import 'package:huahuo_desktop/shared/services/desktop_service_result.dart';

void main() {
  test(
    'persists accepted work, merges the durable reply, and acknowledges only terminal work',
    () async {
      final completion = Completer<DesktopServiceResult<DesktopChatReply>>();
      final store = _MemoryRecoveryStore();
      final tracker = DesktopChatTaskTracker(
        chatPort: _TaskPort(resolve: (_) => completion.future),
        store: store,
        retryDelay: const Duration(milliseconds: 1),
      );
      addTearDown(tracker.dispose);
      await tracker.bindAccount(userId: 'user_1', workspaceId: 'workspace_1');

      final accepted = _acceptedReply();
      await tracker.registerAccepted(accepted);

      expect(tracker.tasks, hasLength(1));
      expect(tracker.tasks.single.isTerminal, isFalse);
      expect(store.saveCount, greaterThanOrEqualTo(1));
      completion.complete(
        DesktopServiceResult<DesktopChatReply>.success(
          DesktopChatReply(
            userMessage: accepted.userMessage,
            assistantMessage: const DesktopChatMessage(
              messageId: 'assistant_1',
              threadId: 'thread_1',
              role: 'assistant',
              text: '已写入持久化回复。',
            ),
            agentRunId: 'run_1',
            completionMode: 'normal',
          ),
        ),
      );
      await _eventually(
        () =>
            tracker.tasks.single.lifecycle ==
            DesktopChatTaskLifecycle.succeeded,
      );

      final detail = tracker.detailFor('thread_1');
      expect(detail?.messages.map((message) => message.messageId), <String>[
        'user_1',
        'assistant_1',
      ]);
      expect(tracker.tasks.single.isTerminal, isTrue);
      await tracker.acknowledgeTerminalTask('run_1');
      expect(tracker.tasks, isEmpty);
    },
  );

  test('keeps task recovery isolated by account and workspace scope', () async {
    final store = _MemoryRecoveryStore();
    final tracker = DesktopChatTaskTracker(
      chatPort: _TaskPort(
        resolve: (_) async =>
            const DesktopServiceResult<DesktopChatReply>.failure(
              code: 'AGENT_RUN_FAILED',
              message: '任务失败',
            ),
      ),
      store: store,
    );
    addTearDown(tracker.dispose);
    await tracker.bindAccount(userId: 'user_a', workspaceId: 'workspace_1');
    await tracker.registerAccepted(_acceptedReply());
    await _eventually(
      () => tracker.tasks.single.lifecycle == DesktopChatTaskLifecycle.failed,
    );

    await tracker.bindAccount(userId: 'user_b', workspaceId: 'workspace_1');
    expect(tracker.snapshot.threads, isEmpty);
    expect(tracker.tasks, isEmpty);

    await tracker.bindAccount(userId: 'user_a', workspaceId: 'workspace_1');
    expect(tracker.snapshot.threads.single.threadId, 'thread_1');
    expect(tracker.tasks.single.lifecycle, DesktopChatTaskLifecycle.failed);
  });

  test('keeps a cached Agent Profile when thread detail omits it', () async {
    final tracker = DesktopChatTaskTracker(
      chatPort: _TaskPort(
        resolve: (_) async =>
            const DesktopServiceResult<DesktopChatReply>.failure(
              code: 'UNUSED',
              message: 'unused',
            ),
      ),
      store: _MemoryRecoveryStore(),
    );
    addTearDown(tracker.dispose);
    await tracker.bindAccount(userId: 'user_1', workspaceId: 'workspace_1');
    await tracker.updateThreads(const <DesktopChatThread>[
      DesktopChatThread(
        threadId: 'thread_1',
        title: '视觉方案',
        agentProfileId: 'visual_chat',
        activeRuns: <DesktopChatActiveRun>[
          DesktopChatActiveRun(agentRunId: 'run_1', status: 'running'),
        ],
      ),
    ]);

    await tracker.recordThreadDetail(
      const DesktopChatThreadDetail(
        thread: DesktopChatThread(threadId: 'thread_1', title: '未命名会话'),
        messages: <DesktopChatMessage>[
          DesktopChatMessage(
            messageId: 'message_1',
            threadId: 'thread_1',
            role: 'user',
            text: '生成一个画面。',
          ),
        ],
      ),
      activate: true,
    );

    final thread = tracker.snapshot.threads.single;
    expect(thread.agentProfileId, 'visual_chat');
    expect(thread.activeRuns.single.agentRunId, 'run_1');
  });
}

DesktopChatReply _acceptedReply() => const DesktopChatReply(
  userMessage: DesktopChatMessage(
    messageId: 'user_1',
    threadId: 'thread_1',
    role: 'user',
    text: '请整理这份内容。',
  ),
  agentRunId: 'run_1',
);

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition did not become true.');
}

final class _TaskPort
    implements DesktopChatPort, DesktopChatTaskResolutionPort {
  _TaskPort({required this.resolve});

  final Future<DesktopServiceResult<DesktopChatReply>> Function(
    DesktopChatReply accepted,
  )
  resolve;

  @override
  Future<DesktopServiceResult<DesktopChatThread>> createThread() async =>
      const DesktopServiceResult<DesktopChatThread>.failure(
        code: 'UNUSED',
        message: 'unused',
      );

  @override
  Future<DesktopServiceResult<DesktopChatThreadDetail>> getThreadDetail(
    String threadId,
  ) async => const DesktopServiceResult<DesktopChatThreadDetail>.failure(
    code: 'UNUSED',
    message: 'unused',
  );

  @override
  Future<DesktopServiceResult<DesktopChatThreadPage>> listThreads({
    String? cursor,
    int limit = 30,
  }) async => const DesktopServiceResult<DesktopChatThreadPage>.failure(
    code: 'UNUSED',
    message: 'unused',
  );

  @override
  Future<DesktopServiceResult<DesktopChatReply>> resolveAcceptedReply(
    DesktopChatReply accepted,
  ) => resolve(accepted);

  @override
  Future<DesktopServiceResult<DesktopChatReply>> sendText({
    required String threadId,
    required String content,
    String? agentProfileId,
    Iterable<DesktopChatContextReference> references =
        const <DesktopChatContextReference>[],
  }) async => const DesktopServiceResult<DesktopChatReply>.failure(
    code: 'UNUSED',
    message: 'unused',
  );
}

final class _MemoryRecoveryStore implements DesktopChatRecoveryStore {
  final Map<String, DesktopChatSessionSnapshot> _snapshots =
      <String, DesktopChatSessionSnapshot>{};
  int saveCount = 0;

  String _key(String userId, String workspaceId) => '$userId|$workspaceId';

  @override
  Future<void> clear({
    required String userId,
    required String workspaceId,
  }) async {
    _snapshots.remove(_key(userId, workspaceId));
  }

  @override
  Future<DesktopChatSessionSnapshot> load({
    required String userId,
    required String workspaceId,
  }) async =>
      _snapshots[_key(userId, workspaceId)] ??
      const DesktopChatSessionSnapshot.empty();

  @override
  Future<void> save({
    required String userId,
    required String workspaceId,
    required DesktopChatSessionSnapshot snapshot,
  }) async {
    saveCount += 1;
    _snapshots[_key(userId, workspaceId)] = snapshot;
  }
}
