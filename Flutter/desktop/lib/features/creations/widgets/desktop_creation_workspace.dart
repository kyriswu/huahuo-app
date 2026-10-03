import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/desktop_theme.dart';

typedef DesktopCreationProposalRequested =
    void Function(ProductCreationDocument document);

final class DesktopCreationWorkspace extends StatefulWidget {
  const DesktopCreationWorkspace({
    required this.workspaceId,
    required this.repository,
    required this.onOpenProposals,
    super.key,
  });

  final String? workspaceId;
  final ProductCreationsRepository repository;
  final DesktopCreationProposalRequested onOpenProposals;

  @override
  State<DesktopCreationWorkspace> createState() =>
      _DesktopCreationWorkspaceState();
}

final class _DesktopCreationWorkspaceState
    extends State<DesktopCreationWorkspace> {
  late ProductCreationsController _controller;
  final _title = TextEditingController();
  final _markdown = TextEditingController();
  bool _showTrash = false;
  bool _syncingDraft = false;
  String? _renderedDocumentId;
  String? _renderedRevisionId;

  @override
  void initState() {
    super.initState();
    _title.addListener(_titleChanged);
    _markdown.addListener(_markdownChanged);
    _createController();
  }

  @override
  void didUpdateWidget(DesktopCreationWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository)) {
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
    _controller = ProductCreationsController(widget.repository)
      ..addListener(_changed);
    unawaited(_controller.bindWorkspace(widget.workspaceId));
  }

  void _changed() {
    if (!mounted) return;
    final document = _controller.state.document;
    if (document == null) {
      _renderedDocumentId = null;
      _renderedRevisionId = null;
      _setDraftText('', '');
    } else if (_renderedDocumentId != document.summary.id ||
        _renderedRevisionId != document.summary.revisionId) {
      _renderedDocumentId = document.summary.id;
      _renderedRevisionId = document.summary.revisionId;
      _setDraftText(
        _controller.state.titleDraft,
        _controller.state.markdownDraft,
      );
    }
    setState(() {});
  }

  void _setDraftText(String title, String markdown) {
    _syncingDraft = true;
    if (_title.text != title) _title.text = title;
    if (_markdown.text != markdown) _markdown.text = markdown;
    _syncingDraft = false;
  }

  void _titleChanged() {
    if (!_syncingDraft) _controller.updateTitle(_title.text);
  }

  void _markdownChanged() {
    if (!_syncingDraft) _controller.updateMarkdown(_markdown.text);
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    _title
      ..removeListener(_titleChanged)
      ..dispose();
    _markdown
      ..removeListener(_markdownChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return ColoredBox(
      key: const ValueKey<String>('desktop-creation-workspace'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _CreationTopBar(
            loading: state.status == ProductCreationsStatus.loading,
            busy: state.busyAction != null,
            onRefresh: _controller.reload,
            onCreate: _showCreateDialog,
          ),
          if (state.errorMessage != null && state.items.isNotEmpty)
            _InlineFailure(
              message: state.errorMessage!,
              retryable: state.retryable,
              onRetry: state.selectedId == null
                  ? _controller.reload
                  : () => _controller.select(state.selectedId!),
            ),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  Widget _body(ProductCreationsState state) {
    if (state.status == ProductCreationsStatus.idle) {
      return const _CenteredState(
        icon: LucideIcons.lockKeyhole,
        title: 'Workspace 尚未就绪',
        detail: '登录并选择 Workspace 后开始云端创作。',
      );
    }
    if (state.status == ProductCreationsStatus.loading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ProductCreationsStatus.failure && state.items.isEmpty) {
      return _CenteredState(
        icon: LucideIcons.cloudOff,
        title: '创作历史加载失败',
        detail: state.errorMessage ?? '暂时无法读取云端创作。',
        action: OutlinedButton.icon(
          key: const ValueKey<String>('creation-retry'),
          onPressed: _controller.reload,
          icon: const Icon(LucideIcons.refreshCw, size: 16),
          label: const Text('重试'),
        ),
      );
    }
    if (state.items.isEmpty) {
      return _CenteredState(
        icon: LucideIcons.filePenLine,
        title: '还没有云端创作',
        detail: '新建一篇创作后，可在桌面端持续编辑、查看版本并发起提案。',
        action: FilledButton.icon(
          key: const ValueKey<String>('creation-empty-create'),
          onPressed: _showCreateDialog,
          icon: const Icon(LucideIcons.plus, size: 16),
          label: const Text('新建创作'),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 780;
        final list = _CreationList(
          controller: _controller,
          state: state,
          showTrash: _showTrash,
          onTrashChanged: (value) => setState(() => _showTrash = value),
        );
        final editor = _CreationEditor(
          state: state,
          titleController: _title,
          markdownController: _markdown,
          onSave: _save,
          onDiscard: _discard,
          onVersions: _showVersions,
          onProposals: _openProposals,
          onDelete: _confirmDelete,
          onRestore: _restore,
        );
        if (compact) {
          if (state.selectedId == null) return list;
          return Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey<String>('creation-back'),
                  onPressed: _controller.resetSelectionForView,
                  icon: const Icon(LucideIcons.arrowLeft, size: 16),
                  label: const Text('创作列表'),
                ),
              ),
              Expanded(child: editor),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 300, child: list),
            VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
            Expanded(child: editor),
          ],
        );
      },
    );
  }

  Future<void> _showCreateDialog() async {
    var title = '';
    var markdown = '';
    final request = await showDialog<({String title, String markdown})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建创作'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey<String>('creation-new-title'),
                contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
                autofocus: true,
                maxLength: 300,
                decoration: const InputDecoration(labelText: '标题'),
                onChanged: (value) => title = value,
              ),
              TextField(
                key: const ValueKey<String>('creation-new-content'),
                contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(labelText: '初稿（可选）'),
                onChanged: (value) => markdown = value,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('creation-new-confirm'),
            onPressed: () {
              final normalized = title.trim();
              if (normalized.isNotEmpty) {
                Navigator.pop(context, (title: normalized, markdown: markdown));
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (!mounted || request == null) return;
    final succeeded = await _controller.create(
      title: request.title,
      rawMarkdown: request.markdown,
    );
    if (mounted) _showResult(succeeded, '创作已创建');
  }

  Future<void> _save() async {
    final succeeded = await _controller.save();
    if (mounted) _showResult(succeeded, '创作已保存');
  }

  void _discard() {
    _controller.discardEdits();
    final state = _controller.state;
    _setDraftText(state.titleDraft, state.markdownDraft);
  }

  void _openProposals() {
    final document = _controller.state.document;
    if (document != null) widget.onOpenProposals(document);
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除创作'),
        content: const Text('创作将移入回收站，可从创作列表恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('creation-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final succeeded = await _controller.deleteSelected();
    if (mounted) _showResult(succeeded, '创作已移入回收站');
  }

  Future<void> _restore() async {
    final succeeded = await _controller.restoreSelected();
    if (mounted) _showResult(succeeded, '创作已恢复');
  }

  Future<void> _showVersions() async {
    await _controller.loadRevisions();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('正文版本'),
        content: SizedBox(
          width: 620,
          height: 420,
          child: _RevisionList(state: _controller.state),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showResult(bool succeeded, String successMessage) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          succeeded
              ? successMessage
              : _controller.state.errorMessage ?? '创作操作失败',
        ),
      ),
    );
  }
}

final class _CreationTopBar extends StatelessWidget {
  const _CreationTopBar({
    required this.loading,
    required this.busy,
    required this.onRefresh,
    required this.onCreate,
  });

  final bool loading;
  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          const Icon(LucideIcons.filePenLine, size: 17),
          const SizedBox(width: 9),
          Text('创作', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          IconButton(
            key: const ValueKey<String>('creation-refresh'),
            tooltip: '刷新创作',
            onPressed: loading || busy ? null : onRefresh,
            icon: loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refreshCw, size: 16),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const ValueKey<String>('creation-create'),
            onPressed: busy ? null : onCreate,
            icon: const Icon(LucideIcons.plus, size: 16),
            label: const Text('新建'),
          ),
        ],
      ),
    ),
  );
}

