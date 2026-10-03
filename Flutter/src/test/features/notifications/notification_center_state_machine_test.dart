import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/notifications/application/notification_center_state_machine.dart';
import 'package:huahuoai_app/features/notifications/application/pending_message_projection.dart';

void main() {
  const policies = NotificationCenterPolicyRegistry();

  group('NotificationCenterPolicyRegistry', () {
    test('classifies every lifecycle into one explicit policy', () {
      final matrix =
          <
            PendingMessageState,
            ({
              NotificationCenterGroup group,
              NotificationRetention retention,
              String label,
              bool badge,
              bool archive,
              bool autoArchive,
            })
          >{
            PendingMessageState.processing: (
              group: NotificationCenterGroup.ongoing,
              retention: NotificationRetention.sourceControlled,
              label: '进行中',
              badge: false,
              archive: false,
              autoArchive: false,
            ),
            PendingMessageState.actionRequired: (
              group: NotificationCenterGroup.ongoing,
              retention: NotificationRetention.manualArchive,
              label: '待处理',
              badge: true,
              archive: true,
              autoArchive: false,
            ),
            PendingMessageState.succeeded: (
              group: NotificationCenterGroup.finished,
              retention: NotificationRetention.destinationOrManualArchive,
              label: '已完成',
              badge: true,
              archive: true,
              autoArchive: true,
            ),
            PendingMessageState.failed: (
              group: NotificationCenterGroup.finished,
              retention: NotificationRetention.manualArchive,
              label: '失败',
              badge: true,
              archive: true,
              autoArchive: false,
            ),
            PendingMessageState.informational: (
              group: NotificationCenterGroup.finished,
              retention: NotificationRetention.manualArchive,
              label: '通知',
              badge: true,
              archive: true,
              autoArchive: false,
            ),
          };

      for (final entry in matrix.entries) {
        final item = _message(
          entry.key,
          isTask: entry.key == PendingMessageState.succeeded,
          targetType: entry.key == PendingMessageState.succeeded
              ? 'task'
              : null,
          targetId: entry.key == PendingMessageState.succeeded
              ? 'task-success'
              : null,
          route: entry.key == PendingMessageState.succeeded
              ? '/v3/workbench/tasks/task-success'
              : null,
        );
        final expected = entry.value;
        final policy = policies.classify(item);
        expect(policy.group, expected.group, reason: entry.key.name);
        expect(policy.retention, expected.retention, reason: entry.key.name);
        expect(policy.statusLabel, expected.label, reason: entry.key.name);
        expect(
          policy.countsTowardBadge(item),
          expected.badge,
          reason: entry.key.name,
        );
        expect(
          policy.canArchive(item.copyWith(isUnread: false)),
          expected.archive,
          reason: entry.key.name,
        );
        expect(policy.canArchive(item), isFalse, reason: entry.key.name);
        expect(
          policy.shouldAutoArchiveAfterDestination,
          expected.autoArchive,
          reason: entry.key.name,
        );
      }
    });

    test('filters groups and counts only unread badge-eligible rows', () {
      final items = <PendingMessage>[
        _message(PendingMessageState.processing),
        _message(PendingMessageState.actionRequired),
        _message(PendingMessageState.succeeded),
        _message(PendingMessageState.failed, isUnread: false),
        _message(PendingMessageState.informational),
      ];

      expect(
        policies
            .filter(items, NotificationCenterFilter.ongoing)
            .map((item) => item.state),
        <PendingMessageState>[
          PendingMessageState.actionRequired,
          PendingMessageState.processing,
        ],
      );
      expect(
        policies
            .filter(items, NotificationCenterFilter.finished)
            .map((item) => item.state),
        <PendingMessageState>[
          PendingMessageState.failed,
          PendingMessageState.informational,
          PendingMessageState.succeeded,
        ],
      );
      expect(policies.badgeCount(items), 3);
      expect(policies.attention(items), (hasProcessing: true, unreadCount: 3));
    });

    test('admits only recoverable tasks and sorts exact deliveries once', () {
      const unrecoverable = PendingMessage(
        id: 'unrecoverable-task',
        source: PendingMessageSource.agentTask,
        scene: 'chat',
        title: '无恢复入口',
        body: '任务仍在运行，但没有可返回的会话。',
        state: PendingMessageState.processing,
        isUnread: false,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        isTask: true,
      );
      const routeLessLocalHistory = PendingMessage(
        id: 'route-less-local-history',
        source: PendingMessageSource.sprout,
        scene: 'sprout',
        title: '无法恢复的本地结果',
        body: '没有可打开的原始任务。',
        state: PendingMessageState.failed,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
      );
      final oldRevision = _message(
        PendingMessageState.informational,
        id: 'duplicate',
        remoteDeliveryResolutionKey: 'delivery:duplicate',
        createdAt: DateTime.utc(2026, 9, 8),
        isUnread: false,
      );
      final latestRevision = _message(
        PendingMessageState.informational,
        id: 'duplicate',
        remoteDeliveryResolutionKey: 'delivery:duplicate',
        createdAt: DateTime.utc(2026, 9, 10),
      );
      final middle = _message(
        PendingMessageState.failed,
        id: 'middle',
        createdAt: DateTime.utc(2026, 9, 9),
      );

      expect(policies.admits(unrecoverable), isFalse);
      expect(policies.admits(routeLessLocalHistory), isFalse);
      final canonical = policies.canonicalItems(<PendingMessage>[
        oldRevision,
        unrecoverable,
        routeLessLocalHistory,
        middle,
        latestRevision,
      ]);
      expect(canonical.map((item) => item.id), <String>['middle', 'duplicate']);
      expect(canonical.last.isUnread, isFalse);
      expect(canonical.last.createdAt, DateTime.utc(2026, 9, 8));
    });

    test('keeps a completed content notification as manual history', () {
      final item = _message(PendingMessageState.succeeded, isUnread: false);
      final policy = policies.classify(item);

      expect(policy.retention, NotificationRetention.manualArchive);
      expect(policy.canArchive(item), isTrue);
      expect(policy.shouldAutoArchiveAfterDestination, isFalse);
    });

    test('requires an exact result receipt for task auto-archive', () {
      final overview = _message(
        PendingMessageState.succeeded,
        isTask: true,
        targetType: 'asset',
        targetId: 'opaque-asset-1',
        route: '/v3/assets?focus=overview',
      );
      final exactNote = _message(
        PendingMessageState.succeeded,
        id: 'exact-note',
        isTask: true,
        targetType: 'asset',
        targetId: 'note-1',
        stage: 'outline',
        route: '/v3/feed/items/note-1?stage=summary',
      );

      expect(policies.retention(overview), NotificationRetention.manualArchive);
      expect(policies.shouldAutoArchiveAfterDestination(overview), isFalse);
      expect(
        policies.retention(exactNote),
        NotificationRetention.destinationOrManualArchive,
      );
      expect(policies.shouldAutoArchiveAfterDestination(exactNote), isTrue);
    });

    test('keeps business-required rows source controlled', () {
      final item = _message(
        PendingMessageState.actionRequired,
        source: PendingMessageSource.onboarding,
      );
      final policy = policies.classify(item);

      expect(policy.retention, NotificationRetention.sourceControlled);
      expect(policy.canArchive(item), isFalse);
    });

    test('coalesces local and server recording lifecycle into one row', () {
      final local = _message(
        PendingMessageState.succeeded,
        id: 'local-recording-1',
        source: PendingMessageSource.recordingTranscription,
        targetType: 'recording',
        targetId: 'recording-1',
        isResolving: true,
      );
      final remote = _message(
        PendingMessageState.succeeded,
        id: 'remote-recording-1',
        source: PendingMessageSource.remote,
        targetType: 'recording',
        targetId: 'recording-1',
        eventType: 'recording.deposit.succeeded',
        isUnread: false,
        isTask: true,
      );

      final canonical = policies.canonicalItems(<PendingMessage>[
        local,
        remote,
      ]);
      expect(canonical, hasLength(1));
      expect(canonical.single.id, remote.id);
      expect(canonical.single.isUnread, isTrue);
      expect(canonical.single.isResolving, isTrue);
      expect(policies.badgeCount(<PendingMessage>[local, remote]), 1);
    });

    test('recording success cannot regress to a newer stale state', () {
      final succeeded = _message(
        PendingMessageState.succeeded,
        id: 'recording-succeeded',
        source: PendingMessageSource.remote,
        targetType: 'recording',
        targetId: 'recording-1',
        stage: 'recording_processing',
        eventType: 'recording.deposit.succeeded',
        isTask: true,
        createdAt: DateTime.utc(2026, 9, 2, 10),
      );

      for (final staleState in <PendingMessageState>[
        PendingMessageState.processing,
        PendingMessageState.failed,
      ]) {
        final stale = _message(
          staleState,
          id: 'newer-${staleState.name}',
          source: PendingMessageSource.recordingTranscription,
          targetType: 'recording',
          targetId: 'recording-1',
          stage: 'recording_processing',
          isTask: true,
          createdAt: DateTime.utc(2026, 9, 2, 11),
        );

        final canonical = policies.canonicalItems(<PendingMessage>[
          succeeded,
          stale,
        ]);

        expect(canonical.single.id, succeeded.id, reason: staleState.name);
        expect(
          policies.filter(<PendingMessage>[
            succeeded,
            stale,
          ], NotificationCenterFilter.ongoing),
          isEmpty,
          reason: staleState.name,
        );
        expect(
          policies
              .filter(<PendingMessage>[
                succeeded,
                stale,
              ], NotificationCenterFilter.finished)
              .single
              .id,
          succeeded.id,
          reason: staleState.name,
        );
      }
    });

    test('non-success recording rows still follow event time', () {
      final failed = _message(
        PendingMessageState.failed,
        id: 'old-recording-failed',
        source: PendingMessageSource.recordingTranscription,
        targetType: 'recording',
        targetId: 'recording-retry-1',
        stage: 'recording_processing',
        isTask: true,
        createdAt: DateTime.utc(2026, 9, 2, 10),
      );
      final processing = _message(
        PendingMessageState.processing,
        id: 'recording-retry',
        source: PendingMessageSource.recordingTranscription,
        targetType: 'recording',
        targetId: 'recording-retry-1',
        stage: 'recording_processing',
        isTask: true,
        createdAt: DateTime.utc(2026, 9, 2, 11),
      );

      final canonical = policies.canonicalItems(<PendingMessage>[
        failed,
        processing,
      ]);

      expect(canonical.single.id, processing.id);
    });
  });

  group('NotificationCenterController', () {
    test('defaults to ongoing and exposes only the two lifecycle groups', () {
      final controller = NotificationCenterController.withActions(
        actions: _GatedActions(),
      );
      addTearDown(controller.dispose);
      final items = <PendingMessage>[
        _message(PendingMessageState.processing),
        _message(PendingMessageState.actionRequired),
        _message(PendingMessageState.succeeded),
        _message(PendingMessageState.failed),
        _message(PendingMessageState.informational),
      ];

      expect(controller.filter, NotificationCenterFilter.ongoing);
      expect(
        controller.visibleItems(items).map((item) => item.state),
        <PendingMessageState>[
          PendingMessageState.processing,
          PendingMessageState.actionRequired,
        ],
      );

      controller.setFilter(NotificationCenterFilter.finished);
      expect(
        controller.visibleItems(items).map((item) => item.state),
        <PendingMessageState>[
          PendingMessageState.succeeded,
          PendingMessageState.failed,
          PendingMessageState.informational,
        ],
      );
    });

    test(
      'keeps per-item read operations non-reentrant and resets in finally',
      () async {
        final actions = _GatedActions();
        final controller = NotificationCenterController.withActions(
          actions: actions,
        );
        addTearDown(controller.dispose);
        final item = _message(PendingMessageState.informational);

        final first = controller.markRead(item);
        expect(
          controller.operationFor(item),
          NotificationCenterOperation.markingRead,
        );
        expect(await controller.markRead(item), isFalse);
        expect(actions.markReadCalls, 1);

        actions.readGate.complete(true);
        expect(await first, isTrue);
        expect(controller.operationFor(item), NotificationCenterOperation.idle);

        actions.readGate = Completer<bool>();
        actions.throwOnRead = true;
        expect(await controller.markRead(item), isFalse);
        expect(
          controller.lastError,
          NotificationCenterController.markReadFailed,
        );
        expect(controller.operationFor(item), NotificationCenterOperation.idle);
      },
    );

    test('isolates row operations by delivery revision', () async {
      final actions = _GatedActions();
      final controller = NotificationCenterController.withActions(
        actions: actions,
      );
      addTearDown(controller.dispose);
      final firstRevision = _message(
        PendingMessageState.informational,
        id: 'reused-row',
        remoteDeliveryResolutionKey: 'delivery:revision-1',
      );
      final secondRevision = _message(
        PendingMessageState.informational,
        id: 'reused-row',
        remoteDeliveryResolutionKey: 'delivery:revision-2',
      );

      final first = controller.markRead(firstRevision);
      final second = controller.markRead(secondRevision);

      expect(actions.markReadCalls, 2);
      expect(
        controller.operationFor(firstRevision),
        NotificationCenterOperation.markingRead,
      );
      expect(
        controller.operationFor(secondRevision),
        NotificationCenterOperation.markingRead,
      );
      expect(await controller.markRead(firstRevision), isFalse);

      actions.readGate.complete(true);
      expect(await Future.wait(<Future<bool>>[first, second]), <bool>[
        true,
        true,
      ]);
      expect(
        controller.operationFor(firstRevision),
        NotificationCenterOperation.idle,
      );
      expect(
        controller.operationFor(secondRevision),
        NotificationCenterOperation.idle,
      );
    });

    test(
      'keeps bulk read non-reentrant and reports partial completion',
      () async {
        final actions = _GatedActions();
        final controller = NotificationCenterController.withActions(
          actions: actions,
        );
        addTearDown(controller.dispose);

        final first = controller.markAllRead();
        expect(controller.bulkReadBusy, isTrue);
        expect(await controller.markAllRead(), isNull);
        expect(
          await controller.markRead(_message(PendingMessageState.failed)),
          isFalse,
        );
        expect(actions.markAllReadCalls, 1);

        actions.bulkGate.complete(
          const PendingMessageMarkAllReadResult(total: 3, succeeded: 2),
        );
        final result = await first;
        expect(result?.failed, 1);
        expect(controller.bulkReadBusy, isFalse);
        expect(
          controller.lastError,
          NotificationCenterController.markAllReadPartial,
        );
      },
    );

    test(
      'bulk delete locks operations and touches only read archives',
      () async {
        final handledGate = Completer<bool>();
        final actions = _GatedActions(handledGate: handledGate);
        final controller = NotificationCenterController.withActions(
          actions: actions,
        );
        addTearDown(controller.dispose);
        final readSuccess = _message(
          PendingMessageState.succeeded,
          id: 'read-success',
          isUnread: false,
          isTask: true,
        );
        final readFailure = _message(
          PendingMessageState.failed,
          id: 'read-failure',
          isUnread: false,
        );
        final unread = _message(
          PendingMessageState.informational,
          id: 'unread',
        );
        final processing = _message(
          PendingMessageState.processing,
          id: 'processing',
        );
        final sourceControlled = _message(
          PendingMessageState.actionRequired,
          id: 'source-controlled',
          isUnread: false,
          source: PendingMessageSource.onboarding,
        );

        final deletion = controller.deleteRead(<PendingMessage>[
          readSuccess,
          unread,
          processing,
          sourceControlled,
          readFailure,
        ]);
        expect(controller.bulkDeleteBusy, isTrue);
        expect(controller.hasBulkOperation, isTrue);
        expect(
          await controller.deleteRead(<PendingMessage>[readSuccess]),
          isNull,
        );
        expect(await controller.markRead(unread), isFalse);

        handledGate.complete(true);
        final result = await deletion;
        expect(result?.total, 2);
        expect(result?.succeeded, 2);
        expect(actions.handledItems.map((item) => item.id).toSet(), <String>{
          'read-success',
          'read-failure',
        });
        expect(controller.bulkDeleteBusy, isFalse);
      },
    );

    test('bulk delete reports partial durable completion', () async {
      final actions = _GatedActions(handledResults: <bool>[true, false]);
      final controller = NotificationCenterController.withActions(
        actions: actions,
      );
      addTearDown(controller.dispose);

      final result = await controller.deleteRead(<PendingMessage>[
        _message(PendingMessageState.failed, id: 'read-a', isUnread: false),
        _message(
          PendingMessageState.informational,
          id: 'read-b',
          isUnread: false,
        ),
      ]);

      expect(result?.failed, 1);
      expect(
        controller.lastError,
        NotificationCenterController.deleteReadPartial,
      );
    });

    test(
      'guards retention and archives success only after destination render',
      () async {
        final actions = _GatedActions(immediateHandled: true);
        final controller = NotificationCenterController.withActions(
          actions: actions,
        );
        addTearDown(controller.dispose);
        final processing = _message(PendingMessageState.processing);
        final succeeded = _message(
          PendingMessageState.succeeded,
          isUnread: false,
          isTask: true,
          targetType: 'task',
          targetId: 'task-success',
          route: '/v3/workbench/tasks/task-success',
        );
        final failed = _message(PendingMessageState.failed, isUnread: false);

        expect(await controller.archive(processing), isFalse);
        expect(await controller.archive(succeeded), isTrue);
        expect(
          await controller.archiveAfterDestinationVisible(failed),
          isFalse,
        );
        expect(actions.markHandledCalls, 1);

        expect(
          await controller.archiveAfterDestinationVisible(succeeded),
          isTrue,
        );
        expect(await controller.archive(failed), isTrue);
        expect(actions.markHandledCalls, 3);
      },
    );

    test('opening is per-item, non-reentrant, and reports failure', () async {
      final actions = _GatedActions();
      final controller = NotificationCenterController.withActions(
        actions: actions,
      );
      addTearDown(controller.dispose);
      final item = _message(PendingMessageState.succeeded);

      final first = controller.markOpened(item);
      expect(
        controller.operationFor(item),
        NotificationCenterOperation.opening,
      );
      expect(await controller.markOpened(item), isFalse);
      actions.openGate.complete(false);
      expect(await first, isFalse);
      expect(controller.lastError, NotificationCenterController.openFailed);
      expect(controller.operationFor(item), NotificationCenterOperation.idle);
    });
  });
}

