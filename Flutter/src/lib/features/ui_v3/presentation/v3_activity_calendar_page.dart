import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../application/activity_calendar_controller.dart';
import '../application/knowledge_library_controller.dart';
import '../application/note_metrics_controller.dart';
import '../domain/feed_item_models.dart';

class V3ActivityCalendarPage extends ConsumerStatefulWidget {
  const V3ActivityCalendarPage({this.initialSelectedDay, super.key});

  final DateTime? initialSelectedDay;

  @override
  ConsumerState<V3ActivityCalendarPage> createState() =>
      _V3ActivityCalendarPageState();
}

class _V3ActivityCalendarPageState
    extends ConsumerState<V3ActivityCalendarPage> {
  bool _coveringMonth = false;
  DateTime? _queuedCoverageMonth;
  String? _lastCoverageSignature;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final calendar = ref.read(activityCalendarControllerProvider);
      final day = widget.initialSelectedDay;
      if (day != null) calendar.selectDay(day);
      unawaited(
        ref
            .read(knowledgeLibraryControllerProvider)
            .synchronizeWorkspaceContent(),
      );
      _scheduleMetricsCoverage(calendar.month);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(activityCalendarControllerProvider);
    final library = ref.watch(knowledgeLibraryControllerProvider);
    final metrics = ref.watch(noteMetricsControllerProvider).state;
    _scheduleMetricsCoverage(state.month);

    final ownedNotes = library.mineNotes;
    final monthNotes = ownedNotes
        .where((note) => _sameMonth(_localCreatedAt(note), state.month))
        .toList(growable: false);
    final selectedNotes = monthNotes
        .where((note) => _sameDay(_localCreatedAt(note), state.selectedDay))
        .toList(growable: false);
    selectedNotes.sort(
      (left, right) => _localCreatedAt(right).compareTo(_localCreatedAt(left)),
    );
    final timeline = <_CalendarTimelineEntry>[
      for (final note in selectedNotes)
        _CalendarTimelineEntry.note(
          note,
          onTap: () =>
              context.push('/v3/feed/items/${Uri.encodeComponent(note.id)}'),
        ),
    ];
    final monthSummary = _metricsForMonth(metrics, state.month);
    final selectedMetric = _metricForDay(metrics, state.selectedDay);
    final displayedSelectedCount =
        selectedMetric == null && selectedNotes.isEmpty
        ? null
        : _largerCount(selectedMetric?.count, selectedNotes.length);
    final libraryState = library.graphReadModel.sourceState;

    return V3PageScaffold(
      title: '日历',
      subtitle: '查看真实资产新增',
      fallbackRoute: '/v3/feed',
      backOffset: const Offset(6, 4),
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 28),
      titleSubtitleGap: 7,
      titleContentGap: 13,
      children: [
        _CalendarSummaryStrip(
          noteCount: ownedNotes.length,
          addedCount: monthSummary?.totalCount,
          activeDays: monthSummary?.activeDays,
        ),
        const SizedBox(height: 6),
        _MonthHeader(
          month: state.month,
          onPrevious: _showPreviousMonth,
          onNext: state.canGoNext ? _showNextMonth : null,
          onToday: _showToday,
        ),
        const SizedBox(height: 8),
        _MonthGrid(
          month: state.month,
          selectedDay: state.selectedDay,
          today: state.today,
          metricFor: (day) {
            final metric = _metricForDay(metrics, day);
            final visibleCount = monthNotes
                .where((note) => _sameDay(_localCreatedAt(note), day))
                .length;
            if (metric == null && visibleCount == 0) return null;
            return _CalendarDayMetric(
              count: _largerCount(metric?.count, visibleCount),
              complete: metric?.complete ?? false,
            );
          },
          onSelect: ref.read(activityCalendarControllerProvider).selectDay,
        ),
        const SizedBox(height: 18),
        _DayHeading(day: state.selectedDay, itemCount: displayedSelectedCount),
        const SizedBox(height: 8),
        ..._buildSelectedDayContent(
          day: state.selectedDay,
          metric: selectedMetric,
          timeline: timeline,
          metrics: metrics,
          libraryState: libraryState,
        ),
      ],
    );
  }

  List<Widget> _buildSelectedDayContent({
    required DateTime day,
    required _CalendarDayMetric? metric,
    required List<_CalendarTimelineEntry> timeline,
    required NoteMetricsState metrics,
    required KnowledgeGraphSourceState libraryState,
  }) {
    final content = <Widget>[];
    if (timeline.isNotEmpty) {
      for (var index = 0; index < timeline.length; index++) {
        content.add(
          _CalendarTimelineRow(
            entry: timeline[index],
            showLine: index != timeline.length - 1,
          ),
        );
      }
      final hiddenCount = metric == null
          ? 0
          : (metric.count - timeline.length).clamp(0, metric.count);
      if (hiddenCount > 0) {
        content.add(_CalendarDataNotice.hidden(hiddenCount));
      } else if (metric == null) {
        content.add(const _CalendarDataNotice.metricsUnavailable());
      }
      if (libraryState == KnowledgeGraphSourceState.failure) {
        content.add(
          _CalendarDataNotice.syncFailed(onRetry: _retryCalendarData),
        );
      } else if (metrics.errorCode != null) {
        content.add(
          _CalendarDataNotice.refreshFailed(onRetry: _retryCalendarData),
        );
      }
      return content;
    }

    if (metric == null) {
      if ((metrics.isLoading && !metrics.hasData) || metrics.isLoadingMore) {
        return const <Widget>[_CalendarStatusPanel.loading(label: '正在加载新增统计')];
      }
      if (metrics.errorCode != null) {
        return <Widget>[
          _CalendarStatusPanel.failed(
            label: '新增统计加载失败',
            onRetry: _retryCalendarData,
          ),
        ];
      }
      return const <Widget>[
        _CalendarStatusPanel.unavailable(label: '该日期统计暂不可用'),
      ];
    }

    if (metric.count == 0) {
      if (!metric.complete) {
        return const <Widget>[
          _CalendarStatusPanel.inProgress(label: '今日新增仍在统计中'),
        ];
      }
      return <Widget>[_CalendarEmptyDay(day: day)];
    }

    if (libraryState == KnowledgeGraphSourceState.loading) {
      return const <Widget>[_CalendarStatusPanel.loading(label: '正在同步当天资产')];
    }
    if (libraryState == KnowledgeGraphSourceState.failure) {
      return <Widget>[
        _CalendarStatusPanel.failed(
          label: '当天资产同步失败',
          onRetry: _retryCalendarData,
        ),
      ];
    }
    return <Widget>[_CalendarDataNotice.hidden(metric.count)];
  }

  void _showPreviousMonth() {
    final controller = ref.read(activityCalendarControllerProvider);
    controller.previousMonth();
    _lastCoverageSignature = null;
    _scheduleMetricsCoverage(controller.month);
  }

  void _showNextMonth() {
    final controller = ref.read(activityCalendarControllerProvider);
    controller.nextMonth();
    _lastCoverageSignature = null;
    _scheduleMetricsCoverage(controller.month);
  }

  void _showToday() {
    final controller = ref.read(activityCalendarControllerProvider);
    controller.selectToday();
    _lastCoverageSignature = null;
    _scheduleMetricsCoverage(controller.month);
  }

  Future<void> _retryCalendarData() async {
    _lastCoverageSignature = null;
    await Future.wait<Object?>([
      ref
          .read(noteMetricsControllerProvider)
          .load(force: true, invalidateCache: true),
      ref
          .read(knowledgeLibraryControllerProvider)
          .synchronizeWorkspaceContent(forceSnapshot: true),
    ]);
    if (!mounted) return;
    await _ensureMetricsCoverage(
      ref.read(activityCalendarControllerProvider).month,
    );
  }

  void _scheduleMetricsCoverage(DateTime month) {
    final metrics = ref.read(noteMetricsControllerProvider).state;
    final oldestDate = metrics.days.isEmpty ? '-' : metrics.days.last.date;
    final signature =
        '${month.year}-${month.month}|${metrics.status.name}|$oldestDate|'
        '${metrics.hasMore}|${metrics.errorCode}';
    if (_lastCoverageSignature == signature) return;
    _lastCoverageSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_ensureMetricsCoverage(month));
    });
  }

  Future<void> _ensureMetricsCoverage(DateTime month) async {
    final normalizedMonth = DateTime(month.year, month.month);
    if (_coveringMonth) {
      _queuedCoverageMonth = normalizedMonth;
      return;
    }
    _coveringMonth = true;
    try {
      var pageCount = 0;
      while (mounted && pageCount < 24) {
        final controller = ref.read(noteMetricsControllerProvider);
        final metrics = controller.state;
        if (_metricsForMonth(metrics, normalizedMonth) != null) {
          return;
        }
        if ((metrics.isLoading && !metrics.hasData) ||
            metrics.isLoadingMore ||
            metrics.errorCode != null ||
            !metrics.hasMore ||
            metrics.nextCursor == null) {
          return;
        }
        final beforeCursor = metrics.nextCursor;
        final beforeLength = metrics.days.length;
        await controller.loadMore();
        pageCount += 1;
        final after = controller.state;
        if (after.errorCode != null ||
            (after.days.length == beforeLength &&
                after.nextCursor == beforeCursor)) {
          return;
        }
      }
    } finally {
      _coveringMonth = false;
      final queued = _queuedCoverageMonth;
      _queuedCoverageMonth = null;
      if (mounted && queued != null && !_sameMonth(queued, month)) {
        unawaited(_ensureMetricsCoverage(queued));
      }
    }
  }
}

