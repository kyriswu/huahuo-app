import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../features/notifications/application/notification_center_state_machine.dart';
import '../../../features/notifications/application/pending_message_projection.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../application/feed_aggregation_controller.dart';

class V3NotificationsPage extends ConsumerStatefulWidget {
  const V3NotificationsPage({this.dismissBeforeNavigation = false, super.key});

  final bool dismissBeforeNavigation;

  @override
  ConsumerState<V3NotificationsPage> createState() =>
      _V3NotificationsPageState();
}

class _V3NotificationsPageState extends ConsumerState<V3NotificationsPage> {
  bool _navigationBusy = false;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() async {
      if (mounted) {
        await ref.read(notificationControllerProvider).load(forceRemote: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(notificationControllerProvider);
    final projection = ref.watch(pendingMessageProjectionProvider);
    final center = ref.watch(notificationCenterControllerProvider);
    final items = center.displayItems(projection.items);
    final unreadCount = center.badgeCount(items);
    final readDeleteCount = center.readDeletableCount(items);
    return V3NotificationsSurface(
      items: items,
      visibleItems: center.visibleItems(items),
      filter: center.filter,
      policies: center.policies,
      unreadCount: unreadCount,
      isLoading: projection.isLoading,
      errorCode: projection.remoteErrorCode,
      hasMore: projection.nextCursor != null,
      markAllReadBusy: center.bulkReadBusy,
      deleteReadBusy: center.bulkDeleteBusy,
      readDeleteCount: readDeleteCount,
      interactionsDisabled: center.hasBulkOperation || _navigationBusy,
      operationFor: center.operationFor,
      onClose: _close,
      onFilterChanged: center.setFilter,
      onMarkAllRead:
          unreadCount > 0 &&
              !center.hasItemOperation &&
              !center.hasBulkOperation &&
              !_navigationBusy
          ? _markAllRead
          : null,
      onDeleteRead:
          readDeleteCount > 0 &&
              !center.hasItemOperation &&
              !center.hasBulkOperation &&
              !_navigationBusy
          ? () => _deleteRead(items)
          : null,
      onRetry: () => controller.load(forceRemote: true),
      onRefresh: () => controller.load(forceRemote: true),
      onLoadMore: projection.isLoading
          ? null
          : () => controller.load(refresh: false),
      onItemTap: (item) => _openMessage(context, item),
      onMarkRead: _markRead,
      onArchive: _archive,
    );
  }

  Future<void> _markAllRead() async {
    final result = await ref
        .read(notificationCenterControllerProvider)
        .markAllRead();
    if (!mounted) return;
    if (result == null) {
      showV3Snack(context, '全部已读未能完成，请重试');
      return;
    }
    showV3Snack(
      context,
      result.failed > 0
          ? '已读 ${result.succeeded} 条，${result.failed} 条同步失败'
          : result.fullyEnumerated
          ? '已将 ${result.succeeded} 条消息标记为已读'
          : '已将当前 ${result.succeeded} 条消息标记为已读',
    );
  }

  Future<void> _markRead(PendingMessage item) async {
    if (await ref.read(notificationCenterControllerProvider).markRead(item) ||
        !mounted) {
      return;
    }
    showV3Snack(context, '标记已读失败，请重试');
  }

  Future<void> _deleteRead(List<PendingMessage> items) async {
    final result = await ref
        .read(notificationCenterControllerProvider)
        .deleteRead(items);
    if (!mounted) return;
    if (result == null) {
      showV3Snack(context, '删除已读消息失败，请重试');
      return;
    }
    if (result.total == 0) {
      showV3Snack(context, '没有可删除的已读消息');
      return;
    }
    showV3Snack(
      context,
      result.failed > 0
          ? '已删除 ${result.succeeded} 条，${result.failed} 条删除失败'
          : '已删除 ${result.succeeded} 条已读消息',
    );
  }

  Future<bool> _archive(PendingMessage item) async {
    final archived = await ref
        .read(notificationCenterControllerProvider)
        .archive(item);
    if (!archived && mounted) showV3Snack(context, '清除失败，请重试');
    return archived;
  }

  void _close() {
    unawaited(returnToPreviousRoute(context, fallbackRoute: '/v3/feed'));
  }

  Future<void> _openMessage(BuildContext context, PendingMessage item) async {
    final route = item.route;
    final center = ref.read(notificationCenterControllerProvider);
    if (route == null ||
        _navigationBusy ||
        center.isBusy(item) ||
        item.isBusy) {
      return;
    }
    if (item.targetType == 'topic_collision') {
      final aggregation = ref.read(feedAggregationControllerProvider);
      if (aggregation.noticeForReference(item.taskId) == null) {
        showV3Snack(context, '聚合任务状态已变化，请刷新消息后查看');
        return;
      }
    }
    setState(() => _navigationBusy = true);
    final router = GoRouter.of(context);
    final read = center.markOpened(item);
    unawaited(
      read.then((succeeded) {
        if (!succeeded && mounted && context.mounted) {
          showV3Snack(context, '已读状态保存失败，可稍后重试');
        }
      }),
    );
    try {
      if (widget.dismissBeforeNavigation &&
          item.source != PendingMessageSource.aggregation &&
          item.targetType != 'topic_collision') {
        Navigator.of(context).pop();
      }
      if (item.replaceRoute) {
        await router.replace<void>(route);
      } else {
        await router.push<void>(route);
      }
    } catch (_) {
      if (mounted && context.mounted) showV3Snack(context, '暂时无法打开消息，请重试');
    } finally {
      if (mounted) setState(() => _navigationBusy = false);
    }
  }
}

class V3NotificationsSurface extends StatelessWidget {
  const V3NotificationsSurface({
    required this.items,
    required this.visibleItems,
    required this.filter,
    required this.policies,
    required this.unreadCount,
    required this.isLoading,
    required this.operationFor,
    required this.onClose,
    required this.onFilterChanged,
    required this.onRetry,
    required this.onRefresh,
    required this.onItemTap,
    required this.onMarkRead,
    required this.onArchive,
    this.errorCode,
    this.hasMore = false,
    this.markAllReadBusy = false,
    this.deleteReadBusy = false,
    this.readDeleteCount = 0,
    this.interactionsDisabled = false,
    this.onMarkAllRead,
    this.onDeleteRead,
    this.onLoadMore,
    super.key,
  });

  final List<PendingMessage> items;
  final List<PendingMessage> visibleItems;
  final NotificationCenterFilter filter;
  final NotificationCenterPolicyRegistry policies;
  final int unreadCount;
  final bool isLoading;
  final String? errorCode;
  final bool hasMore;
  final bool markAllReadBusy;
  final bool deleteReadBusy;
  final int readDeleteCount;
  final bool interactionsDisabled;
  final NotificationCenterOperation Function(PendingMessage item) operationFor;
  final VoidCallback onClose;
  final ValueChanged<NotificationCenterFilter> onFilterChanged;
  final VoidCallback? onMarkAllRead;
  final VoidCallback? onDeleteRead;
  final VoidCallback onRetry;
  final Future<void> Function() onRefresh;
  final VoidCallback? onLoadMore;
  final ValueChanged<PendingMessage> onItemTap;
  final ValueChanged<PendingMessage> onMarkRead;
  final Future<bool> Function(PendingMessage) onArchive;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final preferredHeight = (screenHeight * 0.82).clamp(520.0, 700.0);
    final sheetHeight = preferredHeight.clamp(0.0, screenHeight);
    final ongoingCount = items
        .where(
          (item) => policies.group(item) == NotificationCenterGroup.ongoing,
        )
        .length;
    final finishedCount = items.length - ongoingCount;

    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          key: const ValueKey('notifications-sheet'),
          width: double.infinity,
          height: sheetHeight,
          constraints: const BoxConstraints(maxWidth: 680),
          decoration: BoxDecoration(
            color: colors.canvas,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: colors.line),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x1f1a1f26),
                blurRadius: 32,
                offset: Offset(0, -10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            bottom: false,
            child: Column(
              children: <Widget>[
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.muted,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                _NotificationsHeader(
                  unreadCount: unreadCount,
                  ongoingCount: ongoingCount,
                  markAllReadBusy: markAllReadBusy,
                  deleteReadBusy: deleteReadBusy,
                  readDeleteCount: readDeleteCount,
                  onClose: onClose,
                  onMarkAllRead: onMarkAllRead,
                  onDeleteRead: onDeleteRead,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                  child: _NotificationFilters(
                    value: filter,
                    ongoingCount: ongoingCount,
                    finishedCount: finishedCount,
                    onChanged: onFilterChanged,
                  ),
                ),
                Divider(height: 1, color: colors.line),
                Expanded(
                  child: _NotificationsBody(
                    allItems: items,
                    items: visibleItems,
                    filter: filter,
                    policies: policies,
                    isLoading: isLoading,
                    errorCode: errorCode,
                    hasMore: hasMore,
                    interactionsDisabled: interactionsDisabled,
                    operationFor: operationFor,
                    onRetry: onRetry,
                    onRefresh: onRefresh,
                    onLoadMore: onLoadMore,
                    onItemTap: onItemTap,
                    onMarkRead: onMarkRead,
                    onArchive: onArchive,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationsHeader extends StatelessWidget {
  const _NotificationsHeader({
    required this.unreadCount,
    required this.ongoingCount,
    required this.markAllReadBusy,
    required this.deleteReadBusy,
    required this.readDeleteCount,
    required this.onClose,
    required this.onMarkAllRead,
    required this.onDeleteRead,
  });

  final int unreadCount;
  final int ongoingCount;
  final bool markAllReadBusy;
  final bool deleteReadBusy;
  final int readDeleteCount;
  final VoidCallback onClose;
  final VoidCallback? onMarkAllRead;
  final VoidCallback? onDeleteRead;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      height: 78,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 8),
          V3CloseButton(tooltip: '关闭', onPressed: onClose, color: colors.text),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '消息通知',
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 18,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '$unreadCount 条未读 · $ongoingCount 条正在进行中',
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 12,
                    height: 1.25,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          SizedBox.square(
            dimension: 44,
            child: markAllReadBusy
                ? const Padding(
                    padding: EdgeInsets.all(13),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    key: const ValueKey('notifications-mark-all-read'),
                    tooltip: unreadCount == 0
                        ? '没有未读消息'
                        : onMarkAllRead == null
                        ? '请等待当前操作完成'
                        : '全部已读',
                    onPressed: onMarkAllRead,
                    icon: const Icon(LucideIcons.listChecks, size: 20),
                    color: colors.ink,
                    disabledColor: colors.muted,
                  ),
          ),
          SizedBox.square(
            dimension: 44,
            child: deleteReadBusy
                ? const Padding(
                    padding: EdgeInsets.all(13),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    key: const ValueKey('notifications-delete-read'),
                    tooltip: readDeleteCount == 0
                        ? '没有可删除的已读消息'
                        : onDeleteRead == null
                        ? '请等待当前操作完成'
                        : '删除已读',
                    onPressed: onDeleteRead,
                    icon: const Icon(LucideIcons.trash2, size: 20),
                    color: colors.ink,
                    disabledColor: colors.muted,
                  ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _NotificationFilters extends StatelessWidget {
  const _NotificationFilters({
    required this.value,
    required this.ongoingCount,
    required this.finishedCount,
    required this.onChanged,
  });

  final NotificationCenterFilter value;
  final int ongoingCount;
  final int finishedCount;
  final ValueChanged<NotificationCenterFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<NotificationCenterFilter>(
        key: const ValueKey('notification-filters'),
        showSelectedIcon: false,
        segments: <ButtonSegment<NotificationCenterFilter>>[
          ButtonSegment<NotificationCenterFilter>(
            value: NotificationCenterFilter.ongoing,
            label: Text('正在进行中 $ongoingCount'),
          ),
          ButtonSegment<NotificationCenterFilter>(
            value: NotificationCenterFilter.finished,
            label: Text('已完成 $finishedCount'),
          ),
        ],
        selected: <NotificationCenterFilter>{value},
        onSelectionChanged: (selection) => onChanged(selection.single),
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 38)),
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(fontSize: 12, letterSpacing: 0),
          ),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? colors.ink
                : colors.muted;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? colors.surface
                : colors.surfaceMuted;
          }),
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: colors.line),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationsBody extends StatelessWidget {
  const _NotificationsBody({
    required this.allItems,
    required this.items,
    required this.filter,
    required this.policies,
    required this.isLoading,
    required this.interactionsDisabled,
    required this.operationFor,
    required this.onRetry,
    required this.onRefresh,
    required this.onItemTap,
    required this.onMarkRead,
    required this.onArchive,
    this.errorCode,
    this.hasMore = false,
    this.onLoadMore,
  });

  final List<PendingMessage> allItems;
  final List<PendingMessage> items;
  final NotificationCenterFilter filter;
  final NotificationCenterPolicyRegistry policies;
  final bool isLoading;
  final bool interactionsDisabled;
  final String? errorCode;
  final bool hasMore;
  final NotificationCenterOperation Function(PendingMessage item) operationFor;
  final VoidCallback onRetry;
  final Future<void> Function() onRefresh;
  final VoidCallback? onLoadMore;
  final ValueChanged<PendingMessage> onItemTap;
  final ValueChanged<PendingMessage> onMarkRead;
  final Future<bool> Function(PendingMessage) onArchive;

  @override
  Widget build(BuildContext context) {
    if (isLoading && allItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return Column(
        children: <Widget>[
          if (errorCode != null && allItems.isNotEmpty)
            _NotificationsErrorStrip(errorCode: errorCode!, onRetry: onRetry),
          Expanded(
            child: _NotificationsEmpty(
              filter: filter,
              errorCode: allItems.isEmpty ? errorCode : null,
              onRetry: onRetry,
            ),
          ),
          if (hasMore)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextButton(
                key: const ValueKey('notifications-load-more-empty-filter'),
                onPressed: interactionsDisabled ? null : onLoadMore,
                child: const Text('加载更多'),
              ),
            ),
        ],
      );
    }
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              itemCount:
                  items.length +
                  (errorCode != null ? 1 : 0) +
                  (hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                var rowIndex = index;
                if (errorCode != null) {
                  if (rowIndex == 0) {
                    return _NotificationsErrorStrip(
                      errorCode: errorCode!,
                      onRetry: onRetry,
                    );
                  }
                  rowIndex -= 1;
                }
                if (rowIndex >= items.length) {
                  return Center(
                    child: TextButton(
                      onPressed: interactionsDisabled ? null : onLoadMore,
                      child: const Text('加载更多'),
                    ),
                  );
                }
                final item = items[rowIndex];
                return _NotificationDismissibleRow(
                  item: item,
                  policy: policies.classify(item),
                  operation: operationFor(item),
                  interactionsDisabled: interactionsDisabled,
                  canOpen: item.route != null,
                  onTap: () => onItemTap(item),
                  onMarkRead: () => onMarkRead(item),
                  onArchive: () => onArchive(item),
                );
              },
            ),
          ),
        ),
        if (isLoading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

class _NotificationDismissibleRow extends StatelessWidget {
  const _NotificationDismissibleRow({
    required this.item,
    required this.policy,
    required this.operation,
    required this.interactionsDisabled,
    required this.canOpen,
    required this.onTap,
    required this.onMarkRead,
    required this.onArchive,
  });

  final PendingMessage item;
  final NotificationCenterPolicy policy;
  final NotificationCenterOperation operation;
  final bool interactionsDisabled;
  final bool canOpen;
  final VoidCallback onTap;
  final VoidCallback onMarkRead;
  final Future<bool> Function() onArchive;

  @override
  Widget build(BuildContext context) {
    final row = _NotificationRow(
      item: item,
      policy: policy,
      operation: operation,
      interactionsDisabled: interactionsDisabled,
      canOpen: canOpen,
      onTap: canOpen ? onTap : null,
      onMarkRead: onMarkRead,
      onArchive: onArchive,
    );
    if (interactionsDisabled ||
        operation != NotificationCenterOperation.idle ||
        !policy.canArchive(item)) {
      return row;
    }
    final colors = HuahuoV3Theme.tokensOf(context);
    return Dismissible(
      key: ValueKey(
        'notification-dismiss-${pendingMessagePresentationIdentity(item)}',
      ),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => onArchive(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 18),
        color: colors.danger.withValues(alpha: 0.12),
        child: Icon(LucideIcons.trash2, color: colors.danger, size: 20),
      ),
      child: row,
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({
    required this.item,
    required this.policy,
    required this.operation,
    required this.interactionsDisabled,
    required this.canOpen,
    required this.onTap,
    required this.onMarkRead,
    required this.onArchive,
  });

  final PendingMessage item;
  final NotificationCenterPolicy policy;
  final NotificationCenterOperation operation;
  final bool interactionsDisabled;
  final bool canOpen;
  final VoidCallback? onTap;
  final VoidCallback onMarkRead;
  final Future<bool> Function() onArchive;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final busy = item.isBusy || operation != NotificationCenterOperation.idle;
    final statusColor = switch (item.state) {
      PendingMessageState.processing => colors.primary,
      PendingMessageState.actionRequired => colors.accent,
      PendingMessageState.succeeded => colors.success,
      PendingMessageState.failed => colors.danger,
      PendingMessageState.informational => colors.muted,
    };
    return Column(
      children: <Widget>[
        InkWell(
          key: ValueKey('notification-message-${item.id}'),
          onTap: busy || interactionsDisabled || !canOpen ? null : onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 92),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  SizedBox.square(
                    dimension: 40,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        _notificationSceneIcon(item.scene),
                        color: statusColor,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.ink,
                                  fontSize: 14,
                                  height: 1.35,
                                  fontWeight: item.isUnread
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  letterSpacing: 0,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _NotificationStatusLabel(
                              label: policy.statusLabel,
                              color: statusColor,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.muted,
                            fontSize: 12,
                            height: 1.35,
                            letterSpacing: 0,
                          ),
                        ),
                        if (item.recordingUploadProgress != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            _recordingUploadProgressLabel(item),
                            key: ValueKey(
                              'notification-upload-progress-${item.id}',
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.primary,
                              fontSize: 11,
                              height: 1.25,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0,
                            ),
                          ),
                        ],
                        if (item.createdAt != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            _formatNotificationTime(item.createdAt!),
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 11,
                              height: 1.2,
                              letterSpacing: 0,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 80,
                    height: 40,
                    child: busy
                        ? const Align(
                            alignment: Alignment.centerRight,
                            child: SizedBox.square(
                              dimension: 40,
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          )
                        : Row(
                            children: <Widget>[
                              SizedBox.square(
                                dimension: 40,
                                child: policy.canMarkRead(item)
                                    ? IconButton(
                                        key: ValueKey(
                                          'notification-mark-read-${item.id}',
                                        ),
                                        tooltip: '标记为已读',
                                        onPressed: interactionsDisabled
                                            ? null
                                            : onMarkRead,
                                        icon: const Icon(
                                          LucideIcons.mailOpen,
                                          size: 18,
                                        ),
                                        color: colors.muted,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                              SizedBox.square(
                                dimension: 40,
                                child: policy.canArchive(item)
                                    ? IconButton(
                                        key: ValueKey(
                                          'notification-archive-${item.id}',
                                        ),
                                        tooltip: '清除消息',
                                        onPressed: interactionsDisabled
                                            ? null
                                            : () => unawaited(onArchive()),
                                        icon: const Icon(
                                          LucideIcons.trash2,
                                          size: 18,
                                        ),
                                        color: colors.muted,
                                      )
                                    : canOpen
                                    ? Icon(
                                        LucideIcons.chevronRight,
                                        size: 18,
                                        color: colors.muted,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Divider(height: 1, color: colors.line),
      ],
    );
  }
}

class _NotificationStatusLabel extends StatelessWidget {
  const _NotificationStatusLabel({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

IconData _notificationSceneIcon(String scene) => switch (scene) {
  'recording' => LucideIcons.audioLines,
  'work_ai' || 'feed_ai' || 'sprout' || 'outline' => LucideIcons.sparkles,
  'asset' || 'document' || 'document_outline' => LucideIcons.library,
  'membership' => LucideIcons.badgeCheck,
  'onboarding' || 'device_setup' => LucideIcons.userRoundCheck,
  _ => LucideIcons.bell,
};

String _formatNotificationTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

String _recordingUploadProgressLabel(PendingMessage item) {
  final progress = item.recordingUploadProgress!;
  final rate = progress.bytesPerSecond > 0
      ? '${_formatRecordingUploadBytes(progress.bytesPerSecond.round())}/s'
      : '--/s';
  final eta = progress.estimatedRemainingSeconds == null
      ? '--'
      : _formatRecordingUploadEta(progress.estimatedRemainingSeconds!);
  return '${_formatRecordingUploadBytes(progress.bytesSent)} / '
      '${_formatRecordingUploadBytes(progress.totalBytes)}\n$rate · '
      '预计剩余 $eta';
}

String _formatRecordingUploadBytes(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB'];
  var value = bytes < 0 ? 0.0 : bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final precision = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unit]}';
}

String _formatRecordingUploadEta(int seconds) {
  final safeSeconds = seconds < 0 ? 0 : seconds;
  if (safeSeconds < 60) return '${safeSeconds}s';
  final minutes = safeSeconds ~/ 60;
  final remainingSeconds = safeSeconds % 60;
  if (minutes < 60) return '${minutes}m ${remainingSeconds}s';
  return '${minutes ~/ 60}h ${minutes % 60}m';
}

class _NotificationsEmpty extends StatelessWidget {
  const _NotificationsEmpty({
    required this.filter,
    required this.errorCode,
    required this.onRetry,
  });

  final NotificationCenterFilter filter;
  final String? errorCode;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = errorCode != null;
    final colors = HuahuoV3Theme.tokensOf(context);
    final label = switch (filter) {
      NotificationCenterFilter.ongoing => '暂无正在进行中的消息',
      NotificationCenterFilter.finished => '暂无已完成的消息',
    };
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 52),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              failed ? LucideIcons.triangleAlert : LucideIcons.circleCheck,
              size: 28,
              color: failed ? colors.danger : colors.muted,
            ),
            const SizedBox(height: 18),
            Text(
              failed ? '消息加载失败' : label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.ink,
                letterSpacing: 0,
              ),
            ),
            if (failed) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _notificationErrorMessage(errorCode!),
                style: TextStyle(color: colors.muted, fontSize: 13),
              ),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}

class _NotificationsErrorStrip extends StatelessWidget {
  const _NotificationsErrorStrip({
    required this.errorCode,
    required this.onRetry,
  });

  final String errorCode;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Icon(LucideIcons.triangleAlert, color: colors.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _notificationErrorMessage(errorCode),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

String _notificationErrorMessage(String errorCode) {
  return switch (errorCode) {
    'AUTH_SESSION_EXPIRED' || 'TOKEN_EXPIRED' => '登录状态已失效，请重新登录',
    'NETWORK_ERROR' || 'NETWORK_UNAVAILABLE' => '网络不可用，请检查连接后重试',
    'REQUEST_TIMEOUT' || 'TIMEOUT' => '消息服务响应超时，请稍后重试',
    _ => '消息服务暂时不可用，请稍后重试',
  };
}
