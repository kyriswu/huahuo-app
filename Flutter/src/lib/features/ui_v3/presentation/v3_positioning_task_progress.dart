import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/onboarding_providers.dart';
import '../../../app/di/positioning_progress_providers.dart';
import '../../positioning/application/positioning_progress_controller.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../onboarding/application/initial_positioning_task_coordinator.dart';

class V3PositioningTaskProgress extends ConsumerStatefulWidget {
  const V3PositioningTaskProgress({
    required this.task,
    this.onRefresh,
    super.key,
  });

  final InitialPositioningTaskState task;
  final Future<void> Function()? onRefresh;

  @override
  ConsumerState<V3PositioningTaskProgress> createState() =>
      _V3PositioningTaskProgressState();
}

class _V3PositioningTaskProgressState
    extends ConsumerState<V3PositioningTaskProgress>
    with AppActivityRouteAware<V3PositioningTaskProgress> {
  late PositioningProgressController _controller;
  late final ProviderSubscription<PositioningProgressController Function()>
  _factorySubscription;

  bool get _taskActive =>
      !widget.task.isTerminal &&
      widget.task.status != InitialPositioningTaskStatus.idle &&
      widget.task.status != InitialPositioningTaskStatus.registering;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(positioningProgressControllerFactoryProvider)()
      ..addListener(_onProgressChanged);
    _factorySubscription = ref.listenManual(
      positioningProgressControllerFactoryProvider,
      (_, factory) {
        _controller.removeListener(_onProgressChanged);
        _controller.dispose();
        _controller = factory()..addListener(_onProgressChanged);
        _syncPolling();
        _onProgressChanged();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPolling();
    });
  }

  void _onProgressChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(V3PositioningTaskProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPolling();
  }

  @override
  void onActivityRouteBecameActive() => _syncPolling();

  @override
  void onActivityRouteBecameInactive() => _syncPolling();

  void _syncPolling() => _controller.setActivity(
    visible: activityRouteCanRun,
    taskActive: _taskActive,
  );

  @override
  void dispose() {
    _factorySubscription.close();
    _controller.removeListener(_onProgressChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final failed = widget.task.status == InitialPositioningTaskStatus.failed;
    final registering =
        widget.task.status == InitialPositioningTaskStatus.registering;
    final active = switch (widget.task.status) {
      InitialPositioningTaskStatus.registering ||
      InitialPositioningTaskStatus.running ||
      InitialPositioningTaskStatus.finalizing => true,
      InitialPositioningTaskStatus.idle ||
      InitialPositioningTaskStatus.succeeded ||
      InitialPositioningTaskStatus.failed => false,
    };
    final label = switch (widget.task.status) {
      InitialPositioningTaskStatus.registering =>
        widget.task.errorCode == null ? '正在确认后台接管' : '后台接管尚未确认，请重试确认提交',
      InitialPositioningTaskStatus.running => '正在生成基础定位报告',
      InitialPositioningTaskStatus.finalizing => '正在写入并核对正式定位报告',
      InitialPositioningTaskStatus.succeeded => '基础定位报告已生成',
      InitialPositioningTaskStatus.failed => '本次基础定位未完成，问卷已保留',
      InitialPositioningTaskStatus.idle => '等待提交基础定位问卷',
    };
    return Column(
      key: const ValueKey('positioning-task-progress'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(color: failed ? colors.danger : colors.ink),
        ),
        if (active) ...[
          const SizedBox(height: 10),
          TickerMode(
            enabled:
                activityRouteCanRun && !MediaQuery.disableAnimationsOf(context),
            child: LinearProgressIndicator(
              key: const ValueKey('positioning-task-awaiting-server'),
              minHeight: 6,
              color: colors.accent,
              backgroundColor: colors.line,
              semanticsLabel: label,
            ),
          ),
        ],
        const SizedBox(height: 10),
        if (widget.task.status == InitialPositioningTaskStatus.running ||
            widget.task.status == InitialPositioningTaskStatus.finalizing)
          const V3LongRunningTaskNotice()
        else
          Text(
            failed
                ? '请返回问卷检查并重试；不会将失败任务显示为完成。'
                : registering
                ? '请保持应用开启；任务回执已保留，确认提交不会重复生成。'
                : widget.task.status == InitialPositioningTaskStatus.succeeded
                ? '报告已经完成，可返回定位报告查看。'
                : widget.task.status == InitialPositioningTaskStatus.idle
                ? '提交基础定位问卷后，才会开始生成报告。'
                : '可以离开此页，完成后会在消息提醒中通知你。',
            style: TextStyle(color: colors.muted, height: 1.5),
          ),
        if (_controller.coverage case final progress?) ...[
          const SizedBox(height: 14),
          _CoverageBar(label: '基础信息完整度', percent: progress.coldStartPercent),
          const SizedBox(height: 12),
          _CoverageBar(label: '定位内容覆盖度', percent: progress.completedPercent),
          const SizedBox(height: 8),
          Text(
            progress.isStale
                ? '以上为最近一次已确认的数据，正在等待服务端更新。'
                : '完整度来自服务端已写入资料，不代表本次生成耗时进度。',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
        ] else if (active) ...[
          const SizedBox(height: 8),
          Text(
            '服务端尚未提供可量化进度，当前仅展示真实任务阶段。',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const ValueKey('positioning-task-action'),
            onPressed: failed
                ? () => context.push('/onboarding?resume=1')
                : () {
                    unawaited(
                      widget.onRefresh?.call() ??
                          ref
                              .read(initialPositioningTaskCoordinatorProvider)
                              .refresh(),
                    );
                    _controller.refresh();
                  },
            child: Text(
              failed
                  ? '返回问卷重试'
                  : registering
                  ? '重试确认提交'
                  : '刷新状态',
            ),
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }
}

class _CoverageBar extends StatelessWidget {
  const _CoverageBar({required this.label, required this.percent});

  final String label;
  final int percent;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('$label $percent%'),
      const SizedBox(height: 6),
      LinearProgressIndicator(
        value: percent / 100,
        minHeight: 6,
        semanticsLabel: label,
        semanticsValue: '$percent%',
      ),
    ],
  );
}
