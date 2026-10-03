import 'dart:convert';

import 'notification_models.dart';

enum PushReceiveType { foreground, opened, coldStart }

final class PushMessage {
  const PushMessage({
    required this.notificationId,
    required this.eventType,
    required this.scene,
    required this.targetType,
    required this.targetId,
    required this.title,
    required this.body,
    required this.receiveType,
    this.eventId,
    this.taskStatus,
  });

  final String notificationId;
  final String eventType;
  final String scene;
  final String targetType;
  final String targetId;
  final String title;
  final String body;
  final PushReceiveType receiveType;
  final String? eventId;
  final AppNotificationTaskStatus? taskStatus;

  String get fingerprint =>
      '$notificationId:${eventId ?? 'legacy'}:$eventType:$scene:$targetType:$targetId';
}

sealed class PushParseResult {
  const PushParseResult();

  bool get isValid => this is ValidPushMessage || this is InboxPushMessage;
}

final class ValidPushMessage extends PushParseResult {
  const ValidPushMessage(this.message);

  final PushMessage message;
}

final class InboxPushMessage extends PushParseResult {
  const InboxPushMessage({
    required this.notificationId,
    required this.eventType,
    required this.receiveType,
    this.eventId,
  });

  final String notificationId;
  final String eventType;
  final PushReceiveType receiveType;
  final String? eventId;

  String get fingerprint => '$notificationId:${eventId ?? 'legacy'}:$eventType';
}

final class InvalidPushPayload extends PushParseResult {
  const InvalidPushPayload(this.code);

  final String code;
}

PushParseResult parsePushMessage(
  Object? raw, {
  required PushReceiveType receiveType,
}) {
  final root = _stringMap(raw);
  if (root == null || root.isEmpty) {
    return const InvalidPushPayload('PUSH_PAYLOAD_NOT_OBJECT');
  }
  final extras = _pushExtras(root);
  if (extras == null) {
    return const InvalidPushPayload('PUSH_SCHEMA_UNSUPPORTED');
  }

  final payload = _stringMap(extras['payload']) ?? const <String, Object?>{};
  Object? field(String name) => extras[name] ?? payload[name];
  final schemaVersion = extras['schemaVersion'];
  if (schemaVersion != 'huahuo.push.v1') {
    if (schemaVersion != null) {
      return const InvalidPushPayload('PUSH_SCHEMA_UNSUPPORTED');
    }
    final notificationId = _safeOpaqueIdentifier(field('notificationId'));
    final eventType = _safeTag(field('eventType'));
    final suppliedEventId = field('eventId');
    final eventId = _safeOpaqueIdentifier(suppliedEventId);
    if (suppliedEventId != null && eventId == null) {
      return const InvalidPushPayload('PUSH_EVENT_ID_INVALID');
    }
    if (notificationId != null && eventType != null) {
      return InboxPushMessage(
        notificationId: notificationId,
        eventType: eventType,
        receiveType: receiveType,
        eventId: eventId,
      );
    }
    return const InvalidPushPayload('PUSH_SCHEMA_UNSUPPORTED');
  }

  final notificationId = _safeOpaqueIdentifier(field('notificationId'));
  final eventType = _safeTag(field('eventType'));
  final suppliedEventId = field('eventId');
  final eventId = _safeOpaqueIdentifier(suppliedEventId);
  if (notificationId == null ||
      eventType == null ||
      (suppliedEventId != null && eventId == null)) {
    return const InvalidPushPayload('PUSH_PAYLOAD_INVALID');
  }
  final target = _pushTarget(extras, payload);
  if (target == null) {
    return InboxPushMessage(
      notificationId: notificationId,
      eventType: eventType,
      receiveType: receiveType,
      eventId: eventId,
    );
  }
  final targetType = target.targetType;
  final scene = _safeTag(field('scene')) ?? _sceneForPushTarget(targetType);
  final targetId = target.targetId;
  final title = _safeDisplayText(root['title'] ?? field('title'), maximum: 160);
  final body = _safeDisplayText(
    root['body'] ?? root['alert'] ?? field('body'),
    maximum: 1000,
  );
  final taskStatus = AppNotificationTaskStatus.tryParse(field('taskStatus'));
  if (scene == null || title == null || body == null) {
    return const InvalidPushPayload('PUSH_PAYLOAD_INVALID');
  }
  if (field('taskStatus') != null && taskStatus == null) {
    return const InvalidPushPayload('PUSH_TASK_STATUS_INVALID');
  }

  return ValidPushMessage(
    PushMessage(
      notificationId: notificationId,
      eventType: eventType,
      scene: scene,
      targetType: targetType,
      targetId: targetId,
      title: title,
      body: body,
      receiveType: receiveType,
      eventId: eventId,
      taskStatus: taskStatus,
    ),
  );
}

