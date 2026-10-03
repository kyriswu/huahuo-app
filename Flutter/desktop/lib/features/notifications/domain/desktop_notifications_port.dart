import '../../../shared/services/desktop_service_result.dart';

enum DesktopNotificationStatus { unread, read, handled, expired }

/// Public execution state for an asynchronous notification target. Delivery
/// read state and task state are deliberately separate: reading a reminder
/// cannot make an in-flight Agent task complete.
enum DesktopNotificationTaskStatus {
  queued,
  resolving,
  planning,
  running,
  finalizing,
  succeeded,
  failed,
  timeout,
  cancelled,
  conflict;

  bool get isTerminal => switch (this) {
    DesktopNotificationTaskStatus.succeeded ||
    DesktopNotificationTaskStatus.failed ||
    DesktopNotificationTaskStatus.timeout ||
    DesktopNotificationTaskStatus.cancelled ||
    DesktopNotificationTaskStatus.conflict => true,
    _ => false,
  };

  static DesktopNotificationTaskStatus? tryParse(Object? value) =>
      switch (value) {
        'queued' => DesktopNotificationTaskStatus.queued,
        'resolving' => DesktopNotificationTaskStatus.resolving,
        'planning' => DesktopNotificationTaskStatus.planning,
        'running' => DesktopNotificationTaskStatus.running,
        'finalizing' => DesktopNotificationTaskStatus.finalizing,
        'succeeded' => DesktopNotificationTaskStatus.succeeded,
        'failed' => DesktopNotificationTaskStatus.failed,
        'timeout' => DesktopNotificationTaskStatus.timeout,
        'cancelled' => DesktopNotificationTaskStatus.cancelled,
        'conflict' => DesktopNotificationTaskStatus.conflict,
        _ => null,
      };
}

final class DesktopNotification {
  const DesktopNotification({
    required this.notificationId,
    required this.eventType,
    required this.scene,
    required this.targetType,
    required this.targetId,
    required this.title,
    required this.body,
    required this.status,
    this.taskStatus,
    this.taskId,
    this.createdAt,
  });

  final String notificationId;
  final String eventType;
  final String scene;
  final String targetType;
  final String targetId;
  final String title;
  final String body;
  final DesktopNotificationStatus status;
  final DesktopNotificationTaskStatus? taskStatus;
  final String? taskId;
  final DateTime? createdAt;

  bool get isUnread => status == DesktopNotificationStatus.unread;

  DesktopNotification copyWith({DesktopNotificationStatus? status}) =>
      DesktopNotification(
        notificationId: notificationId,
        eventType: eventType,
        scene: scene,
        targetType: targetType,
        targetId: targetId,
        title: title,
        body: body,
        status: status ?? this.status,
        taskStatus: taskStatus,
        taskId: taskId,
        createdAt: createdAt,
      );
}

final class DesktopNotificationPage {
  const DesktopNotificationPage({required this.items, this.nextCursor});

  final List<DesktopNotification> items;
  final String? nextCursor;
}

abstract interface class DesktopNotificationsPort {
  Future<DesktopServiceResult<DesktopNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  });

  Future<DesktopServiceResult<DesktopNotification>> markRead({
    required String notificationId,
    required String idempotencyKey,
  });
}

final class UnavailableDesktopNotificationsPort
    implements DesktopNotificationsPort {
  const UnavailableDesktopNotificationsPort();

  @override
  Future<DesktopServiceResult<DesktopNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async => const DesktopServiceResult<DesktopNotificationPage>.unavailable(
    code: 'DESKTOP_NOTIFICATIONS_UNAVAILABLE',
    message: '通知服务尚未配置',
  );

  @override
  Future<DesktopServiceResult<DesktopNotification>> markRead({
    required String notificationId,
    required String idempotencyKey,
  }) async => const DesktopServiceResult<DesktopNotification>.unavailable(
    code: 'DESKTOP_NOTIFICATIONS_UNAVAILABLE',
    message: '通知服务尚未配置',
  );
}

bool isSafeDesktopNotificationIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
