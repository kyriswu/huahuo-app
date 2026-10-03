part of 'desktop_document_proposals_workspace.dart';

final class _CandidatePane extends StatelessWidget {
  const _CandidatePane({required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('候选正文', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            child: SelectionArea(
              contextMenuBuilder: HuahuoTextEditing.buildSelectableContextMenu,
              child: HuahuoMarkdown(
                source: markdown,
                key: const ValueKey<String>('proposal-candidate'),
                contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

final class _DiffPane extends StatelessWidget {
  const _DiffPane({
    required this.controller,
    required this.state,
    required this.review,
  });

  final ProductDocumentProposalsController controller;
  final ProductDocumentProposalsState state;
  final ProductProposalReview review;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('逐块差异', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        Expanded(
          child: review.hunks.isEmpty
              ? const Center(child: Text('候选正文没有行级差异'))
              : ListView.separated(
                  itemCount: review.hunks.length,
                  separatorBuilder: (_, _) => const Divider(height: 16),
                  itemBuilder: (context, index) {
                    final tokens = DesktopThemeTokens.of(context);
                    final hunk = review.hunks[index];
                    final selectable = review.diffBundleId != null;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CheckboxListTile(
                          key: ValueKey<String>('proposal-hunk-${hunk.id}'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: state.selectedHunkIds.contains(hunk.id),
                          onChanged: selectable && !state.isBusy
                              ? (_) => controller.toggleHunk(hunk.id)
                              : null,
                          title: Text(
                            '原 ${hunk.oldStart}-${hunk.oldLines} 行 · '
                            '新 ${hunk.newStart}-${hunk.newLines} 行',
                          ),
                        ),
                        for (final change in hunk.changes)
                          Container(
                            color: change.operation == 'insert'
                                ? tokens.success.withValues(alpha: 0.10)
                                : tokens.danger.withValues(alpha: 0.10),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            child: SelectableText(
                              '${change.operation == 'insert' ? '+' : '-'} ${change.text}',
                              contextMenuBuilder:
                                  HuahuoTextEditing.buildEditableContextMenu,
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

final class _ProposalInlineFailure extends StatelessWidget {
  const _ProposalInlineFailure({
    required this.message,
    required this.retryable,
    required this.onRetry,
  });

  final String message;
  final bool retryable;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(LucideIcons.triangleAlert, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          if (retryable)
            TextButton(
              key: const ValueKey<String>('proposal-inline-retry'),
              onPressed: onRetry,
              child: const Text('重试'),
            ),
        ],
      ),
    ),
  );
}

final class _ProposalCenteredState extends StatelessWidget {
  const _ProposalCenteredState({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 430),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 7),
            Text(detail, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    ),
  );
}

bool _sameCreation(
  ProductCreationDocument? left,
  ProductCreationDocument? right,
) =>
    left?.summary.id == right?.summary.id &&
    left?.rawPartRevisionId == right?.rawPartRevisionId;

String _dateLabel(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _lifecycleLabel(ProductProposalLifecycle value) => switch (value) {
  ProductProposalLifecycle.generating => '生成中',
  ProductProposalLifecycle.ready => '待审阅',
  ProductProposalLifecycle.applying => '应用中',
  ProductProposalLifecycle.applied => '已应用',
  ProductProposalLifecycle.rejected => '已拒绝',
  ProductProposalLifecycle.stale => '正文已变化',
  ProductProposalLifecycle.generationFailed => '生成失败',
  ProductProposalLifecycle.applyFailed => '应用失败',
};

IconData _lifecycleIcon(ProductProposalLifecycle value) => switch (value) {
  ProductProposalLifecycle.generating ||
  ProductProposalLifecycle.applying => LucideIcons.loaderCircle,
  ProductProposalLifecycle.ready => LucideIcons.gitCompareArrows,
  ProductProposalLifecycle.applied => LucideIcons.circleCheck,
  ProductProposalLifecycle.rejected => LucideIcons.circleX,
  ProductProposalLifecycle.stale => LucideIcons.gitBranch,
  ProductProposalLifecycle.generationFailed ||
  ProductProposalLifecycle.applyFailed => LucideIcons.triangleAlert,
};

String _terminalDetail(ProductProposalLifecycle value) => switch (value) {
  ProductProposalLifecycle.applied => '候选正文已经写入原文。',
  ProductProposalLifecycle.rejected => '该候选正文没有写入原文。',
  ProductProposalLifecycle.stale => '原文版本已变化，请重基或修订后再审阅。',
  ProductProposalLifecycle.generationFailed => '生成未完成，可以刷新或重新发起提案。',
  ProductProposalLifecycle.applyFailed => '写入未完成，可以修订、拒绝或重新操作。',
  _ => '提案状态已更新。',
};
