import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/notifications/application/push_navigation_controller.dart';
import 'package:huahuoai_app/features/notifications/domain/notification_models.dart';
import 'package:huahuoai_app/features/notifications/domain/push_message.dart';

void main() {
  group('pushLocation', () {
    test('maps the supported safe targets', () {
      expect(
        _location('recording', 'recording'),
        '/v3/feed/transcription-done/id-1?destination=raw',
      );
      expect(_location('work_ai', 'task'), '/v3/workbench/tasks/id-1');
      expect(_location('feed', 'note'), '/v3/feed/items/id-1');
      expect(_location('asset', 'note'), '/v3/feed/items/id-1');
      expect(
        _location('asset', 'note', eventType: 'note.outline.completed'),
        '/v3/feed/items/id-1?stage=summary',
      );
      expect(
        _location('asset', 'note', eventType: 'note.germination.completed'),
        '/v3/feed/items/id-1?stage=sprout',
      );
      expect(
        _location('chat', 'thread'),
        '/v3/feed/chat?threadId=id-1&purpose=general',
      );
      expect(
        _location('chat', 'thread', eventType: 'deep_positioning.reply_ready'),
        '/v3/feed/chat?threadId=id-1&purpose=deep-positioning',
      );
      expect(_location('asset', 'asset'), '/v3/assets?focus=overview');
      expect(_location('graph', 'graph'), '/v3/feed/graph');
      expect(_location('chat', 'conversation'), '/v3/notifications');
    });

    test('matches only a Push for the current public chat thread', () {
      final current = _message(scene: 'chat', targetType: 'thread');
      expect(isPushForChatThread(current, 'id-1'), isTrue);
      expect(isPushForChatThread(current, 'id-2'), isFalse);
      expect(
        isPushForChatThread(_message(targetType: 'recording'), 'id-1'),
        isFalse,
      );
    });
  });

  group('PushNavigationController', () {
    test('deduplicates opened and cold-start callbacks by fingerprint', () {
      final controller = PushNavigationController();
      addTearDown(controller.dispose);
      var changes = 0;
      controller.addListener(() => changes += 1);

      controller.receive(
        ValidPushMessage(_message(receiveType: PushReceiveType.opened)),
        PushReceiveType.opened,
      );
      final first = controller.pendingCommand;
      expect(first?.notificationId, 'notice-1');
      controller.receive(
        ValidPushMessage(_message(receiveType: PushReceiveType.coldStart)),
        PushReceiveType.coldStart,
      );

      expect(controller.pendingCommand, same(first));
      expect(changes, 1);
      controller.consume(first!.id);
      expect(controller.pendingCommand, isNull);
      controller.receive(
        ValidPushMessage(_message(receiveType: PushReceiveType.opened)),
        PushReceiveType.opened,
      );
      expect(controller.pendingCommand, isNull);
    });

    test('rejected ingress can be explicitly opened again', () {
      final controller = PushNavigationController();
      addTearDown(controller.dispose);

      final valid = ValidPushMessage(_message(eventId: 'event-retry-1'));
      controller.receive(valid, PushReceiveType.opened);
      final validId = controller.pendingCommand!.id;
      controller.reject(validId);
      controller.receive(valid, PushReceiveType.opened);
      expect(controller.pendingCommand?.id, validId);
      controller.consume(validId);

      const inbox = InboxPushMessage(
        notificationId: 'notice-inbox-retry-1',
        eventId: 'event-inbox-retry-1',
        eventType: 'hotspot_suggestion',
        receiveType: PushReceiveType.opened,
      );
      controller.receive(inbox, PushReceiveType.opened);
      final inboxId = controller.pendingCommand!.id;
      controller.reject(inboxId);
      controller.receive(inbox, PushReceiveType.opened);
      expect(controller.pendingCommand?.id, inboxId);
      controller.consume(inboxId);

      controller.receive(
        const InvalidPushPayload('PUSH_PAYLOAD_INVALID'),
        PushReceiveType.opened,
      );
      final invalidId = controller.pendingCommand!.id;
      controller.reject(invalidId);
      controller.receive(
        const InvalidPushPayload('PUSH_PAYLOAD_INVALID'),
        PushReceiveType.opened,
      );
      expect(controller.pendingCommand?.id, isNot(invalidId));
    });

    test(
      'rejection releases a versioned delivery but consumption retains it',
      () {
        final controller = PushNavigationController();
        addTearDown(controller.dispose);
        final message = ValidPushMessage(_message());

        controller.receive(message, PushReceiveType.opened);
        final rejected = controller.pendingCommand!;
        controller.reject(rejected.id);
        expect(controller.pendingCommand, isNull);

        controller.receive(message, PushReceiveType.opened);
        final consumed = controller.pendingCommand!;
        controller.consume(consumed.id);
        controller.receive(message, PushReceiveType.coldStart);
        expect(controller.pendingCommand, isNull);
      },
    );

    test('keeps reused notification rows separate by event revision', () {
      final controller = PushNavigationController();
      addTearDown(controller.dispose);

      controller.receive(
        ValidPushMessage(_message(eventId: 'event-1')),
        PushReceiveType.opened,
      );
      final first = controller.pendingCommand!;
      controller.consume(first.id);
      controller.receive(
        ValidPushMessage(_message(eventId: 'event-2')),
        PushReceiveType.opened,
      );
      final second = controller.pendingCommand!;
      const currentDelivery = AppNotification(
        notificationId: 'notice-1',
        eventId: 'event-2',
        eventType: 'event.completed',
        scene: 'recording',
        targetType: 'recording',
        targetId: 'id-1',
        title: 'title',
        body: 'body',
        status: AppNotificationStatus.unread,
      );

      expect(second.id, isNot(first.id));
      expect(first.matchesDelivery(currentDelivery), isFalse);
      expect(second.matchesDelivery(currentDelivery), isTrue);
    });

    test(
      'revisionless complete pushes stay inbox-only and remain reusable',
      () {
        final controller = PushNavigationController();
        addTearDown(controller.dispose);
        final legacy = _message(eventId: null);
        const currentDelivery = AppNotification(
          notificationId: 'notice-1',
          eventId: 'event-2',
          eventType: 'event.completed',
          scene: 'recording',
          targetType: 'recording',
          targetId: 'id-1',
          title: 'title',
          body: 'body',
          status: AppNotificationStatus.unread,
        );

        controller.receive(ValidPushMessage(legacy), PushReceiveType.opened);
        final first = controller.pendingCommand!;
        controller.receive(ValidPushMessage(legacy), PushReceiveType.coldStart);
        expect(controller.pendingCommand, same(first));
        expect(first.location, '/v3/notifications');
        expect(first.matchesDelivery(currentDelivery), isFalse);

        controller.consume(first.id);
        controller.receive(ValidPushMessage(legacy), PushReceiveType.opened);
        expect(controller.pendingCommand?.id, isNot(first.id));
      },
    );

    test('coalesces invalid opens only while a command is pending', () {
      final controller = PushNavigationController();
      addTearDown(controller.dispose);

      controller.receive(
        const InvalidPushPayload('PUSH_PAYLOAD_INVALID'),
        PushReceiveType.opened,
      );
      final first = controller.pendingCommand;
      expect(first?.location, '/v3/notifications');
      controller.receive(
        const InvalidPushPayload('PUSH_SCHEMA_UNSUPPORTED'),
        PushReceiveType.coldStart,
      );
      expect(controller.pendingCommand, same(first));
      controller.consume(first!.id);
      controller.receive(
        const InvalidPushPayload('PUSH_PAYLOAD_INVALID'),
        PushReceiveType.opened,
      );
      expect(controller.pendingCommand?.location, '/v3/notifications');
      expect(controller.pendingCommand?.id, isNot(first.id));
    });

    test('consumes distinct privacy-safe inbox pushes independently', () {
      final controller = PushNavigationController();
      addTearDown(controller.dispose);
      const firstMessage = InboxPushMessage(
        notificationId: 'notice-inbox-1',
        eventType: 'hotspot_suggestion',
        receiveType: PushReceiveType.opened,
      );
      const secondMessage = InboxPushMessage(
        notificationId: 'notice-inbox-2',
        eventType: 'recording.deposit.succeeded',
        receiveType: PushReceiveType.opened,
      );

      controller.receive(firstMessage, PushReceiveType.opened);
      final first = controller.pendingCommand;
      controller.receive(firstMessage, PushReceiveType.coldStart);
      expect(controller.pendingCommand, same(first));
      expect(first?.location, '/v3/notifications');
      expect(first?.notificationId, 'notice-inbox-1');

      controller.consume(first!.id);
      controller.receive(secondMessage, PushReceiveType.opened);
      expect(controller.pendingCommand?.id, isNot(first.id));
      expect(controller.pendingCommand?.location, '/v3/notifications');
      expect(controller.pendingCommand?.notificationId, 'notice-inbox-2');
    });

    test('publishes a foreground command only after banner activation', () {
      final controller = PushNavigationController();
      addTearDown(controller.dispose);
      final message = _message(receiveType: PushReceiveType.foreground);

      controller.receive(ValidPushMessage(message), PushReceiveType.foreground);
      expect(controller.pendingCommand, isNull);

      controller.openForeground(message);
      final first = controller.pendingCommand;
      expect(first?.receiveType, PushReceiveType.foreground);
      expect(first?.notificationId, 'notice-1');
      expect(
        first?.location,
        '/v3/feed/transcription-done/id-1?destination=raw',
      );
      controller.openForeground(message);
      expect(controller.pendingCommand?.id, isNot(first?.id));
      controller.clear();
      expect(controller.pendingCommand, isNull);
    });

    test('routes a retained recording target through its active batch', () {
      final controller = PushNavigationController(
        recordingBatchContextResolver: (recordingId) => recordingId == 'id-1'
            ? (batchId: 'batch-a', itemId: 'item-a')
            : null,
      );
      addTearDown(controller.dispose);
      final message = _message();

      controller.receive(ValidPushMessage(message), PushReceiveType.opened);
      expect(
        controller.pendingCommand?.location,
        '/v3/feed/transcription-batches/batch-a?focusItem=item-a',
      );
      controller.openForeground(message);
      expect(
        controller.pendingCommand?.location,
        '/v3/feed/transcription-batches/batch-a?focusItem=item-a',
      );

      final fallback = PushNavigationController(
        recordingBatchContextResolver: (_) => throw StateError('not ready'),
      );
      addTearDown(fallback.dispose);
      fallback.receive(ValidPushMessage(message), PushReceiveType.opened);
      expect(
        fallback.pendingCommand?.location,
        '/v3/feed/transcription-done/id-1?destination=raw',
      );
    });
  });
}

String _location(
  String scene,
  String targetType, {
  String eventType = 'event.completed',
}) => pushLocation(
  _message(scene: scene, targetType: targetType, eventType: eventType),
);

PushMessage _message({
  String scene = 'recording',
  String targetType = 'recording',
  String eventType = 'event.completed',
  String? eventId = 'event-1',
  PushReceiveType receiveType = PushReceiveType.opened,
}) => PushMessage(
  notificationId: 'notice-1',
  eventId: eventId,
  eventType: eventType,
  scene: scene,
  targetType: targetType,
  targetId: 'id-1',
  title: 'title',
  body: 'body',
  receiveType: receiveType,
);
