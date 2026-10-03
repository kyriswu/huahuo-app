import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/notifications/domain/push_message.dart';

void main() {
  group('parsePushMessage', () {
    test('accepts the deployed privacy-safe payload as inbox-only', () {
      final result = parsePushMessage(<String, Object?>{
        'notificationId': 'notification-production-1',
        'eventType': 'hotspot_suggestion',
        'collapseKey': 'huahuo:notification-production-1',
      }, receiveType: PushReceiveType.opened);

      expect(result, isA<InboxPushMessage>());
      final message = result as InboxPushMessage;
      expect(message.isValid, isTrue);
      expect(message.notificationId, 'notification-production-1');
      expect(message.eventType, 'hotspot_suggestion');
      expect(message.eventId, isNull);
      expect(message.receiveType, PushReceiveType.opened);
    });

    test('preserves a versioned privacy-safe inbox delivery', () {
      final result = parsePushMessage(<String, Object?>{
        'notificationId': 'notification-production-1',
        'eventId': 'hotspot-event-2',
        'eventType': 'hotspot_suggestion',
      }, receiveType: PushReceiveType.opened);

      expect(result, isA<InboxPushMessage>());
      expect((result as InboxPushMessage).eventId, 'hotspot-event-2');
    });

    test('accepts the iOS flat extras shape', () {
      final result = parsePushMessage(<String, Object?>{
        ..._extras,
        'title': '转写完成',
        'body': '访谈内容已经可以查看。',
      }, receiveType: PushReceiveType.foreground);

      expect(result, isA<ValidPushMessage>());
      final message = (result as ValidPushMessage).message;
      expect(message.notificationId, 'notice-1');
      expect(message.eventId, 'recording-event-1');
      expect(message.targetId, 'recording-1');
      expect(message.receiveType, PushReceiveType.foreground);
      expect(message.title, '转写完成');
    });

    test('accepts Android nested extras as a map or JSON string', () {
      for (final nested in <Object?>[_extras, jsonEncode(_extras)]) {
        final result = parsePushMessage(<String, Object?>{
          'title': '转写完成',
          'alert': '访谈内容已经可以查看。',
          'extras': <String, Object?>{'cn.jpush.android.EXTRA': nested},
        }, receiveType: PushReceiveType.opened);

        expect(result, isA<ValidPushMessage>());
        expect(
          (result as ValidPushMessage).message.receiveType,
          PushReceiveType.opened,
        );
      }
    });

    test('accepts the complete public contract nested under payload', () {
      final result = parsePushMessage(<String, Object?>{
        'title': '纲要已生成',
        'body': '可以查看资产纲要。',
        'extras': <String, Object?>{
          'schemaVersion': 'huahuo.push.v1',
          'payload': <String, Object?>{
            'notificationId': 'notice-outline-1',
            'eventId': 'outline-event-1',
            'eventType': 'note.outline.completed',
            'scene': 'asset',
            'targetType': 'note',
            'targetId': 'note-1',
            'title': '纲要已生成',
            'body': '可以查看资产纲要。',
          },
        },
      }, receiveType: PushReceiveType.opened);

      expect(result, isA<ValidPushMessage>());
      final message = (result as ValidPushMessage).message;
      expect(message.eventId, 'outline-event-1');
      expect(message.eventType, 'note.outline.completed');
      expect(message.targetType, 'note');
      expect(message.targetId, 'note-1');
    });

    test('does not complete a partial root target from nested payload', () {
      final result = parsePushMessage(<String, Object?>{
        'title': '转写完成',
        'body': '可以查看结果。',
        'extras': <String, Object?>{
          'schemaVersion': 'huahuo.push.v1',
          'notificationId': 'notice-atomic-1',
          'eventId': 'event-atomic-1',
          'eventType': 'transcription.completed',
          'targetType': 'recording',
          'payload': <String, Object?>{
            'targetType': 'note',
            'targetId': 'note-from-legacy-payload',
          },
        },
      }, receiveType: PushReceiveType.opened);

      expect(result, isA<InboxPushMessage>());
      final message = result as InboxPushMessage;
      expect(message.notificationId, 'notice-atomic-1');
      expect(message.eventId, 'event-atomic-1');
    });

    test('does not route conflicting complete target pairs', () {
      final result = parsePushMessage(<String, Object?>{
        'title': '结果已完成',
        'body': '可以查看结果。',
        'extras': <String, Object?>{
          ..._extras,
          'payload': <String, Object?>{
            'targetType': 'note',
            'targetId': 'note-conflict-1',
          },
        },
      }, receiveType: PushReceiveType.opened);

      expect(result, isA<InboxPushMessage>());
      final message = result as InboxPushMessage;
      expect(message.notificationId, 'notice-1');
      expect(message.eventId, 'recording-event-1');
    });

    test('rejects unsupported schema and malformed identifiers', () {
      expect(
        parsePushMessage(<String, Object?>{
          ..._extras,
          'schemaVersion': 'other.v1',
        }, receiveType: PushReceiveType.opened),
        isA<InvalidPushPayload>().having(
          (value) => value.code,
          'code',
          'PUSH_SCHEMA_UNSUPPORTED',
        ),
      );
      expect(
        parsePushMessage(<String, Object?>{
          ..._extras,
          'targetId': '../private',
        }, receiveType: PushReceiveType.opened),
        isA<InboxPushMessage>(),
      );
      expect(
        parsePushMessage(<String, Object?>{
          ..._extras,
          'eventId': '../event',
        }, receiveType: PushReceiveType.opened),
        isA<InvalidPushPayload>().having(
          (value) => value.code,
          'code',
          'PUSH_PAYLOAD_INVALID',
        ),
      );
    });

    test('rejects private paths, token-like content, and excessive text', () {
      for (final title in <String>[
        'file:///private/internal.log',
        'access_token=secret',
        'x' * 161,
      ]) {
        expect(
          parsePushMessage(<String, Object?>{
            ..._extras,
            'title': title,
            'body': 'safe body',
          }, receiveType: PushReceiveType.coldStart),
          isA<InvalidPushPayload>(),
        );
      }
      expect(
        parsePushMessage(<String, Object?>{
          ..._extras,
          'title': 'safe title',
          'body': 'x' * 1001,
        }, receiveType: PushReceiveType.coldStart),
        isA<InvalidPushPayload>(),
      );
    });
  });
}

const _extras = <String, Object?>{
  'schemaVersion': 'huahuo.push.v1',
  'notificationId': 'notice-1',
  'eventId': 'recording-event-1',
  'eventType': 'transcription.completed',
  'scene': 'recording',
  'targetType': 'recording',
  'targetId': 'recording-1',
};
