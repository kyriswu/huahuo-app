import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../application/workbench_generation_controller.dart';
import '../domain/ui_v3_models.dart';

class V3WorkbenchGeneratingPage extends ConsumerStatefulWidget {
  const V3WorkbenchGeneratingPage({
    required this.purpose,
    this.resumeOperationId,
    super.key,
  });

  final WorkbenchPurpose purpose;
  final String? resumeOperationId;

  @override
  ConsumerState<V3WorkbenchGeneratingPage> createState() =>
      _V3WorkbenchGeneratingPageState();
}

class _V3WorkbenchGeneratingPageState
    extends ConsumerState<V3WorkbenchGeneratingPage>
    with AppActivityRouteAware<V3WorkbenchGeneratingPage> {
  bool _resultOpened = false;
  String? _operationId;
  bool _reconciliationScheduled = false;

  WorkbenchGenerationTask? _task(WorkbenchGenerationController controller) {
    final task = controller.taskForId(_operationId);
    return task?.purpose == widget.purpose ? task : null;
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(workbenchGenerationControllerProvider, (_, __) {
      _scheduleReconciliation();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bindEntry();
    });
  }

  @override
  void didUpdateWidget(covariant V3WorkbenchGeneratingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.purpose != widget.purpose ||
        oldWidget.resumeOperationId != widget.resumeOperationId) {
      _operationId = widget.resumeOperationId;
      _resultOpened = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _bindEntry();
      });
    }
  }

  void _bindEntry() {
    final controller = ref.read(workbenchGenerationControllerProvider);
    _resultOpened = false;
    _operationId = widget.resumeOperationId;
    if (_operationId == null && controller.purpose == widget.purpose) {
      if (controller.status == WorkbenchGenerationStatus.generating) {
        _operationId = controller.generationId;
      } else if (controller.canGenerate) {
        unawaited(controller.generate());
        _operationId = controller.generationId;
      }
    }
    setState(() {});
    _scheduleReconciliation();
  }

  @override
  void onActivityRouteBecameActive() => _scheduleReconciliation();

  void _scheduleReconciliation() {
    if (_reconciliationScheduled) return;
    _reconciliationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reconciliationScheduled = false;
      _openCompletedResult();
    });
  }

  void _retry() {
    final controller = ref.read(workbenchGenerationControllerProvider);
    final task = _task(controller);
    if (task == null) return;
    if (controller.status == WorkbenchGenerationStatus.generating) {
      showV3Snack(context, '另一项生成仍在处理中，请稍后再试');
      return;
    }
    unawaited(controller.retry(task.id));
    setState(() => _operationId = controller.generationId);
  }

  void _openCompletedResult() {
    if (!activityRouteCanRun || _resultOpened) {
      return;
    }
    final task = _task(ref.read(workbenchGenerationControllerProvider));
    if (task?.status != WorkbenchGenerationTaskStatus.succeeded) {
      return;
    }
    _resultOpened = true;
    context.pushReplacement(
      Uri(
        path: AppRoutePaths.workbenchGenerated(widget.purpose.routeName),
        queryParameters: {'operationId': task!.id},
      ).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(workbenchGenerationControllerProvider);
    final task = _task(controller);
    final processing = task?.status == WorkbenchGenerationTaskStatus.processing;
    final awaitingResult =
        task?.status == WorkbenchGenerationTaskStatus.awaitingResult;
    final failed = task?.status == WorkbenchGenerationTaskStatus.failed;
    final unavailable = task == null;
    return V3PageScaffold(
      title: unavailable
          ? '生成记录不可用'
          : awaitingResult
          ? '生成结果待确认'
          : failed
          ? '生成未完成'
          : widget.purpose.generatingTitle,
      subtitle: task == null ? null : '已选择 ${task.notes.length} 条材料',
      fallbackRoute: AppRoutePaths.workbenchMaterials(widget.purpose.routeName),
      children: [
        V3Card(
          child: Column(
            children: [
              if (processing) ...[
                const CircularProgressIndicator.adaptive(),
                const SizedBox(height: 24),
              ],
              Text(
                unavailable
                    ? '这次生成已不在当前会话中，不会自动创建或打开其他任务。'
                    : awaitingResult
                    ? '本轮查询已暂停，尚不能确认云端结果。继续查询原任务，不会重复生成。'
                    : failed
                    ? '生成未完成，原始材料和任务记录仍然保留。'
                    : processing
                    ? '正在读取材料并生成内容，尚未收到处理结果。'
                    : '生成已完成，正在打开结果。',
                style: TextStyle(color: HuahuoV3Theme.tokensOf(context).muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (processing) ...[
          const V3LongRunningTaskNotice(),
          const SizedBox(height: 12),
        ],
        if (failed || awaitingResult) ...[
          V3PrimaryButton(
            label: awaitingResult
                ? '继续查询'
                : task!.requiresNewOperation
                ? '重新生成'
                : '重试同一任务',
            onPressed: _retry,
          ),
          const SizedBox(height: 10),
          V3OutlineButton(label: '返回选择', onPressed: _returnToMaterials),
        ] else if (unavailable)
          V3OutlineButton(label: '返回', onPressed: _returnToMaterials),
      ],
    );
  }

  void _returnToMaterials() {
    unawaited(
      returnFromV3LongRunningTask(
        context,
        fallbackRoute: AppRoutePaths.workbenchMaterials(
          widget.purpose.routeName,
        ),
      ),
    );
  }
}
