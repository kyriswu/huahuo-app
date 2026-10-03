import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../application/knowledge_library_controller.dart';
import '../application/subscription_port.dart';
import '../domain/v3_deposit_models.dart';

// resident-provider: Keeps the v3 local distillation queue value consistent across sibling route consumers.
final v3LocalDistillationQueueProvider = Provider<Set<String>>(
  (ref) => ref.watch(digitalTwinMaterialControllerProvider).pendingNoteIds,
);

Future<bool> queueV3LocalDistillation(WidgetRef ref, String noteId) {
  final normalized = noteId.trim();
  if (normalized.isEmpty) return Future.value(false);
  final note = ref
      .read(knowledgeLibraryControllerProvider)
      .noteForId(normalized);
  if (note?.isReadOnly == true) return Future.value(false);
  return ref
      .read(digitalTwinMaterialControllerProvider)
      .enqueue(
        referenceId: normalized,
        title: note?.title ?? '待同步笔记',
        revisionHint: note?.rawPartRevisionId ?? '',
      );
}

Future<void> showV3DistillationHelpSheet(BuildContext context) {
  return showV3GlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) =>
        _V3DistillationHelpSheet(onClose: () => Navigator.pop(sheetContext)),
  );
}

Future<bool> showV3DistillationFlow({
  required BuildContext context,
  required WidgetRef ref,
  required String noteId,
}) async {
  final confirmed = await showV3GlassBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _V3DistillationConfirmSheet(
      onHelp: () => showV3DistillationHelpSheet(sheetContext),
      onConfirm: () => Navigator.pop(sheetContext, true),
      onCancel: () => Navigator.pop(sheetContext, false),
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  final queued = await queueV3LocalDistillation(ref, noteId);
  if (!context.mounted) return queued;
  if (!queued) {
    final note = ref
        .read(knowledgeLibraryControllerProvider)
        .noteForId(noteId.trim());
    showV3Snack(
      context,
      note?.isReadOnly == true ? '该笔记为只读内容，请先保存为自己的笔记后再蒸馏' : '本地材料队列保存失败，请重试',
    );
    return false;
  }
  await showV3GlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) =>
        _V3DistillationQueuedSheet(onClose: () => Navigator.pop(sheetContext)),
  );
  return true;
}

Future<V3DepositRecord?> showV3DepositPicker(
  BuildContext context, {
  required String contentId,
  bool enableDistillation = false,
}) {
  return showV3GlassBottomSheet<V3DepositRecord>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _V3DepositPickerSheet(
      contentId: contentId,
      enableDistillation: enableDistillation,
    ),
  );
}

class _V3DepositPickerSheet extends ConsumerStatefulWidget {
  const _V3DepositPickerSheet({
    required this.contentId,
    required this.enableDistillation,
  });

  final String contentId;
  final bool enableDistillation;

  @override
  ConsumerState<_V3DepositPickerSheet> createState() =>
      _V3DepositPickerSheetState();
}

