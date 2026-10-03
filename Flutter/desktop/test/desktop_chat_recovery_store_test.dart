import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/chat/data/desktop_chat_recovery_store.dart';
import 'package:huahuo_desktop/features/chat/domain/desktop_chat_port.dart';
import 'package:huahuo_desktop/features/chat/domain/desktop_chat_recovery_models.dart';

void main() {
  test(
    'round trips public desktop Chat state within one account workspace',
    () async {
      final root = await Directory.systemTemp.createTemp('desktop-chat-cache-');
      addTearDown(() => root.delete(recursive: true));
      final store = LocalDesktopChatRecoveryStore(
        supportDirectory: () async => root,
      );
      final snapshot = DesktopChatSessionSnapshot(
        threads: const <DesktopChatThread>[
          DesktopChatThread(
            threadId: 'thread_1',
            title: '内容整理',
            agentProfileId: 'self_media_creation',
            activeRuns: <DesktopChatActiveRun>[
              DesktopChatActiveRun(agentRunId: 'run_1', status: 'running'),
            ],
          ),
        ],
        messagesByThread: const <String, Iterable<DesktopChatMessage>>{
          'thread_1': <DesktopChatMessage>[
            DesktopChatMessage(
              messageId: 'message_1',
              threadId: 'thread_1',
              role: 'user',
              text: '请整理素材。',
            ),
          ],
        },
        activeThreadId: 'thread_1',
        tasks: <DesktopChatPendingTask>[
          DesktopChatPendingTask(
            taskKey: 'run_1',
            acceptedReply: const DesktopChatReply(
              userMessage: DesktopChatMessage(
                messageId: 'message_1',
                threadId: 'thread_1',
                role: 'user',
                text: '请整理素材。',
              ),
              agentRunId: 'run_1',
            ),
            lifecycle: DesktopChatTaskLifecycle.running,
            createdAt: DateTime.utc(2026, 8, 14),
            updatedAt: DateTime.utc(2026, 8, 14, 0, 1),
          ),
        ],
      );

      await store.save(
        userId: 'user_a',
        workspaceId: 'workspace_1',
        snapshot: snapshot,
      );
      final restored = await store.load(
        userId: 'user_a',
        workspaceId: 'workspace_1',
      );
      final other = await store.load(
        userId: 'user_b',
        workspaceId: 'workspace_1',
      );

      expect(restored.activeThreadId, 'thread_1');
      expect(restored.threads.single.agentProfileId, 'self_media_creation');
      expect(restored.detailFor('thread_1')?.messages.single.text, '请整理素材。');
      expect(restored.tasks.single.taskKey, 'run_1');
      expect(other.threads, isEmpty);
      final cacheFile = await root
          .list()
          .where((entity) => entity.path.endsWith('.json'))
          .cast<File>()
          .single;
      final cacheText = await cacheFile.readAsString();
      expect(cacheText, isNot(contains('accessToken')));
      expect(cacheText, isNot(contains('https://')));
    },
  );

  test('returns an empty snapshot for malformed cache data', () async {
    final root = await Directory.systemTemp.createTemp(
      'desktop-chat-cache-invalid-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = LocalDesktopChatRecoveryStore(
      supportDirectory: () async => root,
    );
    await store.save(
      userId: 'user_a',
      workspaceId: 'workspace_1',
      snapshot: const DesktopChatSessionSnapshot.empty(),
    );
    final file = await root
        .list()
        .where((entity) => entity.path.endsWith('.json'))
        .cast<File>()
        .single;
    await file.writeAsString('{not-json');

    final restored = await store.load(
      userId: 'user_a',
      workspaceId: 'workspace_1',
    );

    expect(restored.threads, isEmpty);
    expect(restored.tasks, isEmpty);
  });
}
