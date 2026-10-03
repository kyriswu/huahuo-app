import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/native/native_file_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../chat/application/voice_message_controller.dart';
import '../application/digital_twin_controller.dart';
import '../application/digital_twin_material_controller.dart';
import '../application/digital_twin_particle_projection.dart';
import '../domain/digital_twin_material.dart';
import '../data/v3_document_import_store.dart';
import '../domain/digital_twin_models.dart';
import '../domain/digital_twin_operation.dart';
import '../domain/document_change_proposal_models.dart';

part 'v3_digital_twin_materials.dart';
part 'v3_digital_twin_revision.dart';
part 'v3_digital_twin_history.dart';

enum _DigitalTwinView { person, files }

enum _VersionAction { preview, compare, pull, restore }

const _socialPositioningFileId = 'social_positioning';
const _legacyPositioningFileId = 'positioning';

class V3DigitalTwinPage extends ConsumerStatefulWidget {
  const V3DigitalTwinPage({
    this.initialFileId,
    this.focusPositioningReport = false,
    this.taskId,
    this.importTaskId,
    this.materialId,
    super.key,
  });

  final String? initialFileId;
  final bool focusPositioningReport;
  final String? taskId;
  final String? importTaskId;
  final String? materialId;

  @override
  ConsumerState<V3DigitalTwinPage> createState() => _V3DigitalTwinPageState();
}

