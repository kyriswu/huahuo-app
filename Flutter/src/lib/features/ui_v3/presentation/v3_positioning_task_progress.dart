import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../app/di/onboarding_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/api/scoped_read_cache.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
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
  late final String _userScope;
  late final String? _workspaceId;
  late final OrchestratedPoller _poller;
  ScopedReadCache? _cache;
  WorkspacePositioningProgress? _progress;
  String? _etag;
  bool _stale = false;
  bool _loading = false;

  bool get _canPoll =>
      activityRouteCanRun &&
      !widget.task.isTerminal &&
      widget.task.status != InitialPositioningTaskStatus.idle &&
      widget.task.status != InitialPositioningTaskStatus.registering &&
      _workspaceId != null &&
      _userScope != 'anonymous';

  @override
  void initState() {
    super.initState();
    _userScope = ref.read(authenticatedUserDataScopeProvider);
    _workspaceId = ref.read(sessionStoreProvider).state.workspace?.workspaceId;
    if (_workspaceId != null && _userScope != 'anonymous') {
      _cache = ScopedReadCache(
        dao: ref.read(appPreferencesDaoProvider),
        userScope: _userScope,
        workspaceScope: _workspaceId,
        fallbackTtl: ref.read(appCachePolicyProvider).cacheTtl,
      );
      final cached = _cache?.readFallback(
        'workspacePositioningProgress',
        _workspaceId,
      );
      if (cached != null) {
        _progress = parseWorkspacePositioningProgress(cached.payload);
        if (_progress != null) {
          _etag = cached.etag;
          _stale = true;
        }
      }
    }
    _poller = OrchestratedPoller(
      orchestrator: ref.read(taskOrchestratorProvider),
      spec: TaskSpec(
        key: 'positioning:progress:$_userScope:$_workspaceId',
        owner: 'positioning-report-progress',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 15),
      ),
      interval: const Duration(seconds: 3),
      maxBackoff: const Duration(seconds: 30),
      activityMetrics: ref.read(runtimeActivityMetricsProvider),
      poll: (token) async {
        await _read(token);
        return _canPoll;
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPolling();
    });
  }

  @override
  void didUpdateWidget(V3PositioningTaskProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPolling();
  }

  @override
  void onActivityRouteBecameActive() => _syncPolling();

  @override
  void onActivityRouteBecameInactive() => _poller.stop();

  void _syncPolling() {
    if (_canPoll) {
      _poller.start();
    } else {
      _poller.stop();
    }
  }

  Future<void> _read(AppTaskCancellationToken token) async {
    if (!_canPoll || _loading) return;
    _loading = true;
    try {
      final response = await PositioningProgressClient(
        ref.read(apiClientProvider),
      ).read(workspaceId: _workspaceId!, ifNoneMatch: _etag);
      token.throwIfCancelled();
      if (!_canPoll ||
          ref.read(authenticatedUserDataScopeProvider) != _userScope ||
          ref.read(sessionStoreProvider).state.workspace?.workspaceId !=
              _workspaceId) {
        return;
      }
      if (response.isNotModified && _progress != null) {
        setState(
          () => _stale = _progress!.validationStatus == 'last_known_good',
        );
        return;
      }
      if (!response.ok || response.data == null) {
        throw StateError('POSITIONING_PROGRESS_UNAVAILABLE');
      }
      final progress = response.data!;
      _cache?.write(
        'workspacePositioningProgress',
        _workspaceId,
        etag: response.etag,
        payload: _progressPayload(progress),
      );
      setState(() {
        _progress = progress;
        _etag = response.etag;
        _stale = progress.validationStatus == 'last_known_good';
      });
    } on AppTaskCancelledException {
      rethrow;
    } catch (_) {
      if (mounted) setState(() => _stale = true);
      rethrow;
    } finally {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _poller.dispose();
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
        if (_progress case final progress?) ...[
          const SizedBox(height: 14),
          _CoverageBar(label: '基础信息完整度', percent: progress.coldStartPercent),
          const SizedBox(height: 12),
          _CoverageBar(label: '定位内容覆盖度', percent: progress.completedPercent),
          const SizedBox(height: 8),
          Text(
            _stale ? '以上为最近一次已确认的数据，正在等待服务端更新。' : '完整度来自服务端已写入资料，不代表本次生成耗时进度。',
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
                    _poller.stop();
                    _syncPolling();
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

Map<String, Object?> _progressPayload(WorkspacePositioningProgress progress) =>
    {
      'schemaVersion': progress.schemaVersion,
      'source': progress.source,
      'available': true,
      'projectionVersion': progress.projectionVersion,
      'status': progress.status,
      'validationStatus': progress.validationStatus,
      'completedPercent': progress.completedPercent,
      'coldStartPercent': progress.coldStartPercent,
      'coldStartCompleted': progress.coldStartCompleted,
      'modules': [
        for (final module in progress.modules)
          {
            'id': module.id,
            'label': module.label,
            'weight': module.weight,
            'score': module.score,
            'state': module.state,
            'summary': module.summary,
          },
      ],
      'nextFocus': [
        for (final focus in progress.nextFocus)
          {
            'title': focus.title,
            'detail': focus.detail,
            'moduleId': focus.moduleId,
          },
      ],
      'updatedFiles': progress.updatedFiles,
      'lastUpdated': progress.lastUpdated?.toUtc().toIso8601String(),
    };
