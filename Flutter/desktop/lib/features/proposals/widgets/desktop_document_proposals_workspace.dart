import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/desktop_theme.dart';

part 'desktop_document_proposals_components.dart';

final class DesktopDocumentProposalsWorkspace extends StatefulWidget {
  const DesktopDocumentProposalsWorkspace({
    required this.workspaceId,
    required this.repository,
    required this.initialCreation,
    required this.onOpenCreations,
    super.key,
  });

  final String? workspaceId;
  final ProductDocumentProposalsRepository repository;
  final ProductCreationDocument? initialCreation;
  final VoidCallback onOpenCreations;

  @override
  State<DesktopDocumentProposalsWorkspace> createState() =>
      _DesktopDocumentProposalsWorkspaceState();
}

final class _DesktopDocumentProposalsWorkspaceState
    extends State<DesktopDocumentProposalsWorkspace> {
  late ProductDocumentProposalsController _controller;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  @override
  void didUpdateWidget(DesktopDocumentProposalsWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository)) {
      _controller.removeListener(_changed);
      _controller.dispose();
      _createController();
      return;
    }
    if (oldWidget.workspaceId != widget.workspaceId ||
        !_sameCreation(oldWidget.initialCreation, widget.initialCreation)) {
      unawaited(
        _controller.bindWorkspace(
          widget.workspaceId,
          creation: widget.initialCreation,
        ),
      );
    }
  }

  void _createController() {
    _controller = ProductDocumentProposalsController(widget.repository)
      ..addListener(_changed);
    unawaited(
      _controller.bindWorkspace(
        widget.workspaceId,
        creation: widget.initialCreation,
      ),
    );
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
      key: const ValueKey<String>('desktop-document-proposals-workspace'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _topBar(state),
          if (state.errorMessage != null && state.items.isNotEmpty)
            _ProposalInlineFailure(
              message: state.errorMessage!,
              retryable: state.retryable,
              onRetry: _retry,
            ),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  Widget _topBar(ProductDocumentProposalsState state) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          const Icon(LucideIcons.gitCompareArrows, size: 17),
          const SizedBox(width: 9),
          Text('文档提案', style: Theme.of(context).textTheme.titleMedium),
          if (state.targetCreation != null) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                state.targetCreation!.summary.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            key: const ValueKey<String>('proposal-refresh'),
            tooltip: '刷新提案',
            onPressed: state.isBusy ? null : _controller.reload,
            icon: state.status == ProductProposalsStatus.loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refreshCw, size: 16),
          ),
          const SizedBox(width: 4),
          if (state.targetCreation == null)
            OutlinedButton.icon(
              key: const ValueKey<String>('proposal-open-creations'),
              onPressed: widget.onOpenCreations,
              icon: const Icon(LucideIcons.filePenLine, size: 16),
              label: const Text('选择创作'),
            )
          else
            FilledButton.icon(
              key: const ValueKey<String>('proposal-create'),
              onPressed: state.isBusy ? null : _showCreateDialog,
              icon: const Icon(LucideIcons.plus, size: 16),
              label: const Text('新建提案'),
            ),
        ],
      ),
    ),
  );

  Widget _body(ProductDocumentProposalsState state) {
    if (state.status == ProductProposalsStatus.idle) {
      return const _ProposalCenteredState(
        icon: LucideIcons.lockKeyhole,
        title: 'Workspace 尚未就绪',
        detail: '登录并选择 Workspace 后查看文档提案。',
      );
    }
    if (state.status == ProductProposalsStatus.loading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ProductProposalsStatus.failure && state.items.isEmpty) {
      return _ProposalCenteredState(
        icon: LucideIcons.cloudOff,
        title: '提案历史加载失败',
        detail: state.errorMessage ?? '暂时无法读取提案历史。',
        action: OutlinedButton.icon(
          key: const ValueKey<String>('proposal-retry'),
          onPressed: _controller.reload,
          icon: const Icon(LucideIcons.refreshCw, size: 16),
          label: const Text('重试'),
        ),
      );
    }
    if (state.items.isEmpty) {
      return _ProposalCenteredState(
        icon: LucideIcons.gitPullRequestCreate,
        title: state.targetCreation == null ? '还没有文档提案' : '这篇创作还没有提案',
        detail: state.targetCreation == null
            ? '先从云端创作中选择正文，再提交修改要求。'
            : '发起提案后，可在这里审阅候选正文和逐块差异。',
        action: state.targetCreation == null
            ? OutlinedButton.icon(
                onPressed: widget.onOpenCreations,
                icon: const Icon(LucideIcons.filePenLine, size: 16),
                label: const Text('打开云端创作'),
              )
            : FilledButton.icon(
                key: const ValueKey<String>('proposal-empty-create'),
                onPressed: _showCreateDialog,
                icon: const Icon(LucideIcons.plus, size: 16),
                label: const Text('新建提案'),
              ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 860;
        final list = _ProposalList(controller: _controller, state: state);
        final detail = _ProposalDetail(
          controller: _controller,
          state: state,
          onApply: () => _run(_controller.apply, '提案已提交应用'),
          onReject: _confirmReject,
          onCancel: () => _run(_controller.cancel, '已取消生成'),
          onRebase: () => _run(_controller.rebase, '已提交重基'),
          onRevise: _showReviseDialog,
          onVersions: _showVersions,
        );
        if (compact) {
          if (state.selected == null) return list;
          return Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey<String>('proposal-back'),
                  onPressed: _controller.resetSelectionForView,
                  icon: const Icon(LucideIcons.arrowLeft, size: 16),
                  label: const Text('提案列表'),
                ),
              ),
              Expanded(child: detail),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 310, child: list),
            VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
            Expanded(child: detail),
          ],
        );
      },
    );
  }

  Future<void> _showCreateDialog() async {
    final instruction = await _instructionDialog(
      title: '新建文档提案',
      label: '修改要求',
      confirmLabel: '开始生成',
    );
    if (!mounted || instruction == null) return;
    await _run(() => _controller.create(instruction), '提案已创建');
  }

  Future<void> _showReviseDialog() async {
    final instruction = await _instructionDialog(
      title: '修订提案',
      label: _controller.state.selectedHunkIds.isEmpty
          ? '补充修改要求'
          : '针对选中差异的修改要求',
      confirmLabel: '重新生成',
    );
    if (!mounted || instruction == null) return;
    await _run(() => _controller.revise(instruction), '已提交修订');
  }

  Future<String?> _instructionDialog({
    required String title,
    required String label,
    required String confirmLabel,
  }) async {
    var input = '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: TextField(
            key: const ValueKey<String>('proposal-instruction'),
            contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
            autofocus: true,
            minLines: 4,
            maxLines: 9,
            maxLength: 32000,
            decoration: InputDecoration(
              labelText: label,
              alignLabelWithHint: true,
            ),
            onChanged: (value) => input = value,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('proposal-instruction-confirm'),
            onPressed: () {
              final value = input.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _confirmReject() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('拒绝提案'),
        content: const Text('该提案将标记为已拒绝，候选内容不会写入原文。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            key: const ValueKey<String>('proposal-reject-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认拒绝'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      await _run(_controller.reject, '提案已拒绝');
    }
  }

  Future<void> _showVersions() async {
    await _controller.loadVersions();
    if (!mounted) return;
    final state = _controller.state;
    if (state.errorMessage != null || state.versions.isEmpty) {
      _showMessage(state.errorMessage ?? '暂无历史版本');
      return;
    }
    final version = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提案版本'),
        content: SizedBox(
          width: 520,
          height: 360,
          child: ListView.separated(
            itemCount: state.versions.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = state.versions[index];
              return ListTile(
                key: ValueKey<String>('proposal-version-${item.version}'),
                leading: const Icon(LucideIcons.history, size: 17),
                title: Text('版本 ${item.version}'),
                subtitle: Text(_dateLabel(item.createdAt)),
                trailing: const Icon(LucideIcons.chevronRight, size: 15),
                onTap: () => Navigator.pop(context, item.version),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (!mounted || version == null) return;
    await _controller.showVersion(version);
  }

  Future<void> _run(Future<bool> Function() action, String success) async {
    final succeeded = await action();
    if (!mounted) return;
    _showMessage(
      succeeded ? success : _controller.state.errorMessage ?? '操作失败',
    );
  }

  void _retry() {
    if (_controller.state.selected == null) {
      unawaited(_controller.reload());
    } else {
      unawaited(_controller.refreshSelected());
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _ProposalList extends StatelessWidget {
  const _ProposalList({required this.controller, required this.state});

  final ProductDocumentProposalsController controller;
  final ProductDocumentProposalsState state;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: state.items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = state.items[index];
            return ListTile(
              key: ValueKey<String>('proposal-item-${item.id}'),
              selected: item.id == state.selected?.id,
              leading: Icon(_lifecycleIcon(item.lifecycle), size: 17),
              title: Text(
                item.ownerId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_lifecycleLabel(item.lifecycle)} · 版本 ${item.version}',
              ),
              trailing: const Icon(LucideIcons.chevronRight, size: 15),
              onTap: () => controller.select(item.id),
            );
          },
        ),
      ),
      if (state.nextCursor != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: OutlinedButton.icon(
            key: const ValueKey<String>('proposal-load-more'),
            onPressed: state.loadingMore ? null : controller.loadMore,
            icon: state.loadingMore
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.chevronsDown, size: 16),
            label: const Text('加载更多'),
          ),
        ),
    ],
  );
}

