import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../application/canvas_interaction_policy.dart';
import '../domain/canvas_ai_models.dart';

final class V3CanvasEditingModeSwitch extends StatelessWidget {
  const V3CanvasEditingModeSwitch({
    required this.value,
    required this.onChanged,
    this.onBlocked,
    super.key,
  });

  final CanvasEditingMode value;
  final ValueChanged<CanvasEditingMode>? onChanged;
  final VoidCallback? onBlocked;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final enabled = onChanged != null;
    return SizedBox(
      key: const ValueKey<String>('canvas-editing-mode-switch'),
      width: 116,
      height: HuahuoControlSize.iconComfortable,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: '编辑模式选择',
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: enabled ? 1 : .48,
          child: Material(
            color: tokens.surfaceMuted,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HuahuoRadius.control),
              side: BorderSide(color: tokens.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                Expanded(
                  child: KeyedSubtree(
                    key: const ValueKey<String>('canvas-edit-mode'),
                    child: _CanvasEditingModeSegment(
                      label: '编辑',
                      selected: value == CanvasEditingMode.edit,
                      enabled: enabled,
                      onPressed: () => onChanged?.call(CanvasEditingMode.edit),
                      onBlocked: onBlocked,
                    ),
                  ),
                ),
                Expanded(
                  child: KeyedSubtree(
                    key: const ValueKey<String>('canvas-ai-tools'),
                    child: _CanvasEditingModeSegment(
                      label: 'AI',
                      selected: value == CanvasEditingMode.ai,
                      enabled: enabled,
                      onPressed: () => onChanged?.call(CanvasEditingMode.ai),
                      onBlocked: onBlocked,
                    ),
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

final class V3CanvasSaveStatusLabel extends StatelessWidget {
  const V3CanvasSaveStatusLabel({required this.indicator, super.key});

  final CanvasSaveIndicator indicator;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final presentation = switch (indicator) {
      CanvasSaveIndicator.none => _CanvasSavePresentation(
        label: '尚无本地草稿',
        icon: Icons.edit_note_rounded,
        color: tokens.muted,
      ),
      CanvasSaveIndicator.localDraft => _CanvasSavePresentation(
        label: '草稿已存本机',
        icon: Icons.save_outlined,
        color: tokens.muted,
      ),
      CanvasSaveIndicator.unsavedChanges => _CanvasSavePresentation(
        label: '修改未保存',
        icon: Icons.edit_note_rounded,
        color: tokens.accent,
      ),
      CanvasSaveIndicator.cloudSaved => _CanvasSavePresentation(
        label: '已保存',
        icon: Icons.cloud_done_outlined,
        color: tokens.success,
      ),
      CanvasSaveIndicator.saving => _CanvasSavePresentation(
        label: '正在保存',
        icon: Icons.cloud_upload_outlined,
        color: tokens.accent,
        busy: true,
      ),
      CanvasSaveIndicator.recoveryPending => _CanvasSavePresentation(
        label: '待完成保存',
        icon: Icons.pending_actions_outlined,
        color: tokens.accent,
      ),
      CanvasSaveIndicator.localWriteFailed => _CanvasSavePresentation(
        label: '本地保存失败',
        icon: Icons.cloud_off_outlined,
        color: tokens.danger,
      ),
    };
    final compactLabel = switch (indicator) {
      CanvasSaveIndicator.none => '尚未存储',
      CanvasSaveIndicator.localWriteFailed => '保存失败',
      CanvasSaveIndicator.localDraft => '本机',
      CanvasSaveIndicator.unsavedChanges => '未保存',
      CanvasSaveIndicator.cloudSaved => '已存',
      CanvasSaveIndicator.saving => '保存中',
      CanvasSaveIndicator.recoveryPending => '待续',
    };
    return Semantics(
      key: const ValueKey<String>('canvas-save-indicator'),
      container: true,
      liveRegion: true,
      label: presentation.label,
      child: ExcludeSemantics(
        child: Tooltip(
          message: presentation.label,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: HuahuoControlSize.iconComfortable,
              maxWidth: 116,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 88;
                final showIcon = constraints.maxWidth >= 64;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (showIcon) ...[
                        if (presentation.busy)
                          SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: presentation.color,
                            ),
                          )
                        else
                          Icon(
                            presentation.icon,
                            size: 16,
                            color: presentation.color,
                          ),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: Text(
                          compact ? compactLabel : presentation.label,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: HuahuoV3Theme.compactLabel.copyWith(
                            color: presentation.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

final class V3CanvasAiDiffDecisionBar extends StatelessWidget {
  const V3CanvasAiDiffDecisionBar({
    required this.action,
    required this.scope,
    required this.insertedCharacters,
    required this.deletedCharacters,
    required this.onReject,
    required this.onApply,
    this.applying = false,
    super.key,
  }) : assert(insertedCharacters >= 0),
       assert(deletedCharacters >= 0);

  final CanvasAiAction? action;
  final CanvasAiEditScope scope;
  final int insertedCharacters;
  final int deletedCharacters;
  final VoidCallback? onReject;
  final VoidCallback? onApply;
  final bool applying;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final actionLabel = action?.label ?? 'AI 改写';
    final scopeLabel = switch (scope) {
      CanvasAiEditScope.global => '全文',
      CanvasAiEditScope.local => '选中文字',
    };
    return Semantics(
      key: const ValueKey<String>('canvas-ai-confirmation'),
      container: true,
      explicitChildNodes: true,
      label:
          'AI 修改预览，$actionLabel，$scopeLabel，'
          '新增 $insertedCharacters 个字符，删除 $deletedCharacters 个字符',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.canvas,
          border: Border(top: BorderSide(color: tokens.line)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 18,
                      color: tokens.accent,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'AI 修改预览',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HuahuoV3Theme.listTitle.copyWith(fontSize: 15),
                      ),
                    ),
                    if (applying)
                      Text(
                        '正在应用',
                        style: HuahuoV3Theme.compactLabel.copyWith(
                          color: tokens.accent,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _CanvasAiReviewMetadata(
                      label: actionLabel,
                      icon: Icons.auto_fix_high_rounded,
                      foreground: tokens.text,
                      background: tokens.surfaceMuted,
                    ),
                    _CanvasAiReviewMetadata(
                      label: scopeLabel,
                      icon: scope == CanvasAiEditScope.local
                          ? Icons.select_all_rounded
                          : Icons.article_outlined,
                      foreground: tokens.text,
                      background: tokens.surfaceMuted,
                    ),
                    _CanvasAiReviewMetadata(
                      label: '新增 $insertedCharacters',
                      icon: Icons.add_rounded,
                      foreground: tokens.success,
                      background: Color.alphaBlend(
                        tokens.success.withValues(alpha: .10),
                        tokens.canvas,
                      ),
                    ),
                    _CanvasAiReviewMetadata(
                      label: '删除 $deletedCharacters',
                      icon: Icons.remove_rounded,
                      foreground: tokens.danger,
                      background: Color.alphaBlend(
                        tokens.danger.withValues(alpha: .10),
                        tokens.canvas,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey<String>('canvas-ai-reject'),
                        onPressed: applying ? null : onReject,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(
                            0,
                            HuahuoControlSize.iconComfortable,
                          ),
                          foregroundColor: tokens.text,
                          side: BorderSide(color: tokens.line),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              HuahuoRadius.control,
                            ),
                          ),
                        ),
                        child: const _CanvasDecisionButtonContent(
                          icon: Icons.close_rounded,
                          label: '放弃建议',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey<String>('canvas-ai-apply'),
                        onPressed: applying ? null : onApply,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(
                            0,
                            HuahuoControlSize.iconComfortable,
                          ),
                          backgroundColor: tokens.primary,
                          foregroundColor: tokens.onPrimary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              HuahuoRadius.control,
                            ),
                          ),
                        ),
                        child: applying
                            ? SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: tokens.onPrimary,
                                ),
                              )
                            : const _CanvasDecisionButtonContent(
                                icon: Icons.check_rounded,
                                label: '应用修改',
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _CanvasEditingModeSegment extends StatelessWidget {
  const _CanvasEditingModeSegment({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onPressed,
    this.onBlocked,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;
  final VoidCallback? onBlocked;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled || onBlocked != null,
      hint: enabled ? null : '点按查看暂不可切换的原因',
      onTap: enabled ? (selected ? null : onPressed) : onBlocked,
      label: '$label模式',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: enabled ? (selected ? null : onPressed) : onBlocked,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            alignment: Alignment.center,
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: selected ? tokens.canvas : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: selected ? Border.all(color: tokens.line) : null,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  label,
                  style: HuahuoV3Theme.compactLabel.copyWith(
                    color: selected ? tokens.ink : tokens.muted,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CanvasAiReviewMetadata extends StatelessWidget {
  const _CanvasAiReviewMetadata({
    required this.label,
    required this.icon,
    required this.foreground,
    required this.background,
  });

  final String label;
  final IconData icon;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 28, maxWidth: 154),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: foreground),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HuahuoV3Theme.compactLabel.copyWith(color: foreground),
          ),
        ),
      ],
    ),
  );
}

final class _CanvasDecisionButtonContent extends StatelessWidget {
  const _CanvasDecisionButtonContent({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)],
    ),
  );
}

final class _CanvasSavePresentation {
  const _CanvasSavePresentation({
    required this.label,
    required this.icon,
    required this.color,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool busy;
}