class _V3DigitalTwinPageState extends ConsumerState<V3DigitalTwinPage>
    with AppActivityRouteAware<V3DigitalTwinPage> {
  final TextEditingController _revisionController = TextEditingController();
  late DigitalTwinController _controller;
  late DigitalTwinMaterialController _materials;
  _DigitalTwinView _view = _DigitalTwinView.person;
  bool _visualActivityActive = true;
  bool _showingFileDetail = false;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(digitalTwinControllerProvider);
    _materials = ref.read(digitalTwinMaterialControllerProvider);
    if (widget.materialId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_showMaterialQueue(focusMaterialId: widget.materialId));
        }
      });
    }
    _materials.setActive(activityRouteCanRun);
    ref.listenManual(digitalTwinMaterialControllerProvider, (_, next) {
      if (identical(_materials, next)) return;
      _materials.setActive(false);
      _materials = next;
      _materials.setActive(activityRouteCanRun);
    });
    _visualActivityActive = activityRouteCanRun;
    _controller.setPollingRouteActive(activityRouteCanRun);
    ref.listenManual<DigitalTwinController>(digitalTwinControllerProvider, (
      _,
      next,
    ) {
      if (identical(_controller, next)) return;
      _controller.setPollingRouteActive(false);
      _controller = next;
      _controller.setPollingRouteActive(activityRouteCanRun);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isPositioningFileId(widget.initialFileId) ||
          widget.focusPositioningReport) {
        unawaited(_openPositioning());
      } else {
        unawaited(_loadInitialSurface());
      }
    });
  }

  @override
  void dispose() {
    _materials.setActive(false);
    _controller.setPollingRouteActive(false);
    _revisionController.dispose();
    super.dispose();
  }

  @override
  void onActivityRouteBecameActive() {
    _materials.setActive(true);
    _controller.setPollingRouteActive(true);
    _setVisualActivityActive(true);
  }

  @override
  void onActivityRouteBecameInactive() {
    _materials.setActive(false);
    _controller.setPollingRouteActive(false);
    _setVisualActivityActive(false);
  }

  void _setVisualActivityActive(bool active) {
    if (_visualActivityActive == active) return;
    setState(() => _visualActivityActive = active);
  }

  Future<void> _loadInitialSurface() async {
    final source = _materialSources()
        .where((source) => source.importTaskId == widget.importTaskId)
        .firstOrNull;
    final checkpoint = ref.read(digitalTwinMaterialStoreProvider);
    final pendingConfirmation =
        checkpoint.pendingConfirmationId ?? source?.confirmationTaskId;
    final restoreCheckpoint =
        checkpoint.pendingConfirmationId != null &&
        source?.confirmationTaskId != checkpoint.pendingConfirmationId;
    await _controller.load(
      importSource: restoreCheckpoint ? null : source,
      confirmationTaskId: pendingConfirmation,
      reviewProposalIds:
          (source == null || restoreCheckpoint) && pendingConfirmation != null
          ? checkpoint.pendingProposalIds
          : null,
    );
    if (mounted &&
        widget.initialFileId != null &&
        !_isPositioningFileId(widget.initialFileId)) {
      _view = _DigitalTwinView.files;
      await _selectFileForPresentation(widget.initialFileId!);
    }
  }

  Future<void> _selectFileForPresentation(String fileId) async {
    if (_isPositioningFileId(fileId)) {
      await _openPositioning();
      return;
    }
    await _controller.selectFile(fileId);
    if (mounted) setState(() => _showingFileDetail = true);
  }

  Future<void> _openPositioning() async {
    await context.push(
      widget.taskId == null
          ? AppRoutePaths.positioningReport
          : AppRoutePaths.positioningReportForTask(widget.taskId!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(digitalTwinControllerProvider);
    final state = controller.state;
    final compact = MediaQuery.sizeOf(context).width < 720;
    if (compact) {
      return _buildCompact(context, controller, state);
    }
    return V3PageScaffold(
      title: '数字孪生',
      subtitle: state.current == null
          ? null
          : '${state.current!.currentVersion?.label ?? 'v0'} · ${_statusLabel(state.current!.state)}',
      fallbackRoute: AppRoutePaths.home,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            key: const ValueKey('digital-twin-import-material'),
            onPressed: state.isBusy
                ? null
                : () => context.push(
                    '${AppRoutePaths.documentImport}?entry=fresh&digitalTwin=1',
                  ),
            icon: const Icon(Icons.note_add_outlined),
            label: const Text('导入材料'),
          ),
          TextButton(
            onPressed: state.isBusy ? null : _showMaterialQueue,
            child: const Text('材料记录'),
          ),
          IconButton(
            key: const ValueKey('digital-twin-info'),
            tooltip: '什么是数字孪生',
            onPressed: _showInfo,
            icon: const Icon(Icons.info_outline_rounded),
          ),
          IconButton(
            key: const ValueKey('digital-twin-refresh'),
            tooltip: '刷新',
            onPressed: state.isBusy ? null : controller.load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      children: [
        TextButton(onPressed: _openPositioning, child: const Text('查看定位报告')),
        _materialQueueButton(),
        if (controller.importSource != null)
          _materialActions(controller, mutationLocked: state.isBusy),
        _ModeControl(
          value: _view,
          onChanged: (value) => setState(() {
            _view = value;
          }),
        ),
        const SizedBox(height: 16),
        if (state.current == null &&
            state.phase == DigitalTwinControllerPhase.loading)
          const _InitialLoading()
        else if (state.current == null)
          _LoadFailure(onRetry: controller.load)
        else ...[
          if (_view == _DigitalTwinView.person)
            TickerMode(
              enabled: _visualActivityActive,
              child: _PersonView(
                state: state,
                onOpenPositioning: _openPositioning,

                onOpenChat: () => context.push(
                  '/v3/feed/chat?agentProfileId=$digitalTwinAgentProfileId',
                ),
              ),
            )
          else
            _FilesView(state: state, onSelect: _selectFileForPresentation),
          if (state.errorCode != null) ...[
            const SizedBox(height: 14),
            _InlineError(onRetry: controller.load),
          ],
          if (state.reviews.isNotEmpty) ...[
            const SizedBox(height: 22),
            _ProposalReviewSection(
              state: state,
              mutationLocked: state.isBusy,
              revisionController: _revisionController,
              onSelectProposal: controller.selectProposal,
              onToggleHunk: controller.toggleHunk,
              onInspectVersion: controller.inspectProposalVersion,
              onRevise: () => _revise(controller),
              onReject: () => _rejectCandidate(controller),
              onRegenerate: () => _regenerateCandidate(controller),
              onConfirm: () => _confirm(controller),
            ),
          ],
          if (state.confirmation != null) ...[
            const SizedBox(height: 16),
            _ConfirmationReport(confirmation: state.confirmation!),
          ],
          const SizedBox(height: 22),
          _VersionHistory(
            state: state,
            onPreview: (version) => _previewVersion(controller, version),
            onCompare: (version) => _compareVersion(controller, version),
            onPull: (version) => _pullVersion(controller, version),
            onRestore: (version) => _restoreVersion(controller, version),
          ),
          const SizedBox(height: 22),
          _ScheduleSection(
            schedule: state.schedule,
            saving: state.phase == DigitalTwinControllerPhase.savingSchedule,
            onEdit: () => _editSchedule(controller),
          ),
        ],
      ],
    );
  }

  Widget _buildCompact(
    BuildContext context,
    DigitalTwinController controller,
    DigitalTwinControllerState state,
  ) {
    const background = Color(0xFF07060B);
    return Theme(
      data: _twinTheme(context),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: background,
          systemNavigationBarColor: background,
        ),
        child: Scaffold(
          backgroundColor: background,
          body: SafeArea(
            child: Column(
              children: [
                _CompactDigitalTwinHeader(
                  view: _view,
                  fileDetail: _showingFileDetail,
                  detailTitle: '文件详情',
                  onBack: () {
                    if (_showingFileDetail) {
                      setState(() {
                        _showingFileDetail = false;
                      });
                      return;
                    }
                    unawaited(
                      returnToPreviousRoute(
                        context,
                        fallbackRoute: AppRoutePaths.home,
                      ),
                    );
                  },
                  onViewChanged: (value) => setState(() {
                    _view = value;
                    _showingFileDetail = false;
                  }),
                  onInfo: _showInfo,
                  onHistory: () => _showHistory(controller, state),
                ),
                Expanded(
                  child: state.current == null
                      ? state.phase == DigitalTwinControllerPhase.loading
                            ? const _CompactInitialLoading()
                            : _CompactLoadFailure(onRetry: controller.load)
                      : _showingFileDetail && state.selectedFile != null
                      ? KeyedSubtree(
                          key: ValueKey(state.selectedFile!.id),
                          child: _CompactFileDetail(
                            state: state,

                            onOpenRevision: () => _showRevisionSheet(
                              controller,
                              expanded: true,
                              mutationLocked: state.isBusy,
                            ),
                          ),
                        )
                      : _view == _DigitalTwinView.person
                      ? _CompactPersonView(
                          state: state,
                          visualActivityActive: _visualActivityActive,
                          revisionBusy: state.isBusy,
                          onOpenRevision: () => _showRevisionSheet(
                            controller,
                            mutationLocked: state.isBusy,
                          ),
                        )
                      : _CompactFilesView(
                          state: state,
                          onSelect: _selectFileForPresentation,
                        ),
                ),
                TextButton(
                  onPressed: _openPositioning,
                  child: const Text('查看定位报告'),
                ),
                if (!_showingFileDetail) _materialQueueButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<DigitalTwinImportSource> _materialSources() => [
    for (final task in ref.read(v3DocumentImportStoreProvider).listTasks())
      if (task.distillToDigitalTwin &&
          task.distillationTaskId != null &&
          task.distillationResourceId != null &&
          task.remoteNoteId != null)
        DigitalTwinImportSource(
          importTaskId: task.id,
          taskId: task.distillationTaskId!,
          resourceId: task.distillationResourceId!,
          noteId: task.remoteNoteId!,
          title: task.displayName,
          confirmationTaskId: task.digitalTwinConfirmationId,
        ),
  ];

  Future<void> _showMaterials() async {
    final tasks = ref
        .read(v3DocumentImportStoreProvider)
        .listTasks()
        .where((task) => task.acceptedForImport && task.distillToDigitalTwin)
        .toList(growable: false);
    final selected = await showV3GlassBottomSheet<V3DocumentImportTask>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('数字孪生材料'),
              subtitle: Text('逐份查看导入、候选和确认报告；未完成任务可继续查询'),
            ),
            if (tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('尚未导入数字孪生材料。请从文件导入会议纪要或内容复盘。'),
              ),
            for (final task in tasks)
              ListTile(
                key: ValueKey('digital-twin-material-${task.id}'),
                title: Text(task.displayName),
                subtitle: Text(
                  task.remoteNoteId == null
                      ? task.hasRemoteCheckpoint
                            ? '材料已上传，继续核验导入进度'
                            : '导入尚未完成'
                      : task.digitalTwinConfirmationId == null
                      ? '查看候选与来源'
                      : '查看确认报告与候选',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, task),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected.remoteNoteId == null ||
        selected.distillationTaskId == null ||
        selected.distillationResourceId == null) {
      await context.push(
        Uri(
          path: AppRoutePaths.documentImport,
          queryParameters: {'taskId': selected.id},
        ).toString(),
      );
      return;
    }
    _revisionController.clear();
    await _controller.load(
      importSource: DigitalTwinImportSource(
        importTaskId: selected.id,
        taskId: selected.distillationTaskId!,
        resourceId: selected.distillationResourceId!,
        noteId: selected.remoteNoteId!,
        title: selected.displayName,
        confirmationTaskId: selected.digitalTwinConfirmationId,
      ),
    );
  }

  Widget _materialActions(
    DigitalTwinController controller, {
    required bool mutationLocked,
  }) {
    final source = controller.importSource;
    final task = controller.distillationTask;
    final state = controller.state;
    final unchanged = state.reviews
        .where(
          (review) =>
              review.snapshot.proposal.state == DocumentProposalState.ready &&
              review.snapshot.proposal.hasChanges == false,
        )
        .length;
    final confirmationPending =
        state.confirmation != null && !state.confirmation!.isTerminal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                key: const ValueKey('digital-twin-import-material'),
                onPressed: state.isBusy
                    ? null
                    : () => context.push(
                        '${AppRoutePaths.documentImport}?entry=fresh&digitalTwin=1',
                      ),
                icon: const Icon(Icons.note_add_outlined, size: 18),
                label: const Text('导入材料'),
              ),
              TextButton(
                key: const ValueKey('digital-twin-materials'),
                onPressed: state.isBusy ? null : _showMaterialQueue,
                child: const Text('材料记录'),
              ),
              IconButton(
                tooltip: '与数字孪生对话',
                onPressed: () => context.push(
                  '/v3/feed/chat?agentProfileId=$digitalTwinAgentProfileId',
                ),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
              ),
            ],
          ),
          if (source != null || controller.hasIndependentReview) ...[
            Text(
              source?.title ?? '独立候选审核（历史恢复 / 重新生成）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB8B4C9), fontSize: 12),
            ),
            Text(
              task?.isFailed == true
                  ? state.reviews.isEmpty
                        ? '源材料处理失败：${task?.failureCode ?? task?.status}。请更换材料重新导入；刷新仅核验原任务。'
                        : '原蒸馏任务失败，已有 ${state.reviews.length} 项候选可继续审核或重新生成。'
                  : controller.importWaiting
                  ? '材料已保存，正在生成候选；确认后才会更新正式数字孪生。'
                  : state.errorCode == 'DIGITAL_TWIN_PROJECTION_PENDING'
                  ? '确认报告已返回，正式版本仍在同步，请稍后刷新核验。'
                  : state.errorCode != null
                  ? '进度暂未核验，请刷新重试；材料不会重复上传。'
                  : '${state.readyProposalCount} 项可确认 · $unchanged 项无变化',
              style: const TextStyle(color: Color(0xFFB8B4C9), fontSize: 12),
            ),
            Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: state.isBusy ? null : controller.load,
                  child: const Text('刷新进度'),
                ),
                TextButton(
                  key: const ValueKey('digital-twin-material-review'),
                  onPressed: state.reviews.isEmpty || state.isBusy
                      ? null
                      : () => _showRevisionSheet(
                          controller,
                          expanded: true,
                          mutationLocked: mutationLocked,
                        ),
                  child: const Text('审核候选'),
                ),
                if (unchanged > 0)
                  TextButton(
                    onPressed: state.isBusy || mutationLocked
                        ? null
                        : () async {
                            final accepted = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('忽略无变化候选？'),
                                content: Text(
                                  '仅关闭当前审核范围的 $unchanged 项无变化提案，不修改正式文件。',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('取消'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('忽略'),
                                  ),
                                ],
                              ),
                            );
                            if (accepted == true && mounted) {
                              await controller.rejectUnchanged();
                            }
                          },
                    child: const Text('忽略无变化'),
                  ),
                if (confirmationPending)
                  TextButton(
                    onPressed: state.isBusy ? null : () => _confirm(controller),
                    child: const Text('继续核验确认'),
                  ),
                TextButton(
                  onPressed: state.isBusy
                      ? null
                      : () => controller.load(importSource: null),
                  child: const Text('查看全部'),
                ),
              ],
            ),
            if (state.confirmation != null)
              _ConfirmationReport(confirmation: state.confirmation!),
          ],
        ],
      ),
    );
  }

  Future<void> _showHistory(
    DigitalTwinController controller,
    DigitalTwinControllerState state,
  ) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _TwinHistoryPage(
        controller: controller,
        onOpen: (version) => _openHistoryVersion(controller, version),
      ),
    ),
  );

  Future<void> _openHistoryVersion(
    DigitalTwinController controller,
    DigitalTwinVersion version,
  ) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _TwinHistoryDetail(
        controller: controller,
        version: version,
        onPull: () => _pullVersion(controller, version),
        onRestore: () => _restoreVersion(controller, version),
      ),
    ),
  );

  Future<void> _showRevisionSheet(
    DigitalTwinController controller, {
    bool expanded = false,
    bool preserveScope = false,
    required bool mutationLocked,
  }) async {
    if (!preserveScope &&
        widget.importTaskId == null &&
        (controller.hasIndependentReview || controller.importSource != null)) {
      if (!await controller.openOverview()) {
        if (mounted) _message('先核验上次操作，已保留原候选和修订记录');
        return;
      }
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .56),
      builder: (_) => _CompactRevisionSheet(
        controller: controller,
        mutationLocked: mutationLocked,
        revisionController: _revisionController,
        expanded: expanded,
        onRevise: () => _revise(controller),
        onReject: () => _rejectCandidate(controller),
        onRegenerate: () => _regenerateCandidate(controller),
        onConfirm: () => _confirm(controller),
        onReport: (version) => _openHistoryVersion(controller, version),
      ),
    );
    if (mounted &&
        widget.importTaskId == null &&
        controller.hasIndependentReview &&
        !controller.state.isBusy &&
        !controller.hasUnresolvedMutation) {
      await controller.openOverview();
    }
  }

  Future<void> _rejectCandidate(DigitalTwinController controller) async {
    final snapshot = controller.state.selectedReview?.snapshot;
    if (snapshot == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '不采用此候选？',
        message: '仅关闭当前候选，不修改正式数字孪生，也不会拒绝其他候选。',
        primaryLabel: '不采用',
        onPrimary: () => Navigator.pop(dialogContext, true),
        onCancel: () => Navigator.pop(dialogContext, false),
      ),
    );
    if (accepted != true || !mounted) return;
    final ok = await controller.rejectSelectedProposal(selection: snapshot);
    if (mounted) _message(ok ? '已关闭此候选，正式内容未改变' : '候选未关闭，请刷新后重试');
  }

  Future<void> _regenerateCandidate(DigitalTwinController controller) async {
    final snapshot = controller.state.selectedReview?.snapshot;
    if (snapshot == null) return;
    final instruction = _revisionController.text.trim();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '重新生成候选？',
        message:
            '根据原始来源重新生成，仅产生待审核候选，不直接修改正式文件。'
            '${instruction.isEmpty ? '' : '\n补充要求：$instruction'}',
        primaryLabel: '重新生成',
        onPrimary: () => Navigator.pop(dialogContext, true),
        onCancel: () => Navigator.pop(dialogContext, false),
      ),
    );
    if (accepted != true || !mounted) return;
    final ok = await controller.regenerateSelected(
      instruction,
      selection: snapshot,
    );
    if (!mounted) return;
    final code = controller.state.errorCode;
    _message(
      ok
          ? '新候选已提交，请等待生成并重新审核'
          : code == 'DIGITAL_TWIN_REBUILD_BASE_UNAVAILABLE' ||
                code == 'DOCUMENT_BASE_REVISION_STALE'
          ? '正式内容已变化，暂无法取得可重建的版本。可先不采用旧候选，再导入补充材料。'
          : '重新生成未完成，请刷新后重试',
    );
  }

  Future<void> _revise(DigitalTwinController controller) async {
    final instruction = _revisionController.text.trim();
    if (instruction.isEmpty) {
      _message('请输入修订内容');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final ok = await controller.reviseSelected(instruction);
    if (!mounted) return;
    if (ok && _revisionController.text.trim() == instruction) {
      _revisionController.clear();
    }
    _message(
      ok
          ? '修订版本已生成'
          : controller.hasPendingEdits
          ? '修改要求已保存，请继续核验上次修改'
          : '请查看当前候选与修订记录，核验本次处理结果',
    );
  }

  Future<void> _showInfo() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF17141D),
    barrierColor: Colors.black.withValues(alpha: .68),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _CompactSheetHeader(title: '什么是数字孪生'),
            const SizedBox(height: 20),
            Flexible(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.manual,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '数字孪生由你的经历、知识、观点、表达习惯和方法持续构成。新信息会先形成可审阅的差分，只有确认后才进入正式版本。定位报告独立维护，不参与这里的版本确认。',
                      style: TextStyle(
                        color: Color(0xFFC1BAC8),
                        fontSize: 14,
                        height: 1.65,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _materialActions(_controller, mutationLocked: false),
                    TextButton(
                      onPressed: () => _editSchedule(_controller),
                      child: const Text('自动蒸馏设置'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF30243F),
                  foregroundColor: const Color(0xFFF7F1FF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('知道了'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _confirm(DigitalTwinController controller) async {
    final selection = controller.captureConfirmationSelection();
    if (selection == null) {
      _message('请先返回当前候选版本并完成审核');
      return;
    }
    final ok = await controller.confirmReady(selection: selection);
    if (mounted) _message(ok ? '正式版本已更新' : '确认未完成，请查看报告');
  }

  Future<void> _previewVersion(
    DigitalTwinController controller,
    DigitalTwinVersion version,
  ) async {
    if (!await controller.inspectVersion(version.versionId) || !mounted) return;
    await _showVersionSheet();
  }

  Future<void> _compareVersion(
    DigitalTwinController controller,
    DigitalTwinVersion version,
  ) async {
    if (!await controller.compareVersion(version.versionId) || !mounted) {
      if (mounted) _message('首个版本没有可比较的前序版本');
      return;
    }
    await _showVersionSheet();
  }

  Future<void> _showVersionSheet() => showV3GlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const FractionallySizedBox(
      heightFactor: .82,
      child: _VersionInspectionSheet(),
    ),
  );

  Future<void> _pullVersion(
    DigitalTwinController controller,
    DigitalTwinVersion version,
  ) async {
    final ok = await controller.pullVersion(
      version.versionId,
      export: (bytes) async {
        final service = ref.read(knowledgeDocumentExportServiceProvider);
        final result = await service.prepareArchive(
          title: 'digital-twin-${version.label}',
          bytes: bytes,
        );
        final prepared = result.value;
        if (!result.ok || prepared == null) return false;
        final opened = await ref
            .read(nativePreparedDocumentExportPortProvider)
            .openPreparedKnowledgeExport(
              opaqueExportRef: prepared.opaqueExportRef,
              displayName: prepared.displayName,
              mimeType: prepared.mimeType,
            );
        if (!opened.ok || opened.value != true) {
          await service.discard(prepared);
          return false;
        }
        return true;
      },
    );
    if (!mounted) return;
    final bytes = controller.state.archiveSizeBytes;
    _message(
      ok && bytes != null ? '已打开系统保存方式 · ${_byteLabel(bytes)}' : '版本拉取失败',
    );
  }

  Future<void> _restoreVersion(
    DigitalTwinController controller,
    DigitalTwinVersion version,
  ) async {
    if (!controller.canRestoreVersion) {
      _message('请先完成或核验当前确认、修订及恢复操作');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '基于 ${version.label} 恢复？',
        message: '系统会生成新的待提交提案，当前正式版本和历史版本都不会被直接改写。',
        primaryLabel: '生成提案',
        onPrimary: () => Navigator.pop(dialogContext, true),
        onCancel: () => Navigator.pop(dialogContext, false),
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!controller.canRestoreVersion) {
      _message('当前操作尚未完成，请核验后再恢复');
      return;
    }
    final ok = await controller.restoreVersion(version.versionId);
    if (!mounted) return;
    final partial =
        controller.state.errorCode == 'DIGITAL_TWIN_RESTORE_PARTIAL' &&
        controller.lastRestore?.versionId == version.versionId &&
        (controller.lastRestore?.proposalIds.isNotEmpty ?? false);
    _message(
      ok
          ? '恢复候选已生成，审核确认后才会修改正式版本'
          : partial
          ? '部分恢复失败，已生成的候选已保留，请逐项审核'
          : controller.state.errorCode == 'DIGITAL_TWIN_RESTORE_NO_CANDIDATES'
          ? '所选版本没有可生成的恢复候选，正式内容未改变'
          : '恢复未完成，请刷新核验；原请求和已返回的候选已保留',
    );
    if (ok || partial) {
      await _showRevisionSheet(
        controller,
        preserveScope: true,
        mutationLocked: false,
      );
    }
  }

  Future<void> _editSchedule(DigitalTwinController controller) async {
    final schedule = controller.state.schedule;
    if (schedule == null) return;
    var enabled = schedule.enabled;
    final days = TextEditingController(text: '${schedule.intervalDays}');
    final time = TextEditingController(text: schedule.preferredLocalTime);
    final instruction = TextEditingController(text: schedule.instruction);
    try {
      final draft = await showDialog<DigitalTwinScheduleDraft>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => V3GlassDialogFrame(
            title: '周期维护',
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用周期维护'),
                    value: enabled,
                    onChanged: (value) => setDialogState(() => enabled = value),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('digital-twin-schedule-days'),
                    controller: days,
                    contextMenuBuilder: V3TextEditing.buildContextMenu,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '间隔天数',
                      prefixIcon: Icon(Icons.calendar_today_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: time,
                    contextMenuBuilder: V3TextEditing.buildContextMenu,
                    decoration: const InputDecoration(
                      labelText: '执行时间',
                      prefixIcon: Icon(Icons.schedule_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('digital-twin-schedule-instruction'),
                    controller: instruction,
                    contextMenuBuilder: V3TextEditing.buildContextMenu,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '维护提示词',
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: () {
                  final interval = int.tryParse(days.text.trim());
                  if (interval == null || interval < 1 || interval > 365) {
                    return;
                  }
                  Navigator.pop(
                    dialogContext,
                    DigitalTwinScheduleDraft(
                      enabled: enabled,
                      intervalDays: interval,
                      preferredLocalTime: time.text,
                      timezone: schedule.timezone,
                      instruction: instruction.text,
                    ),
                  );
                },
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (draft == null) return;
      final ok = await controller.saveSchedule(draft);
      if (mounted) _message(ok ? '周期设置已保存' : '周期设置保存失败');
    } finally {
      days.dispose();
      time.dispose();
      instruction.dispose();
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: _twinRail,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          content: Text(value, style: _twinText(12)),
        ),
      );
  }
}

const _compactTwinSurface = Color(0xFF17141D);
const _compactTwinSelected = Color(0xFF332A45);
const _compactTwinStrong = Color(0xFFF4F0FA);
const _compactTwinText = Color(0xFFC1BAC8);
const _compactTwinMuted = Color(0xFF7E7888);
const _compactTwinAccent = Color(0xFFC8A7FF);
const _compactTwinWarm = Color(0xFFFF9B89);

class _CompactDigitalTwinHeader extends StatelessWidget {
  const _CompactDigitalTwinHeader({
    required this.view,
    required this.fileDetail,
    required this.detailTitle,
    required this.onBack,
    required this.onViewChanged,
    required this.onInfo,
    required this.onHistory,
  });

  final _DigitalTwinView view;
  final bool fileDetail;
  final String detailTitle;
  final VoidCallback onBack;
  final ValueChanged<_DigitalTwinView> onViewChanged;
  final VoidCallback onInfo;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('digital-twin-compact-header'),
    width: double.infinity,
    height: 54,
    child: Stack(
      alignment: Alignment.center,
      children: [
        if (fileDetail)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 64),
            child: Text(
              detailTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: _twinText(17, weight: FontWeight.w500),
            ),
          )
        else
          _CompactViewSwitch(value: view, onChanged: onViewChanged),
        Positioned(
          left: 9,
          child: IconButton(
            key: const ValueKey('digital-twin-back'),
            tooltip: '返回',
            onPressed: onBack,
            icon: const Icon(
              Icons.arrow_back_rounded,
              size: 22,
              color: _compactTwinStrong,
            ),
          ),
        ),
        if (!fileDetail && view == _DigitalTwinView.person)
          Positioned(
            right: 53,
            child: _CompactIconButton(
              key: const ValueKey('digital-twin-info'),
              tooltip: '什么是数字孪生',
              icon: Icons.info_outline_rounded,
              onPressed: onInfo,
              color: _compactTwinStrong,
            ),
          ),
        Positioned(
          right: 9,
          child: _CompactIconButton(
            key: const ValueKey('digital-twin-history'),
            tooltip: '修订记录',
            icon: fileDetail && detailTitle != '社媒定位'
                ? Icons.more_horiz_rounded
                : Icons.history_rounded,
            onPressed: onHistory,
          ),
        ),
      ],
    ),
  );
}

class _CompactViewSwitch extends StatelessWidget {
  const _CompactViewSwitch({required this.value, required this.onChanged});

  final _DigitalTwinView value;
  final ValueChanged<_DigitalTwinView> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('digital-twin-view-switch'),
      width: math.min(176, MediaQuery.sizeOf(context).width - 196),
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _compactTwinSurface,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          for (final item in _DigitalTwinView.values)
            Expanded(
              child: Material(
                color: item == value
                    ? _compactTwinSelected
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  key: ValueKey('digital-twin-mode-${item.name}'),
                  onTap: item == value ? null : () => onChanged(item),
                  borderRadius: BorderRadius.circular(14),
                  child: Center(
                    child: Text(
                      item == _DigitalTwinView.person ? '数字孪生' : '文件',
                      style: TextStyle(
                        color: item == value
                            ? const Color(0xFFF8F4FF)
                            : const Color(0xFF8F899A),
                        fontSize: 13,
                        fontWeight: item == value
                            ? FontWeight.w500
                            : FontWeight.w400,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CompactIconButton extends StatelessWidget {
  const _CompactIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color = const Color(0xFFAAA3B2),
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 22, color: color),
    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    padding: EdgeInsets.zero,
  );
}

class _CompactPersonView extends StatelessWidget {
  const _CompactPersonView({
    required this.state,
    required this.visualActivityActive,
    required this.revisionBusy,
    required this.onOpenRevision,
  });

  final DigitalTwinControllerState state;
  final bool visualActivityActive;
  final bool revisionBusy;
  final VoidCallback onOpenRevision;

  @override
  Widget build(BuildContext context) {
    final current = state.current!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
      child: Column(
        children: [
          Expanded(
            child: TickerMode(
              enabled: visualActivityActive,
              child: _ParticlePerson(current: current),
            ),
          ),
          if (current.pendingReviewCount > 0)
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                key: const ValueKey('digital-twin-open-revision'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF30243F),
                  foregroundColor: const Color(0xFFF7F1FF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                onPressed: revisionBusy ? null : onOpenRevision,
                child: Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome_rounded,
                      size: 20,
                      color: _compactTwinWarm,
                    ),
                    Expanded(
                      child: Text(
                        '${current.pendingReviewCount} 项更新待确认',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      size: 19,
                      color: Color(0xFFD8C4FF),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CompactFilesView extends StatelessWidget {
  const _CompactFilesView({required this.state, required this.onSelect});

  final DigitalTwinControllerState state;
  final Future<void> Function(String) onSelect;

  @override
  Widget build(BuildContext context) {
    final files = state.current!.files;
    return ListView(
      key: const ValueKey('digital-twin-compact-files'),
      padding: const EdgeInsets.fromLTRB(14, 19, 14, 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '构成文件',
                  style: TextStyle(
                    color: _compactTwinStrong,
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
              ),
              Text(
                '${files.length} 个文件',
                style: const TextStyle(
                  color: _compactTwinMuted,
                  fontSize: 12,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 13),
        for (final file in files)
          _CompactFileRow(
            file: file,
            updatedAt: state.current!.updatedAt,
            onTap: () => unawaited(onSelect(file.id)),
          ),
      ],
    );
  }
}

class _CompactFileRow extends StatelessWidget {
  const _CompactFileRow({
    required this.file,
    required this.updatedAt,
    required this.onTap,
  });

  final DigitalTwinLogicalFile file;
  final DateTime updatedAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pending = file.pendingCount > 0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('digital-twin-file-${file.id}'),
        onTap: onTap,
        child: SizedBox(
          height: 92,
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Icon(
                  _fileIcon(file.id),
                  size: 20,
                  color: pending ? _compactTwinAccent : const Color(0xFF82798E),
                ),
              ),
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF24212B)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              file.name.replaceFirst(RegExp(r'\\.md$'), ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _compactTwinStrong,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              pending
                                  ? '${file.pendingCount} 项修改待确认'
                                  : '最近更新 ${_compactDate(updatedAt)}',
                              style: TextStyle(
                                color: pending
                                    ? const Color(0xFFB8A4CF)
                                    : _compactTwinMuted,
                                fontSize: 12,
                                letterSpacing: 0,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (pending)
                        Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _compactTwinSelected,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            '${file.pendingCount}',
                            style: const TextStyle(
                              color: Color(0xFFE8DDFF),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: Color(0xFF6E6877),
                      ),
                      const SizedBox(width: 5),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactFileDetail extends StatelessWidget {
  const _CompactFileDetail({required this.state, required this.onOpenRevision});

  final DigitalTwinControllerState state;

  final VoidCallback onOpenRevision;

  @override
  Widget build(BuildContext context) {
    final file = state.selectedFile!;
    final review = state.selectedReview;
    final changes = review?.diff ?? const <DocumentProposalDiffHunk>[];
    return Column(
      key: const ValueKey('digital-twin-compact-file-detail'),
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 13, 22, 28),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      file.name.endsWith('.md') ? file.name : '${file.name}.md',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _compactTwinStrong,
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                file.pendingCount > 0
                    ? '${file.pendingCount} 项修改待确认'
                    : '当前文件没有待确认修改',
                style: TextStyle(
                  color: file.pendingCount > 0
                      ? _compactTwinWarm
                      : _compactTwinMuted,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 14),
              const Divider(color: Color(0xFF24212B), height: 1),
              const SizedBox(height: 16),
              if (review?.loadingDetails == true)
                const Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: Center(
                    child: CircularProgressIndicator(color: _compactTwinAccent),
                  ),
                )
              else if (changes.isNotEmpty)
                for (var index = 0; index < changes.length; index++)
                  _CompactDiffItem(index: index, hunk: changes[index])
              else
                SelectionArea(
                  contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
                  child: V3AssistantReplyMarkdown(
                    source: file.markdown.trim().isEmpty
                        ? '尚未沉淀内容'
                        : file.markdown,
                  ),
                ),
            ],
          ),
        ),
        if (file.pendingCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                key: const ValueKey('digital-twin-discuss-revision'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF30243F),
                  foregroundColor: const Color(0xFFF7F1FF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: state.isBusy ? null : onOpenRevision,
                icon: Icon(
                  Icons.forum_outlined,
                  size: 20,
                  color: state.isBusy ? _compactTwinMuted : _compactTwinAccent,
                ),
                label: const Text('在修订中讨论'),
              ),
            ),
          ),
      ],
    );
  }
}

class _CompactDiffItem extends StatelessWidget {
  const _CompactDiffItem({required this.index, required this.hunk});

  final int index;
  final DocumentProposalDiffHunk hunk;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(bottom: 20, top: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF24212B))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '第 ${index + 1} 项修改',
                  style: const TextStyle(
                    color: _compactTwinStrong,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                hunk.changes.any((change) => change.op == 'insert')
                    ? '新增'
                    : '删除',
                style: const TextStyle(
                  color: _compactTwinWarm,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final change in hunk.changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: SelectableText(
                '${change.op == 'insert' ? '+' : '-'} ${change.text}',
                contextMenuBuilder: V3TextEditing.buildContextMenu,
                style: const TextStyle(
                  color: Color(0xFFE8E2EE),
                  fontSize: 13,
                  height: 1.55,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CompactSheetHeader extends StatelessWidget {
  const _CompactSheetHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            color: _compactTwinStrong,
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      _CompactIconButton(
        tooltip: '关闭',
        icon: Icons.close_rounded,
        onPressed: () => Navigator.pop(context),
        color: const Color(0xFFDAD4E0),
      ),
    ],
  );
}

class _CompactInitialLoading extends StatelessWidget {
  const _CompactInitialLoading();

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator(color: _compactTwinAccent));
}

class _CompactLoadFailure extends StatelessWidget {
  const _CompactLoadFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('数字孪生暂时无法加载', style: TextStyle(color: _compactTwinText)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重新加载'),
        ),
      ],
    ),
  );
}

String _compactDate(DateTime value) => '${value.month} 月 ${value.day} 日';

class _ModeControl extends StatelessWidget {
  const _ModeControl({required this.value, required this.onChanged});

  final _DigitalTwinView value;
  final ValueChanged<_DigitalTwinView> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: SegmentedButton<_DigitalTwinView>(
      segments: const [
        ButtonSegment(
          value: _DigitalTwinView.person,
          icon: Icon(Icons.person_outline_rounded),
          label: Text('数字人'),
        ),
        ButtonSegment(
          value: _DigitalTwinView.files,
          icon: Icon(Icons.folder_copy_outlined),
          label: Text('文件'),
        ),
      ],
      selected: <_DigitalTwinView>{value},
      onSelectionChanged: (values) => onChanged(values.first),
    ),
  );
}

class _InitialLoading extends StatelessWidget {
  const _InitialLoading();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 420,
    child: Center(child: CircularProgressIndicator()),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.onRetry});

  final Future<bool> Function() onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 360,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 34),
          const SizedBox(height: 10),
          const Text('数字孪生暂时无法加载'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}

class _PersonView extends StatelessWidget {
  const _PersonView({
    required this.state,

    required this.onOpenChat,
    required this.onOpenPositioning,
  });

  final DigitalTwinControllerState state;

  final VoidCallback onOpenChat;
  final VoidCallback onOpenPositioning;

  @override
  Widget build(BuildContext context) {
    final current = state.current!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final visual = _ParticlePerson(current: current);
        final summary = _TwinSummary(
          current: current,

          onOpenChat: onOpenChat,
          onOpenPositioning: onOpenPositioning,
        );
        if (constraints.maxWidth < 720) {
          return Column(
            children: [visual, const SizedBox(height: 10), summary],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: visual),
            const SizedBox(width: 28),
            Expanded(child: summary),
          ],
        );
      },
    );
  }
}

class _ParticlePerson extends StatefulWidget {
  const _ParticlePerson({required this.current});

  final DigitalTwinCurrent current;

  @override
  State<_ParticlePerson> createState() => _ParticlePersonState();
}

class _ParticlePersonState extends State<_ParticlePerson>
    with TickerProviderStateMixin {
  static const _initialYaw = -.18;
  static const _initialPitch = -.04;

  late final AnimationController _pulse;
  late final AnimationController _merge;
  late final Listenable _particleRepaint;
  final _projection = DigitalTwinParticleProjection();
  double _mergeFraction = 0;
  final _tickerMetrics = RuntimeTickerMetricsLease('digital_twin_pulse');
  double _yaw = _initialYaw;
  double _pitch = _initialPitch;
  double _zoom = 1;
  double _gestureStartZoom = 1;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: V3MotionTokens.ambientLoop,
    );
    _merge = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      value: 1,
    );
    _particleRepaint = Listenable.merge([_pulse, _merge]);
  }

  @override
  void didUpdateWidget(covariant _ParticlePerson oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.current;
    final current = widget.current;
    if (current.currentVersion != null &&
        current.currentVersion!.versionId !=
            previous.currentVersion?.versionId &&
        previous.pendingReviewCount > current.pendingReviewCount) {
      _mergeFraction =
          (previous.pendingReviewCount - current.pendingReviewCount) /
          previous.pendingReviewCount;
      if (!MediaQuery.disableAnimationsOf(context)) {
        _merge.value = 0;
        if (TickerMode.valuesOf(context).enabled) _merge.forward();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shouldAnimate =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldAnimate && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldAnimate && _pulse.isAnimating) {
      _pulse.stop(canceled: false);
    }
    if (shouldAnimate && _merge.value < 1 && !_merge.isAnimating) {
      _merge.forward();
    } else if (!shouldAnimate && _merge.isAnimating) {
      _merge.stop(canceled: false);
    }
    if (MediaQuery.disableAnimationsOf(context)) _merge.value = 1;
    _tickerMetrics.sync(context, active: shouldAnimate);
  }

  @override
  void dispose() {
    _tickerMetrics.dispose();
    _pulse.dispose();
    _merge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.current.pendingReviewCount > 0;
    final completionOpacity =
        (.55 + widget.current.level.completionPercent / 225).clamp(0, 1);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 620),
        child: AspectRatio(
          aspectRatio: 360 / 620,
          child: Semantics(
            key: const ValueKey('digital-twin-interactive-viewer'),
            label: '数字孪生三维粒子人',
            hint: '单指拖动旋转，双指缩放，双击恢复默认视角',
            value:
                '水平 ${(_yaw * 180 / math.pi).round()} 度，'
                '垂直 ${(_pitch * 180 / math.pi).round()} 度，'
                '缩放 ${(_zoom * 100).round()}%',
            child: GestureDetector(
              key: const ValueKey('digital-twin-orbit-surface'),
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _resetView,
              onScaleStart: (_) => _gestureStartZoom = _zoom,
              onScaleUpdate: _updateView,
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('digital-twin-particle-person'),
                  painter: _TwinParticlePainter(
                    pulse: _pulse,
                    merge: _merge,
                    projection: _projection,
                    repaint: _particleRepaint,
                    pending: pending,
                    opacity: completionOpacity.toDouble(),
                    yaw: _yaw,
                    pitch: _pitch,
                    zoom: _zoom,
                    mergeFraction: _mergeFraction,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _updateView(ScaleUpdateDetails details) {
    setState(() {
      _zoom = (_gestureStartZoom * details.scale).clamp(.78, 2.3).toDouble();
      if (details.pointerCount != 1) return;
      _yaw = (_yaw + details.focalPointDelta.dx * .012) % (math.pi * 2);
      _pitch = (_pitch + details.focalPointDelta.dy * .009)
          .clamp(-.65, .65)
          .toDouble();
    });
  }

  void _resetView() => setState(() {
    _yaw = _initialYaw;
    _pitch = _initialPitch;
    _zoom = 1;
  });
}

class _TwinParticlePainter extends CustomPainter {
  _TwinParticlePainter({
    required this.pulse,
    required this.merge,
    required this.projection,
    required Listenable repaint,
    required this.pending,
    required this.opacity,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    this.mergeFraction = 0,
  }) : super(repaint: repaint);

  final Animation<double> pulse;
  final Animation<double> merge;
  final DigitalTwinParticleProjection projection;
  final bool pending;
  final double opacity;
  final double yaw;
  final double pitch;
  final double zoom;
  final double mergeFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final pulseValue = pulse.value;
    final mergeProgress = Curves.easeInOutCubic.transform(merge.value);
    final projected = projection.project(
      viewport: size,
      yaw: yaw,
      pitch: pitch,
      zoom: zoom,
      pending: pending,
      mergeProgress: mergeProgress,
      mergeFraction: mergeFraction,
    );
    final paint = Paint();
    for (final point in projected) {
      paint.color = point.color.withValues(
        alpha:
            (point.baseOpacity + pulseValue * (point.warning ? .34 : .05))
                .clamp(0, 1)
                .toDouble() *
            opacity,
      );
      if (point.merging) {
        paint.color = Color.lerp(
          paint.color,
          const Color(0xFFE8DDFF).withValues(alpha: 0),
          mergeProgress,
        )!;
      }
      canvas.drawCircle(
        point.position,
        point.radius * (.9 + pulseValue * .08),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TwinParticlePainter oldDelegate) =>
      oldDelegate.pulse != pulse ||
      oldDelegate.merge != merge ||
      oldDelegate.projection != projection ||
      oldDelegate.pending != pending ||
      oldDelegate.opacity != opacity ||
      oldDelegate.yaw != yaw ||
      oldDelegate.pitch != pitch ||
      oldDelegate.zoom != zoom ||
      oldDelegate.mergeFraction != mergeFraction;
}

class _TwinSummary extends StatelessWidget {
  const _TwinSummary({
    required this.current,

    required this.onOpenChat,
    required this.onOpenPositioning,
  });

  final DigitalTwinCurrent current;

  final VoidCallback onOpenChat;
  final VoidCallback onOpenPositioning;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Lv.${current.level.value} ${current.level.name}',
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              '${current.level.completionPercent}%',
              style: TextStyle(
                color: colors.accent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(
          value: current.level.completionPercent / 100,
          minHeight: 7,
          borderRadius: BorderRadius.circular(4),
          color: colors.accent,
          backgroundColor: colors.surfaceMuted,
        ),
        const SizedBox(height: 18),
        _MetricRow(
          icon: Icons.description_outlined,
          label: '已沉淀文件',
          value:
              '${current.files.where((file) => file.exists).length}/${current.files.length}',
        ),
        _MetricRow(
          icon: Icons.rate_review_outlined,
          label: '待审差分',
          value: '${current.pendingReviewCount}',
        ),
        _MetricRow(
          icon: Icons.history_rounded,
          label: '正式版本',
          value: current.currentVersion?.label ?? 'v0',
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('digital-twin-open-chat'),
            onPressed: onOpenChat,
            icon: const Icon(Icons.forum_outlined),
            label: const Text('和数字分身对话'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey('digital-twin-positioning-summary-action'),
            onPressed: onOpenPositioning,
            icon: const Icon(Icons.explore_outlined),
            label: const Text('查看定位报告'),
          ),
        ),
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 19, color: colors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: TextStyle(color: colors.text)),
          ),
          Text(
            value,
            style: TextStyle(color: colors.ink, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _FilesView extends StatelessWidget {
  const _FilesView({required this.state, required this.onSelect});

  final DigitalTwinControllerState state;

  final Future<void> Function(String) onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = state.selectedFile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 680 ? 3 : 2;
            const gap = 10.0;
            final width =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final file in state.current!.files)
                  SizedBox(
                    width: width,
                    child: _FileTile(
                      file: file,
                      selected: file.id == selected?.id,
                      onTap: () => onSelect(file.id),
                    ),
                  ),
              ],
            );
          },
        ),
        if (selected != null) ...[
          const SizedBox(height: 22),
          _FileDetail(file: selected),
        ],
      ],
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.file,
    required this.selected,
    required this.onTap,
  });

  final DigitalTwinLogicalFile file;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: selected ? colors.surfaceMuted : colors.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 106),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? colors.accent : colors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_fileIcon(file.id), color: colors.accent, size: 21),
                  const Spacer(),
                  if (file.pendingCount > 0)
                    _CountBadge(value: file.pendingCount),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                file.exists ? '${file.sourceCount} 个来源' : '尚未沉淀',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileDetail extends StatelessWidget {
  const _FileDetail({required this.file});

  final DigitalTwinLogicalFile file;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final sources = <DigitalTwinSourceRef>[
      for (final conclusion in file.conclusions) ...conclusion.sources,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [Expanded(child: V3SectionTitle(file.name))]),
        const SizedBox(height: 10),
        SelectionArea(
          contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
          child: V3AssistantReplyMarkdown(
            source: file.markdown.trim().isEmpty ? '尚未沉淀内容' : file.markdown,
          ),
        ),
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            '来源',
            style: TextStyle(color: colors.ink, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (var index = 0; index < sources.length; index += 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.link_rounded, size: 17, color: colors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_sourceLabel(sources[index].sourceKind)} ${index + 1}',
                      style: TextStyle(color: colors.text),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: colors.accent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$value',
        style: TextStyle(
          color: colors.onPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ProposalReviewSection extends StatelessWidget {
  const _ProposalReviewSection({
    required this.state,
    required this.mutationLocked,
    required this.revisionController,
    required this.onSelectProposal,
    required this.onToggleHunk,
    required this.onInspectVersion,
    required this.onRevise,
    required this.onReject,
    required this.onRegenerate,
    required this.onConfirm,
  });

  final DigitalTwinControllerState state;
  final bool mutationLocked;
  final TextEditingController revisionController;
  final Future<void> Function(String) onSelectProposal;
  final ValueChanged<String> onToggleHunk;
  final Future<void> Function(String, int) onInspectVersion;
  final VoidCallback onRevise;
  final VoidCallback onReject;
  final VoidCallback onRegenerate;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final review = state.selectedReview;
    final fileIds = state.reviews
        .map((review) => review.snapshot.proposal.proposalId)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: V3SectionTitle('待提交修改')),
            _CountBadge(value: state.current!.pendingReviewCount),
          ],
        ),
        if (fileIds.length > 1) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (var index = 0; index < fileIds.length; index += 1)
                ChoiceChip(
                  label: Text('提案 ${index + 1}'),
                  selected: state.selectedProposalId == fileIds[index],
                  onSelected: (_) => onSelectProposal(fileIds[index]),
                ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        if (review == null)
          const Text('请选择包含待提交修改的文件')
        else if (review.loadingDetails)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (review.errorCode != null)
          const Text('提案详情暂时无法读取')
        else ...[
          _ProposalHeader(review: review),
          if (review.versions.length > 1) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final version in review.versions)
                  ChoiceChip(
                    label: Text('v${version.proposalVersion}'),
                    selected: review.visibleVersion == version.proposalVersion,
                    onSelected: (_) => onInspectVersion(
                      review.snapshot.proposal.proposalId,
                      version.proposalVersion,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          for (final hunk in review.diff)
            _DiffHunk(
              hunk: hunk,
              selected: review.selectedHunkIds.contains(hunk.hunkId),
              onChanged: review.isViewingCurrent
                  ? () => onToggleHunk(hunk.hunkId)
                  : null,
            ),
          if (review.diff.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('当前版本没有可显示的差分'),
            ),
          if (review.candidateMarkdown case final candidate?)
            V3DisclosureTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('候选全文'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectionArea(
                    contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
                    child: V3AssistantReplyMarkdown(source: candidate),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('digital-twin-revision-input'),
            controller: revisionController,
            contextMenuBuilder: V3TextEditing.buildContextMenu,
            enabled:
                review.snapshot.proposal.state == DocumentProposalState.ready &&
                review.isViewingCurrent &&
                !mutationLocked,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: state.selectedHunkCount == 0
                  ? '修订内容（整个文件）'
                  : '修订内容（已引用 ${state.selectedHunkCount} 条）',
              suffixIcon: IconButton(
                key: const ValueKey('digital-twin-revise-submit'),
                tooltip: '提交修订',
                onPressed: mutationLocked || !state.canRevise ? null : onRevise,
                icon: state.phase == DigitalTwinControllerPhase.revising
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ),
          ),
        ],
        if (review != null) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              if (state.canRegenerateSelected)
                OutlinedButton.icon(
                  key: const ValueKey('digital-twin-regenerate-candidate'),
                  onPressed: mutationLocked ? null : onRegenerate,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新生成候选'),
                ),
              if (state.canRejectSelected)
                TextButton.icon(
                  key: const ValueKey('digital-twin-reject-candidate'),
                  onPressed: mutationLocked ? null : onReject,
                  icon: const Icon(Icons.close),
                  label: const Text('不采用此候选'),
                ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('digital-twin-confirm'),
            onPressed: state.readyProposalCount == 0 || mutationLocked
                ? null
                : onConfirm,
            icon: state.phase == DigitalTwinControllerPhase.confirming
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle_outline_rounded),
            label: Text('确认并形成版本 (${state.readyProposalCount.clamp(0, 20)})'),
          ),
        ),
      ],
    );
  }
}

