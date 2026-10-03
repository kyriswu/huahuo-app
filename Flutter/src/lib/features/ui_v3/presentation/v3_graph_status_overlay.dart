import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../domain/graph_snapshot.dart';

class V3GraphStatusOverlay extends StatelessWidget {
  const V3GraphStatusOverlay({
    required this.state,
    this.progress,
    this.refreshing = false,
    this.showCompleted = false,
    this.compactTopInset = 18,
    this.errorMessage,
    this.onRetry,
    this.onCreate,
    this.onDismissCompleted,
    super.key,
  }) : assert(compactTopInset >= 0);

  final GraphLoadingState state;
  final double? progress;
  final bool refreshing;
  final bool showCompleted;
  final double compactTopInset;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final VoidCallback? onCreate;
  final VoidCallback? onDismissCompleted;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    Widget content;
    if (state == GraphLoadingState.loading ||
        state == GraphLoadingState.building) {
      content = Center(
        key: ValueKey('feed-graph-status-${state.name}'),
        child: _CenteredGraphStatus(
          icon: state == GraphLoadingState.loading
              ? LucideIcons.loaderCircle
              : LucideIcons.network,
          title: state == GraphLoadingState.loading ? '正在加载图谱' : '正在构建关系',
          progress: progress,
        ),
      );
    } else if (state == GraphLoadingState.empty) {
      content = Center(
        key: const ValueKey('feed-graph-status-empty'),
        child: _CenteredGraphStatus(
          icon: LucideIcons.network,
          title: '还没有可展示的知识',
          actionLabel: '添加内容',
          onAction: onCreate,
        ),
      );
    } else if (state == GraphLoadingState.failure) {
      content = Center(
        key: const ValueKey('feed-graph-status-failure'),
        child: _CenteredGraphStatus(
          icon: LucideIcons.circleAlert,
          title: errorMessage?.trim().isNotEmpty == true
              ? errorMessage!.trim()
              : '图谱加载失败',
          actionLabel: '重试',
          onAction: onRetry,
        ),
      );
    } else if (refreshing || showCompleted) {
      content = Align(
        key: ValueKey(
          refreshing
              ? 'feed-graph-status-refreshing'
              : 'feed-graph-status-completed',
        ),
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: compactTopInset),
          child: Semantics(
            liveRegion: true,
            label: refreshing ? '正在刷新图谱' : '图谱构建完成',
            child: V3LiquidGlassSurface(
              style: V3GlassSurfaceStyle.subtle,
              borderRadius: 18,
              opacity: .76,
              padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (refreshing)
                    SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: colors.primary,
                        backgroundColor: colors.line,
                      ),
                    )
                  else
                    Icon(
                      LucideIcons.circleCheck,
                      size: 17,
                      color: colors.success,
                    ),
                  const SizedBox(width: 8),
                  Text(
                    refreshing ? '正在刷新' : '构建完成',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!refreshing && onDismissCompleted != null) ...[
                    const SizedBox(width: 2),
                    V3CloseButton(
                      key: const ValueKey(
                        'feed-graph-status-completed-dismiss',
                      ),
                      tooltip: '关闭',
                      onPressed: onDismissCompleted,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      content = const SizedBox.shrink(
        key: ValueKey('feed-graph-status-hidden'),
      );
    }
    return IgnorePointer(
      ignoring:
          state != GraphLoadingState.empty &&
          state != GraphLoadingState.failure &&
          !(showCompleted && onDismissCompleted != null),
      child: AnimatedSwitcher(
        duration: V3MotionTokens.resolve(context, V3MotionTokens.standard),
        child: content,
      ),
    );
  }
}

class _CenteredGraphStatus extends StatelessWidget {
  const _CenteredGraphStatus({
    required this.icon,
    required this.title,
    this.progress,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final double? progress;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      liveRegion: true,
      label: title,
      child: V3LiquidGlassSurface(
        style: V3GlassSurfaceStyle.panel,
        borderRadius: 18,
        opacity: .80,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 190, maxWidth: 260),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: colors.ink),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (progress != null) ...[
                const SizedBox(height: 13),
                LinearProgressIndicator(
                  value: progress!.clamp(0.0, 1.0).toDouble(),
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(3),
                  color: colors.primary,
                  backgroundColor: colors.line,
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: onAction,
                  icon: Icon(
                    actionLabel == '重试'
                        ? LucideIcons.refreshCw
                        : LucideIcons.plus,
                    size: 17,
                  ),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