class _CalendarSummaryStrip extends StatelessWidget {
  const _CalendarSummaryStrip({
    required this.noteCount,
    required this.addedCount,
    required this.activeDays,
  });

  final int noteCount;
  final int? addedCount;
  final int? activeDays;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final items = <(String, String)>[
      ('$noteCount', '当前资产'),
      ('${addedCount ?? '--'}', '本月新增'),
      ('${activeDays ?? '--'}', '新增天数'),
    ];
    return Semantics(
      label:
          '当前资产 $noteCount 条，本月新增 ${addedCount ?? '暂不可用'} 条，'
          '新增 ${activeDays ?? '暂不可用'} 天',
      child: Container(
        key: const ValueKey('calendar-summary-strip'),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceMuted.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            for (var index = 0; index < items.length; index++) ...[
              if (index > 0)
                SizedBox(
                  height: 28,
                  child: VerticalDivider(color: colors.line),
                ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      items[index].$1,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      items[index].$2,
                      style: TextStyle(color: colors.muted, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.month,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
  });

  final DateTime month;
  final VoidCallback onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Row(
      children: [
        Text(
          '${month.year}年${month.month}月',
          style: TextStyle(
            color: colors.text,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        TextButton(onPressed: onToday, child: const Text('今天')),
        _CalendarIconButton(
          tooltip: '上个月',
          icon: Icons.chevron_left_rounded,
          onPressed: onPrevious,
        ),
        _CalendarIconButton(
          tooltip: '下个月',
          icon: Icons.chevron_right_rounded,
          onPressed: onNext,
        ),
      ],
    );
  }
}

class _CalendarIconButton extends StatelessWidget {
  const _CalendarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 20),
    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
  );
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.selectedDay,
    required this.today,
    required this.metricFor,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime selectedDay;
  final DateTime today;
  final _CalendarDayMetric? Function(DateTime) metricFor;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final first = DateTime(month.year, month.month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final leading = first.weekday % 7;
    final rows = ((leading + days) / 7).ceil();
    return V3Card(
      key: const ValueKey('calendar-month-grid'),
      radius: 12,
      padding: const EdgeInsets.fromLTRB(8, 9, 8, 8),
      child: Column(
        children: [
          Row(
            children: [
              for (final label in ['日', '一', '二', '三', '四', '五', '六'])
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: colors.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: rows * 7,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: 38.5,
            ),
            itemBuilder: (context, index) {
              final number = index - leading + 1;
              if (number < 1 || number > days) return const SizedBox.shrink();
              final day = DateTime(month.year, month.month, number);
              final metric = metricFor(day);
              final activityCount = metric?.count ?? 0;
              final selected = _sameDay(day, selectedDay);
              final isToday = _sameDay(day, today);
              final isFuture = day.isAfter(today);
              return Semantics(
                button: !isFuture,
                enabled: !isFuture,
                selected: selected,
                label: isFuture
                    ? '${day.month}月${day.day}日，不可选择'
                    : metric == null
                    ? '${day.month}月${day.day}日，新增统计暂不可用'
                    : '${day.month}月${day.day}日，新增 $activityCount 条',
                child: InkWell(
                  key: ValueKey(
                    'calendar-day-${day.year}-${day.month}-${day.day}',
                  ),
                  onTap: isFuture ? null : () => onSelect(day),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: selected
                          ? colors.accent
                          : activityCount > 0
                          ? Color.lerp(
                              colors.surface,
                              colors.accent,
                              .12 + _heatLevelForCount(activityCount) * .08,
                            )
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: isToday && !selected
                          ? Border.all(color: colors.accent, width: 1)
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '$number',
                          style: TextStyle(
                            color: isFuture
                                ? colors.muted.withValues(alpha: .45)
                                : selected
                                ? colors.onPrimary
                                : colors.text,
                            fontSize: 11.5,
                            fontWeight: selected || isToday
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (activityCount > 0)
                              _CalendarDot(
                                color: selected
                                    ? colors.onPrimary
                                    : colors.accent,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CalendarDot extends StatelessWidget {
  const _CalendarDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: const SizedBox.square(dimension: 3.5),
  );
}

class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.day, required this.itemCount});

  final DateTime day;
  final int? itemCount;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            '${day.month}月${day.day}日 · ${_weekdayLabel(day)}',
            style: TextStyle(
              color: colors.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          '新增 ${itemCount ?? '--'} 条',
          style: TextStyle(color: colors.muted, fontSize: 11.5),
        ),
      ],
    );
  }
}

class _CalendarTimelineEntry {
  const _CalendarTimelineEntry({
    required this.occurredAt,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  factory _CalendarTimelineEntry.note(
    V3FeedItem note, {
    required VoidCallback onTap,
  }) {
    final occurredAt = _localCreatedAt(note);
    final sourceLabel = note.contentOrigin == V3ContentOrigin.freeCreation
        ? '自由创作'
        : note.source.label;
    final syncLabel = note.syncState == NoteSyncState.synced
        ? ''
        : ' · ${note.syncState.label}';
    return _CalendarTimelineEntry(
      occurredAt: occurredAt,
      icon: _noteSourceIcon(note),
      title: note.title.trim().isEmpty ? '未命名笔记' : note.title.trim(),
      subtitle: '${_formatClock(occurredAt)} · $sourceLabel$syncLabel',
      onTap: onTap,
    );
  }

  final DateTime occurredAt;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
}

class _CalendarTimelineRow extends StatelessWidget {
  const _CalendarTimelineRow({required this.entry, required this.showLine});

  final _CalendarTimelineEntry entry;
  final bool showLine;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: entry.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          decoration: BoxDecoration(
            border: showLine
                ? Border(bottom: BorderSide(color: colors.line))
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Icon(entry.icon, color: colors.accent, size: 19),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.subtitle,
                      style: TextStyle(color: colors.muted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (entry.onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  color: colors.muted,
                  size: 18,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CalendarEmptyDay extends StatelessWidget {
  const _CalendarEmptyDay({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.event_available_outlined, color: colors.muted, size: 20),
          const SizedBox(width: 8),
          Text(
            '${day.month}月${day.day}日暂无新增资产',
            style: TextStyle(color: colors.muted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _CalendarStatusPanel extends StatelessWidget {
  const _CalendarStatusPanel.loading({required this.label})
    : icon = Icons.sync_rounded,
      loading = true,
      onRetry = null;

  const _CalendarStatusPanel.failed({
    required this.label,
    required this.onRetry,
  }) : icon = Icons.sync_problem_rounded,
       loading = false;

  const _CalendarStatusPanel.unavailable({required this.label})
    : icon = Icons.info_outline_rounded,
      loading = false,
      onRetry = null;

  const _CalendarStatusPanel.inProgress({required this.label})
    : icon = Icons.schedule_rounded,
      loading = false,
      onRetry = null;

  final String label;
  final IconData icon;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (loading)
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accent,
              ),
            )
          else
            Icon(icon, color: colors.muted, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(color: colors.muted, fontSize: 13),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 6),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}

class _CalendarDataNotice extends StatelessWidget {
  const _CalendarDataNotice.hidden(int count)
    : label = '另有 $count 条资产已删除或暂不可查看',
      icon = Icons.visibility_off_outlined,
      onRetry = null;

  const _CalendarDataNotice.metricsUnavailable()
    : label = '新增统计暂不可用，以上为当前可查看资产',
      icon = Icons.info_outline_rounded,
      onRetry = null;

  const _CalendarDataNotice.syncFailed({required this.onRetry})
    : label = '部分资产同步失败，当前列表可能不完整',
      icon = Icons.sync_problem_rounded;

  const _CalendarDataNotice.refreshFailed({required this.onRetry})
    : label = '统计刷新失败，当前显示上次成功结果',
      icon = Icons.sync_problem_rounded;

  final String label;
  final IconData icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: const ValueKey('calendar-data-notice'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: colors.surfaceMuted.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: colors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: colors.muted, fontSize: 11.5),
            ),
          ),
          if (onRetry != null)
            IconButton(
              tooltip: '重新加载日历数据',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

final class _CalendarDayMetric {
  const _CalendarDayMetric({required this.count, required this.complete});

  final int count;
  final bool complete;
}

final class _CalendarMonthMetrics {
  const _CalendarMonthMetrics({
    required this.totalCount,
    required this.activeDays,
  });

  final int totalCount;
  final int activeDays;
}

_CalendarMonthMetrics? _metricsForMonth(
  NoteMetricsState state,
  DateTime month,
) {
  final coverage = state.coverage;
  final current = coverage == null
      ? null
      : _parseMetricDate(coverage.currentDate);
  if (current == null) return null;
  final monthStart = DateTime.utc(month.year, month.month);
  if (monthStart.isAfter(current)) return null;
  final monthEnd = DateTime.utc(month.year, month.month + 1, 0);
  final end = monthEnd.isBefore(current) ? monthEnd : current;
  var totalCount = 0;
  var activeDays = 0;
  for (
    var day = monthStart;
    !day.isAfter(end);
    day = day.add(const Duration(days: 1))
  ) {
    final metric = _metricForDay(state, day);
    if (metric == null) return null;
    totalCount += metric.count;
    if (metric.count > 0) activeDays += 1;
  }
  return _CalendarMonthMetrics(totalCount: totalCount, activeDays: activeDays);
}

_CalendarDayMetric? _metricForDay(NoteMetricsState state, DateTime day) {
  final coverage = state.coverage;
  if (coverage == null) return null;
  final normalized = DateTime.utc(day.year, day.month, day.day);
  final current = _parseMetricDate(coverage.currentDate);
  final coverageStart = _parseMetricDate(coverage.startDate);
  if (current == null || normalized.isAfter(current)) return null;
  final dateText = _metricDateText(normalized);
  for (final value in state.days) {
    if (value.date == dateText) {
      if (!value.complete && normalized != current) return null;
      return _CalendarDayMetric(count: value.count, complete: value.complete);
    }
  }
  if (coverage.historyComplete &&
      coverageStart != null &&
      normalized.isBefore(coverageStart)) {
    return const _CalendarDayMetric(count: 0, complete: true);
  }
  return null;
}

DateTime? _parseMetricDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
  final year = int.tryParse(value.substring(0, 4));
  final month = int.tryParse(value.substring(5, 7));
  final day = int.tryParse(value.substring(8, 10));
  if (year == null || month == null || day == null) return null;
  final parsed = DateTime.utc(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day
      ? parsed
      : null;
}

String _metricDateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

DateTime _localCreatedAt(V3FeedItem note) =>
    note.createdAt.isUtc ? note.createdAt.toLocal() : note.createdAt;

int _largerCount(int? serverCount, int visibleCount) =>
    serverCount == null || visibleCount > serverCount
    ? visibleCount
    : serverCount;

double _heatLevelForCount(int count) {
  if (count <= 0) return 0;
  if (count == 1) return 1;
  if (count <= 3) return 2;
  if (count <= 7) return 3;
  return 4;
}

IconData _noteSourceIcon(V3FeedItem note) {
  if (note.contentOrigin == V3ContentOrigin.freeCreation) {
    return Icons.edit_note_rounded;
  }
  return switch (note.source) {
    V3MaterialSource.meeting ||
    V3MaterialSource.internalRecording ||
    V3MaterialSource.monologue ||
    V3MaterialSource.recordingCard => Icons.mic_none_rounded,
    V3MaterialSource.link => Icons.link_rounded,
    V3MaterialSource.documentImport => Icons.description_outlined,
    V3MaterialSource.mediaImport => Icons.photo_outlined,
    V3MaterialSource.subscription => Icons.rss_feed_rounded,
    V3MaterialSource.knowledgeSquare => Icons.public_rounded,
    V3MaterialSource.hotspot => Icons.local_fire_department_outlined,
    V3MaterialSource.note => Icons.note_alt_outlined,
    V3MaterialSource.chatExcerpt => Icons.chat_bubble_outline_rounded,
    V3MaterialSource.materialMigration => Icons.history_rounded,
    V3MaterialSource.topicCollision => Icons.hub_outlined,
    V3MaterialSource.other => Icons.help_outline_rounded,
  };
}

bool _sameMonth(DateTime value, DateTime month) =>
    value.year == month.year && value.month == month.month;

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _formatClock(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String _weekdayLabel(DateTime value) => switch (value.weekday) {
  DateTime.monday => '周一',
  DateTime.tuesday => '周二',
  DateTime.wednesday => '周三',
  DateTime.thursday => '周四',
  DateTime.friday => '周五',
  DateTime.saturday => '周六',
  _ => '周日',
};
