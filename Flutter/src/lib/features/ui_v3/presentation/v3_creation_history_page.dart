import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../application/creation_canvas_history_port.dart';
import '../domain/creation_canvas_history.dart';
import '../domain/ui_v3_models.dart';

final creationHistoryEntriesProvider = FutureProvider.autoDispose
    .family<List<CreationCanvasHistoryEntry>, String>(
      (ref, userScope) => Future<List<CreationCanvasHistoryEntry>>.sync(
        () => ref.watch(creationCanvasHistoryPortProvider).list(userScope),
      ),
    );

class V3CreationHistoryPage extends ConsumerStatefulWidget {
  const V3CreationHistoryPage({super.key});

  @override
  ConsumerState<V3CreationHistoryPage> createState() =>
      _V3CreationHistoryPageState();
}

class _V3CreationHistoryPageState extends ConsumerState<V3CreationHistoryPage> {
  @override
  Widget build(BuildContext context) {
    final userScope = ref.watch(authenticatedUserDataScopeProvider);
    final port = ref.watch(creationCanvasHistoryPortProvider);
    final entries = ref.watch(creationHistoryEntriesProvider(userScope));
    final colors = HuahuoV3Theme.tokensOf(context);

    return V3PageScaffold(
      title: '创作历史',
      centerTitle: true,
      fallbackRoute: '/v3/workbench',
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: entries.when(
        loading: () => const <Widget>[_HistoryLoadingState()],
        error: (_, _) => <Widget>[
          _HistoryFailureState(
            onRetry: () =>
                ref.invalidate(creationHistoryEntriesProvider(userScope)),
          ),
        ],
        data: (items) => <Widget>[
          if (items.isEmpty)
            _EmptyHistoryCard(
              onCreate: () => context.push(
                '/v3/workbench/canvas',
                extra: const CanvasEntryIntent.blank(),
              ),
            )
          else ...[
            Text(
              '共 ${items.length} 篇 · 继续编辑仅更新原始内容',
              style: HuahuoV3Theme.meta.copyWith(color: colors.muted),
            ),
            const SizedBox(height: 12),
            for (final entry in items) ...[
              _HistoryRow(
                entry: entry,
                onTap: () => _openItem(context, entry),
                onLongPress: () => _showItemActions(port, userScope, entry),
                onConfirmDelete: () => _confirmDelete(entry),
                onDeleted: () => _deleteItem(port, userScope, entry),
              ),
              const SizedBox(height: 2),
            ],
          ],
        ],
      ),
    );
  }

  void _openItem(BuildContext context, CreationCanvasHistoryEntry entry) {
    context.push(
      '/v3/workbench/canvas',
      extra: CanvasEntryIntent.history(entry.id),
    );
  }

  Future<void> _showItemActions(
    CreationCanvasHistoryPort port,
    String userScope,
    CreationCanvasHistoryEntry entry,
  ) async {
    final action = await showV3ActionSheet<String>(
      context: context,
      title: entry.title,
      items: const [
        V3ActionSheetItem(
          value: 'copy',
          icon: Icons.copy_rounded,
          label: '复制标题',
        ),
        V3ActionSheetItem(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: '删除历史记录',
          destructive: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'copy') {
      await V3TextEditing.copy(context, entry.title);
      return;
    }
    if (await _confirmDelete(entry)) _deleteItem(port, userScope, entry);
  }

  Future<bool> _confirmDelete(CreationCanvasHistoryEntry entry) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      elevation: 0,
      isScrollControlled: true,
      builder: (sheetContext) => _HistoryDeleteConfirmation(
        onCancel: () => Navigator.of(sheetContext).pop(false),
        onDelete: () => Navigator.of(sheetContext).pop(true),
      ),
    );
    return confirmed ?? false;
  }