PendingMessage _message(
  PendingMessageState state, {
  String? id,
  bool isUnread = true,
  bool isOpening = false,
  bool isResolving = false,
  bool isTask = false,
  PendingMessageSource source = PendingMessageSource.remote,
  String? targetType,
  String? targetId,
  String? stage,
  String? route,
  String? eventType,
  String? remoteDeliveryResolutionKey,
  DateTime? createdAt,
}) {
  final messageId = id ?? 'message-${state.name}';
  final effectiveIsTask = isTask || state == PendingMessageState.processing;
  return PendingMessage(
    id: messageId,
    source: source,
    scene: 'notification',
    title: state.name,
    body: 'body',
    state: state,
    isUnread: isUnread,
    isDemo: false,
    isOpening: isOpening,
    isResolving: isResolving,
    route: route ?? '/target/${state.name}',
    isTask: effectiveIsTask,
    targetType: targetType,
    targetId: targetId,
    stage: stage,
    eventType: eventType,
    remoteNotificationId: source == PendingMessageSource.remote
        ? messageId
        : null,
    remoteDeliveryResolutionKey: source == PendingMessageSource.remote
        ? remoteDeliveryResolutionKey ?? 'delivery:$messageId'
        : remoteDeliveryResolutionKey,
    createdAt: createdAt,
  );
}

