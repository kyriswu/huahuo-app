import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_notifications_port.dart';

final class RemoteDesktopNotificationsPort implements DesktopNotificationsPort {
  const RemoteDesktopNotificationsPort(this._apiClient);

  final ApiClient _apiClient;

  NotificationClient get _notifications => NotificationClient(_apiClient);

  @override
  Future<DesktopServiceResult<DesktopNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    final normalizedCursor = cursor?.trim();
    if (normalizedCursor != null &&
        !isSafeDesktopNotificationIdentifier(normalizedCursor)) {
      return const DesktopServiceResult<DesktopNotificationPage>.failure(
        code: 'DESKTOP_NOTIFICATION_CURSOR_INVALID',
        message: '通知分页标识无效',
      );
    }
    if (limit != null && (limit < 1 || limit > 100)) {
      return const DesktopServiceResult<DesktopNotificationPage>.failure(
        code: 'DESKTOP_NOTIFICATION_LIMIT_INVALID',
        message: '通知分页大小无效',
      );
    }
    final result = await _notifications.list<DesktopNotificationPage>(
      cursor: normalizedCursor,
      limit: limit,
      parseData: _parsePage,
    );
    return _toDesktop(result);
  }

  @override
  Future<DesktopServiceResult<DesktopNotification>> markRead({
    required String notificationId,
    required String idempotencyKey,
  }) async {
    final normalizedId = notificationId.trim();
    if (!isSafeDesktopNotificationIdentifier(normalizedId) ||
        idempotencyKey.trim().isEmpty) {
      return const DesktopServiceResult<DesktopNotification>.failure(
        code: 'DESKTOP_NOTIFICATION_ID_INVALID',
        message: '通知标识无效',
      );
    }
    final result = await _notifications.markRead<DesktopNotification>(
      notificationId: normalizedId,
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: _parseReadReceipt,
    );
    return _toDesktop(result);
  }
}

DesktopServiceResult<T> _toDesktop<T>(ApiResult<T> result) {
  final data = result.data;
  if (result.ok && data != null) {
    return DesktopServiceResult<T>.success(data);
  }
  final failure = result.error;
  return DesktopServiceResult<T>.failure(
    code: failure?.code ?? 'DESKTOP_NOTIFICATION_RESPONSE_INVALID',
    message: failure?.message ?? '通知服务返回的数据无效',
    retryable: failure?.isRetryable ?? false,
  );
}

DesktopNotificationPage? _parsePage(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final rawItems = object['items'] ?? object['notifications'];
  if (rawItems is! List) return null;
  final items = <DesktopNotification>[];
  for (final raw in rawItems) {
    final item = _parseNotification(raw);
    if (item == null) return null;
    items.add(item);
  }
  final cursor = _safeIdentifier(object['nextCursor']);
  if (object['nextCursor'] != null && cursor == null) return null;
  return DesktopNotificationPage(
    items: List<DesktopNotification>.unmodifiable(items),
    nextCursor: cursor,
  );
}

DesktopNotification? _parseReadReceipt(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final nested = object['notification'];
  if (nested != null) return _parseNotification(nested);
  final notification = _parseNotification(object);
  if (notification != null) return notification;
  final id = _safeIdentifier(object['notificationId']);
  return id == null || object['status'] != 'read'
      ? null
      : DesktopNotification(
          notificationId: id,
          eventType: 'notification.read',
          scene: 'notification',
          targetType: 'notification',
          targetId: id,
          title: '通知已读',
          body: '通知已读',
          status: DesktopNotificationStatus.read,
        );
}

DesktopNotification? _parseNotification(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final payload = asObjectMap(object['payload']) ?? const <String, Object?>{};
  Object? field(String name) => object[name] ?? payload[name];
  final notificationId = _safeIdentifier(object['notificationId']);
  final eventType = _safeTag(field('eventType')) ?? 'system.legacy';
  final targetType = _safeTag(field('targetType'));
  final scene = _safeTag(field('scene')) ?? _sceneForTarget(targetType);
  final targetId = _safeIdentifier(field('targetId'));
  final title = _safeText(field('title'), 160);
  final body = _safeText(field('body'), 1000);
  final status = _status(object['status']);
  final rawTaskStatus = field('taskStatus');
  final taskStatus = DesktopNotificationTaskStatus.tryParse(rawTaskStatus);
  final rawTaskId = field('taskId');
  final taskId = _safeIdentifier(rawTaskId);
  final createdAt = _safeDate(object['createdAt']);
  if (notificationId == null ||
      targetType == null ||
      scene == null ||
      targetId == null ||
      title == null ||
      body == null ||
      status == null ||
      (rawTaskStatus != null && taskStatus == null) ||
      (rawTaskId != null && taskId == null) ||
      (object['createdAt'] != null && createdAt == null)) {
    return null;
  }
  return DesktopNotification(
    notificationId: notificationId,
    eventType: eventType,
    scene: scene,
    targetType: targetType,
    targetId: targetId,
    title: title,
    body: body,
    status: status,
    taskStatus: taskStatus,
    taskId: taskId,
    createdAt: createdAt,
  );
}

String? _safeIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeDesktopNotificationIdentifier(text)
      ? text
      : null;
}

String? _safeTag(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && RegExp(r'^[a-z][a-z0-9_.-]{0,63}$').hasMatch(text)
      ? text
      : null;
}

String? _safeText(Object? value, int maximum) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > maximum) return null;
  return _unsafeText.hasMatch(text) ? null : text;
}

DateTime? _safeDate(Object? value) {
  final text = value is String ? value.trim() : null;
  return text == null || text.length > 64
      ? null
      : DateTime.tryParse(text)?.toUtc();
}

DesktopNotificationStatus? _status(Object? value) => switch (value) {
  'unread' => DesktopNotificationStatus.unread,
  'read' => DesktopNotificationStatus.read,
  'handled' => DesktopNotificationStatus.handled,
  'expired' => DesktopNotificationStatus.expired,
  _ => null,
};

String? _sceneForTarget(String? targetType) => switch (targetType) {
  'thread' => 'chat',
  'recording' => 'recording',
  'note' || 'asset' => 'asset',
  'task' => 'work_ai',
  _ => null,
};

final _unsafeText = RegExp(
  r'file://|/home/|access-token|refresh-token|workspace|provider.*key|runtime:',
  caseSensitive: false,
);