final class _ProposalDetail extends StatelessWidget {
  const _ProposalDetail({
    required this.controller,
    required this.state,
    required this.onApply,
    required this.onReject,
    required this.onCancel,
    required this.onRebase,
    required this.onRevise,
    required this.onVersions,
  });

  final ProductDocumentProposalsController controller;
  final ProductDocumentProposalsState state;
  final VoidCallback onApply;
  final VoidCallback onReject;
  final VoidCallback onCancel;
  final VoidCallback onRebase;
  final VoidCallback onRevise;
  final VoidCallback onVersions;

  @override
  Widget build(BuildContext context) {
    final proposal = state.selected;
    if (proposal == null) {
      return const _ProposalCenteredState(
        icon: LucideIcons.panelRightOpen,
        title: '选择一个提案',
        detail: '查看候选正文、逐块差异和历史版本。',
      );
    }
    if (state.detailStatus == ProductProposalDetailStatus.loading ||
        state.detailStatus == ProductProposalDetailStatus.reviewLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.detailStatus == ProductProposalDetailStatus.polling) {
      return _ProposalCenteredState(
        icon: LucideIcons.loaderCircle,
        title: proposal.lifecycle == ProductProposalLifecycle.applying
            ? '正在应用提案'
            : '正在生成候选正文',
        detail: '已检查 ${state.pollAttempt} 次，完成后会自动刷新。',
        action: proposal.canCancel
            ? OutlinedButton.icon(
                key: const ValueKey<String>('proposal-cancel'),
                onPressed: state.isBusy ? null : onCancel,
                icon: const Icon(LucideIcons.circleStop, size: 16),
                label: const Text('取消生成'),
              )
            : null,
      );
    }
    if (state.detailStatus == ProductProposalDetailStatus.failure) {
      return _ProposalCenteredState(
        icon: LucideIcons.triangleAlert,
        title: '提案加载失败',
        detail: state.errorMessage ?? '请刷新后重试。',
        action: state.retryable
            ? OutlinedButton.icon(
                onPressed: controller.refreshSelected,
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                label: const Text('重试'),
              )
            : null,
      );
    }
    if (state.detailStatus == ProductProposalDetailStatus.noChanges) {
      return _ProposalTerminal(
        proposal: proposal,
        title: '无需修改',
        detail: '候选正文与当前正文一致，可以修订要求或拒绝该提案。',
        state: state,
        onReject: onReject,
        onRebase: onRebase,
        onRevise: onRevise,
        onVersions: onVersions,
      );
    }
    if (state.detailStatus == ProductProposalDetailStatus.terminal) {
      return _ProposalTerminal(
        proposal: proposal,
        title: _lifecycleLabel(proposal.lifecycle),
        detail: proposal.failureCode ?? _terminalDetail(proposal.lifecycle),
        state: state,
        onReject: onReject,
        onRebase: onRebase,
        onRevise: onRevise,
        onVersions: onVersions,
      );
    }
    final review = state.review;
    if (review == null) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProposalActions(
            proposal: proposal,
            busy: state.isBusy,
            onApply: onApply,
            onReject: onReject,
            onRebase: onRebase,
            onRevise: onRevise,
            onVersions: onVersions,
          ),
          const SizedBox(height: 10),
          Text(
            '版本 ${review.proposalVersion} · +${review.summary.insertedLines} '
            '-${review.summary.deletedLines} · ${review.summary.hunks} 个差异块',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stacked = constraints.maxWidth < 760;
                final candidate = _CandidatePane(
                  markdown: review.candidateMarkdown,
                );
                final diff = _DiffPane(
                  controller: controller,
                  state: state,
                  review: review,
                );
                return stacked
                    ? Column(
                        children: [
                          Expanded(child: candidate),
                          const Divider(height: 1),
                          Expanded(child: diff),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: candidate),
                          const VerticalDivider(width: 1),
                          Expanded(child: diff),
                        ],
                      );
              },
            ),
          ),
        ],
      ),
    );
  }
}

