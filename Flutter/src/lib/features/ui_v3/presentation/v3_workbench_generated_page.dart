import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../application/workbench_generation_controller.dart';
import '../domain/feed_item_models.dart';
import '../domain/ui_v3_models.dart';

class V3WorkbenchGeneratedPage extends ConsumerStatefulWidget {
  const V3WorkbenchGeneratedPage({
    required this.purpose,
    this.operationId,
    super.key,
  });

  final WorkbenchPurpose purpose;
  final String? operationId;

  @override
  ConsumerState<V3WorkbenchGeneratedPage> createState() =>
      _V3WorkbenchGeneratedPageState();
}

class _V3WorkbenchGeneratedPageState
    extends ConsumerState<V3WorkbenchGeneratedPage> {
  String? _operationId;

  @override
  void initState() {
    super.initState();
    _bindEntry();
  }

  @override
  void didUpdateWidget(covariant V3WorkbenchGeneratedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.purpose != widget.purpose ||
        oldWidget.operationId != widget.operationId) {
      _bindEntry();
    }
  }

  void _bindEntry() {
    _operationId =
        widget.operationId ??
        ref.read(workbenchGenerationControllerProvider).generationId;
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(workbenchGenerationControllerProvider);
    final candidate = controller.taskForId(_operationId);
    final task =
        candidate?.purpose == widget.purpose &&
            candidate?.status == WorkbenchGenerationTaskStatus.succeeded
        ? candidate
        : null;
    final result = task?.result;
    return V3PageScaffold(
      title: widget.purpose.resultTitle,
      subtitle: result == null
          ? null
          : '生成时间 ${_formatDateTime(result.generatedAt)}',
      fallbackRoute: AppRoutePaths.workbenchMaterials(widget.purpose.routeName),
      children: [
        if (task != null)
          V3DisclosureTile(
            tilePadding: EdgeInsets.zero,
            title: Text('引用材料（${task.notes.length}）'),
            children: [
              for (final note in task.notes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(note.title),
                  subtitle: Text(note.source.label),
                ),
            ],
          ),
        const SizedBox(height: 14),
        V3Card(
          child: V3AssistantReplyMarkdown(
            source: result?.markdown ?? '这次生成结果已不在当前会话中，不会显示其他任务的内容。',
          ),
        ),
        const SizedBox(height: 18),
        if (task != null)
          V3PrimaryButton(
            label: '重新生成',
            onPressed: () {
              if (controller.status == WorkbenchGenerationStatus.generating) {
                showV3Snack(context, '另一项生成仍在处理中，请稍后再试');
                return;
              }
              unawaited(controller.regenerate(task.id));
              context.pushReplacement(
                Uri(
                  path: AppRoutePaths.workbenchGenerating(
                    widget.purpose.routeName,
                  ),
                  queryParameters: {'operationId': controller.generationId!},
                ).toString(),
              );
            },
          ),
        const SizedBox(height: 10),
        V3OutlineButton(
          label: '返回创作空间',
          onPressed: () {
            ref.read(workbenchGenerationControllerProvider).clearForWorkbench();
            context.go(AppRoutePaths.workbench);
          },
        ),
      ],
    );
  }
}

String _formatDateTime(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