final class _CreationList extends StatelessWidget {
  const _CreationList({
    required this.controller,
    required this.state,
    required this.showTrash,
    required this.onTrashChanged,
  });

  final ProductCreationsController controller;
  final ProductCreationsState state;
  final bool showTrash;
  final ValueChanged<bool> onTrashChanged;

  @override
  Widget build(BuildContext context) {
    final items = state.items
        .where((item) => item.isTrashed == showTrash)
        .toList(growable: false);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: SegmentedButton<bool>(
            key: const ValueKey<String>('creation-lifecycle-filter'),
            segments: const [
              ButtonSegment(value: false, label: Text('创作中')),
              ButtonSegment(value: true, label: Text('回收站')),
            ],
            selected: {showTrash},
            showSelectedIcon: false,
            onSelectionChanged: (value) => onTrashChanged(value.single),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(child: Text(showTrash ? '回收站为空' : '暂无进行中的创作'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        key: ValueKey<String>('creation-item-${item.id}'),
                        selected: item.id == state.selectedId,
                        leading: Icon(
                          item.isTrashed
                              ? LucideIcons.trash2
                              : LucideIcons.fileText,
                          size: 17,
                        ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('版本 ${item.revision}'),
                        trailing: const Icon(
                          LucideIcons.chevronRight,
                          size: 15,
                        ),
                        onTap: () => controller.select(item.id),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

final class _CreationEditor extends StatelessWidget {
  const _CreationEditor({
    required this.state,
    required this.titleController,
    required this.markdownController,
    required this.onSave,
    required this.onDiscard,
    required this.onVersions,
    required this.onProposals,
    required this.onDelete,
    required this.onRestore,
  });

  final ProductCreationsState state;
  final TextEditingController titleController;
  final TextEditingController markdownController;
  final VoidCallback onSave;
  final VoidCallback onDiscard;
  final VoidCallback onVersions;
  final VoidCallback onProposals;
  final VoidCallback onDelete;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    if (state.selectedId == null) {
      return const _CenteredState(
        icon: LucideIcons.panelRightOpen,
        title: '选择一篇创作',
        detail: '编辑正文、查看历史版本或发起文档变更提案。',
      );
    }
    if (state.detailStatus == ProductCreationDetailStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.detailStatus == ProductCreationDetailStatus.failure ||
        state.document == null) {
      return _CenteredState(
        icon: LucideIcons.triangleAlert,
        title: '创作内容加载失败',
        detail: state.errorMessage ?? '请重试。',
      );
    }
    final busy = state.busyAction != null;
    final trashed = state.document!.summary.isTrashed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('creation-title'),
                  contextMenuBuilder:
                      HuahuoTextEditing.buildEditableContextMenu,
                  controller: titleController,
                  readOnly: trashed || busy,
                  maxLength: 300,
                  decoration: const InputDecoration(
                    hintText: '创作标题',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                key: const ValueKey<String>('creation-versions'),
                tooltip: '查看版本',
                onPressed: busy ? null : onVersions,
                icon: const Icon(LucideIcons.history, size: 17),
              ),
              if (trashed)
                FilledButton.icon(
                  key: const ValueKey<String>('creation-restore'),
                  onPressed: busy ? null : onRestore,
                  icon: const Icon(LucideIcons.archiveRestore, size: 16),
                  label: const Text('恢复'),
                )
              else ...[
                IconButton(
                  key: const ValueKey<String>('creation-delete'),
                  tooltip: '移入回收站',
                  onPressed: busy ? null : onDelete,
                  icon: const Icon(LucideIcons.trash2, size: 17),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('creation-proposals'),
                  onPressed: busy ? null : onProposals,
                  icon: const Icon(LucideIcons.gitCompareArrows, size: 16),
                  label: const Text('提案'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const ValueKey<String>('creation-discard'),
                  onPressed: !busy && state.isDirty ? onDiscard : null,
                  child: const Text('放弃'),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  key: const ValueKey<String>('creation-save'),
                  onPressed: !busy && state.isDirty ? onSave : null,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(LucideIcons.save, size: 16),
                  label: const Text('保存'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: TextField(
              key: const ValueKey<String>('creation-markdown'),
              contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
              controller: markdownController,
              readOnly: trashed || busy,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                hintText: '用 Markdown 写下正文…',
                alignLabelWithHint: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _RevisionList extends StatelessWidget {
  const _RevisionList({required this.state});

  final ProductCreationsState state;

  @override
  Widget build(BuildContext context) {
    if (state.revisionsStatus == ProductCreationRevisionsStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.revisionsStatus == ProductCreationRevisionsStatus.failure) {
      return Center(child: Text(state.errorMessage ?? '版本读取失败'));
    }
    if (state.revisions.isEmpty) return const Center(child: Text('暂无版本'));
    return ListView.separated(
      itemCount: state.revisions.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final revision = state.revisions[index];
        return DesktopDisclosureTile(
          key: ValueKey<String>('creation-revision-${revision.id}'),
          title: Text('版本 ${revision.revision}'),
          subtitle: Text(_dateLabel(revision.createdAt)),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SelectionArea(
                contextMenuBuilder:
                    HuahuoTextEditing.buildSelectableContextMenu,
                child: HuahuoMarkdown(
                  source: revision.markdown.isEmpty
                      ? '（空内容）'
                      : revision.markdown,
                  contextMenuBuilder:
                      HuahuoTextEditing.buildEditableContextMenu,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

final class _InlineFailure extends StatelessWidget {
  const _InlineFailure({
    required this.message,
    required this.retryable,
    required this.onRetry,
  });

  final String message;
  final bool retryable;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => MaterialBanner(
    content: Text(message),
    leading: const Icon(LucideIcons.triangleAlert, size: 18),
    actions: [
      if (retryable)
        TextButton(onPressed: onRetry, child: const Text('重试'))
      else
        const SizedBox.shrink(),
    ],
  );
}

final class _CenteredState extends StatelessWidget {
  const _CenteredState({
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
  );
}

String _dateLabel(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
