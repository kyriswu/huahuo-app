import 'package:flutter/material.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

typedef DesktopWorkspaceChanged = Future<void> Function(String workspaceId);

final class DesktopWorkspaceManagementWorkspace extends StatefulWidget {
  const DesktopWorkspaceManagementWorkspace({
    required this.controller,
    this.onDefaultWorkspaceChanged,
    super.key,
  });

  final WorkspaceManagementController controller;
  final DesktopWorkspaceChanged? onDefaultWorkspaceChanged;

  @override
  State<DesktopWorkspaceManagementWorkspace> createState() =>
      _DesktopWorkspaceManagementWorkspaceState();
}

final class _DesktopWorkspaceManagementWorkspaceState
    extends State<DesktopWorkspaceManagementWorkspace> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChanged);
  }

  @override
  void didUpdateWidget(DesktopWorkspaceManagementWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleChanged);
    widget.controller.addListener(_handleChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleChanged);
    super.dispose();
  }

  void _handleChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return ColoredBox(
      key: const ValueKey<String>('desktop-workspace-management'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _WorkspaceTopBar(
            loading: state.status == WorkspaceManagementStatus.loading,
            creating: state.creating,
            onRefresh: widget.controller.reload,
            onCreate: _showCreateDialog,
          ),
          Expanded(child: _buildBody(state)),
        ],
      ),
    );
  }

  Widget _buildBody(WorkspaceManagementState state) {
    if (state.status == WorkspaceManagementStatus.idle) {
      return const Center(child: Text('登录后管理 Workspace'));
    }
    if (state.status == WorkspaceManagementStatus.loading &&
        state.workspaces.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == WorkspaceManagementStatus.failure &&
        state.workspaces.isEmpty) {
      return _WorkspaceFailure(
        message: state.errorMessage ?? 'Workspace 读取失败',
        onRetry: widget.controller.reload,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 40),
      children: [
        if (state.errorMessage != null) ...[
          _WorkspaceInlineError(message: state.errorMessage!),
          const SizedBox(height: 12),
        ],
        if (state.workspaces.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 80),
            child: Center(child: Text('还没有 Workspace，请先创建一个')),
          )
        else
          for (final (index, workspace) in state.workspaces.indexed) ...[
            _WorkspaceRow(
              workspace: workspace,
              busy: state.busyWorkspaceIds.contains(workspace.workspaceId),
              onRename: () => _showRenameDialog(workspace),
              onSetDefault: () => _setDefault(workspace),
              onDisable: () => _confirmDisable(workspace),
              onRestore: () => _restore(workspace),
            ),
            if (index < state.workspaces.length - 1) const Divider(height: 1),
          ],
      ],
    );
  }

  Future<void> _showCreateDialog() async {
    var name = '';
    var setAsDefault = true;
    final request = await showDialog<({String name, bool setAsDefault})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('创建 Workspace'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey<String>('workspace-create-name'),
                  contextMenuBuilder:
                      HuahuoTextEditing.buildEditableContextMenu,
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: '名称'),
                  onChanged: (value) => name = value,
                ),
                CheckboxListTile(
                  key: const ValueKey<String>('workspace-create-default'),
                  value: setAsDefault,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('创建后切换到此 Workspace'),
                  onChanged: (value) =>
                      setDialogState(() => setAsDefault = value ?? true),
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
              key: const ValueKey<String>('workspace-create-confirm'),
              onPressed: () {
                final trimmedName = name.trim();
                if (trimmedName.isNotEmpty) {
                  Navigator.pop(context, (
                    name: trimmedName,
                    setAsDefault: setAsDefault,
                  ));
                }
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || request == null) return;
    final succeeded = await widget.controller.create(
      displayName: request.name,
      setAsDefault: request.setAsDefault,
    );
    if (!mounted) return;
    if (succeeded && request.setAsDefault) {
      final created = widget.controller.state.workspaces
          .where((workspace) => workspace.isDefault)
          .firstOrNull;
      if (created != null) {
        await widget.onDefaultWorkspaceChanged?.call(created.workspaceId);
      }
    }
    if (mounted) _showResult(succeeded, 'Workspace 已创建');
  }

  Future<void> _showRenameDialog(ProductWorkspace workspace) async {
    var name = workspace.displayName;
    final requestedName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名 Workspace'),
        content: TextFormField(
          key: const ValueKey<String>('workspace-rename-name'),
          contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
          initialValue: workspace.displayName,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '名称'),
          onChanged: (value) => name = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('workspace-rename-confirm'),
            onPressed: () {
              final value = name.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted ||
        requestedName == null ||
        requestedName == workspace.displayName) {
      return;
    }
    final succeeded = await widget.controller.rename(
      workspace.workspaceId,
      requestedName,
    );
    if (mounted) _showResult(succeeded, 'Workspace 已重命名');
  }

  Future<void> _setDefault(ProductWorkspace workspace) async {
    final succeeded = await widget.controller.setDefault(workspace.workspaceId);
    if (!mounted) return;
    if (succeeded) {
      await widget.onDefaultWorkspaceChanged?.call(workspace.workspaceId);
    }
    if (mounted) _showResult(succeeded, '已切换 Workspace');
  }

  Future<void> _confirmDisable(ProductWorkspace workspace) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停用 Workspace'),
        content: Text('停用「${workspace.displayName}」后，可随时从此处恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('workspace-disable-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('停用'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final succeeded = await widget.controller.disable(workspace.workspaceId);
    if (mounted) _showResult(succeeded, 'Workspace 已停用');
  }

  Future<void> _restore(ProductWorkspace workspace) async {
    final succeeded = await widget.controller.restore(workspace.workspaceId);
    if (mounted) _showResult(succeeded, 'Workspace 已恢复');
  }

  void _showResult(bool succeeded, String successMessage) {
    final state = widget.controller.state;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          succeeded ? successMessage : state.errorMessage ?? 'Workspace 操作失败',
        ),
      ),
    );
  }
}

