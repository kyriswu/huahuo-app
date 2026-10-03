enum AppNotificationStatus { unread, read, handled, expired }

enum AppNotificationTaskStatus {
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
    AppNotificationTaskStatus.succeeded ||
    AppNotificationTaskStatus.failed ||
    AppNotificationTaskStatus.timeout ||
    AppNotificationTaskStatus.cancelled ||
    AppNotificationTaskStatus.conflict => true,
    _ => false,
  };

  static AppNotificationTaskStatus? tryParse(Object? value) => switch (value) {
    'queued' => AppNotificationTaskStatus.queued,
    'resolving' => AppNotificationTaskStatus.resolving,
    'planning' => AppNotificationTaskStatus.planning,
    'running' => AppNotificationTaskStatus.running,
    'finalizing' => AppNotificationTaskStatus.finalizing,
    'succeeded' => AppNotificationTaskStatus.succeeded,
    'failed' => AppNotificationTaskStatus.failed,
    'timeout' => AppNotificationTaskStatus.timeout,
    'cancelled' => AppNotificationTaskStatus.cancelled,
    'conflict' => AppNotificationTaskStatus.conflict,
    _ => null,
  };
}

final class AppNotification {
  const AppNotification({
    required this.notificationId,
    required this.eventType,
    required this.scene,
    required this.targetType,
    required this.targetId,
    required this.title,
    required this.body,
    required this.status,
    this.workspaceId,
    this.taskStatus,
    this.taskId,
    this.eventId,
    this.createdAt,
    this.updatedAt,
    this.isReadReceipt = false,
  });

  const AppNotification.readReceipt({
    required this.notificationId,
    required this.status,
  }) : eventType = 'notification.read',
       scene = 'notification',
       targetType = 'notification',
       targetId = notificationId,
       title = '通知已读',
       body = '通知已读',
       workspaceId = null,
       taskStatus = null,
       taskId = null,
       eventId = null,
       createdAt = null,
       updatedAt = null,
       isReadReceipt = true;

  final String notificationId;
  final String eventType;
  final String scene;
  final String targetType;
  final String targetId;
  final String title;
  final String body;
  final AppNotificationStatus status;
  final String? workspaceId;
  final AppNotificationTaskStatus? taskStatus;
  final String? taskId;
  final String? eventId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool isReadReceipt;

  bool get isUnread => status == AppNotificationStatus.unread;
  bool get isUnresolved =>
      status == AppNotificationStatus.unread ||
      status == AppNotificationStatus.read;

  DateTime? get inboxOccurredAt =>
      isUnread ? updatedAt ?? createdAt : createdAt ?? updatedAt;

  bool get canMarkHandled => taskStatus?.isTerminal ?? true;

  AppNotificationTaskStatus? get resolvedTaskStatus {
    if (taskStatus != null) return taskStatus;
    if (taskId == null) return null;
    final tokens = '$scene.$eventType'.toLowerCase().split(
      RegExp(r'[^a-z0-9]+'),
    );
    for (final token in tokens.reversed) {
      final parsed = AppNotificationTaskStatus.tryParse(token);
      if (parsed != null) return parsed;
      if (const {'failure', 'error'}.contains(token)) {
        return AppNotificationTaskStatus.failed;
      }
      if (token == 'canceled') return AppNotificationTaskStatus.cancelled;
      if (const {
        'success',
        'completed',
        'finished',
        'ready',
        'deposited',
      }.contains(token)) {
        return AppNotificationTaskStatus.succeeded;
      }
    }
    return null;
  }

  AppNotification copyWith({
    AppNotificationStatus? status,
    bool? isReadReceipt,
  }) {
    return AppNotification(
      notificationId: notificationId,
      eventType: eventType,
      scene: scene,
      targetType: targetType,
      targetId: targetId,
      title: title,
      body: body,
      status: status ?? this.status,
      workspaceId: workspaceId,
      taskStatus: taskStatus,
      taskId: taskId,
      eventId: eventId,
      createdAt: createdAt,
      updatedAt: updatedAt,
      isReadReceipt: isReadReceipt ?? this.isReadReceipt,
    );
  }
}

bool preferTaskNotificationSnapshot({
  required AppNotification current,
  required AppNotification candidate,
}) {
  final currentStatus = current.resolvedTaskStatus;
  final candidateStatus = candidate.resolvedTaskStatus;
  final currentTerminal = currentStatus?.isTerminal ?? false;
  final candidateTerminal = candidateStatus?.isTerminal ?? false;
  if (currentTerminal != candidateTerminal) {
    final terminal = currentTerminal ? current : candidate;
    final active = currentTerminal ? candidate : current;
    final terminalTime = terminal.updatedAt ?? terminal.createdAt;
    final activeTime = active.updatedAt ?? active.createdAt;
    final isNewRetry =
        terminal.resolvedTaskStatus != AppNotificationTaskStatus.succeeded &&
        terminal.eventId != null &&
        active.eventId != null &&
        terminal.eventId != active.eventId &&
        terminalTime != null &&
        activeTime != null &&
        activeTime.isAfter(terminalTime);
    if (!isNewRetry) return candidateTerminal;
  }
  if (current.eventId != null &&
      current.eventId == candidate.eventId &&
      !currentTerminal &&
      !candidateTerminal &&
      currentStatus != null &&
      candidateStatus != null &&
      currentStatus != candidateStatus) {
    return candidateStatus.index > currentStatus.index;
  }
  final currentTime = current.updatedAt ?? current.createdAt;
  final candidateTime = candidate.updatedAt ?? candidate.createdAt;
  if (currentTime != null &&
      candidateTime != null &&
      currentTime != candidateTime) {
    return candidateTime.isAfter(currentTime);
  }
  if (currentTerminal != candidateTerminal) return candidateTerminal;
  return candidate.notificationId.compareTo(current.notificationId) >= 0;
}

final class AppNotificationPage {
  const AppNotificationPage({
    required this.items,
    this.nextCursor,
    this.rejectedItemCount = 0,
  }) : assert(rejectedItemCount >= 0);

  final List<AppNotification> items;
  final String? nextCursor;
  final int rejectedItemCount;

  bool get hasRejectedItems => rejectedItemCount > 0;
}

bool isAccountLevelNotificationCompatibility(AppNotification notification) =>
    notification.workspaceId == null &&
    notification.eventType == 'topic_recommendation.ready' &&
    notification.targetType == 'topic_recommendation' &&
    notification.scene == 'work_ai';

bool isSafeNotificationIdentifier(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
}

bool isSafeNotificationOpaqueIdentifier(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,511}$').hasMatch(value);
}

bool isSafeNotificationTaskIdentifier(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,511}$').hasMatch(value);
}
