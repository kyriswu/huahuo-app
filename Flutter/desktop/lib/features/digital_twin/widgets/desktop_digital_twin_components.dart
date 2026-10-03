part of 'desktop_digital_twin_workspace.dart';

final class _DigitalTwinLevelBadge extends StatelessWidget {
  const _DigitalTwinLevelBadge({required this.level});
  final ProductDigitalTwinLevel level;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      'Lv.${level.value} ${level.name} · ${level.completionPercent}%',
      style: Theme.of(context).textTheme.labelSmall,
    ),
  );
}

final class _DigitalTwinInlineFailure extends StatelessWidget {
  const _DigitalTwinInlineFailure({
    required this.message,
    required this.retryable,
    required this.onRetry,
  });
  final String message;
  final bool retryable;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
      child: Row(
        children: [
          Icon(
            LucideIcons.triangleAlert,
            size: 15,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(message, maxLines: 2)),
          if (retryable)
            TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

final class _DigitalTwinCenteredState extends StatelessWidget {
  const _DigitalTwinCenteredState({
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
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(detail, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    ),
  );
}

final class _DigitalTwinFileList extends StatelessWidget {
  const _DigitalTwinFileList({required this.state, required this.onSelect});
  final ProductDigitalTwinState state;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.fromLTRB(10, 2, 10, 14),
    itemCount: state.current?.files.length ?? 0,
    itemBuilder: (context, index) {
      final file = state.current!.files[index];
      return ListTile(
        key: ValueKey<String>('digital-twin-file-${file.id}'),
        selected: file.id == state.selectedFileId,
        onTap: () => onSelect(file.id),
        leading: Icon(
          file.exists ? LucideIcons.fileText : LucideIcons.filePlus2,
        ),
        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${file.conclusions.length} 项结论 · ${file.sourceCount} 个来源',
        ),
        trailing: file.pendingCount == 0
            ? null
            : Badge(label: Text('${file.pendingCount}')),
      );
    },
  );
}

final class _DigitalTwinFileDetail extends StatelessWidget {
  const _DigitalTwinFileDetail({required this.file});
  final ProductDigitalTwinFile? file;
  @override
  Widget build(BuildContext context) {
    final value = file;
    if (value == null) {
      return const _DigitalTwinCenteredState(
        icon: LucideIcons.fileSearch,
        title: '选择一份档案',
        detail: '查看长期结论、正文和来源。',
      );
    }
    return SelectionArea(
      contextMenuBuilder: HuahuoTextEditing.buildSelectableContextMenu,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
        children: [
          Text(value.name, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            value.exists ? '已形成档案' : '尚未形成档案',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          if (value.markdown.trim().isEmpty)
            const Text('暂无正文。')
          else
            SelectionArea(
              contextMenuBuilder: HuahuoTextEditing.buildSelectableContextMenu,
              child: HuahuoMarkdown(
                source: value.markdown,
                contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
              ),
            ),
          const SizedBox(height: 22),
          Text('长期结论', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (value.conclusions.isEmpty)
            const Text('暂无独立结论。')
          else
            for (final conclusion in value.conclusions)
              DesktopDisclosureTile(
                key: ValueKey<String>(
                  'digital-twin-conclusion-${conclusion.id}',
                ),
                tilePadding: EdgeInsets.zero,
                title: Text(conclusion.profileKind),
                subtitle: Text(
                  '修订 ${conclusion.revision} · ${conclusion.sources.length} 个来源',
                ),
                status: conclusion.sourceReviewNeeded
                    ? const Tooltip(
                        message: '需要复核来源',
                        child: Icon(LucideIcons.badgeAlert, size: 17),
                      )
                    : null,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: SelectionArea(
                        contextMenuBuilder:
                            HuahuoTextEditing.buildSelectableContextMenu,
                        child: HuahuoMarkdown(
                          source: conclusion.markdown,
                          contextMenuBuilder:
                              HuahuoTextEditing.buildEditableContextMenu,
                        ),
                      ),
                    ),
                  ),
                  for (final source in conclusion.sources)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(LucideIcons.link, size: 15),
                      title: Text(source.kind),
                      subtitle: Text(
                        source.noteId ?? source.messageId ?? source.id,
                      ),
                    ),
                ],
              ),
        ],
      ),
    );
  }
}