  void _deleteItem(
    CreationCanvasHistoryPort port,
    String userScope,
    CreationCanvasHistoryEntry entry,
  ) {
    if (!port.delete(userScope, entry.id)) return;
    ref.invalidate(creationHistoryEntriesProvider(userScope));
    showV3Snack(context, '已删除创作历史');
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    required this.onConfirmDelete,
    required this.onDeleted,
  });

  final CreationCanvasHistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Future<bool> Function() onConfirmDelete;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Dismissible(
      key: ValueKey<String>('creation-history-${entry.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        final confirmed = await onConfirmDelete();
        if (confirmed) onDeleted();
        return false;
      },
      background: const SizedBox.shrink(),
      secondaryBackground: _HistorySwipeDeleteBackground(colors: colors),
      child: Semantics(
        button: true,
        label: '打开创作历史：${entry.title}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: onLongPress,
          child: Material(
            color: colors.canvas,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 15.5,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _historyExcerpt(entry),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.muted,
                        fontSize: 13,
                        height: 1.4,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 7),
                    const Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _HistoryMetaTag(label: '来源 · 外部知识'),
                        _HistoryMetaTag(label: '文件夹 · 订阅'),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        const _HistoryKindTag(),
                        const SizedBox(width: 6),
                        Text(
                          '· ${_historyTime(entry.updatedAt)}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.muted,
                            fontWeight: FontWeight.w400,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistorySwipeDeleteBackground extends StatelessWidget {
  const _HistorySwipeDeleteBackground({required this.colors});

  final HuahuoV3ThemeTokens colors;

  @override
  Widget build(BuildContext context) {
    final foreground = HuahuoV3Theme.contrastingForeground(
      colors.onPrimary,
      background: colors.danger,
    );
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        key: const ValueKey<String>('creation-history-swipe-delete'),
        width: 64,
        decoration: BoxDecoration(
          color: colors.danger,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.delete_outline_rounded, size: 22, color: foreground),
            const SizedBox(height: 8),
            Text(
              '删除',
              style: TextStyle(
                color: foreground,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryDeleteConfirmation extends StatefulWidget {
  const _HistoryDeleteConfirmation({
    required this.onCancel,
    required this.onDelete,
  });

  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  State<_HistoryDeleteConfirmation> createState() =>
      _HistoryDeleteConfirmationState();
}

class _HistoryDeleteConfirmationState
    extends State<_HistoryDeleteConfirmation> {
  var _deleting = false;

  Future<void> _delete() async {
    if (_deleting) return;
    setState(() => _deleting = true);
    await Future<void>.delayed(V3FeedbackTimingTokens.destructiveConfirmation);
    if (mounted) widget.onDelete();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final dangerForeground = HuahuoV3Theme.contrastingForeground(
      colors.onPrimary,
      background: colors.danger,
    );
    return Material(
      key: const ValueKey<String>('creation-history-delete-confirmation'),
      color: colors.canvas,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.muted.withValues(alpha: .36),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '删除这篇创作？',
                style: TextStyle(
                  fontSize: 20,
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '删除后将无法恢复，原文内容不会受到影响。',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 14,
                  height: 1.55,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey<String>(
                        'creation-history-delete-cancel',
                      ),
                      onPressed: _deleting ? null : widget.onCancel,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey<String>(
                        'creation-history-delete-confirm',
                      ),
                      onPressed: _deleting ? null : _delete,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        backgroundColor: colors.danger,
                        foregroundColor: dangerForeground,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _deleting
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox.square(
                                  dimension: 17,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: dangerForeground,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text('正在删除...'),
                              ],
                            )
                          : const Text('删除'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryKindTag extends StatelessWidget {
  const _HistoryKindTag();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: colors.surfaceMuted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          '自由创作',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colors.text,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _HistoryMetaTag extends StatelessWidget {
  const _HistoryMetaTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          label,
          style: TextStyle(fontSize: 10.5, color: colors.muted),
        ),
      ),
    );
  }
}

class _HistoryLoadingState extends StatelessWidget {
  const _HistoryLoadingState();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: 150),
      child: Column(
        children: [
          CircularProgressIndicator(color: colors.muted, strokeWidth: 2),
          const SizedBox(height: 14),
          Text('正在加载创作历史...', style: TextStyle(color: colors.muted)),
        ],
      ),
    );
  }
}

class _HistoryFailureState extends StatelessWidget {
  const _HistoryFailureState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: 120),
      child: Column(
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: colors.muted),
          const SizedBox(height: 14),
          const Text(
            '加载失败',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text('网络开小差了，请稍后重试', style: TextStyle(color: colors.muted)),
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const ValueKey<String>('creation-history-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新加载'),
          ),
        ],
      ),
    );
  }
}

class _EmptyHistoryCard extends StatelessWidget {
  const _EmptyHistoryCard({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.history_toggle_off_rounded,
              size: 44,
              color: colors.muted,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有创作历史',
              style: TextStyle(
                color: colors.text,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '自由创作保存成功后会出现在这里',
              style: TextStyle(fontSize: 13, color: colors.muted),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: const Text('开始创作'),
            ),
          ],
        ),
      ),
    );
  }
}

String _historyTime(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _historyExcerpt(CreationCanvasHistoryEntry entry) {
  final value = entry.markdown.trim().replaceAll('\n', ' ');
  return value.isEmpty ? '继续完善这篇创作。' : value;
}
