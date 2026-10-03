import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/desktop_theme.dart';

part 'desktop_digital_twin_components.dart';

enum _DigitalTwinView { profile, review, versions }

final class DesktopDigitalTwinWorkspace extends StatefulWidget {
  const DesktopDigitalTwinWorkspace({
    required this.workspaceId,
    required this.repository,
    required this.proposalsRepository,
    super.key,
  });

  final String? workspaceId;
  final ProductDigitalTwinRepository repository;
  final ProductDocumentProposalsRepository proposalsRepository;

  @override
  State<DesktopDigitalTwinWorkspace> createState() =>
      _DesktopDigitalTwinWorkspaceState();
}

final class _DesktopDigitalTwinWorkspaceState
    extends State<DesktopDigitalTwinWorkspace> {
  late ProductDigitalTwinController _controller;
  _DigitalTwinView _view = _DigitalTwinView.profile;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  @override
  void didUpdateWidget(DesktopDigitalTwinWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository) ||
        !identical(oldWidget.proposalsRepository, widget.proposalsRepository)) {
      _controller.removeListener(_changed);
      _controller.dispose();
      _createController();
      return;
    }
    if (oldWidget.workspaceId != widget.workspaceId) {
      unawaited(_controller.bindWorkspace(widget.workspaceId));
    }
  }

  void _createController() {
    _controller = ProductDigitalTwinController(
      widget.repository,
      widget.proposalsRepository,
    )..addListener(_changed);
    unawaited(_controller.bindWorkspace(widget.workspaceId));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return Material(
      key: const ValueKey<String>('desktop-digital-twin-workspace'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _topBar(state),
          if (state.errorMessage != null &&
              state.status != ProductDigitalTwinStatus.failure)
            _DigitalTwinInlineFailure(
              message: state.errorMessage!,
              retryable: state.retryable,
              onRetry: _controller.reload,
            ),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  Widget _topBar(ProductDigitalTwinState state) => SizedBox(
    height: 56,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          const Icon(LucideIcons.fingerprint, size: 18),
          const SizedBox(width: 9),
          Text('数字分身', style: Theme.of(context).textTheme.titleMedium),
          if (state.current case final current?) ...[
            const SizedBox(width: 12),
            _DigitalTwinLevelBadge(level: current.level),
          ],
          const Spacer(),
          if (state.schedule case final schedule?)
            TextButton.icon(
              key: const ValueKey<String>('digital-twin-schedule'),
              onPressed: state.isBusy ? null : () => _editSchedule(schedule),
              icon: Icon(
                schedule.enabled
                    ? LucideIcons.calendarClock
                    : LucideIcons.calendarOff,
                size: 16,
              ),
              label: Text(schedule.enabled ? '计划已开启' : '定期计划'),
            ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey<String>('digital-twin-refresh'),
            tooltip: '刷新数字分身',
            onPressed: state.isBusy ? null : _controller.reload,
            icon: state.status == ProductDigitalTwinStatus.loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refreshCw, size: 16),
          ),
        ],
      ),
    ),
  );

  Widget _body(ProductDigitalTwinState state) {
    if (state.status == ProductDigitalTwinStatus.idle) {
      return const _DigitalTwinCenteredState(
        icon: LucideIcons.lockKeyhole,
        title: 'Workspace 尚未就绪',
        detail: '登录并选择 Workspace 后管理数字分身。',
      );
    }
    if (state.status == ProductDigitalTwinStatus.loading &&
        state.current == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ProductDigitalTwinStatus.failure &&
        state.current == null) {
      return _DigitalTwinCenteredState(
        icon: LucideIcons.cloudOff,
        title: '数字分身加载失败',
        detail: state.errorMessage ?? '暂时无法读取数字分身。',
        action: OutlinedButton.icon(
          key: const ValueKey<String>('digital-twin-retry'),
          onPressed: _controller.reload,
          icon: const Icon(LucideIcons.refreshCw, size: 16),
          label: const Text('重试'),
        ),
      );
    }
    if (state.status == ProductDigitalTwinStatus.empty ||
        state.current?.files.isEmpty == true) {
      return const _DigitalTwinCenteredState(
        icon: LucideIcons.fileStack,
        title: '数字分身正在等待资料',
        detail: '沉淀笔记或导入资料后，这里会形成可审阅的长期档案。',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 900;
        return Column(
          children: [
            _viewSelector(compact),
            Expanded(
              child: switch (_view) {
                _DigitalTwinView.profile => _profileView(state, compact),
                _DigitalTwinView.review => _reviewView(state, compact),
                _DigitalTwinView.versions => _versionsView(state),
              },
            ),
          ],
        );
      },
    );
  }

  Widget _viewSelector(bool compact) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
      child: SegmentedButton<_DigitalTwinView>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: _DigitalTwinView.profile,
            icon: Icon(LucideIcons.files, size: 15),
            label: Text('档案'),
          ),
          ButtonSegment(
            value: _DigitalTwinView.review,
            icon: Icon(LucideIcons.gitPullRequest, size: 15),
            label: Text('审阅'),
          ),
          ButtonSegment(
            value: _DigitalTwinView.versions,
            icon: Icon(LucideIcons.history, size: 15),
            label: Text('版本'),
          ),
        ],
        selected: {_view},
        onSelectionChanged: (selection) =>
            setState(() => _view = selection.single),
      ),
    ),
  );

  Widget _profileView(ProductDigitalTwinState state, bool compact) {
    final list = _DigitalTwinFileList(
      state: state,
      onSelect: _controller.selectFile,
    );
    final detail = _DigitalTwinFileDetail(file: state.selectedFile);
    if (compact) {
      return Column(
        children: [
          SizedBox(height: 190, child: list),
          Expanded(child: detail),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 300, child: list),
        const VerticalDivider(width: 1),
        Expanded(child: detail),
      ],
    );
  }

  Widget _reviewView(ProductDigitalTwinState state, bool compact) {
    final list = _DigitalTwinProposalList(
      state: state,
      onSelect: _controller.selectProposal,
    );
    final detail = _DigitalTwinReviewDetail(
      state: state,
      onToggleHunk: _controller.toggleHunk,
      onInspectVersion: _controller.inspectProposalVersion,
      onRevise: _revise,
      onConfirm: _confirm,
    );
    if (compact) {
      return Column(
        children: [
          SizedBox(height: 170, child: list),
          Expanded(child: detail),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 310, child: list),
        const VerticalDivider(width: 1),
        Expanded(child: detail),
      ],
    );
  }

  Widget _versionsView(ProductDigitalTwinState state) => _DigitalTwinVersions(
    state: state,
    onPreview: _previewVersion,
    onCompare: _compareVersion,
    onDownload: _downloadVersion,
    onRestore: _restoreVersion,
    onCloseInspection: _controller.clearVersionInspection,
  );

  Future<void> _editSchedule(ProductDigitalTwinSchedule schedule) async {
    final draft = await showDialog<ProductDigitalTwinScheduleDraft>(
      context: context,
      builder: (context) => _DigitalTwinScheduleDialog(schedule: schedule),
    );
    if (draft == null) return;
    final ok = await _controller.saveSchedule(draft);
    if (mounted) _message(ok ? '定期计划已保存' : '计划保存失败');
  }

  Future<void> _revise() async {
    final instruction = await showDialog<String>(
      context: context,
      builder: (context) => const _DigitalTwinInstructionDialog(),
    );
    if (instruction == null) return;
    final ok = await _controller.reviseSelected(instruction);
    if (mounted) _message(ok ? '修改要求已提交' : '修改要求提交失败');
  }

  Future<void> _confirm() async {
    final count = _controller.state.readyProposalCount;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认当前版本？'),
        content: Text('将应用 $count 个已就绪提案，并生成一个正式数字分身版本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('digital-twin-confirm-submit'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认应用'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    final ok = await _controller.confirmReady();
    if (mounted) _message(ok ? '正式版本已生成' : '确认未完成，请查看报告');
  }

  Future<void> _previewVersion(ProductDigitalTwinVersion version) async {
    final ok = await _controller.inspectVersion(version.id);
    if (mounted && !ok) _message('版本预览加载失败');
  }

  Future<void> _compareVersion(ProductDigitalTwinVersion version) async {
    final ok = await _controller.compareVersion(version.id);
    if (mounted && !ok) _message('该版本没有可比较的前一版本');
  }

  Future<void> _downloadVersion(ProductDigitalTwinVersion version) async {
    final archive = await _controller.downloadVersion(version.id);
    if (!mounted || archive == null) {
      if (mounted) _message('版本下载失败');
      return;
    }
    final location = await getSaveLocation(
      suggestedName: 'digital-twin-v${version.number}.zip',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'ZIP 归档', extensions: ['zip']),
      ],
    );
    if (location == null) return;
    try {
      await File(location.path).writeAsBytes(archive.bytes, flush: true);
      if (mounted) _message('版本归档已保存');
    } on Object {
      if (mounted) _message('无法写入所选位置');
    }
  }

  Future<void> _restoreVersion(ProductDigitalTwinVersion version) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('基于 ${version.label} 恢复？'),
        content: const Text('恢复会生成可审阅提案，不会直接覆盖当前档案。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            key: const ValueKey<String>('digital-twin-restore-submit'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(LucideIcons.rotateCcw, size: 16),
            label: const Text('生成恢复提案'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    final ok = await _controller.restoreVersion(version.id);
    if (!mounted) return;
    if (ok) setState(() => _view = _DigitalTwinView.review);
    _message(ok ? '恢复提案已生成' : '恢复提案生成失败');
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}
