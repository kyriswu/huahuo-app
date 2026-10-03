import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/agent/application/desktop_agent_controller.dart';

import 'support/desktop_port_fakes.dart';

void main() {
  test(
    'Catalog cache is scoped by user, Workspace and Catalog version',
    () async {
      final port = FakeDesktopCatalogPort();
      final controller = DesktopAgentController(
        port: port,
        pollInterval: Duration.zero,
      )..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');

      final first = await controller.resolveFeature('note.sprout');
      final second = await controller.resolveFeature('note.sprout');

      expect(first.isSuccess, isTrue);
      expect(second.isSuccess, isTrue);
      expect(controller.catalogVersion, 'catalog-desktop-1');
      expect(
        port.operations.where((item) => item.startsWith('profiles:')),
        hasLength(1),
      );

      port.catalogVersion = 'catalog-desktop-2';
      final refreshed = await controller.resolveFeature(
        'note.sprout',
        refresh: true,
      );
      expect(refreshed.data?.catalogVersion, 'catalog-desktop-2');
      expect(controller.catalogVersion, 'catalog-desktop-2');

      controller.bindAccount(userId: 'user-2', workspaceId: 'workspace-2');
      await controller.resolveFeature('note.sprout');
      expect(
        port.operations.where((item) => item.startsWith('profiles:')),
        hasLength(3),
      );
    },
  );

  test('Feature admission leaves Skill installation to the server', () async {
    final port = FakeDesktopCatalogPort(installationState: 'disabled');
    final controller = DesktopAgentController(port: port)
      ..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');

    final result = await controller.resolveFeature('note.sprout');

    expect(result.isSuccess, isTrue);
    expect(port.createdRequests, isEmpty);
  });

  test('Work AI and Feed AI are rejected before any Port call', () async {
    final port = FakeDesktopCatalogPort();
    final controller = DesktopAgentController(port: port)
      ..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');

    final work = await controller.resolveFeature('work-ai.topic-generation');
    final feed = await controller.resolveFeature('feed-ai.deposit-summary');
    final workRun = await controller.runFeature(
      featureId: 'work-ai.topic-generation',
      actionId: 'prohibited-action',
      instruction: '禁止发送',
      document: DesktopAgentDocumentReference(
        ownerId: 'note-remote-1',
        part: 'raw',
        partRevisionId: 'raw-part-revision-9',
      ),
    );

    expect(work.code, 'API_ENDPOINT_PROHIBITED');
    expect(feed.code, 'API_ENDPOINT_PROHIBITED');
    expect(workRun.code, 'API_ENDPOINT_PROHIBITED');
    expect(port.operations, isEmpty);
  });

  test(
    'sign-out clears Catalog scope and blocks later Agent admission',
    () async {
      final port = FakeDesktopCatalogPort();
      final controller = DesktopAgentController(port: port)
        ..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');
      expect(
        (await controller.resolveFeature('note.sprout')).isSuccess,
        isTrue,
      );

      controller.clearAccount();
      final signedOut = await controller.resolveFeature('note.sprout');

      expect(signedOut.isUnavailable, isTrue);
      expect(signedOut.code, 'DESKTOP_AGENT_ACCOUNT_REQUIRED');
      expect(controller.catalogVersion, isNull);
    },
  );

  test(
    'AgentRun retry reuses opaque idempotency and sends exact remote reference',
    () async {
      final port = FakeDesktopCatalogPort()..createFailureCount = 1;
      final controller = DesktopAgentController(
        port: port,
        pollInterval: Duration.zero,
        idempotencyKeyFactory: () => 'opaque-agent-action-key',
      )..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');
      final reference = DesktopAgentDocumentReference(
        ownerId: 'note-remote-1',
        part: 'raw',
        partRevisionId: 'raw-part-revision-9',
        targetPartRevisionId: 'germination-part-revision-3',
      );

      final failed = await controller.runFeature(
        featureId: 'note.sprout',
        actionId: 'sprout-action',
        instruction: '请基于引用的原始内容生成发芽洞见。',
        document: reference,
      );
      final retried = await controller.runFeature(
        featureId: 'note.sprout',
        actionId: 'sprout-action',
        instruction: '请基于引用的原始内容生成发芽洞见。',
        document: reference,
      );

      expect(failed.isFailure, isTrue);
      expect(retried.isSuccess, isTrue);
      expect(retried.data?.outputPartRevisionId, 'germination-revision-output');
      expect(port.idempotencyKeys, <String>[
        'opaque-agent-action-key',
        'opaque-agent-action-key',
      ]);
      final request = port.createdFileAgentRuns.last;
      expect(request.workspaceId, 'workspace-test');
      expect(request.noteId, 'note-remote-1');
      expect(request.agentProfileId, 'faya_germination');
      expect(request.skillProfileIds, <String>['viewpoint_germination']);
      expect(request.inputPart, 'raw');
      expect(request.inputPartRevisionId, 'raw-part-revision-9');
      expect(request.targetPart, 'germination');
      expect(request.targetPartRevisionId, 'germination-part-revision-3');
      expect(request.instruction, isNot(contains('/Users/')));
    },
  );

  test('pending action rejects every changed canonical intent field', () async {
    final baselineReference = DesktopAgentDocumentReference(
      ownerId: 'note-remote-1',
      part: 'raw',
      partRevisionId: 'raw-part-revision-9',
      targetPartRevisionId: 'germination-part-revision-3',
    );
    final changedIntents =
        <
          ({
            String featureId,
            String instruction,
            DesktopAgentDocumentReference reference,
          })
        >[
          (
            featureId: 'creation.deep_value',
            instruction: '生成发芽洞见',
            reference: baselineReference,
          ),
          (
            featureId: 'note.sprout',
            instruction: '改成另一条指令',
            reference: baselineReference,
          ),
          (
            featureId: 'note.sprout',
            instruction: '生成发芽洞见',
            reference: DesktopAgentDocumentReference(
              ownerId: 'note-remote-1',
              part: 'raw',
              partRevisionId: 'raw-part-revision-10',
              targetPartRevisionId: 'germination-part-revision-3',
            ),
          ),
        ];

    for (var index = 0; index < changedIntents.length; index += 1) {
      final port = FakeDesktopCatalogPort()..createFailureCount = 1;
      final controller = DesktopAgentController(
        port: port,
        pollInterval: Duration.zero,
        idempotencyKeyFactory: () => 'stable-key-$index',
      )..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');
      final initial = await controller.runFeature(
        featureId: 'note.sprout',
        actionId: 'same-action-scope',
        instruction: '生成发芽洞见',
        document: baselineReference,
      );
      final operationCount = port.operations.length;
      final changed = changedIntents[index];

      final conflict = await controller.runFeature(
        featureId: changed.featureId,
        actionId: 'same-action-scope',
        instruction: changed.instruction,
        document: changed.reference,
      );

      expect(initial.code, 'TEST_CREATE_FAILED', reason: 'case $index');
      expect(
        conflict.code,
        'DESKTOP_AGENT_IDEMPOTENCY_CONFLICT',
        reason: 'case $index',
      );
      expect(port.createdFileAgentRuns, hasLength(1), reason: 'case $index');
      expect(port.operations, hasLength(operationCount), reason: 'case $index');
    }
  });

  test(
    'in-flight action rejects changed intent without a second request',
    () async {
      final port = FakeDesktopCatalogPort();
      final controller = DesktopAgentController(
        port: port,
        pollInterval: Duration.zero,
      )..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');
      final reference = DesktopAgentDocumentReference(
        ownerId: 'note-remote-1',
        part: 'raw',
        partRevisionId: 'raw-part-revision-9',
        targetPartRevisionId: 'germination-part-revision-3',
      );

      final firstFuture = controller.runFeature(
        featureId: 'note.sprout',
        actionId: 'concurrent-action',
        instruction: '生成发芽洞见',
        document: reference,
      );
      final conflictFuture = controller.runFeature(
        featureId: 'note.sprout',
        actionId: 'concurrent-action',
        instruction: '并发时更换指令',
        document: reference,
      );
      final conflict = await conflictFuture;
      final first = await firstFuture;

      expect(first.isSuccess, isTrue);
      expect(conflict.code, 'DESKTOP_AGENT_IDEMPOTENCY_CONFLICT');
      expect(port.createdFileAgentRuns, hasLength(1));
    },
  );

  test('generic AgentRun keeps Skill and Model fields server-owned', () async {
    final port = FakeDesktopCatalogPort();
    final controller = DesktopAgentController(
      port: port,
      pollInterval: Duration.zero,
    )..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');

    final result = await controller.runFeature(
      featureId: 'creation.deep_value',
      actionId: 'no-model-selection',
      instruction: '生成发芽洞见',
      document: DesktopAgentDocumentReference(
        ownerId: 'note-remote-1',
        part: 'raw',
        partRevisionId: 'raw-part-revision-9',
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(port.createdRequests.single.modelProfileId, isNull);
    expect(port.createdRequests.single.skillProfileIds, isEmpty);
    expect(
      port.createdRequests.single.toJson(),
      isNot(contains('modelProfileId')),
    );
    expect(
      port.createdRequests.single.toJson(),
      isNot(contains('skillProfileIds')),
    );
  });

  test(
    'accepted run is polled without creating a second run after timeout',
    () async {
      final port = FakeDesktopCatalogPort()..terminalStatus = 'running';
      final controller = DesktopAgentController(
        port: port,
        pollInterval: Duration.zero,
        maxPollAttempts: 1,
        idempotencyKeyFactory: () => 'stable-key',
      )..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');
      final reference = DesktopAgentDocumentReference(
        ownerId: 'note-remote-1',
        part: 'raw',
        partRevisionId: 'raw-part-revision-9',
        targetPartRevisionId: 'germination-part-revision-3',
      );

      final timeout = await controller.runFeature(
        featureId: 'note.sprout',
        actionId: 'sprout-action',
        instruction: '生成发芽洞见',
        document: reference,
      );
      port.terminalStatus = 'succeeded';
      final resumed = await controller.runFeature(
        featureId: 'note.sprout',
        actionId: 'sprout-action',
        instruction: '生成发芽洞见',
        document: reference,
      );

      expect(timeout.code, 'DESKTOP_AGENT_RUN_TIMEOUT');
      expect(resumed.isSuccess, isTrue);
      expect(port.createdFileAgentRuns, hasLength(1));
      expect(port.idempotencyKeys, <String>['stable-key']);
    },
  );

  test('degraded and fallback terminal runs never become success', () async {
    for (final mode in <String>['degraded', 'system_fallback']) {
      final port = FakeDesktopCatalogPort()..terminalCompletionMode = mode;
      final controller = DesktopAgentController(
        port: port,
        pollInterval: Duration.zero,
      )..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');

      final result = await controller.runFeature(
        featureId: 'creation.deep_value',
        actionId: 'action-$mode',
        instruction: '生成发芽洞见',
        document: DesktopAgentDocumentReference(
          ownerId: 'note-remote-1',
          part: 'raw',
          partRevisionId: 'raw-part-revision-9',
        ),
      );

      expect(result.isFailure, isTrue, reason: mode);
      expect(
        result.code,
        contains(mode == 'degraded' ? 'DEGRADED' : 'FALLBACK'),
      );
    }
  });

  test('normal status without a durable result is rejected', () async {
    final port = FakeDesktopCatalogPort()..includeDurableResult = false;
    final controller = DesktopAgentController(
      port: port,
      pollInterval: Duration.zero,
    )..bindAccount(userId: 'user-1', workspaceId: 'workspace-test');

    final result = await controller.runFeature(
      featureId: 'creation.deep_value',
      actionId: 'missing-durable-result',
      instruction: '生成发芽洞见',
      document: DesktopAgentDocumentReference(
        ownerId: 'note-remote-1',
        part: 'raw',
        partRevisionId: 'raw-part-revision-9',
      ),
    );

    expect(result.isFailure, isTrue);
    expect(result.code, 'DESKTOP_AGENT_DURABLE_RESULT_MISSING');
  });
}