({String targetType, String targetId})? _pushTarget(
  Map<String, Object?> extras,
  Map<String, Object?> payload,
) {
  final rootHasTarget =
      extras.containsKey('targetType') || extras.containsKey('targetId');
  final payloadHasTarget =
      payload.containsKey('targetType') || payload.containsKey('targetId');
  final root = rootHasTarget ? _targetPair(extras) : null;
  final nested = payloadHasTarget ? _targetPair(payload) : null;
  if ((rootHasTarget && root == null) || (payloadHasTarget && nested == null)) {
    return null;
  }
  if (root != null && nested != null && root != nested) return null;
  return root ?? nested;
}

({String targetType, String targetId})? _targetPair(
  Map<String, Object?> source,
) {
  final targetType = _safeTag(source['targetType']);
  final targetId = _safeOpaqueIdentifier(source['targetId']);
  if (targetType == null || targetId == null) return null;
  return (targetType: targetType, targetId: targetId);
}

String? _sceneForPushTarget(String? targetType) => switch (targetType) {
  'thread' => 'chat',
  'recording' => 'recording',
  'note' || 'asset' => 'asset',
  'task' => 'work_ai',
  _ => null,
};

Map<String, Object?>? _pushExtras(Map<String, Object?> root) {
  final direct = _stringMap(root['extras']);
  if (direct == null) {
    return _hasPushEnvelopeFields(root) ? root : null;
  }
  if (_hasPushEnvelopeFields(direct)) return direct;
  for (final key in const <String>[
    'cn.jpush.android.EXTRA',
    'extra',
    'custom',
  ]) {
    final nested = _stringMap(direct[key]);
    if (nested != null && _hasPushEnvelopeFields(nested)) return nested;
  }
  return null;
}

bool _hasPushEnvelopeFields(Map<String, Object?> value) {
  if (value.containsKey('schemaVersion') ||
      value.containsKey('notificationId') ||
      value.containsKey('eventType')) {
    return true;
  }
  final payload = _stringMap(value['payload']);
  return payload != null &&
      (payload.containsKey('notificationId') ||
          payload.containsKey('eventType'));
}

Map<String, Object?>? _stringMap(Object? value) {
  if (value is String) {
    try {
      return _stringMap(jsonDecode(value));
    } catch (_) {
      return null;
    }
  }
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

String? _safeOpaqueIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeNotificationOpaqueIdentifier(text) ? text : null;
}

String? _safeTag(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && RegExp(r'^[a-z][a-z0-9_.-]{0,63}$').hasMatch(text)
      ? text
      : null;
}

String? _safeDisplayText(Object? value, {required int maximum}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > maximum) return null;
  return _unsafePushText.hasMatch(text) ? null : text;
}

final _unsafePushText = RegExp(
  r'file://|/(private|var|home)/|access[-_ ]?token|refresh[-_ ]?token|push[-_ ]?token|provider.*key|runtime:',
  caseSensitive: false,
);