class _V3DepositPickerSheetState extends ConsumerState<_V3DepositPickerSheet> {
  String? _selectedFolderId;
  bool _selectionInitialized = false;
  bool _saving = false;
  bool _distillToTwin = false;

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(knowledgeLibraryControllerProvider);
    final note = library.noteForId(widget.contentId);
    final existing = library.depositRecordFor(widget.contentId);
    final folders = library.depositFolders.toList(growable: false)
      ..sort((left, right) {
        final byPath = library
            .depositFolderPath(left.id)
            .compareTo(library.depositFolderPath(right.id));
        return byPath != 0 ? byPath : left.id.compareTo(right.id);
      });
    if (!_selectionInitialized) {
      _selectedFolderId = existing?.folderId;
      _selectionInitialized = true;
    }
    if (note == null) {
      return const SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('该内容已不在外部世界中。'),
        ),
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '保存到我的资产',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('deposit-picker-create-folder'),
                    onPressed: () => _createFolder(context, ref),
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                    label: const Text('新建'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                note.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: HuahuoV3Theme.tokensOf(context).muted,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '保存位置',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _DepositDestinationRow(
                      key: const ValueKey('deposit-picker-folder-unclassified'),
                      icon: Icons.inbox_outlined,
                      label: '未分类',
                      selected: _selectedFolderId == null,
                      onTap: () => setState(() => _selectedFolderId = null),
                    ),
                    for (final folder in folders)
                      _DepositDestinationRow(
                        key: ValueKey('deposit-picker-folder-${folder.id}'),
                        icon: Icons.folder_outlined,
                        label: folder.name,
                        subtitle: folder.parentFolderId == null
                            ? null
                            : library.depositFolderPath(folder.id),
                        horizontalInset:
                            16.0 * library.depositFolderDepth(folder.id),
                        selected: _selectedFolderId == folder.id,
                        onTap: () =>
                            setState(() => _selectedFolderId = folder.id),
                      ),
                  ],
                ),
              ),
              if (widget.enableDistillation) ...[
                const SizedBox(height: 12),
                _V3DistillationOption(
                  checked: _distillToTwin,
                  onChanged: (value) => setState(() => _distillToTwin = value),
                  onHelp: () => showV3DistillationHelpSheet(context),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('deposit-picker-confirm'),
                  onPressed: _saving ? null : _confirm,
                  child: _saving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(existing == null ? '确认沉淀' : '确认移动'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createFolder(BuildContext context, WidgetRef ref) async {
    final name = await showV3TextInputDialog(
      context: context,
      title: '创建文件夹',
      initialValue: '',
      label: '文件夹名称',
      confirmLabel: '创建',
      maxLength: 40,
      inputKey: const ValueKey('deposit-picker-folder-name'),
      validator: (value) => value.isEmpty ? '请输入文件夹名称' : null,
    );
    if (name == null || !context.mounted) return;
    final library = ref.read(knowledgeLibraryControllerProvider);
    final result = await library.createWorkspaceDepositFolder(name);
    if (!context.mounted) return;
    final folder = result.data;
    if (!result.isSuccess || folder == null) {
      showV3Snack(context, _workspaceFolderFailureMessage(result.errorCode));
      return;
    }
    setState(() => _selectedFolderId = folder.id);
    showV3Snack(context, '已创建文件夹');
  }

  Future<void> _confirm() async {
    if (_saving) return;
    final library = ref.read(knowledgeLibraryControllerProvider);
    final note = library.noteForId(widget.contentId);
    if (note == null) {
      showV3Snack(context, '该内容已不存在，无法沉淀');
      return;
    }
    if (note.isReadOnly && !library.canDepositReadOnlyContent(note.id)) {
      showV3Snack(context, '当前内容不支持沉淀到资产');
      return;
    }
    setState(() => _saving = true);
    try {
      V3DepositRecord? assigned;
      String? depositedContentId;
      if (note.isReadOnly && note.articleId != null) {
        final saved = await library.saveRemoteSubscriptionArticle(note.id);
        if (!mounted) return;
        final savedNote = saved.item;
        if (saved.status != MobileSubscriptionResultStatus.success ||
            savedNote == null ||
            savedNote.remoteNoteId == null ||
            savedNote.rawPartRevisionId == null) {
          showV3Snack(context, '云端沉淀失败，请稍后重试');
          return;
        }
        final placement = await library.moveDepositContentToWorkspaceFolder(
          contentId: savedNote.id,
          folderId: _selectedFolderId,
        );
        if (!mounted) return;
        if (!placement.isSuccess || placement.data == null) {
          showV3Snack(
            context,
            _workspaceFolderFailureMessage(placement.errorCode),
          );
          return;
        }
        assigned = placement.data;
        depositedContentId = savedNote.id;
      } else if (note.isReadOnly) {
        final snapshot = library.depositSubscribedSnapshot(
          widget.contentId,
          folderId: _selectedFolderId,
        );
        assigned = snapshot == null
            ? null
            : library.depositRecordFor(snapshot.id);
        depositedContentId = snapshot?.id;
      } else {
        final placement = await library.moveDepositContentToWorkspaceFolder(
          contentId: widget.contentId,
          folderId: _selectedFolderId,
        );
        if (!mounted) return;
        if (!placement.isSuccess || placement.data == null) {
          showV3Snack(
            context,
            _workspaceFolderFailureMessage(placement.errorCode),
          );
          return;
        }
        assigned = placement.data;
        depositedContentId = note.id;
      }
      if (assigned == null) {
        showV3Snack(
          context,
          library.depositPersistenceErrorCode == null
              ? '无法更新沉淀位置'
              : '沉淀位置保存失败，请重试',
        );
        return;
      }
      if (_distillToTwin && depositedContentId != null) {
        final queued = await queueV3LocalDistillation(ref, depositedContentId);
        if (!mounted) return;
        if (!queued) {
          showV3Snack(context, '内容已保存，但蒸馏排队未保存，请重试');
          return;
        }
      }
      Navigator.of(context).pop(assigned);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class V3DigitalTwinDistillationOption extends StatelessWidget {
  const V3DigitalTwinDistillationOption({
    required this.checked,
    required this.onChanged,
    this.optionKey = const ValueKey('deposit-distillation-option'),
    super.key,
  });

  final bool checked;
  final ValueChanged<bool>? onChanged;
  final Key optionKey;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final violet = dark ? const Color(0xffc9b8ee) : const Color(0xff6b5791);
    final surface = HuahuoV3Theme.semanticSurface(
      violet,
      colors.canvas,
      opacity: dark ? .18 : .1,
    );
    return Material(
      key: optionKey,
      color: surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!checked),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 22,
                  child: Checkbox(
                    value: checked,
                    onChanged: onChanged == null
                        ? null
                        : (value) => onChanged!(value ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(color: violet.withValues(alpha: .38)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '蒸馏到我的数字孪生',
                        style: TextStyle(
                          color: violet,
                          fontSize: 14,
                          height: 20 / 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '自动学习其中的观点、方法与人生故事',
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 11,
                          height: 17 / 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class V3DigitalTwinDistillationHelpLink extends StatelessWidget {
  const V3DigitalTwinDistillationHelpLink({
    required this.onTap,
    this.helpKey = const ValueKey('deposit-distillation-help'),
    super.key,
  });

  final VoidCallback onTap;
  final Key helpKey;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final violet = dark ? const Color(0xffc9b8ee) : const Color(0xff6b5791);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: helpKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Icon(Icons.psychology_alt_outlined, size: 20, color: violet),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '什么叫蒸馏到数字孪生？',
                    style: TextStyle(
                      color: violet,
                      fontSize: 13,
                      height: 20 / 13,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 20, color: violet),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _V3DistillationOption extends StatelessWidget {
  const _V3DistillationOption({
    required this.checked,
    required this.onChanged,
    required this.onHelp,
  });

  final bool checked;
  final ValueChanged<bool> onChanged;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        V3DigitalTwinDistillationOption(checked: checked, onChanged: onChanged),
        V3DigitalTwinDistillationHelpLink(onTap: onHelp),
      ],
    );
  }
}

class _V3DistillationConfirmSheet extends StatelessWidget {
  const _V3DistillationConfirmSheet({
    required this.onHelp,
    required this.onConfirm,
    required this.onCancel,
  });

  final VoidCallback onHelp;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => V3SheetScaffold(
    maxHeightFactor: .9,
    child: Flexible(
      fit: FlexFit.loose,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 16, bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.psychology_alt_outlined, size: 34),
            const SizedBox(height: 10),
            const Text(
              '蒸馏到数字孪生',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              '系统会从这篇笔记中提取知识、观点与方法；如果包含与你相关的经历，也会整理为人生故事。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 14),
            const ListTile(
              leading: Icon(Icons.check_circle_rounded),
              title: Text('蒸馏到我的数字孪生'),
              subtitle: Text('自动学习其中的观点、方法与人生故事'),
            ),
            ListTile(
              key: const ValueKey('distillation-confirm-help'),
              leading: const Icon(Icons.help_outline_rounded),
              title: const Text('什么叫蒸馏到数字孪生？'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onHelp,
            ),
            const SizedBox(height: 10),
            FilledButton(
              key: const ValueKey('distillation-confirm'),
              onPressed: onConfirm,
              child: const Text('开始蒸馏'),
            ),
            TextButton(onPressed: onCancel, child: const Text('暂不蒸馏')),
          ],
        ),
      ),
    ),
  );
}

class _V3DistillationQueuedSheet extends StatelessWidget {
  const _V3DistillationQueuedSheet({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => V3SheetScaffold(
    maxHeightFactor: .9,
    child: Flexible(
      fit: FlexFit.loose,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.auto_awesome_rounded, size: 38),
            const SizedBox(height: 12),
            const Text(
              '已加入蒸馏队列',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              '材料已保存到当前账号的待确认列表。前往数字孪生确认后才会生成候选，正式内容仍需另行审核确认。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 18),
            FilledButton(
              key: const ValueKey('distillation-queued-done'),
              onPressed: onClose,
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _V3DistillationHelpSheet extends StatelessWidget {
  const _V3DistillationHelpSheet({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => V3SheetScaffold(
    maxHeightFactor: .9,
    child: Flexible(
      fit: FlexFit.loose,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 16, bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.psychology_alt_outlined, size: 34),
            const SizedBox(height: 10),
            const Text(
              '什么叫蒸馏到数字孪生？',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              '开启后，系统会从这篇笔记中提取可复用的知识、观点与方法，并写入你的数字孪生。\n\n如果内容包含与你相关的经历，也会整理为人生故事。数字孪生会持续学习这些内容，用于后续理解、创作与回答。',
              style: TextStyle(fontSize: 14, height: 1.55),
            ),
            const SizedBox(height: 12),
            const _V3DistillationHelpRow(
              icon: Icons.timeline_rounded,
              title: '人生故事',
              subtitle: '重要经历与关键转折',
            ),
            const _V3DistillationHelpRow(
              icon: Icons.visibility_outlined,
              title: '观点与观察',
              subtitle: '判断、立场与长期观察',
            ),
            const _V3DistillationHelpRow(
              icon: Icons.account_tree_outlined,
              title: '方法与流程',
              subtitle: '可重复使用的做事方法',
            ),
            const SizedBox(height: 8),
            const Text(
              '仅处理本次保存的内容，可随时在数字孪生中查看和修订。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('distillation-help-done'),
              onPressed: onClose,
              child: const Text('我知道了'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _V3DistillationHelpRow extends StatelessWidget {
  const _V3DistillationHelpRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
  );
}

class _DepositDestinationRow extends StatelessWidget {
  const _DepositDestinationRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.horizontalInset = 0,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final double horizontalInset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return ListTile(
      contentPadding: EdgeInsets.only(left: horizontalInset),
      leading: Icon(icon, color: selected ? colors.accent : colors.ink),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: selected
          ? Icon(
              Icons.check_circle_rounded,
              key: const ValueKey('deposit-picker-selected-check'),
              color: colors.accent,
            )
          : null,
      onTap: onTap,
    );
  }
}

String _workspaceFolderFailureMessage(String? errorCode) => switch (errorCode) {
  'WORKSPACE_FOLDER_NAME_INVALID' => '文件夹名称无效或已存在',
  'WORKSPACE_NOTE_SYNC_REQUIRED' => '笔记正在同步，完成后可移动到文件夹',
  'PRECONDITION_FAILED' || 'NOTE_BATCH_MOVE_CONFLICT' => '内容已在其他设备更新，已刷新后重试',
  'WORKSPACE_CONTEXT_UNAVAILABLE' ||
  'WORKSPACE_FOLDER_UNAVAILABLE' => '云端工作空间尚未就绪',
  _ => '云端目录操作失败，请重试',
};
