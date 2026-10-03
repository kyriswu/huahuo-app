import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../application/desktop_notifications_controller.dart';
import '../domain/desktop_notifications_port.dart';

final class DesktopNotificationsWorkspace extends StatefulWidget {
  const DesktopNotificationsWorkspace({
    required this.controller,
    required this.onOpen,
    super.key,
  });

  final DesktopNotificationsController controller;
  final Future<void> Function(DesktopNotification notification) onOpen;

  @override
  State<DesktopNotificationsWorkspace> createState() =>
      _DesktopNotificationsWorkspaceState();
}

final class _DesktopNotificationsWorkspaceState
    extends State<DesktopNotificationsWorkspace> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() => widget.controller.load());
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final state = widget.controller.state;
        return ColoredBox(
          key: const ValueKey<String>('desktop-notifications-workspace'),
          color: colors.surface,
          child: Column(
            children: [
              SizedBox(
                height: 56,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.bell,
                        size: 16,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 9),
                      Text(
                        '通知',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      IconButton(
                        key: const ValueKey<String>(
                          'desktop-notifications-refresh',
                        ),
                        tooltip: '刷新通知',
                        onPressed: state.isLoading
                            ? null
                            : () => widget.controller.load(),
                        icon: const Icon(LucideIcons.refreshCw, size: 16),
                      ),
                    ],
                  ),
                ),
              ),
              if (state.errorMessage?.trim().isNotEmpty == true)
                _ErrorStrip(
                  message: state.errorMessage!,
                  onRetry: state.isLoading
                      ? null
                      : () => widget.controller.load(),
                ),
              Expanded(child: _body(context, state)),
            ],
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, DesktopNotificationsState state) {
    if (state.isLoading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (state.items.isEmpty) {
      return _EmptyState(
        error: state.phase == DesktopNotificationsPhase.failure,
        onRetry: state.isLoading ? null : () => widget.controller.load(),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
      itemCount: state.items.length + (state.nextCursor == null ? 0 : 1),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == state.items.length) {
          return Align(
            child: TextButton.icon(
              key: const ValueKey<String>('desktop-notifications-load-more'),
              onPressed: state.isLoading
                  ? null
                  : () => widget.controller.load(refresh: false),
              icon: const Icon(LucideIcons.chevronsDown, size: 15),
              label: const Text('加载更多'),
            ),
          );
        }
        final item = state.items[index];
        final pending = state.pendingReadIds.contains(item.notificationId);
        return _NotificationRow(
          notification: item,
          pending: pending,
          onOpen: pending ? null : () => _open(item),
          onMarkRead: !item.isUnread || pending
              ? null
              : () => widget.controller.markRead(item),
        );
      },
    );
  }

  Future<void> _open(DesktopNotification item) async {
    await widget.controller.markRead(item);
    if (!mounted) return;
    await widget.onOpen(item);
  }
}

final class _NotificationRow extends StatelessWidget {
  const _NotificationRow({
    required this.notification,
    required this.pending,
    required this.onOpen,
    required this.onMarkRead,
  });

  final DesktopNotification notification;
  final bool pending;
  final VoidCallback? onOpen;
  final VoidCallback? onMarkRead;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: notification.isUnread
          ? colors.primaryContainer.withValues(alpha: .32)
          : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _icon(notification.scene),
                size: 17,
                color: notification.isUnread
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notification.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: notification.isUnread
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (notification.isUnread)
                          Container(
                            width: 7,
                            height: 7,
                            margin: const EdgeInsets.only(left: 8),
                            decoration: BoxDecoration(
                              color: colors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      notification.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          _time(notification.createdAt),
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                        if (notification.taskStatus != null)
                          _TaskStatusBadge(status: notification.taskStatus!),
                        if (pending)
                          const SizedBox.square(
                            dimension: 15,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        else ...[
                          if (onMarkRead != null)
                            IconButton(
                              tooltip: '标记已读',
                              onPressed: onMarkRead,
                              icon: const Icon(LucideIcons.check, size: 15),
                            ),
                          IconButton(
                            tooltip: '打开通知目标',
                            onPressed: onOpen,
                            icon: const Icon(
                              LucideIcons.arrowUpRight,
                              size: 15,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _TaskStatusBadge extends StatelessWidget {
  const _TaskStatusBadge({required this.status});

  final DesktopNotificationTaskStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final terminal = status.isTerminal;
    final successful = status == DesktopNotificationTaskStatus.succeeded;
    final color = !terminal || successful ? colors.primary : colors.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!terminal)
            SizedBox.square(
              dimension: 10,
              child: CircularProgressIndicator(color: color, strokeWidth: 1.6),
            )
          else
            Icon(
              successful ? LucideIcons.circleCheck : LucideIcons.circleAlert,
              size: 11,
              color: color,
            ),
          const SizedBox(width: 4),
          Text(
            _taskStatusLabel(status),
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

String _taskStatusLabel(DesktopNotificationTaskStatus status) =>
    switch (status) {
      DesktopNotificationTaskStatus.queued => '排队中',
      DesktopNotificationTaskStatus.resolving => '正在准备',
      DesktopNotificationTaskStatus.planning => '正在规划',
      DesktopNotificationTaskStatus.running => '运行中',
      DesktopNotificationTaskStatus.finalizing => '正在写入',
      DesktopNotificationTaskStatus.succeeded => '已完成',
      DesktopNotificationTaskStatus.failed => '未完成',
      DesktopNotificationTaskStatus.timeout => '已超时',
      DesktopNotificationTaskStatus.cancelled => '已取消',
      DesktopNotificationTaskStatus.conflict => '需要处理',
    };

final class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      color: colors.errorContainer,
      child: Row(
        children: [
          Icon(
            LucideIcons.circleAlert,
            size: 15,
            color: colors.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

final class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.error, required this.onRetry});

  final bool error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(error ? LucideIcons.circleAlert : LucideIcons.bellOff, size: 28),
        const SizedBox(height: 12),
        Text(error ? '通知暂时无法加载' : '暂时没有待处理通知'),
        const SizedBox(height: 8),
        TextButton(onPressed: onRetry, child: const Text('刷新')),
      ],
    ),
  );
}

IconData _icon(String scene) => switch (scene) {
  'chat' => LucideIcons.messagesSquare,
  'recording' => LucideIcons.audioLines,
  'asset' => LucideIcons.fileText,
  'work_ai' => LucideIcons.sparkles,
  _ => LucideIcons.bell,
};

String _time(DateTime? value) {
  if (value == null) return '刚刚';
  final difference = DateTime.now().toUtc().difference(value);
  if (difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes} 分钟前';
  if (difference.inDays < 1) return '${difference.inHours} 小时前';
  return '${value.month}月${value.day}日';
}
