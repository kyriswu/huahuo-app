import 'package:flutter/material.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

typedef DesktopHomeActionCallback = void Function(ProductHomeAction action);
typedef DesktopHomeSuggestionCallback =
    void Function(ProductHomeSuggestion suggestion);

final class DesktopHomeWorkspace extends StatefulWidget {
  const DesktopHomeWorkspace({
    required this.controller,
    required this.onPrimaryAction,
    required this.onOpenSuggestion,
    required this.onOpenRecordings,
    required this.onOpenCredits,
    super.key,
  });

  final ProductHomeController controller;
  final DesktopHomeActionCallback onPrimaryAction;
  final DesktopHomeSuggestionCallback onOpenSuggestion;
  final VoidCallback onOpenRecordings;
  final VoidCallback onOpenCredits;

  @override
  State<DesktopHomeWorkspace> createState() => _DesktopHomeWorkspaceState();
}

final class _DesktopHomeWorkspaceState extends State<DesktopHomeWorkspace> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChanged);
  }

  @override
  void didUpdateWidget(DesktopHomeWorkspace oldWidget) {
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
      key: const ValueKey<String>('desktop-home-workspace'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _HomeTopBar(
            loading: state.status == ProductHomeStatus.loading,
            onRefresh: widget.controller.reload,
          ),
          Expanded(child: _buildBody(state)),
        ],
      ),
    );
  }

  Widget _buildBody(ProductHomeState state) {
    if (state.status == ProductHomeStatus.idle) {
      return const Center(child: Text('登录并完成 Workspace 初始化后查看首页'));
    }
    if (state.status == ProductHomeStatus.loading && state.home == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ProductHomeStatus.failure && state.home == null) {
      return _HomeFailure(
        message: state.errorMessage ?? '首页加载失败',
        onRetry: widget.controller.reload,
      );
    }
    final home = state.home;
    if (home == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state.errorMessage != null) ...[
                    _HomeInlineError(message: state.errorMessage!),
                    const SizedBox(height: 16),
                  ],
                  _HomePrimaryAction(
                    action: home.action,
                    onPressed: () => widget.onPrimaryAction(home.action),
                  ),
                  const SizedBox(height: 24),
                  _HomeMetrics(
                    home: home,
                    compact: constraints.maxWidth < 760,
                    onOpenRecordings: widget.onOpenRecordings,
                    onOpenCredits: widget.onOpenCredits,
                  ),
                  const SizedBox(height: 28),
                  if (home.suggestion case final suggestion?)
                    _HomeSuggestion(
                      suggestion: suggestion,
                      busy: state.acknowledgingSuggestionId == suggestion.id,
                      onOpen: () => widget.onOpenSuggestion(suggestion),
                      onAcknowledge: widget.controller.acknowledgeSuggestion,
                    )
                  else
                    const _HomeEmptySuggestion(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _HomeTopBar extends StatelessWidget {
  const _HomeTopBar({required this.loading, required this.onRefresh});

  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(
            children: [
              const Icon(LucideIcons.house, size: 16),
              const SizedBox(width: 9),
              Text('首页', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Tooltip(
                message: '刷新首页',
                child: IconButton(
                  key: const ValueKey<String>('home-refresh'),
                  onPressed: loading ? null : onRefresh,
                  icon: loading
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(LucideIcons.refreshCw, size: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _HomePrimaryAction extends StatelessWidget {
  const _HomePrimaryAction({required this.action, required this.onPressed});

  final ProductHomeAction action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (title, detail, icon) = switch (action.type) {
      ProductHomeActionType.openRunningTask => (
        '继续正在运行的任务',
        action.label,
        LucideIcons.loaderCircle,
      ),
      ProductHomeActionType.viewHotspotSuggestion => (
        '查看今日推荐',
        action.label,
        LucideIcons.sparkles,
      ),
      ProductHomeActionType.uploadRecording => (
        '导入已有录音',
        action.label,
        LucideIcons.audioLines,
      ),
    };
    return Material(
      color: colors.primaryContainer.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        key: const ValueKey<String>('home-primary-action'),
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              Icon(icon, size: 20, color: colors.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(LucideIcons.arrowRight, size: 17),
            ],
          ),
        ),
      ),
    );
  }
}

final class _HomeMetrics extends StatelessWidget {
  const _HomeMetrics({
    required this.home,
    required this.compact,
    required this.onOpenRecordings,
    required this.onOpenCredits,
  });

  final ProductHome home;
  final bool compact;
  final VoidCallback onOpenRecordings;
  final VoidCallback onOpenCredits;

  @override
  Widget build(BuildContext context) {
    final metrics = <Widget>[
      _HomeMetric(
        key: const ValueKey<String>('home-running-tasks'),
        icon: LucideIcons.activity,
        label: '运行任务',
        value: '${home.runningTaskCount}',
      ),
      _HomeMetric(
        key: const ValueKey<String>('home-recordings'),
        icon: LucideIcons.audioLines,
        label: '录音文件',
        value: '${home.recordingCount}',
        detail: '已沉淀 ${home.depositedRecordingCount}',
        onTap: onOpenRecordings,
      ),
      _HomeMetric(
        key: const ValueKey<String>('home-credits'),
        icon: LucideIcons.gauge,
        label: '生成额度',
        value: home.availableGenerationCredits?.toString() ?? '--',
        onTap: onOpenCredits,
      ),
    ];
    if (compact) {
      return Column(
        children: [
          for (var index = 0; index < metrics.length; index++) ...[
            metrics[index],
            if (index < metrics.length - 1) const SizedBox(height: 8),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var index = 0; index < metrics.length; index++) ...[
          Expanded(child: metrics[index]),
          if (index < metrics.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

final class _HomeMetric extends StatelessWidget {
  const _HomeMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          constraints: const BoxConstraints(minHeight: 86),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    Text(value, style: Theme.of(context).textTheme.titleLarge),
                    if (detail != null)
                      Text(
                        detail!,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              if (onTap != null) const Icon(LucideIcons.chevronRight, size: 15),
            ],
          ),
        ),
      ),
    );
  }
}

final class _HomeSuggestion extends StatelessWidget {
  const _HomeSuggestion({
    required this.suggestion,
    required this.busy,
    required this.onOpen,
    required this.onAcknowledge,
  });

  final ProductHomeSuggestion suggestion;
  final bool busy;
  final VoidCallback onOpen;
  final Future<bool> Function() onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('今日推荐', style: Theme.of(context).textTheme.titleMedium),
            if (!suggestion.acknowledged) ...[
              const SizedBox(width: 8),
              Container(
                key: const ValueKey<String>('home-suggestion-unread'),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ],
            const Spacer(),
            if (!suggestion.acknowledged)
              TextButton(
                key: const ValueKey<String>('home-acknowledge-suggestion'),
                onPressed: busy ? null : onAcknowledge,
                child: Text(busy ? '更新中' : '标为已读'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey<String>('home-open-suggestion'),
            borderRadius: BorderRadius.circular(6),
            onTap: onOpen,
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    suggestion.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    suggestion.summary ?? suggestion.eventBrief ?? '查看完整推荐',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (suggestion.sourceName != null)
                        Text(
                          suggestion.sourceName!,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      const Spacer(),
                      const Text('查看详情'),
                      const SizedBox(width: 5),
                      const Icon(LucideIcons.arrowRight, size: 15),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _HomeEmptySuggestion extends StatelessWidget {
  const _HomeEmptySuggestion();

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey<String>('home-suggestion-empty'),
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        Icon(
          LucideIcons.inbox,
          size: 26,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 10),
        const Text('今天暂无新的推荐'),
      ],
    ),
  );
}

final class _HomeFailure extends StatelessWidget {
  const _HomeFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        TextButton.icon(
          key: const ValueKey<String>('home-retry'),
          onPressed: onRetry,
          icon: const Icon(LucideIcons.rotateCw, size: 15),
          label: const Text('重试'),
        ),
      ],
    ),
  );
}

final class _HomeInlineError extends StatelessWidget {
  const _HomeInlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    color: Theme.of(context).colorScheme.errorContainer,
    child: Text(message),
  );
}
