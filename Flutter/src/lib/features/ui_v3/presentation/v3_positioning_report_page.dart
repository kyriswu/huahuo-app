import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../app/di/onboarding_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../chat/domain/chat_models.dart';
import '../../notifications/application/pending_message_projection.dart';
import '../../onboarding/application/initial_positioning_task_coordinator.dart';
import '../application/deep_positioning_controller.dart';
import '../application/positioning_report_presentation.dart';
import '../domain/deep_positioning_models.dart';
import '../domain/positioning_lifecycle.dart';
import 'v3_positioning_dashboard.dart';
import 'v3_positioning_task_progress.dart';

const _initialPositioningStatusPollInterval = Duration(seconds: 3);

class V3PositioningReportPage extends ConsumerStatefulWidget {
  const V3PositioningReportPage({this.taskId, super.key});

  final String? taskId;

  @override
  ConsumerState<V3PositioningReportPage> createState() =>
      _V3PositioningReportPageState();
}

class _V3PositioningReportPageState
    extends ConsumerState<V3PositioningReportPage>
    with AppActivityRouteAware<V3PositioningReportPage> {
  InitialPositioningServerState? _serverState;
  bool _checking = true;
  Future<void>? _refreshInFlight;
  String? _refreshKey;
  OrchestratedPoller? _serverPoller;
  String? _serverPollerKey;
  Timer? _acknowledgementRetryTimer;
  String? _acknowledgementInFlightTaskId;
  String? _notificationAcknowledgedTaskId;
  String? _localCheckpointAcknowledgedTaskId;
  int _scopeRevision = 0;

  String? get _requestedTaskId {
    final taskId = widget.taskId?.trim();
    return taskId == null || taskId.isEmpty ? null : taskId;
  }

  String? get _workspaceId {
    final session = ref.read(sessionStoreProvider).state;
    if (session.authState != SessionAuthState.authenticated ||
        session.workspaceStatus != SessionWorkspaceStatus.ready) {
      return null;
    }
    final workspaceId = session.workspace?.workspaceId?.trim();
    return workspaceId == null || workspaceId.isEmpty ? null : workspaceId;
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual<String?>(
      sessionStoreProvider.select((store) {
        final session = store.state;
        if (session.authState != SessionAuthState.authenticated ||
            session.workspaceStatus != SessionWorkspaceStatus.ready) {
          return null;
        }
        final workspaceId = session.workspace?.workspaceId?.trim();
        return workspaceId == null || workspaceId.isEmpty
            ? null
            : '${session.user?.userId}\u0000$workspaceId';
      }),
      _handleWorkspaceChanged,
    );
    ref.listenManual<InitialPositioningTaskState>(
      initialPositioningTaskStateProvider,
      _handleTaskChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshSurface(showChecking: true));
    });
  }

  @override
  void didUpdateWidget(covariant V3PositioningReportPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId?.trim() == widget.taskId?.trim()) return;
    _scopeRevision += 1;
    _disposeServerPoller();
    _acknowledgementRetryTimer?.cancel();
    _acknowledgementInFlightTaskId = null;
    _notificationAcknowledgedTaskId = null;
    _localCheckpointAcknowledgedTaskId = null;
    _serverState = null;
    _checking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && activityRouteCanRun) {
        unawaited(_refreshSurface(showChecking: true));
      }
    });
  }

  @override
  void onActivityRouteBecameActive() {
    unawaited(_refreshSurface(showChecking: _serverState == null));
  }

  @override
  void onActivityRouteBecameInactive() {
    _disposeServerPoller();
    _acknowledgementRetryTimer?.cancel();
  }

  void _handleWorkspaceChanged(String? previous, String? next) {
    if (previous == next) return;
    _scopeRevision += 1;
    _disposeServerPoller();
    _acknowledgementRetryTimer?.cancel();
    _acknowledgementInFlightTaskId = null;
    _notificationAcknowledgedTaskId = null;
    _localCheckpointAcknowledgedTaskId = null;
    if (mounted) {
      setState(() {
        _serverState = null;
        _checking = true;
      });
    }
    if (next != null && activityRouteCanRun) {
      unawaited(_refreshSurface(showChecking: true));
    }
  }

  void _handleTaskChanged(
    InitialPositioningTaskState? previous,
    InitialPositioningTaskState next,
  ) {
    if (!mounted) return;
    setState(() {});
    final scopedPrevious = previous == null
        ? null
        : _workspaceScopedLocalTask(previous);
    final scopedNext = _workspaceScopedLocalTask(next);
    if (scopedNext.status == InitialPositioningTaskStatus.succeeded &&
        scopedPrevious?.status != scopedNext.status &&
        activityRouteCanRun) {
      unawaited(_refreshSurface());
    } else {
      _syncServerPolling();
    }
  }

  bool _canApply(String workspaceId, int revision) =>
      mounted &&
      activityRouteCanRun &&
      revision == _scopeRevision &&
      _workspaceId == workspaceId;

  Future<void> _refreshSurface({
    bool showChecking = false,
    bool managePolling = true,
  }) {
    final workspaceId = _workspaceId;
    if (workspaceId == null || !activityRouteCanRun) {
      return Future<void>.value();
    }
    final revision = _scopeRevision;
    final key = '$workspaceId:$revision';
    final active = _refreshInFlight;
    if (active != null) {
      if (_refreshKey == key) return active;
      return active.then((_) {
        if (!_canApply(workspaceId, revision)) return Future<void>.value();
        return _refreshSurface(
          showChecking: showChecking,
          managePolling: managePolling,
        );
      });
    }

    final hasReport =
        ref
            .read(deepPositioningControllerProvider)
            .result
            ?.markdown
            .trim()
            .isNotEmpty ==
        true;
    if (showChecking && !hasReport && _serverState == null) {
      setState(() => _checking = true);
    }

    late final Future<void> operation;
    operation =
        _performRefresh(
          workspaceId: workspaceId,
          revision: revision,
          managePolling: managePolling,
        ).whenComplete(() {
          if (identical(_refreshInFlight, operation)) {
            _refreshInFlight = null;
            _refreshKey = null;
          }
        });
    _refreshKey = key;
    _refreshInFlight = operation;
    return operation;
  }

  Future<void> _performRefresh({
    required String workspaceId,
    required int revision,
    required bool managePolling,
  }) async {
    final lifecycle = ref.read(positioningLifecycleCoordinatorProvider);
    if (managePolling) {
      await lifecycle?.continueRecovery();
    } else {
      await lifecycle?.reconcile();
    }
    if (!_canApply(workspaceId, revision)) return;
    final reportRefresh = ref.read(deepPositioningControllerProvider).refresh();
    InitialPositioningServerState serverState;
    try {
      serverState = await ref.read(initialPositioningServerStateReaderProvider)(
        workspaceId: workspaceId,
      );
    } catch (_) {
      serverState = InitialPositioningServerState.unavailable(
        workspaceId: workspaceId,
      );
    }
    await reportRefresh;
    if (!_canApply(workspaceId, revision)) return;
    setState(() {
      _serverState = serverState;
      _checking = false;
    });
    if (managePolling) _syncServerPolling();
  }

  void _syncServerPolling() {
    if (ref.read(positioningLifecycleCoordinatorProvider) != null) {
      _disposeServerPoller();
      return;
    }
    if (!mounted || !activityRouteCanRun) {
      _disposeServerPoller();
      return;
    }
    final report = ref.read(deepPositioningControllerProvider).result;
    final workspaceId = _workspaceId;
    final localTask = _workspaceScopedLocalTask(
      ref.read(initialPositioningTaskStateProvider),
    );
    final serverState = _serverStateForCurrentRequest(localTask);
    if (report?.markdown.trim().isNotEmpty == true ||
        workspaceId == null ||
        serverState?.shouldPoll != true) {
      _disposeServerPoller();
      return;
    }
    _startServerPoller(workspaceId, _scopeRevision);
  }

  void _startServerPoller(String workspaceId, int revision) {
    final key = '$workspaceId:$revision';
    if (_serverPollerKey == key && _serverPoller != null) {
      if (!_serverPoller!.isRunning) _serverPoller!.start(immediate: false);
      return;
    }
    _disposeServerPoller();
    final poller = OrchestratedPoller(
      orchestrator: ref.read(taskOrchestratorProvider),
      spec: TaskSpec(
        key: 'positioning:report-state:$key',
        owner: 'positioning-report',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 15),
      ),
      interval: _initialPositioningStatusPollInterval,
      maxBackoff: const Duration(seconds: 30),
      activityMetrics: ref.read(runtimeActivityMetricsProvider),
      poll: (token) async {
        await _refreshSurface(managePolling: false);
        token.throwIfCancelled();
        if (!_canApply(workspaceId, revision)) return false;
        final report = ref.read(deepPositioningControllerProvider).result;
        final localTask = _workspaceScopedLocalTask(
          ref.read(initialPositioningTaskStateProvider),
        );
        return report?.markdown.trim().isNotEmpty != true &&
            _serverStateForCurrentRequest(localTask)?.shouldPoll == true;
      },
    );
    _serverPollerKey = key;
    _serverPoller = poller;
    poller.start(immediate: false);
  }

  void _disposeServerPoller() {
    _serverPoller?.dispose();
    _serverPoller = null;
    _serverPollerKey = null;
  }

  InitialPositioningTaskState _workspaceScopedLocalTask(
    InitialPositioningTaskState localTask,
  ) {
    final workspaceId = _workspaceId;
    if (workspaceId == null || localTask.workspaceId?.trim() != workspaceId) {
      return const InitialPositioningTaskState();
    }
    final requestedTaskId = _requestedTaskId;
    if (requestedTaskId != null &&
        localTask.agentRunId?.trim() != requestedTaskId) {
      return const InitialPositioningTaskState();
    }
    return localTask;
  }

  String? _expectedRunId(InitialPositioningTaskState localTask) {
    final requestedTaskId = _requestedTaskId;
    if (requestedTaskId != null) return requestedTaskId;
    final localRunId = localTask.agentRunId?.trim();
    return localRunId == null || localRunId.isEmpty ? null : localRunId;
  }

  InitialPositioningServerState? get _observedServerState {
    final attempt = ref.read(positioningLifecycleCoordinatorProvider)?.attempt;
    return attempt == null
        ? _serverState
        : InitialPositioningServerState.fromAttempt(attempt);
  }

  InitialPositioningServerState? _serverStateForCurrentRequest(
    InitialPositioningTaskState localTask,
  ) {
    final serverState = _observedServerState;
    final workspaceId = _workspaceId;
    if (serverState == null ||
        workspaceId == null ||
        serverState.workspaceId != workspaceId) {
      return null;
    }
    final expectedRunId = _expectedRunId(localTask);
    if (expectedRunId == null ||
        serverState.phase == InitialPositioningServerPhase.unavailable) {
      return serverState;
    }
    final serverRunId = serverState.agentRunId?.trim();
    return serverRunId == expectedRunId ? serverState : null;
  }

  bool _serverStateConflictsWithExpectedRun(
    InitialPositioningTaskState localTask,
  ) {
    final serverState = _observedServerState;
    final workspaceId = _workspaceId;
    final expectedRunId = _expectedRunId(localTask);
    if (expectedRunId == null ||
        workspaceId == null ||
        serverState == null ||
        serverState.workspaceId != workspaceId ||
        serverState.phase == InitialPositioningServerPhase.unavailable) {
      return false;
    }
    final serverRunId = serverState.agentRunId?.trim();
    return serverRunId != expectedRunId;
  }

  Future<void> _continueDeepPositioning() async {
    await context.push<void>(
      Uri(
        path: '/v3/feed/chat',
        queryParameters: <String, String>{
          'skill': WorkbenchChatSkill.socialPositioning.routeValue,
          'purpose': ChatConversationPurpose.deepPositioning.routeValue,
        },
      ).toString(),
    );
    if (mounted && activityRouteCanRun) await _refreshSurface();
  }

  void _scheduleAcknowledgement(
    DeepPositioningResult report,
    InitialPositioningTaskState localTask,
    InitialPositioningServerState? serverState,
  ) {
    if (report.markdown.trim().isEmpty ||
        !activityRouteCanRun ||
        !ref.read(deepPositioningControllerProvider).reportRead.isRemote)
      return;
    final taskId =
        _requestedTaskId ?? localTask.agentRunId ?? serverState?.agentRunId;
    final localReportReady = localTask.isReportReadyFor(taskId);
    final serverReportReady =
        serverState?.phase == InitialPositioningServerPhase.completed &&
        serverState?.agentRunId == taskId;
    if (taskId == null ||
        (!localReportReady && !serverReportReady) ||
        (_notificationAcknowledgedTaskId == taskId &&
            (!localReportReady ||
                _localCheckpointAcknowledgedTaskId == taskId)) ||
        _acknowledgementInFlightTaskId == taskId) {
      return;
    }
    _acknowledgementInFlightTaskId = taskId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          _acknowledgeReport(
            taskId,
            acknowledgeLocalCheckpoint: localReportReady,
          ),
        );
      }
    });
  }

  Future<void> _acknowledgeReport(
    String taskId, {
    required bool acknowledgeLocalCheckpoint,
  }) async {
    var notificationSettled = _notificationAcknowledgedTaskId == taskId;
    final revision = _scopeRevision;
    final workspaceId = _workspaceId;
    var localCheckpointSettled =
        !acknowledgeLocalCheckpoint ||
        _localCheckpointAcknowledgedTaskId == taskId;
    try {
      if (!mounted || !activityRouteCanRun) return;
      if (!notificationSettled) {
        notificationSettled = await ref
            .read(pendingMessageActionsProvider)
            .acknowledgeResultShown(
              targetType: 'positioning_report',
              targetId: taskId,
              stage: 'report',
            );
        if (workspaceId == null || !_canApply(workspaceId, revision)) return;
        if (notificationSettled) {
          _notificationAcknowledgedTaskId = taskId;
        }
      }
      if (notificationSettled && !localCheckpointSettled) {
        localCheckpointSettled = ref.read(
          initialPositioningReportAcknowledgerProvider,
        )(taskId);
        if (localCheckpointSettled) {
          _localCheckpointAcknowledgedTaskId = taskId;
        }
      }
    } finally {
      if (_acknowledgementInFlightTaskId == taskId) {
        _acknowledgementInFlightTaskId = null;
      }
      if ((!notificationSettled || !localCheckpointSettled) &&
          mounted &&
          activityRouteCanRun) {
        _acknowledgementRetryTimer?.cancel();
        _acknowledgementRetryTimer = Timer(const Duration(seconds: 3), () {
          _acknowledgementRetryTimer = null;
          if (mounted && activityRouteCanRun) setState(() {});
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final reportController = ref.watch(deepPositioningControllerProvider);
    final lifecycle = ref.watch(positioningLifecycleCoordinatorProvider);
    final update = lifecycle?.latestUpdate;
    final report = reportController.result;
    final localTask = _workspaceScopedLocalTask(
      ref.watch(initialPositioningTaskStateProvider),
    );
    final matchingServerState = _serverStateForCurrentRequest(localTask);
    final serverHasAttempt =
        matchingServerState?.agentRunId?.trim().isNotEmpty == true;
    final effectiveTask = serverHasAttempt
        ? matchingServerState!.taskState
        : localTask;
    final presentation = reducePositioningReportPresentation(
      markdown: report?.markdown ?? '',
      taskStatus: effectiveTask.status,
      serverPhase: _serverStateConflictsWithExpectedRun(localTask)
          ? InitialPositioningServerPhase.unavailable
          : matchingServerState?.phase,
      checking: _checking && _workspaceId != null,
    );
    if (report != null && presentation.showReport) {
      _scheduleAcknowledgement(report, localTask, matchingServerState);
    }

    return V3PageScaffold(
      title: '社媒定位',
      subtitle: presentation.showReport ? '定位报告' : null,
      fallbackRoute: AppRoutePaths.workbench,
      onRefresh: _refreshSurface,
      trailing: presentation.showReport
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const ValueKey('positioning-report-refresh'),
                  tooltip: '刷新报告',
                  onPressed: reportController.refreshing
                      ? null
                      : () => unawaited(_refreshSurface()),
                  icon: const Icon(Icons.refresh_rounded),
                ),
                TextButton.icon(
                  key: const ValueKey('positioning-report-continue'),
                  onPressed: _continueDeepPositioning,
                  icon: const Icon(Icons.forum_outlined, size: 18),
                  label: const Text('继续深度定位'),
                ),
              ],
            )
          : IconButton(
              key: const ValueKey('positioning-report-refresh'),
              tooltip: '刷新状态',
              onPressed: _checking ? null : () => unawaited(_refreshSurface()),
              icon: const Icon(Icons.refresh_rounded),
            ),
      children: [
        if (lifecycle?.errorCode != null)
          _PositioningReportStatus(
            icon: Icons.info_outline_rounded,
            title: '定位状态需要继续核验',
            body: _positioningRecoveryMessage(lifecycle!.errorCode!),
            actionLabel: '继续恢复',
            onAction: lifecycle.continueRecovery,
          ),
        if (update != null) ...[
          _PositioningReportStatus(
            icon: Icons.sync_rounded,
            title: switch (update.stage) {
              PositioningUpdateStage.updated => '定位报告已更新',
              PositioningUpdateStage.noChanges => '本次对话未修改定位报告',
              PositioningUpdateStage.blocked => '本次更新未应用，已保留原报告',
              PositioningUpdateStage.retryableFailure => '更新暂时不可用，可以继续恢复',
              PositioningUpdateStage.applying => '正在应用本次定位更新',
              PositioningUpdateStage.awaitingReadback => '正在核对正式报告',
              _ => '正在核对本次定位任务',
            },
            body: update.errorCode == null
                ? '报告更新与数字孪生独立处理。'
                : _positioningRecoveryMessage(update.errorCode!),
            actionLabel: update.terminal ? null : '继续恢复',
            onAction: update.terminal ? null : lifecycle?.continueRecovery,
          ),
          const SizedBox(height: 16),
        ],
        if (report != null &&
            !reportController.reportRead.isRemote &&
            !report.isDemo)
          const Text('当前显示本账号缓存；尚未核验为本次更新后的正式报告。'),
        if (report != null && presentation.showReport) ...[
          V3PositioningReportContent(
            key: const ValueKey('positioning-report-content'),
            markdown: report.markdown,
            progress: report.progress,
            compactDashboard: false,
            markdownKey: const ValueKey('positioning-report-markdown'),
          ),
          if (report.progress == null &&
              parseLatestPositioningProgress(report.markdown) == null) ...[
            const SizedBox(height: 16),
            const _PositioningReportStatus(
              icon: Icons.info_outline_rounded,
              title: '报告维度进度暂不可用',
              body: '正式报告已经生成，可以正常查看；维度评分不会被当作报告生成状态。',
            ),
          ],
          const SizedBox(height: 16),
          Text(
            '最近更新 ${_dateTimeLabel(report.savedAt)}',
            style: TextStyle(
              color: HuahuoV3Theme.tokensOf(context).muted,
              fontSize: 12,
            ),
          ),
        ] else if (presentation.showGenerationProgress)
          V3PositioningTaskProgress(
            key: ValueKey(
              'positioning-report-task:${effectiveTask.agentRunId}:${effectiveTask.status.name}',
            ),
            task: effectiveTask,
            onRefresh: _refreshSurface,
          )
        else
          _buildNonReportState(presentation, effectiveTask),
      ],
    );
  }

  Widget _buildNonReportState(
    PositioningReportPresentationState state,
    InitialPositioningTaskState effectiveTask,
  ) => switch (state) {
    PositioningReportPresentationState.checking =>
      const _PositioningReportStatus(
        key: ValueKey('positioning-report-checking'),
        icon: Icons.sync_rounded,
        title: '正在核对定位报告',
        body: '正在读取当前 Workspace 的基础定位状态与正式报告。',
        checking: true,
      ),
    PositioningReportPresentationState.reportUnavailable =>
      _PositioningReportStatus(
        key: const ValueKey('positioning-report-read-unavailable'),
        icon: Icons.description_outlined,
        title: '报告已完成，但暂时无法读取',
        body: '基础定位任务已经结束，当前没有读到正式报告。请重新读取，不会再次提交生成任务。',
        actionLabel: '重新读取',
        onAction: _refreshSurface,
      ),
    PositioningReportPresentationState.failed => V3PositioningTaskProgress(
      key: ValueKey('positioning-report-failed:${effectiveTask.agentRunId}'),
      task: effectiveTask,
      onRefresh: _refreshSurface,
    ),
    PositioningReportPresentationState.unavailable => _PositioningReportStatus(
      key: const ValueKey('positioning-report-state-unavailable'),
      icon: Icons.cloud_off_outlined,
      title: '暂时无法读取定位状态',
      body: '没有可读的正式报告，且当前状态核对失败。重新检查不会创建新的定位任务。',
      actionLabel: '重新检查',
      onAction: _refreshSurface,
    ),
    PositioningReportPresentationState.notStarted => _PositioningReportStatus(
      key: const ValueKey('positioning-report-not-started'),
      icon: Icons.explore_outlined,
      title: '尚未生成基础定位报告',
      body: '完成基础定位问卷后，这里会显示正式报告和每个定位维度的完成度。',
      actionLabel: '开始基础定位',
      onAction: () async => context.push('/onboarding'),
    ),
    PositioningReportPresentationState.ready ||
    PositioningReportPresentationState.generating => const SizedBox.shrink(),
  };

  @override
  void dispose() {
    _scopeRevision += 1;
    _disposeServerPoller();
    _acknowledgementRetryTimer?.cancel();
    super.dispose();
  }
}