final class _ProposalActions extends StatelessWidget {
  const _ProposalActions({
    required this.proposal,
    required this.busy,
    required this.onApply,
    required this.onReject,
    required this.onRebase,
    required this.onRevise,
    required this.onVersions,
  });

  final ProductDocumentProposal proposal;
  final bool busy;
  final VoidCallback onApply;
  final VoidCallback onReject;
  final VoidCallback onRebase;
  final VoidCallback onRevise;
  final VoidCallback onVersions;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.end,
    spacing: 8,
    runSpacing: 8,
    children: [
      IconButton(
        key: const ValueKey<String>('proposal-versions'),
        tooltip: '查看版本',
        onPressed: busy ? null : onVersions,
        icon: const Icon(LucideIcons.history, size: 17),
      ),
      if (proposal.canRebase)
        OutlinedButton.icon(
          key: const ValueKey<String>('proposal-rebase'),
          onPressed: busy ? null : onRebase,
          icon: const Icon(LucideIcons.gitBranch, size: 16),
          label: const Text('重基'),
        ),
      if (proposal.canRevise)
        OutlinedButton.icon(
          key: const ValueKey<String>('proposal-revise'),
          onPressed: busy ? null : onRevise,
          icon: const Icon(LucideIcons.wandSparkles, size: 16),
          label: const Text('修订'),
        ),
      if (proposal.canReject)
        TextButton(
          key: const ValueKey<String>('proposal-reject'),
          onPressed: busy ? null : onReject,
          child: const Text('拒绝'),
        ),
      if (proposal.canApply)
        FilledButton.icon(
          key: const ValueKey<String>('proposal-apply'),
          onPressed: busy ? null : onApply,
          icon: const Icon(LucideIcons.check, size: 16),
          label: const Text('应用到正文'),
        ),
    ],
  );
}

final class _ProposalTerminal extends StatelessWidget {
  const _ProposalTerminal({
    required this.proposal,
    required this.title,
    required this.detail,
    required this.state,
    required this.onReject,
    required this.onRebase,
    required this.onRevise,
    required this.onVersions,
  });

  final ProductDocumentProposal proposal;
  final String title;
  final String detail;
  final ProductDocumentProposalsState state;
  final VoidCallback onReject;
  final VoidCallback onRebase;
  final VoidCallback onRevise;
  final VoidCallback onVersions;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _ProposalActions(
            proposal: proposal,
            busy: state.isBusy,
            onApply: () {},
            onReject: onReject,
            onRebase: onRebase,
            onRevise: onRevise,
            onVersions: onVersions,
          ),
        ),
      ),
      Expanded(
        child: _ProposalCenteredState(
          icon: _lifecycleIcon(proposal.lifecycle),
          title: title,
          detail: detail,
        ),
      ),
    ],
  );
}