final class _WorkspaceTopBar extends StatelessWidget {
  const _WorkspaceTopBar({
    required this.loading,
    required this.creating,
    required this.onRefresh,
    required this.onCreate,
  });

  final bool loading;
  final bool creating;
  final VoidCallback onRefresh;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          const Icon(LucideIcons.panelsTopLeft, size: 17),
          const SizedBox(width: 9),
          Text('Workspace', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          IconButton(
            key: const ValueKey<String>('workspace-refresh'),
            tooltip: '刷新',
            onPressed: loading ? null : onRefresh,
            icon: const Icon(LucideIcons.refreshCw, size: 16),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const ValueKey<String>('workspace-create'),
            onPressed: creating ? null : onCreate,
            icon: const Icon(LucideIcons.plus, size: 15),
            label: Text(creating ? '正在创建' : '新建'),
          ),
        ],
      ),
    ),
  );
}

final class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow({
    required this.workspace,
    required this.busy,
    required this.onRename,
    required this.onSetDefault,
    required this.onDisable,
    required this.onRestore,
  });

  final ProductWorkspace workspace;
  final bool busy;
  final VoidCallback onRename;
  final VoidCallback onSetDefault;
  final VoidCallback onDisable;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        height: 74,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: Icon(
            workspace.isDisabled
                ? LucideIcons.archiveRestore
                : LucideIcons.panelsTopLeft,
            size: 18,
            color: colors.onSurfaceVariant,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  workspace.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (workspace.isDefault) ...[
                const SizedBox(width: 8),
                const Icon(LucideIcons.circleCheck, size: 14),
              ],
            ],
          ),
          subtitle: Text(
            workspace.isDisabled
                ? '已停用'
                : workspace.isDefault
                ? '当前默认 Workspace'
                : '可用',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          trailing: busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: ValueKey<String>(
                        'workspace-rename-${workspace.workspaceId}',
                      ),
                      tooltip: '重命名',
                      onPressed: onRename,
                      icon: const Icon(LucideIcons.pencil, size: 15),
                    ),
                    if (workspace.isDisabled)
                      TextButton(
                        key: ValueKey<String>(
                          'workspace-restore-${workspace.workspaceId}',
                        ),
                        onPressed: onRestore,
                        child: const Text('恢复'),
                      )
                    else ...[
                      if (!workspace.isDefault)
                        TextButton(
                          key: ValueKey<String>(
                            'workspace-default-${workspace.workspaceId}',
                          ),
                          onPressed: onSetDefault,
                          child: const Text('切换'),
                        ),
                      if (!workspace.isDefault)
                        IconButton(
                          key: ValueKey<String>(
                            'workspace-disable-${workspace.workspaceId}',
                          ),
                          tooltip: '停用',
                          onPressed: onDisable,
                          icon: const Icon(LucideIcons.archive, size: 15),
                        ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

final class _WorkspaceFailure extends StatelessWidget {
  const _WorkspaceFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message),
        const SizedBox(height: 12),
        TextButton.icon(
          key: const ValueKey<String>('workspace-retry'),
          onPressed: onRetry,
          icon: const Icon(LucideIcons.rotateCw, size: 15),
          label: const Text('重试'),
        ),
      ],
    ),
  );
}

final class _WorkspaceInlineError extends StatelessWidget {
  const _WorkspaceInlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey<String>('workspace-inline-error'),
    children: [
      Icon(
        LucideIcons.circleAlert,
        size: 16,
        color: Theme.of(context).colorScheme.error,
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(message)),
    ],
  );
}