final class _GatedActions implements NotificationCenterActionPort {
  _GatedActions({
    this.immediateHandled = false,
    this.handledGate,
    this.handledResults = const <bool>[],
  });

  final bool immediateHandled;
  final Completer<bool>? handledGate;
  final List<bool> handledResults;
  Completer<bool> readGate = Completer<bool>();
  final Completer<bool> openGate = Completer<bool>();
  final Completer<PendingMessageMarkAllReadResult> bulkGate =
      Completer<PendingMessageMarkAllReadResult>();
  bool throwOnRead = false;
  int markReadCalls = 0;
  int markAllReadCalls = 0;
  int markOpenedCalls = 0;
  int markHandledCalls = 0;
  final List<PendingMessage> handledItems = <PendingMessage>[];

  @override
  Future<bool> markRead(PendingMessage item) {
    markReadCalls += 1;
    if (throwOnRead) throw StateError('read failed');
    return readGate.future;
  }

  @override
  Future<PendingMessageMarkAllReadResult> markAllRead() {
    markAllReadCalls += 1;
    return bulkGate.future;
  }

  @override
  Future<bool> markOpened(PendingMessage item) {
    markOpenedCalls += 1;
    return openGate.future;
  }

  @override
  Future<bool> markHandled(PendingMessage item) async {
    handledItems.add(item);
    markHandledCalls += 1;
    if (handledGate != null) return handledGate!.future;
    if (markHandledCalls <= handledResults.length) {
      return handledResults[markHandledCalls - 1];
    }
    return immediateHandled;
  }
}