class _ProposalHeader extends StatelessWidget {
  const _ProposalHeader({required this.review});

  final DigitalTwinProposalReview review;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final proposal = review.snapshot.proposal;
    return Row(
      children: [
        Icon(Icons.change_circle_outlined, color: colors.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '提案 v${review.visibleVersion}',
            style: TextStyle(color: colors.ink, fontWeight: FontWeight.w700),
          ),
        ),
        Text(
          review.isViewingCurrent
              ? _proposalStateLabel(proposal.state)
              : '历史只读',
          style: TextStyle(color: colors.muted),
        ),
      ],
    );
  }
}

class _DiffHunk extends StatelessWidget {
  const _DiffHunk({
    required this.hunk,
    required this.selected,
    required this.onChanged,
  });

  final DocumentProposalDiffHunk hunk;
  final bool selected;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: ValueKey('digital-twin-hunk-${hunk.hunkId}'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: selected,
            onChanged: onChanged == null ? null : (_) => onChanged!(),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '第 ${hunk.newStart} 行',
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                for (final change in hunk.changes)
                  SelectableText(
                    '${change.op == 'insert' ? '+' : '-'} ${change.text}',
                    contextMenuBuilder: V3TextEditing.buildContextMenu,
                    style: TextStyle(
                      color: change.op == 'insert'
                          ? colors.success
                          : colors.danger,
                      height: 1.45,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmationReport extends StatelessWidget {
  const _ConfirmationReport({required this.confirmation});

  final DigitalTwinConfirmation confirmation;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: [
          Icon(
            confirmation.isTerminal
                ? Icons.assignment_turned_in_outlined
                : Icons.pending_actions_outlined,
            color: confirmation.failedCount > 0
                ? colors.danger
                : colors.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              confirmation.isTerminal
                  ? '已应用 ${confirmation.appliedCount} 项，失败 ${confirmation.failedCount} 项'
                  : '正在确认 ${confirmation.outcomes.length} 项修改',
              style: TextStyle(color: colors.text),
            ),
          ),
          if (confirmation.version != null)
            Text(
              confirmation.version!.label,
              style: TextStyle(
                color: colors.accent,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      ),
    );
  }
}

class _VersionHistory extends StatelessWidget {
  const _VersionHistory({
    required this.state,
    required this.onPreview,
    required this.onCompare,
    required this.onPull,
    required this.onRestore,
  });

  final DigitalTwinControllerState state;
  final ValueChanged<DigitalTwinVersion> onPreview;
  final ValueChanged<DigitalTwinVersion> onCompare;
  final ValueChanged<DigitalTwinVersion> onPull;
  final ValueChanged<DigitalTwinVersion> onRestore;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const V3SectionTitle('版本历史'),
        const SizedBox(height: 8),
        if (state.versions.isEmpty)
          Text('暂无正式版本', style: TextStyle(color: colors.muted))
        else
          for (final version in state.versions)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 19,
                backgroundColor: colors.surfaceMuted,
                child: Text(
                  '${version.versionNumber}',
                  style: TextStyle(
                    color: colors.accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              title: Text(version.label),
              subtitle: Text(
                '${_dateLabel(version.createdAt)} · 完成度 ${version.completionPercent}%',
              ),
              trailing: SizedBox.square(
                dimension: HuahuoControlSize.iconComfortable,
                child: IconButton(
                  key: ValueKey<String>(
                    'digital-twin-version-actions-${version.versionId}',
                  ),
                  tooltip: '版本操作',
                  onPressed: state.isBusy
                      ? null
                      : () => _showVersionActions(context, version),
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _showVersionActions(
    BuildContext context,
    DigitalTwinVersion version,
  ) async {
    final action = await showV3ActionSheet<_VersionAction>(
      context: context,
      title: '版本操作',
      message: version.label,
      items: [
        const V3ActionSheetItem<_VersionAction>(
          value: _VersionAction.preview,
          icon: Icons.visibility_outlined,
          label: '预览',
        ),
        V3ActionSheetItem<_VersionAction>(
          value: _VersionAction.compare,
          icon: Icons.compare_arrows_rounded,
          label: '与前版比较',
          enabled: version.versionNumber > 0,
        ),
        const V3ActionSheetItem<_VersionAction>(
          value: _VersionAction.pull,
          icon: Icons.download_outlined,
          label: '拉取快照',
        ),
        const V3ActionSheetItem<_VersionAction>(
          value: _VersionAction.restore,
          icon: Icons.restore_rounded,
          label: '基于此版本恢复',
        ),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _VersionAction.preview:
        onPreview(version);
        break;
      case _VersionAction.compare:
        onCompare(version);
        break;
      case _VersionAction.pull:
        onPull(version);
        break;
      case _VersionAction.restore:
        onRestore(version);
        break;
    }
  }
}

class _VersionInspectionSheet extends ConsumerWidget {
  const _VersionInspectionSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(digitalTwinControllerProvider).state;
    final colors = HuahuoV3Theme.tokensOf(context);
    final comparison = state.comparison;
    return SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        children: [
          Text(
            comparison == null
                ? state.versionDetail?.version.label ?? '版本预览'
                : '${comparison.baseVersion.label} → ${comparison.version.label}',
            style: TextStyle(
              color: colors.ink,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          if (comparison == null)
            for (final file in state.previewFiles) ...[
              Text(
                file.name,
                style: TextStyle(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              SelectionArea(
                contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
                child: V3AssistantReplyMarkdown(
                  source: file.markdown.trim().isEmpty
                      ? '尚未沉淀内容'
                      : file.markdown,
                ),
              ),
              const SizedBox(height: 18),
            ]
          else
            for (final file in comparison.files) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      file.name,
                      style: TextStyle(
                        color: colors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '+${file.summary.insertedLines} -${file.summary.deletedLines}',
                    style: TextStyle(color: colors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final hunk in file.hunks)
                for (final change in hunk.changes)
                  SelectableText(
                    '${change.op == 'insert' ? '+' : '-'} ${change.text}',
                    contextMenuBuilder: V3TextEditing.buildContextMenu,
                    style: TextStyle(
                      color: change.op == 'insert'
                          ? colors.success
                          : colors.danger,
                      height: 1.45,
                    ),
                  ),
              const SizedBox(height: 18),
            ],
        ],
      ),
    );
  }
}

class _ScheduleSection extends StatelessWidget {
  const _ScheduleSection({
    required this.schedule,
    required this.saving,
    required this.onEdit,
  });

  final DigitalTwinSchedule? schedule;
  final bool saving;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: V3SectionTitle('周期维护')),
            IconButton(
              tooltip: '设置',
              onPressed: saving || schedule == null ? null : onEdit,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.tune_rounded),
            ),
          ],
        ),
        if (schedule == null)
          Text('周期设置暂时不可用', style: TextStyle(color: colors.muted))
        else
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              schedule!.enabled
                  ? Icons.event_repeat_rounded
                  : Icons.event_busy_outlined,
              color: schedule!.enabled ? colors.success : colors.muted,
            ),
            title: Text(
              schedule!.enabled ? '每 ${schedule!.intervalDays} 天' : '未启用',
            ),
            subtitle: Text(
              schedule!.enabled && schedule!.nextRunAt != null
                  ? '下次 ${_dateTimeLabel(schedule!.nextRunAt!)}'
                  : schedule!.instruction,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.onRetry});

  final Future<bool> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Row(
      children: [
        Icon(Icons.error_outline_rounded, color: colors.danger),
        const SizedBox(width: 8),
        const Expanded(child: Text('本次操作未完成')),
        IconButton(
          tooltip: '重试',
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }
}

String _statusLabel(String value) => switch (value) {
  'agent_working' => 'Agent 工作中',
  'pending_review' => '等待确认',
  'confirming' => '正在确认',
  _ => '持续生长',
};

String _proposalStateLabel(DocumentProposalState value) => switch (value) {
  DocumentProposalState.generating => '生成中',
  DocumentProposalState.ready => '待确认',
  DocumentProposalState.applying => '应用中',
  DocumentProposalState.applied => '已应用',
  DocumentProposalState.rejected => '已拒绝',
  DocumentProposalState.stale => '已过期，需重新生成或放弃',
  DocumentProposalState.generationFailed => '生成失败',
  DocumentProposalState.applyFailed => '应用失败',
};

bool _isPositioningFileId(String? fileId) =>
    fileId == _socialPositioningFileId || fileId == _legacyPositioningFileId;

IconData _fileIcon(String id) => switch (id) {
  'life_experiences' => Icons.route_outlined,
  'professional_knowledge' => Icons.school_outlined,
  'viewpoints_insights' => Icons.lightbulb_outline_rounded,
  'expression_habits' => Icons.record_voice_over_outlined,
  'methods_processes' => Icons.account_tree_outlined,
  'social_positioning' => Icons.location_on_outlined,
  _ => Icons.description_outlined,
};

String _sourceLabel(String sourceKind) => switch (sourceKind) {
  'note' => '资料',
  'message' || 'user_confirmation' => '对话',
  'resource' => '上传文件',
  _ => '来源',
};

String _dateLabel(DateTime value) =>
    '${value.toLocal().year}-${value.toLocal().month.toString().padLeft(2, '0')}-${value.toLocal().day.toString().padLeft(2, '0')}';

String _dateTimeLabel(DateTime value) {
  final local = value.toLocal();
  return '${_dateLabel(local)} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _byteLabel(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
