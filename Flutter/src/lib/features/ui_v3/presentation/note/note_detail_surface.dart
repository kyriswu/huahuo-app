import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/navigation/safe_navigation.dart';
import '../../../../shared/theme/huahuo_v3_theme.dart';
import '../../../../shared/ui_v3/v3_components.dart';
import '../../../../shared/ui_v3/v3_liquid_glass.dart';
import '../../domain/feed_item_models.dart';
import '../v3_feed_quick_dock.dart' show V3ChatEntry;

class NoteDetailSurface extends StatelessWidget {
  const NoteDetailSurface({
    required this.title,
    required this.subtitle,
    required this.stage,
    required this.onBack,
    required this.onMore,
    required this.onSelectStage,
    required this.pageController,
    required this.onPageChanged,
    required this.pages,
    required this.bottomBar,
    super.key,
  });

  final String title;
  final String subtitle;
  final V3ContentStage stage;
  final VoidCallback onBack;
  final VoidCallback onMore;
  final ValueChanged<V3ContentStage> onSelectStage;
  final PageController pageController;
  final ValueChanged<int> onPageChanged;
  final List<Widget> pages;
  final Widget bottomBar;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final canPop = canReturnToPreviousRoute(context);
    return PopScope<Object?>(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !canPop) onBack();
      },
      child: Scaffold(
        key: const ValueKey<String>('note-detail-surface'),
        backgroundColor: colors.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                height: 50,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Text(
                      '资料详情',
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                    Positioned(
                      left: 8,
                      child: V3NavigationBackButton(
                        tooltip: '返回',
                        onPressed: onBack,
                      ),
                    ),
                    Positioned(
                      right: 8,
                      child: V3LiquidGlassIconAction(
                        tooltip: '更多操作',
                        semanticLabel: '更多操作',
                        icon: const Icon(Icons.more_horiz_rounded, size: 22),
                        onTap: onMore,
                      ),
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 72),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 22,
                          height: 1.22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _NoteDetailStageBar(
                  stage: stage,
                  onSelect: onSelectStage,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: PageView(
                    controller: pageController,
                    onPageChanged: onPageChanged,
                    children: pages,
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: Material(
          color: colors.canvas,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
              child: bottomBar,
            ),
          ),
        ),
      ),
    );
  }
}

class NoteDetailCreationDock extends StatelessWidget {
  const NoteDetailCreationDock({
    required this.readOnly,
    required this.onChat,
    required this.onAssistant,
    required this.onFreeCreation,
    super.key,
  });

  final bool readOnly;
  final VoidCallback onChat;
  final VoidCallback onAssistant;
  final VoidCallback? onFreeCreation;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final assistantLabelWidth = _scaledActionLabelWidth(
          context,
          'Agent 辅助创作',
        );
        final freeCreationLabelWidth = _scaledActionLabelWidth(
          context,
          'Agent 自由创作',
        );
        final widestLabel = assistantLabelWidth > freeCreationLabelWidth
            ? assistantLabelWidth
            : freeCreationLabelWidth;
        const fixedActionWidth = 16 + 18 + 7;
        const chatAndSpacingWidth = 48 + 8 + 8;
        final singleRowMinimumWidth =
            chatAndSpacingWidth + ((fixedActionWidth + widestLabel) * 2);

        Widget chatAction() => V3ChatEntry(
          key: const ValueKey<String>('detail-chat-entry'),
          borderless: true,
          onTap: onChat,
        );

        Widget assistantAction() => _NoteDetailAgentAction(
          key: const ValueKey<String>('detail-floating-action-Agent 辅助创作'),
          icon: LucideIcons.sparkles,
          label: 'Agent 辅助创作',
          onPressed: onAssistant,
        );

        Widget freeCreationAction() => _NoteDetailAgentAction(
          key: const ValueKey<String>('detail-floating-action-Agent 自由创作'),
          icon: LucideIcons.notebookPen,
          label: 'Agent 自由创作',
          onPressed: onFreeCreation,
        );

        if (readOnly && onFreeCreation == null) {
          return SizedBox(
            height: 48,
            child: Row(
              children: [
                chatAction(),
                const SizedBox(width: 8),
                Expanded(child: assistantAction()),
              ],
            ),
          );
        }

        if (constraints.maxWidth >= singleRowMinimumWidth) {
          return SizedBox(
            height: 48,
            child: Row(
              children: [
                chatAction(),
                const SizedBox(width: 8),
                Expanded(child: assistantAction()),
                const SizedBox(width: 8),
                Expanded(child: freeCreationAction()),
              ],
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  chatAction(),
                  const SizedBox(width: 8),
                  Expanded(child: assistantAction()),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: freeCreationAction(),
            ),
          ],
        );
      },
    );
  }

  double _scaledActionLabelWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

class _NoteDetailStageBar extends StatelessWidget {
  const _NoteDetailStageBar({required this.stage, required this.onSelect});

  final V3ContentStage stage;
  final ValueChanged<V3ContentStage> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      key: const ValueKey<String>('note-detail-stage-bar'),
      height: 49,
      child: Column(
        children: [
          SizedBox(
            height: 46,
            child: Row(
              children: [
                for (final value in V3ContentStage.values)
                  Expanded(
                    child: Semantics(
                      button: true,
                      selected: value == stage,
                      label: value.label,
                      child: InkWell(
                        onTap: () => onSelect(value),
                        child: Center(
                          child: Text(
                            value.label,
                            style: TextStyle(
                              color: value == stage ? colors.ink : colors.muted,
                              fontSize: 15,
                              fontWeight: value == stage
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
          ),
          SizedBox(
            height: 3,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(height: .5, color: colors.line),
                ),
                AnimatedAlign(
                  duration: V3MotionTokens.resolve(
                    context,
                    V3MotionTokens.standard,
                  ),
                  curve: Curves.easeOutCubic,
                  alignment: switch (stage) {
                    V3ContentStage.raw => const Alignment(-2 / 3, 1),
                    V3ContentStage.summary => Alignment.bottomCenter,
                    V3ContentStage.sprout => const Alignment(2 / 3, 1),
                  },
                  child: Container(
                    width: 36,
                    height: 2,
                    decoration: BoxDecoration(
                      color: colors.ink,
                      borderRadius: BorderRadius.circular(1),
                    ),
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

class _NoteDetailAgentAction extends StatelessWidget {
  const _NoteDetailAgentAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final enabled = onPressed != null;
    final foregroundColor = enabled
        ? colors.ink
        : colors.muted.withValues(alpha: .64);
    return SizedBox.expand(
      child: Semantics(
        container: true,
        excludeSemantics: true,
        button: true,
        enabled: enabled,
        label: label,
        onTap: onPressed,
        child: Material(
          color: colors.canvas,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: enabled ? colors.line : colors.line.withValues(alpha: .48),
              width: .5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 18, color: foregroundColor),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foregroundColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
