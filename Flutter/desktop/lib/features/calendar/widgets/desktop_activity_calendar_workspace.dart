import 'package:flutter/material.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../application/desktop_activity_calendar_controller.dart';

final class DesktopActivityCalendarWorkspace extends StatelessWidget {
  const DesktopActivityCalendarWorkspace({required this.controller, super.key});

  final DesktopActivityCalendarController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, child) {
      final state = controller.state;
      return ColoredBox(
        key: const ValueKey<String>('desktop-activity-calendar'),
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            _CalendarTopBar(controller: controller, state: state),
            Expanded(
              child: _CalendarBody(controller: controller, state: state),
            ),
          ],
        ),
      );
    },
  );
}

final class _CalendarTopBar extends StatelessWidget {
  const _CalendarTopBar({required this.controller, required this.state});

  final DesktopActivityCalendarController controller;
  final DesktopActivityCalendarState state;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          const Icon(LucideIcons.calendarDays, size: 17),
          const SizedBox(width: 9),
          Text('活动日历', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (state.timezone != null)
            Text(
              state.timezone!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey<String>('activity-calendar-refresh'),
            tooltip: '刷新',
            onPressed: state.status == DesktopActivityCalendarStatus.loading
                ? null
                : controller.reload,
            icon: const Icon(LucideIcons.refreshCw, size: 16),
          ),
        ],
      ),
    ),
  );
}

final class _CalendarBody extends StatelessWidget {
  const _CalendarBody({required this.controller, required this.state});

  final DesktopActivityCalendarController controller;
  final DesktopActivityCalendarState state;

  @override
  Widget build(BuildContext context) {
    if (state.status == DesktopActivityCalendarStatus.idle) {
      return const Center(child: Text('登录并选择 Workspace 后查看活动'));
    }
    if (state.status == DesktopActivityCalendarStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == DesktopActivityCalendarStatus.failure) {
      return _CalendarFailure(
        message: state.errorMessage ?? '活动日历读取失败',
        onRetry: controller.reload,
      );
    }
    if (state.days.isEmpty) {
      return const Center(child: Text('当前 Workspace 暂无活动记录'));
    }
    final selected = state.selectedDay;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 36),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final day in state.days)
              _CalendarDay(
                day: day,
                selected: day.date == state.selectedDate,
                onTap: () => controller.selectDate(day.date),
              ),
          ],
        ),
        if (selected != null) ...[
          const SizedBox(height: 22),
          _SelectedDay(day: selected),
        ],
        if (state.errorMessage != null) ...[
          const SizedBox(height: 14),
          Text(
            state.errorMessage!,
            key: const ValueKey<String>('activity-calendar-page-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (state.hasMore || state.loadingMore) ...[
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey<String>('activity-calendar-load-more'),
              onPressed: state.loadingMore ? null : controller.loadOlder,
              icon: state.loadingMore
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    )
                  : const Icon(LucideIcons.history, size: 15),
              label: Text(state.loadingMore ? '正在读取' : '加载更早记录'),
            ),
          ),
        ],
      ],
    );
  }
}

final class _CalendarDay extends StatelessWidget {
  const _CalendarDay({
    required this.day,
    required this.selected,
    required this.onTap,
  });

  final WorkspaceNoteMetricDay day;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.secondaryContainer : colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: ValueKey<String>('activity-calendar-day-${day.date}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 112,
          height: 76,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_shortDate(day.date)),
                const Spacer(),
                Text(
                  '${day.count} 条笔记',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _SelectedDay extends StatelessWidget {
  const _SelectedDay({required this.day});

  final WorkspaceNoteMetricDay day;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      key: const ValueKey<String>('activity-calendar-selection'),
      children: [
        const Icon(LucideIcons.calendarCheck, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '${day.date} 新增 ${day.count} 条笔记${day.complete ? '' : ' · 数据仍在更新'}',
          ),
        ),
      ],
    ),
  );
}

final class _CalendarFailure extends StatelessWidget {
  const _CalendarFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message),
        const SizedBox(height: 12),
        TextButton.icon(
          key: const ValueKey<String>('activity-calendar-retry'),
          onPressed: onRetry,
          icon: const Icon(LucideIcons.rotateCw, size: 15),
          label: const Text('重试'),
        ),
      ],
    ),
  );
}

String _shortDate(String value) {
  final parts = value.split('-');
  return parts.length == 3 ? '${parts[1]}-${parts[2]}' : value;
}