final class _DigitalTwinProposalList extends StatelessWidget {
  const _DigitalTwinProposalList({required this.state, required this.onSelect});
  final ProductDigitalTwinState state;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) {
    if (state.proposals.isEmpty) {
      return const _DigitalTwinCenteredState(
        icon: LucideIcons.circleCheck,
        title: '没有待审阅修改',
        detail: '定期计划或资料沉淀产生的修改会出现在这里。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 14),
      itemCount: state.proposals.length,
      itemBuilder: (context, index) {
        final proposal = state.proposals[index];
        return ListTile(
          key: ValueKey<String>('digital-twin-proposal-${proposal.id}'),
          selected: proposal.id == state.selectedProposalId,
          onTap: () => onSelect(proposal.id),
          leading: Icon(_proposalIcon(proposal.lifecycle), size: 18),
          title: Text('修改提案 v${proposal.version}'),
          subtitle: Text(_proposalLabel(proposal.lifecycle)),
          trailing: proposal.hasChanges == false
              ? const Tooltip(
                  message: '内容没有变化',
                  child: Icon(LucideIcons.equal, size: 16),
                )
              : null,
        );
      },
    );
  }
}

final class _DigitalTwinReviewDetail extends StatelessWidget {
  const _DigitalTwinReviewDetail({
    required this.state,
    required this.onToggleHunk,
    required this.onInspectVersion,
    required this.onRevise,
    required this.onConfirm,
  });
  final ProductDigitalTwinState state;
  final ValueChanged<String> onToggleHunk;
  final ValueChanged<int> onInspectVersion;
  final VoidCallback onRevise;
  final VoidCallback onConfirm;
  @override
  Widget build(BuildContext context) {
    final proposal = state.selectedProposal;
    if (proposal == null) {
      return const _DigitalTwinCenteredState(
        icon: LucideIcons.gitPullRequest,
        title: '选择一项修改',
        detail: '审阅候选正文和逐块差异。',
      );
    }
    if (state.busyAction == 'review' && state.review == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final review = state.review;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '提案 ${proposal.id}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FilledButton.icon(
              key: const ValueKey<String>('digital-twin-confirm'),
              onPressed: state.readyProposalCount == 0 || state.isBusy
                  ? null
                  : onConfirm,
              icon: const Icon(LucideIcons.circleCheck, size: 16),
              label: Text('确认 ${state.readyProposalCount} 项'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(_proposalLabel(proposal.lifecycle)),
        if (proposal.failureCode != null) ...[
          const SizedBox(height: 6),
          Text(
            proposal.failureCode!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (review == null) ...[
          const SizedBox(height: 24),
          const Text('该提案尚未生成可审阅内容，请稍后刷新。'),
        ] else ...[
          const SizedBox(height: 16),
          if (state.selectedProposalId != null)
            _ProposalVersionPicker(
              versions: state.proposalVersions,
              currentVersion: proposal.version,
              visibleVersion: review.proposalVersion,
              enabled: !state.isBusy,
              onSelected: onInspectVersion,
            ),
          const SizedBox(height: 12),
          Text('候选内容', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          SelectionArea(
            contextMenuBuilder: HuahuoTextEditing.buildSelectableContextMenu,
            child: HuahuoMarkdown(
              source: review.candidateMarkdown,
              contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  '差异 · +${review.summary.insertedLines} '
                  '-${review.summary.deletedLines}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              OutlinedButton.icon(
                key: const ValueKey<String>('digital-twin-revise'),
                onPressed: state.canRevise && !state.isBusy ? onRevise : null,
                icon: const Icon(LucideIcons.wandSparkles, size: 16),
                label: Text(
                  state.selectedHunkIds.isEmpty
                      ? '整体修改'
                      : '修改 ${state.selectedHunkIds.length} 块',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (review.hunks.isEmpty)
            const Text('候选内容与当前内容一致。')
          else
            for (final hunk in review.hunks)
              CheckboxListTile(
                key: ValueKey<String>('digital-twin-hunk-${hunk.id}'),
                contentPadding: EdgeInsets.zero,
                value: state.selectedHunkIds.contains(hunk.id),
                onChanged:
                    state.isBusy || !state.isViewingCurrentProposalVersion
                    ? null
                    : (_) => onToggleHunk(hunk.id),
                title: Text('第 ${hunk.newStart} 行附近'),
                subtitle: Text(
                  hunk.changes
                      .map(
                        (change) =>
                            '${change.operation == 'insert' ? '+' : '-'} ${change.text}',
                      )
                      .join('\n'),
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
        ],
        if (state.confirmation case final report?) ...[
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              report.isTerminal
                  ? LucideIcons.badgeCheck
                  : LucideIcons.loaderCircle,
            ),
            title: Text(report.isTerminal ? '确认报告已就绪' : '正在确认'),
            subtitle: Text(
              '已应用 ${report.appliedCount} 项 · 失败 ${report.failedCount} 项',
            ),
            trailing: report.version == null
                ? null
                : Text(report.version!.label),
          ),
        ],
      ],
    );
  }
}

final class _ProposalVersionPicker extends StatelessWidget {
  const _ProposalVersionPicker({
    required this.versions,
    required this.currentVersion,
    required this.visibleVersion,
    required this.enabled,
    required this.onSelected,
  });
  final List<ProductProposalVersion> versions;
  final int currentVersion;
  final int visibleVersion;
  final bool enabled;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) {
    final hasVisibleVersion = versions.any(
      (version) => version.version == visibleVersion,
    );
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(visibleVersion == currentVersion ? '当前提案版本' : '历史版本 · 只读'),
        DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            key: const ValueKey<String>('digital-twin-proposal-version'),
            value: hasVisibleVersion ? visibleVersion : null,
            hint: Text('v$visibleVersion'),
            onChanged: enabled
                ? (version) {
                    if (version != null) onSelected(version);
                  }
                : null,
            items: [
              for (final version in versions)
                DropdownMenuItem<int>(
                  value: version.version,
                  child: Text(
                    'v${version.version}'
                    '${version.version == currentVersion ? ' · 当前' : ''}',
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _DigitalTwinVersionAction { preview, compare, download, restore }

final class _DigitalTwinVersions extends StatelessWidget {
  const _DigitalTwinVersions({
    required this.state,
    required this.onPreview,
    required this.onCompare,
    required this.onDownload,
    required this.onRestore,
    required this.onCloseInspection,
  });
  final ProductDigitalTwinState state;
  final ValueChanged<ProductDigitalTwinVersion> onPreview;
  final ValueChanged<ProductDigitalTwinVersion> onCompare;
  final ValueChanged<ProductDigitalTwinVersion> onDownload;
  final ValueChanged<ProductDigitalTwinVersion> onRestore;
  final VoidCallback onCloseInspection;
  @override
  Widget build(BuildContext context) {
    if (state.versions.isEmpty) {
      return const _DigitalTwinCenteredState(
        icon: LucideIcons.history,
        title: '还没有正式版本',
        detail: '确认至少一项修改后会生成首个正式版本。',
      );
    }
    return Row(
      children: [
        SizedBox(
          width: 350,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 20),
            itemCount: state.versions.length,
            itemBuilder: (context, index) {
              final version = state.versions[index];
              return ListTile(
                key: ValueKey<String>('digital-twin-version-${version.id}'),
                leading: CircleAvatar(
                  radius: 16,
                  child: Text('${version.number}'),
                ),
                title: Text(version.label),
                subtitle: Text(
                  '${_dateLabel(version.createdAt)} · 完成度 ${version.completionPercent}%',
                ),
                trailing: PopupMenuButton<_DigitalTwinVersionAction>(
                  tooltip: '版本操作',
                  onSelected: (action) => switch (action) {
                    _DigitalTwinVersionAction.preview => onPreview(version),
                    _DigitalTwinVersionAction.compare => onCompare(version),
                    _DigitalTwinVersionAction.download => onDownload(version),
                    _DigitalTwinVersionAction.restore => onRestore(version),
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: _DigitalTwinVersionAction.preview,
                      child: ListTile(
                        leading: Icon(LucideIcons.eye, size: 16),
                        title: Text('预览'),
                      ),
                    ),
                    PopupMenuItem(
                      value: _DigitalTwinVersionAction.compare,
                      enabled: state.versions.any(
                        (item) => item.number < version.number,
                      ),
                      child: const ListTile(
                        leading: Icon(LucideIcons.gitCompare, size: 16),
                        title: Text('与前版比较'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: _DigitalTwinVersionAction.download,
                      child: ListTile(
                        leading: Icon(LucideIcons.download, size: 16),
                        title: Text('下载 ZIP'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: _DigitalTwinVersionAction.restore,
                      child: ListTile(
                        leading: Icon(LucideIcons.rotateCcw, size: 16),
                        title: Text('生成恢复提案'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _VersionInspection(state: state, onClose: onCloseInspection),
        ),
      ],
    );
  }
}

final class _VersionInspection extends StatelessWidget {
  const _VersionInspection({required this.state, required this.onClose});
  final ProductDigitalTwinState state;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    if (state.busyAction == 'version' || state.busyAction == 'compare') {
      return const Center(child: CircularProgressIndicator());
    }
    final comparison = state.comparison;
    final detail = state.versionDetail;
    if (comparison == null && detail == null) {
      return const _DigitalTwinCenteredState(
        icon: LucideIcons.scanSearch,
        title: '选择版本操作',
        detail: '可预览内容、比较差异、下载归档或生成恢复提案。',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                comparison == null
                    ? detail!.version.label
                    : '${comparison.baseVersion.label} → ${comparison.version.label}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: '关闭检查',
              onPressed: onClose,
              icon: const Icon(LucideIcons.x, size: 17),
            ),
          ],
        ),
        if (comparison != null)
          for (final file in comparison.files) ...[
            const SizedBox(height: 12),
            Text(file.name, style: Theme.of(context).textTheme.titleSmall),
            Text(
              '${file.summary.hunks} 个差异块 · '
              '+${file.summary.insertedLines} -${file.summary.deletedLines}',
            ),
            for (final hunk in file.hunks)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  hunk.changes
                      .map(
                        (change) =>
                            '${change.operation == 'insert' ? '+' : '-'} ${change.text}',
                      )
                      .join('\n'),
                  contextMenuBuilder:
                      HuahuoTextEditing.buildEditableContextMenu,
                ),
              ),
          ]
        else ...[
          Text('档案结论 ${detail!.profileCount} 项'),
          Text(detail.hasPositioning ? '包含定位档案' : '不包含定位档案'),
          Text('关联提案 ${detail.proposalResultCount} 项'),
          const Divider(height: 28),
          for (final file in state.previewFiles) ...[
            Text(file.name, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            SelectionArea(
              contextMenuBuilder: HuahuoTextEditing.buildSelectableContextMenu,
              child: HuahuoMarkdown(
                source: file.markdown,
                contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
              ),
            ),
            const SizedBox(height: 18),
          ],
        ],
      ],
    );
  }
}

final class _DigitalTwinScheduleDialog extends StatefulWidget {
  const _DigitalTwinScheduleDialog({required this.schedule});
  final ProductDigitalTwinSchedule schedule;
  @override
  State<_DigitalTwinScheduleDialog> createState() =>
      _DigitalTwinScheduleDialogState();
}

final class _DigitalTwinScheduleDialogState
    extends State<_DigitalTwinScheduleDialog> {
  late bool _enabled;
  late final TextEditingController _days;
  late final TextEditingController _time;
  late final TextEditingController _timezone;
  late final TextEditingController _instruction;
  final _form = GlobalKey<FormState>();
  @override
  void initState() {
    super.initState();
    final value = widget.schedule;
    _enabled = value.enabled;
    _days = TextEditingController(text: '${value.intervalDays}');
    _time = TextEditingController(text: value.preferredLocalTime);
    _timezone = TextEditingController(text: value.timezone);
    _instruction = TextEditingController(text: value.instruction);
  }

  @override
  void dispose() {
    _days.dispose();
    _time.dispose();
    _timezone.dispose();
    _instruction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('定期更新计划'),
    content: SizedBox(
      width: 480,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
              title: const Text('启用定期更新'),
            ),
            Row(
              children: [
                Expanded(child: _field(_days, '间隔天数', _daysValidator)),
                const SizedBox(width: 10),
                Expanded(child: _field(_time, '本地时间', _timeValidator)),
              ],
            ),
            const SizedBox(height: 10),
            _field(_timezone, '时区', _timezoneValidator),
            const SizedBox(height: 10),
            TextFormField(
              key: const ValueKey<String>('digital-twin-schedule-instruction'),
              contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
              controller: _instruction,
              maxLength: 4000,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: '更新要求'),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入更新要求' : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey<String>('digital-twin-schedule-save'),
        onPressed: _save,
        child: const Text('保存'),
      ),
    ],
  );

  Widget _field(
    TextEditingController controller,
    String label,
    String? Function(String?) validator,
  ) => TextFormField(
    controller: controller,
    contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
    decoration: InputDecoration(labelText: label),
    validator: validator,
  );

  String? _daysValidator(String? value) {
    final days = int.tryParse(value ?? '');
    return days == null || days < 1 || days > 365 ? '请输入 1–365' : null;
  }

  String? _timeValidator(String? value) =>
      RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(value ?? '')
      ? null
      : '格式为 HH:mm';
  String? _timezoneValidator(String? value) =>
      value == 'UTC' ||
          RegExp(r'^[A-Za-z]+(?:/[A-Za-z0-9_+\-]+)+$').hasMatch(value ?? '')
      ? null
      : '请输入 IANA 时区';
  void _save() {
    if (_form.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      ProductDigitalTwinScheduleDraft(
        enabled: _enabled,
        intervalDays: int.parse(_days.text),
        preferredLocalTime: _time.text.trim(),
        timezone: _timezone.text.trim(),
        instruction: _instruction.text.trim(),
      ),
    );
  }
}

final class _DigitalTwinInstructionDialog extends StatefulWidget {
  const _DigitalTwinInstructionDialog();
  @override
  State<_DigitalTwinInstructionDialog> createState() =>
      _DigitalTwinInstructionDialogState();
}

final class _DigitalTwinInstructionDialogState
    extends State<_DigitalTwinInstructionDialog> {
  String _instruction = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('提出修改要求'),
    content: SizedBox(
      width: 460,
      child: TextField(
        key: const ValueKey<String>('digital-twin-revise-instruction'),
        contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
        autofocus: true,
        minLines: 3,
        maxLines: 6,
        maxLength: 4000,
        onChanged: (value) => setState(() => _instruction = value),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey<String>('digital-twin-revise-submit'),
        onPressed: _instruction.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _instruction.trim()),
        child: const Text('提交'),
      ),
    ],
  );
}

IconData _proposalIcon(ProductProposalLifecycle state) => switch (state) {
  ProductProposalLifecycle.generating ||
  ProductProposalLifecycle.applying => LucideIcons.loaderCircle,
  ProductProposalLifecycle.ready => LucideIcons.gitPullRequest,
  ProductProposalLifecycle.applied => LucideIcons.circleCheck,
  ProductProposalLifecycle.rejected => LucideIcons.circleX,
  ProductProposalLifecycle.stale => LucideIcons.triangleAlert,
  ProductProposalLifecycle.generationFailed ||
  ProductProposalLifecycle.applyFailed => LucideIcons.cloudOff,
};

String _proposalLabel(ProductProposalLifecycle state) => switch (state) {
  ProductProposalLifecycle.generating => '正在生成',
  ProductProposalLifecycle.ready => '等待确认',
  ProductProposalLifecycle.applying => '正在应用',
  ProductProposalLifecycle.applied => '已应用',
  ProductProposalLifecycle.rejected => '已拒绝',
  ProductProposalLifecycle.stale => '基线已变化',
  ProductProposalLifecycle.generationFailed => '生成失败',
  ProductProposalLifecycle.applyFailed => '应用失败',
};

String _dateLabel(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}
