import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/notifications/application/notification_destination_registry.dart';
import 'package:huahuoai_app/features/notifications/domain/notification_models.dart';
import 'package:huahuoai_app/features/notifications/domain/push_message.dart';

void main() {
  const registry = NotificationDestinationRegistry();

  group('NotificationDestinationRegistry', () {
    test('uses one target mapping for inbox notifications and Push', () {
      final cases = <({String eventType, String targetType, String location})>[
        (
          eventType: 'recording.deposit.succeeded',
          targetType: 'recording',
          location: '/v3/feed/transcription-done/id-1?destination=raw',
        ),
        (
          eventType: 'recording.batch.updated',
          targetType: 'recording_batch',
          location: '/v3/feed/transcription-batches/id-1',
        ),
        (
          eventType: 'thread.reply.ready',
          targetType: 'thread',
          location: '/v3/feed/chat?threadId=id-1&purpose=general',
        ),
        (
          eventType: 'note.outline.completed',
          targetType: 'note',
          location: '/v3/feed/items/id-1?stage=summary',
        ),
        (
          eventType: 'note.germination.completed',
          targetType: 'hnote',
          location: '/v3/feed/items/id-1?stage=sprout',
        ),
        (
          eventType: 'asset.ready',
          targetType: 'asset',
          location: '/v3/assets?focus=overview',
        ),
        (
          eventType: 'task.succeeded',
          targetType: 'task',
          location: '/v3/workbench/tasks/id-1',
        ),
        (
          eventType: 'hotspot_suggestion',
          targetType: 'hotspot_suggestion',
          location: '/v3/feed',
        ),
        (
          eventType: 'topic_recommendation.ready',
          targetType: 'topic_recommendation',
          location: '/v3/workbench/recommendations/id-1',
        ),
        (
          eventType: 'graph.ready',
          targetType: 'graph',
          location: '/v3/feed/graph',
        ),
      ];

      for (final item in cases) {
        final notification = _notification(
          eventType: item.eventType,
          targetType: item.targetType,
        );
        final push = _push(
          eventType: item.eventType,
          targetType: item.targetType,
        );

        expect(
          registry.forNotification(notification)?.location,
          item.location,
          reason: 'inbox ${item.targetType}',
        );
        expect(
          registry.forPush(push)?.location,
          item.location,
          reason: 'Push ${item.targetType}',
        );
      }
    });

    test('adds the deep-positioning purpose only for its thread signal', () {
      final destination = registry.forNotification(
        _notification(
          scene: 'social_positioning',
          eventType: 'positioning_lv2.thread.ready',
          targetType: 'thread',
        ),
      );

      expect(destination?.kind, NotificationDestinationKind.thread);
      expect(
        destination?.purpose,
        NotificationDestinationPurpose.deepPositioning,
      );
      expect(
        destination?.location,
        '/v3/feed/chat?threadId=id-1&purpose=deep-positioning',
      );
    });

    test('adds an explicit general purpose for an ordinary thread signal', () {
      final destination = registry.forNotification(
        _notification(eventType: 'thread.reply.ready', targetType: 'thread'),
      );

      expect(destination?.purpose, NotificationDestinationPurpose.general);
      expect(
        destination?.location,
        '/v3/feed/chat?threadId=id-1&purpose=general',
      );
    });

    test('routes positioning progress and reports to the report page', () {
      final progress = registry.resolve(
        scene: 'onboarding',
        eventType: 'positioning.running',
        targetType: 'positioning_progress',
        targetId: 'agent_run_1',
      );
      expect(
        progress?.location,
        '/v3/workbench/deep-positioning?focus=report&taskId=agent_run_1',
      );
      final destination = registry.resolve(
        scene: 'onboarding',
        eventType: 'positioning.completed',
        targetType: 'positioning_report',
        targetId: 'agent_run_1',
      );

      expect(destination?.kind, NotificationDestinationKind.positioningReport);
      expect(
        destination?.location,
        '/v3/workbench/deep-positioning?focus=report&taskId=agent_run_1',
      );
    });

    test('shares the bounded Chat Thread identifier envelope', () {
      final acceptedId = 't' * 128;
      final accepted = registry.resolve(
        scene: 'chat',
        eventType: 'thread.reply.ready',
        targetType: 'thread',
        targetId: acceptedId,
      );
      final rejected = registry.resolve(
        scene: 'chat',
        eventType: 'thread.reply.ready',
        targetType: 'thread',
        targetId: 't' * 129,
      );

      expect(accepted?.targetId, acceptedId);
      expect(
        registry.receiptForCommittedUri(accepted!.uri)?.targetId,
        acceptedId,
      );
      expect(rejected, isNull);
    });

    test('keeps a plain note in the typed raw stage', () {
      final destination = registry.forPush(
        _push(eventType: 'note.ready', targetType: 'note'),
      );

      expect(destination?.kind, NotificationDestinationKind.note);
      expect(destination?.targetType, 'asset');
      expect(destination?.stage, NotificationDestinationStage.raw);
      expect(destination?.location, '/v3/feed/items/id-1');
    });

    test('preserves and encodes public identifiers', () {
      final recording = registry.resolve(
        scene: 'recording',
        eventType: 'recording.deposit.succeeded',
        targetType: 'recording',
        targetId: 'recording:part.1',
      );
      final suggestion = registry.resolve(
        scene: 'feed',
        eventType: 'hotspot_suggestion',
        targetType: 'hotspot_suggestion',
        targetId: 'suggestion:1',
      );

      expect(
        recording?.location,
        '/v3/feed/transcription-done/recording%3Apart.1?destination=raw',
      );
      expect(suggestion?.kind, NotificationDestinationKind.hotspotSuggestion);
      expect(suggestion?.location, '/v3/feed');
      expect(suggestion?.targetId, 'suggestion:1');
      expect(
        registry.receiptForCommittedUri(recording!.uri)?.targetId,
        'recording:part.1',
      );
      expect(registry.receiptForCommittedUri(suggestion!.uri), isNull);
    });

    test('uses active batch context only with retained local evidence', () {
      final active = registry.forRecordingWithBatchContext(
        recordingId: 'recording-1',
        activeBatchId: 'batch:1',
        focusItemId: 'item:1',
      );
      final fallback = registry.forRecordingWithBatchContext(
        recordingId: 'recording-1',
      );

      expect(active?.kind, NotificationDestinationKind.recordingBatch);
      expect(
        active?.location,
        '/v3/feed/transcription-batches/batch%3A1?focusItem=item%3A1',
      );
      expect(active?.focusItemId, 'item:1');
      expect(
        fallback?.location,
        '/v3/feed/transcription-done/recording-1?destination=raw',
      );
    });

    test('does not guess unsupported or unsafe targets', () {
      expect(
        registry.resolve(
          scene: 'feed',
          eventType: 'event.ready',
          targetType: 'conversation',
          targetId: 'id-1',
        ),
        isNull,
      );
      expect(
        registry.resolve(
          scene: 'recording',
          eventType: 'recording.deposit.succeeded',
          targetType: 'recording',
          targetId: '../../settings',
        ),
        isNull,
      );
    });
  });

  group('committed destination receipts', () {
    test('extracts thread and recording identity', () {
      final thread = registry.receiptForCommittedUri(
        Uri.parse('/v3/feed/chat?threadId=thread%3A1&purpose=deep-positioning'),
      );
      final recording = registry.receiptForCommittedUri(
        Uri.parse('/v3/feed/transcription-done/recording%3A1?destination=raw'),
      );

      expect(thread?.kind, NotificationDestinationKind.thread);
      expect(thread?.targetType, 'thread');
      expect(thread?.targetId, 'thread:1');
      expect(thread?.purpose, NotificationDestinationPurpose.deepPositioning);
      expect(recording?.kind, NotificationDestinationKind.recording);
      expect(recording?.targetId, 'recording:1');
    });

    test('extracts a focused recording batch and rejects ambiguous queries', () {
      final receipt = registry.receiptForCommittedUri(
        Uri.parse(
          '/v3/feed/transcription-batches/batch%3A1?focusItem=item%3A1',
        ),
      );
      final duplicate = registry.receiptForCommittedUri(
        Uri.parse(
          '/v3/feed/transcription-batches/batch-1?focusItem=one&focusItem=two',
        ),
      );
      final unknown = registry.receiptForCommittedUri(
        Uri.parse('/v3/feed/transcription-batches/batch-1?other=value'),
      );

      expect(receipt?.kind, NotificationDestinationKind.recordingBatch);
      expect(receipt?.targetId, 'batch:1');
      expect(receipt?.focusItemId, 'item:1');
      expect(duplicate, isNull);
      expect(unknown, isNull);
    });

    test('normalizes a rendered note route to its result receipt', () {
      final outline = registry.receiptForCommittedUri(
        Uri.parse('/v3/feed/items/note-1?stage=summary'),
      );
      final sprout = registry.receiptForCommittedUri(
        Uri.parse('/v3/feed/items/note-1?stage=sprout'),
      );
      final raw = registry.receiptForCommittedUri(
        Uri.parse('/v3/feed/items/note-1'),
      );

      expect(outline?.targetType, 'asset');
      expect(outline?.targetId, 'note-1');
      expect(outline?.stage, NotificationDestinationStage.outline);
      expect(outline?.stageValue, 'outline');
      expect(sprout?.stage, NotificationDestinationStage.sprout);
      expect(raw?.stage, NotificationDestinationStage.raw);
      expect(raw?.stageValue, 'raw');
    });

    test('extracts task and positioning report receipts', () {
      final task = registry.receiptForCommittedUri(
        Uri.parse('/v3/workbench/tasks/task-1'),
      );
      final report = registry.receiptForCommittedUri(
        Uri.parse('/v3/workbench/deep-positioning?focus=report&taskId=run%3A1'),
      );
      final legacyReport = registry.receiptForCommittedUri(
        Uri.parse(
          '/v3/profile/digital-twin?file=social_positioning&focus=report&taskId=run%3A1',
        ),
      );

      expect(task?.kind, NotificationDestinationKind.task);
      expect(task?.targetId, 'task-1');
      expect(report?.kind, NotificationDestinationKind.positioningReport);
      expect(report?.targetType, 'positioning_report');
      expect(report?.targetId, 'run:1');
      expect(report?.stageValue, 'report');
      expect(legacyReport?.kind, NotificationDestinationKind.positioningReport);
      expect(legacyReport?.targetId, 'run:1');
      expect(
        registry.receiptForCommittedUri(
          Uri.parse(
            '/v3/profile/digital-twin?file=social_positioning&focus=report&taskId=run%3A1&extra=1',
          ),
        ),
        isNull,
      );
    });

    test('keeps hotspot overview outside exact result receipts', () {
      final recommendation = registry.receiptForCommittedUri(
        Uri.parse('/v3/workbench/recommendations/recommendation-1'),
      );
      final suggestion = registry.receiptForCommittedUri(Uri.parse('/v3/feed'));

      expect(
        recommendation?.kind,
        NotificationDestinationKind.topicRecommendation,
      );
      expect(recommendation?.targetId, 'recommendation-1');
      expect(suggestion, isNull);
      expect(
        registry.isExactResultDestination(
          location: '/v3/feed/items/suggestion-1',
          targetType: 'hotspot_suggestion',
          targetId: 'suggestion-1',
        ),
        isFalse,
      );
    });

    test('rejects ambiguous, external, and unrelated committed URIs', () {
      expect(
        registry.receiptForCommittedUri(
          Uri.parse('/v3/feed/chat?threadId=one&threadId=two'),
        ),
        isNull,
      );
      expect(
        registry.receiptForCommittedUri(
          Uri.parse('/v3/feed/chat?threadId=thread-without-purpose'),
        ),
        isNull,
      );
      expect(
        registry.receiptForCommittedUri(
          Uri.parse('/v3/feed/items/note-1?stage=raw&stage=sprout'),
        ),
        isNull,
      );
      expect(
        registry.receiptForCommittedUri(
          Uri.parse('https://example.com/v3/feed/items/note-1'),
        ),
        isNull,
      );
      expect(
        registry.receiptForCommittedUri(Uri.parse('/v3/notifications')),
        isNull,
      );
      expect(
        registry.receiptForCommittedUri(
          Uri.parse('/v3?suggestionId=suggestion-1'),
        ),
        isNull,
      );
    });
  });
}

AppNotification _notification({
  String scene = 'feed',
  required String eventType,
  required String targetType,
}) {
  return AppNotification(
    notificationId: 'notification-1',
    eventType: eventType,
    scene: scene,
    targetType: targetType,
    targetId: 'id-1',
    title: 'title',
    body: 'body',
    status: AppNotificationStatus.unread,
  );
}

PushMessage _push({
  String scene = 'feed',
  required String eventType,
  required String targetType,
}) {
  return PushMessage(
    notificationId: 'notification-1',
    eventType: eventType,
    scene: scene,
    targetType: targetType,
    targetId: 'id-1',
    title: 'title',
    body: 'body',
    receiveType: PushReceiveType.opened,
  );
}