class _PositioningReportStatus extends StatelessWidget {
  const _PositioningReportStatus({
    required this.icon,
    required this.title,
    required this.body,
    this.checking = false,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool checking;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      variant: V3CardVariant.outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (checking)
                const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, color: colors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(body, style: TextStyle(color: colors.text, height: 1.5)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => unawaited(onAction!.call()),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(actionLabel!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _dateTimeLabel(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _positioningRecoveryMessage(String code) {
  final reason = switch (code) {
    'POSITIONING_SOURCE_UNVERIFIED' ||
    'POSITIONING_SOURCE_MISMATCH' => '暂时无法确认候选来自本次定位任务，未应用候选。',
    'POSITIONING_SCOPE_MISMATCH' ||
    'POSITIONING_WORKSPACE_MISMATCH' ||
    'POSITIONING_SCOPE_CHANGED' => '账号或工作区已经变化，已停止处理原账号的请求。',
    'POSITIONING_CANDIDATE_NOT_CURRENT' => '已有更新的定位候选，旧候选不会自动覆盖当前报告。',
    'POSITIONING_RUN_FAILED' => '原定位任务未成功完成，已保留现有报告。可继续深度定位，明确发起新的对话。',
    'POSITIONING_READBACK_PENDING' => '本轮核验已暂停。继续恢复只检查原任务和正式报告，不会重新生成。',
    _ when RegExp('VERSION|STALE|CONFLICT|PRECONDITION').hasMatch(code) =>
      '报告或候选版本已经变化，未强制覆盖。请刷新当前报告后继续深度定位。',
    _ => '暂时无法完成核验，现有报告和问卷答案会保留。继续恢复只检查原任务，不会重新生成。',
  };
  return '$reason\n诊断代码：$code';
}
