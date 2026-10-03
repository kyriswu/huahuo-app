import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/chat/domain/assistant_runtime.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';

void main() {
  test('prefers the provider-neutral runtime for polling reads', () async {
    final runtime = _FakeAssistantRuntime(
      AssistantRunSnapshot(
        handle: const AssistantRunHandle('agent_run_neutral_1'),
        status: AssistantRunStatus.running,
        conversationId: 'thread-neutral',
        createdAt: DateTime.utc(2026, 10, 2, 8),
        updatedAt: DateTime.utc(2026, 10, 2, 8),
      ),
    );
    final tracker = ChatRunTracker(
      assistantRuntime: runtime,
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'assistant-runtime-test',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);

    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_neutral_1',
      threadId: 'thread-neutral',
      scene: ChatScene.feedAi,
    );
    await Future<void>.delayed(Duration.zero);

    expect(runtime.handles, <String>['agent_run_neutral_1']);
    expect(tracker.threadRunStatus('thread-neutral'), 'running');
  });
}

final class _FakeAssistantRuntime implements AssistantRuntimePort {
  _FakeAssistantRuntime(this.snapshot);

  final AssistantRunSnapshot snapshot;
  final handles = <String>[];

  @override
  Future<AssistantRuntimeRead<AssistantRunSnapshot>> readRun({
    required AssistantRunHandle handle,
  }) async {
    handles.add(handle.value);
    return AssistantRuntimeRead.success(snapshot);
  }
}
