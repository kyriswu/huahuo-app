import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/app_route_observer.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../notifications/application/pending_message_projection.dart';
import '../../work_ai/application/work_ai_task_controller.dart';
import '../../work_ai/domain/work_ai_task.dart';

class V3WorkAiTaskPage extends ConsumerStatefulWidget {
  const V3WorkAiTaskPage({required this.taskId, super.key});

  final String taskId;

  @override
  ConsumerState<V3WorkAiTaskPage> createState() => _V3WorkAiTaskPageState();
}

class _V3WorkAiTaskPageState extends ConsumerState<V3WorkAiTaskPage>
    with AppActivityRouteAware<V3WorkAiTaskPage> {
  OrchestratedPoller? _poller;
  String? _pollTaskId;
  String? _scheduledResultAcknowledgementTaskId;
  String? _acknowledgedResultTaskId;
  var _receivedFreshRunningStateWhileInactive = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<WorkAiTaskState>(
      workAiTaskControllerProvider.select((controller) => controller.state),
      (_, next) {
        final task = next.detail?.task;
        if (!activityRouteCanRun &&
            next.status == WorkAiTaskControllerStatus.ready &&
            task != null &&
            task.isRunning) {
          _receivedFreshRunningStateWhileInactive = true;
        }
        _syncPolling(next);
      },
      fireImmediately: true,
    );
    Future<void>.microtask(_loadActiveTask);
  }

  @override
  void dispose() {
    _poller?.dispose();
    super.dispose();
  }

  @override
  void onActivityRouteBecameActive() {
    final state = ref.read(workAiTaskControllerProvider).state;
    final task = state.detail?.task;
    if (task != null && task.isRunning && !state.isSubmitting) {
      final immediate = !_receivedFreshRunningStateWhileInactive;
      _receivedFreshRunningStateWhileInactive = false;
      _syncPolling(state, immediate: immediate);
    } else {
      _receivedFreshRunningStateWhileInactive = false;
      _loadActiveTask();
    }
    _scheduleVisibleResultAcknowledgement(state.detail);
  }

  @override
  void onActivityRouteBecameInactive() {
    _receivedFreshRunningStateWhileInactive = false;
    _poller?.stop();
  }

  void _loadActiveTask() {
    if (!activityRouteCanRun) return;
    final controller = ref.read(workAiTaskControllerProvider);
    final task = controller.state.detail?.task;
    if (task == null || task.isRunning) {
      unawaited(controller.load(task?.taskId ?? widget.taskId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(workAiTaskControllerProvider);
    final state = controller.state;
    _scheduleVisibleResultAcknowledgement(state.detail);
    return V3PageScaffold(
      title: '选题任务',
      centerTitle: true,
      fallbackRoute: '/v3/workbench',
      trailing: IconButton(
        tooltip: '任务操作',
        icon: const Icon(Icons.more_horiz_rounded),
        onPressed: () async {
          final action = await showV3ActionSheet<_TaskMenuAction>(
            context: context,
            title: '任务操作',
            items: <V3ActionSheetItem<_TaskMenuAction>>[
              V3ActionSheetItem(
                value: _TaskMenuAction.refresh,
                icon: Icons.refresh_rounded,
                label: '刷新状态',
                enabled: !state.isLoading,
              ),
              V3ActionSheetItem(
                value: _TaskMenuAction.regenerate,
                icon: Icons.autorenew_rounded,
                label: '重新生成',
                enabled: state.detail != null && !state.isSubmitting,
              ),
            ],
          );
          if (action != null && context.mounted) {
            _onMenuAction(context, controller, action);
          }
        },
      ),
      children: [
        if (state.isLoading && state.detail == null)
          const Padding(
            padding: EdgeInsets.only(top: 72),
            child: Center(child: CircularProgressIndicator.adaptive()),
          )
        else if (state.detail != null)
          _TaskBody(
            detail: state.detail!,
            submitting: state.isSubmitting,
            onRetry: (action) => _retry(context, controller, action),
            onRecording: (recordingId) => context.push(
              '/v3/feed/transcription-done/${Uri.encodeComponent(recordingId)}',
            ),
          )
        else
          _TaskFailure(
            code: state.errorCode,
            onRetry: () => controller.load(widget.taskId),
          ),
        if (state.detail != null && state.errorCode != null) ...[
          const SizedBox(height: 12),
          Text(
            state.errorCode!,
            style: TextStyle(
              color: HuahuoV3Theme.tokensOf(context).danger,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  void _scheduleVisibleResultAcknowledgement(WorkAiTaskDetail? detail) {
    final task = detail?.task;
    final taskId = task?.taskId;
    if (taskId == null ||
        taskId != widget.taskId ||
        task?.status != 'succeeded' ||
        detail?.topicResult?.taskId != taskId ||
        _scheduledResultAcknowledgementTaskId == taskId ||
        _acknowledgedResultTaskId == taskId) {
      return;
    }
    _scheduledResultAcknowledgementTaskId = taskId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_acknowledgeVisibleResult(taskId));
    });
  }

  Future<void> _acknowledgeVisibleResult(String taskId) async {
    try {
      if (!mounted || !activityRouteCanRun) return;
      final detail = ref.read(workAiTaskControllerProvider).state.detail;
      if (detail?.task.taskId != taskId ||
          detail?.task.status != 'succeeded' ||
          detail?.topicResult?.taskId != taskId) {
        return;
      }
      final acknowledged = await ref
          .read(pendingMessageActionsProvider)
          .acknowledgeResultShown(targetType: 'task', targetId: taskId);
      if (acknowledged) _acknowledgedResultTaskId = taskId;
    } finally {
      if (_scheduledResultAcknowledgementTaskId == taskId) {
        _scheduledResultAcknowledgementTaskId = null;
      }
    }
  }

  void _syncPolling(WorkAiTaskState state, {bool immediate = false}) {
    final task = state.detail?.task;
    final shouldPoll = task != null && task.isRunning && !state.isSubmitting;
    if (shouldPoll && activityRouteCanRun) {
      final taskId = task.taskId.trim();
      if (_pollTaskId != taskId) {
        _poller?.dispose();
        _poller = null;
        _pollTaskId = taskId;
      }
      _poller ??= OrchestratedPoller(
        orchestrator: ref.read(taskOrchestratorProvider),
        // performance-rfc: unified-network-pollers
        spec: TaskSpec(
          key: _taskStatusPollKey(taskId),
          owner: 'work-ai.task-status',
          priority: TaskPriority.foregroundDeferred,
          resources: const <TaskResource>{TaskResource.network},
          foregroundOnly: true,
          replaceExisting: true,
          retryable: true,
          deadline: const Duration(seconds: 10),
        ),
        interval: const Duration(seconds: 5),
        maxBackoff: const Duration(seconds: 30),
        activityMetrics: ref.read(runtimeActivityMetricsProvider),
        poll: (_) async {
          if (!mounted || !activityRouteCanRun) return false;
          final controller = ref.read(workAiTaskControllerProvider);
          final latest = controller.state.detail?.task;
          if (latest == null ||
              !latest.isRunning ||
              controller.state.isSubmitting) {
            return false;
          }
          await controller.load(latest.taskId);
          final next = controller.state.detail?.task;
          return mounted &&
              activityRouteCanRun &&
              next != null &&
              next.isRunning &&
              !controller.state.isSubmitting;
        },
      );
      _poller!.start(immediate: immediate);
      return;
    }
    if (!shouldPoll) {
      _poller?.stop();
    }
  }

  void _onMenuAction(
    BuildContext context,
    WorkAiTaskController controller,
    _TaskMenuAction action,
  ) {
    switch (action) {
      case _TaskMenuAction.refresh:
        final taskId = controller.state.detail?.task.taskId ?? widget.taskId;
        controller.load(taskId);
        return;
      case _TaskMenuAction.regenerate:
        _showRegenerateDialog(context, controller);
        return;
    }
  }

  Future<void> _retry(
    BuildContext context,
    WorkAiTaskController controller,
    WorkAiTaskRetryAction action,
  ) async {
    final task = await controller.retry(action);
    if (!context.mounted || task == null) return;
    showV3Snack(context, '已创建新的任务');
  }

  Future<void> _showRegenerateDialog(
    BuildContext context,
    WorkAiTaskController controller,
  ) async {
    final task = await showDialog<WorkAiTaskInfo>(
      context: context,
      builder: (dialogContext) =>
          _RegenerateTaskDialog(submit: controller.regenerate),
    );
    if (!context.mounted || task == null) return;
    showV3Snack(context, '已创建新的任务');
  }
}

String _taskStatusPollKey(String taskId) {
  final digest = sha256.convert(utf8.encode(taskId.trim())).toString();
  return 'work-ai.task-status.${digest.substring(0, 16)}';
}

enum _TaskMenuAction { refresh, regenerate }

class _RegenerateTaskDialog extends StatefulWidget {
  const _RegenerateTaskDialog({required this.submit});

  final Future<WorkAiTaskInfo?> Function({String? supplement}) submit;

  @override
  State<_RegenerateTaskDialog> createState() => _RegenerateTaskDialogState();
}

class _RegenerateTaskDialogState extends State<_RegenerateTaskDialog> {
  final _input = TextEditingController();
  var _submitting = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final value = _input.text.trim();
    final task = await widget.submit(supplement: value.isEmpty ? null : value);
    if (!mounted) return;
    if (task == null) {
      setState(() => _submitting = false);
      return;
    }
    Navigator.of(context).pop(task);
  }

  @override
  Widget build(BuildContext context) {
    return V3GlassDialogFrame(
      title: '重新生成',
      content: TextField(
        controller: _input,
        contextMenuBuilder: V3TextEditing.buildContextMenu,
        maxLength: 500,
        minLines: 2,
        maxLines: 4,
        enabled: !_submitting,
        decoration: const InputDecoration(hintText: '补充生成要求（可选）'),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? '提交中' : '提交'),
        ),
      ],
    );
  }
}

class _TaskBody extends StatelessWidget {
  const _TaskBody({
    required this.detail,
    required this.submitting,
    required this.onRetry,
    required this.onRecording,
  });

  final WorkAiTaskDetail detail;
  final bool submitting;
  final ValueChanged<WorkAiTaskRetryAction> onRetry;
  final ValueChanged<String> onRecording;

  @override
  Widget build(BuildContext context) {
    final task = detail.task;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        V3Card(
          radius: 16,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            children: [
              _StatusIcon(status: task.status),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.taskType,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '状态：${task.status}',
                      style: TextStyle(
                        color: HuahuoV3Theme.tokensOf(context).muted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (task.isRunning)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        if (task.errorMessage != null) ...[
          const SizedBox(height: 12),
          _TaskErrorCard(task: task),
        ],
        if (detail.topicResult != null) ...[
          const SizedBox(height: 12),
          const Text(
            '服务端生成的选题',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          for (final item in detail.topicResult!.topics) ...[
            _TopicResultCard(item: item, onRecording: onRecording),
            const SizedBox(height: 8),
          ],
        ] else if (task.isRunning) ...[
          const SizedBox(height: 12),
          const _TaskPendingCard(),
        ],
        if (!submitting &&
            detail.retryActions.any((action) => action.allowed)) ...[
          const SizedBox(height: 12),
          const Text(
            '可用操作',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          for (final action in detail.retryActions.where(
            (item) => item.allowed,
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: V3OutlineButton(
                label: action.title,
                icon: Icons.replay_rounded,
                onPressed: () => onRetry(action),
              ),
            ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final failed = status == 'failed';
    final done = status == 'succeeded';
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: failed
            ? HuahuoV3Theme.semanticSurface(colors.danger, colors.surface)
            : done
            ? HuahuoV3Theme.semanticSurface(colors.success, colors.surface)
            : colors.surfaceMuted,
        shape: BoxShape.circle,
      ),
      child: Icon(
        failed
            ? Icons.error_outline_rounded
            : done
            ? Icons.check_circle_outline_rounded
            : Icons.auto_awesome_rounded,
        color: failed
            ? colors.danger
            : done
            ? colors.success
            : colors.muted,
      ),
    );
  }
}

class _TaskErrorCard extends StatelessWidget {
  const _TaskErrorCard({required this.task});

  final WorkAiTaskInfo task;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: HuahuoV3Theme.semanticSurface(colors.danger, colors.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.danger.withValues(alpha: .45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          task.errorMessage!,
          style: TextStyle(color: colors.ink, fontSize: 14, height: 1.35),
        ),
      ),
    );
  }
}

class _TaskPendingCard extends StatelessWidget {
  const _TaskPendingCard();

  @override
  Widget build(BuildContext context) {
    return V3Card(
      radius: 16,
      padding: const EdgeInsets.all(16),
      child: Text(
        '任务正在服务端处理，页面会自动刷新状态。',
        style: TextStyle(
          color: HuahuoV3Theme.tokensOf(context).muted,
          height: 1.4,
        ),
      ),
    );
  }
}

class _TopicResultCard extends StatelessWidget {
  const _TopicResultCard({required this.item, required this.onRecording});

  final WorkAiTopicResultItem item;
  final ValueChanged<String> onRecording;

  @override
  Widget build(BuildContext context) {
    return V3Card(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          Text(item.reason, style: const TextStyle(fontSize: 14, height: 1.4)),
          if (item.sourceRecordingIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final recordingId in item.sourceRecordingIds)
                  ActionChip(
                    label: const Text('查看来源录音'),
                    onPressed: () => onRecording(recordingId),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskFailure extends StatelessWidget {
  const _TaskFailure({required this.code, required this.onRetry});

  final String? code;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 72),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 34),
            const SizedBox(height: 10),
            Text('任务暂时不可用${code == null ? '' : ' ($code)'}'),
            const SizedBox(height: 8),
            IconButton(
              tooltip: '重试',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
