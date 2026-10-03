import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../domain/feed_item_models.dart';

class V3FeedAggregationSelectionSheet extends StatelessWidget {
  const V3FeedAggregationSelectionSheet({
    required this.notes,
    required this.onClose,
    required this.onReshuffle,
    required this.onStart,
    this.canReshuffle = true,
    this.canStart = true,
    super.key,
  });

  final List<V3FeedItem> notes;
  final VoidCallback onClose;
  final VoidCallback onReshuffle;
  final VoidCallback onStart;
  final bool canReshuffle;
  final bool canStart;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final sheetHeight = constraints.maxHeight.clamp(0.0, 548.0).toDouble();
        return Material(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            bottom: false,
            child: SizedBox(
              height: sheetHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  children: [
                    Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '本次聚合',
                              style: TextStyle(
                                fontSize: 18,
                                height: 1.55,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            key: const ValueKey('aggregation-sheet-reshuffle'),
                            onPressed: canReshuffle ? onReshuffle : null,
                            style: TextButton.styleFrom(
                              foregroundColor: colors.accent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              minimumSize: const Size(72, 44),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(LucideIcons.refreshCw, size: 15),
                            label: const Text(
                              '换一批',
                              style: TextStyle(fontSize: 12.5),
                            ),
                          ),
                          const SizedBox(width: 4),
                          _AggregationIconAction(
                            tooltip: '关闭',
                            icon: Icons.close_rounded,
                            onTap: onClose,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        key: const ValueKey('aggregation-content-scroll'),
                        child: Column(
                          children: [
                            Container(
                              width: double.infinity,
                              constraints: const BoxConstraints(minHeight: 58),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '已随机选中 ${notes.length} 篇笔记',
                                    style: const TextStyle(
                                      fontSize: 17,
                                      height: 1.53,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '将使用以下内容碰撞出一个新的观点与笔记',
                                    style: TextStyle(
                                      color: colors.muted,
                                      fontSize: 12.5,
                                      height: 1.76,
                                      letterSpacing: 0,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              constraints: const BoxConstraints(minHeight: 264),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (var index = 0; index < 4; index++) ...[
                                    if (index > 0) const SizedBox(height: 8),
                                    _AggregationSourceRow(
                                      index: index,
                                      note: index < notes.length
                                          ? notes[index]
                                          : null,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton.icon(
                        key: const ValueKey('aggregation-sheet-start'),
                        onPressed: canStart ? onStart : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.primary,
                          foregroundColor: colors.onPrimary,
                          disabledBackgroundColor: colors.surfaceMuted,
                          disabledForegroundColor: colors.muted,
                        ),
                        icon: const Icon(Icons.join_inner_rounded, size: 19),
                        label: const Text(
                          '开始聚合',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 42),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class V3FeedAggregationProgressSurface extends StatelessWidget {
  const V3FeedAggregationProgressSurface({
    required this.sourceCount,
    required this.onBack,
    this.onLeave,
    this.failed = false,
    this.onRetry,
    this.statusTitle,
    this.statusMessage,
    this.referenceId,
    this.retryLabel = '重试',
    this.showSkeleton = true,
    super.key,
  });

  final int sourceCount;
  final bool failed;
  final VoidCallback onBack;
  final VoidCallback? onLeave;
  final VoidCallback? onRetry;
  final String? statusTitle;
  final String? statusMessage;
  final String? referenceId;
  final String retryLabel;
  final bool showSkeleton;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return ColoredBox(
      key: const ValueKey('aggregation-v5-processing'),
      color: colors.canvas,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: V3NavigationBackButton(tooltip: '返回', onPressed: onBack),
            ),
            const SizedBox(height: 16),
            if (sourceCount > 0) ...[
              Container(
                constraints: const BoxConstraints(minHeight: 60),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  border: Border.all(color: colors.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.link_rounded, size: 21),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '已选中 $sourceCount 篇笔记',
                        style: TextStyle(
                          color: colors.accent,
                          fontSize: 15,
                          height: 1.45,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            Semantics(
              liveRegion: true,
              child: Container(
                constraints: const BoxConstraints(minHeight: 120),
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border.all(color: colors.line),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: colors.ink.withValues(alpha: .08),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      statusTitle ?? (failed ? '观点聚合失败' : '观点聚合中...'),
                      style: TextStyle(
                        color: failed ? colors.danger : colors.ink,
                        fontSize: 17,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      statusMessage ??
                          (failed ? '未能生成新的观点，请重试。' : '正在梳理笔记之间的关系并生成新的观点。'),
                      style: TextStyle(
                        color: colors.muted,
                        fontSize: 13,
                        height: 1.3,
                        letterSpacing: 0,
                      ),
                    ),
                    if (onRetry != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const ValueKey('aggregation-processing-retry'),
                          onPressed: onRetry,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(retryLabel),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (onLeave != null && !failed) ...[
              const SizedBox(height: 16),
              V3LongRunningTaskNotice(
                key: const ValueKey('aggregation-processing-leave'),
                onReturn: onLeave,
              ),
            ],
            if (showSkeleton && !failed) ...[
              const SizedBox(height: 16),
              _AggregationSkeleton(failed: failed),
            ],
            if (referenceId != null) ...[
              const SizedBox(height: 16),
              SelectableText(
                '任务编号：$referenceId',
                contextMenuBuilder: V3TextEditing.buildContextMenu,
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class V3FeedAggregationResultSurface extends StatelessWidget {
  const V3FeedAggregationResultSurface({
    required this.sources,
    required this.generatedNote,
    required this.onBack,
    required this.onSave,
    required this.onReshuffle,
    this.headline = '四段原本分散的记录，碰撞出了一个共同主题',
    super.key,
  });

  final List<V3FeedItem> sources;
  final V3FeedItem generatedNote;
  final VoidCallback onBack;
  final VoidCallback onSave;
  final VoidCallback onReshuffle;
  final String headline;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final content = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Row(
              children: [
                V3NavigationBackButton(
                  key: const ValueKey('aggregation-result-back'),
                  tooltip: '返回',
                  onPressed: onBack,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '观点碰撞',
                    style: TextStyle(
                      fontSize: 20,
                      height: 1.25,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                _AggregationIconAction(
                  tooltip: '换一组',
                  icon: LucideIcons.shuffle,
                  onTap: onReshuffle,
                  square: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _AggregationResultIntro(title: headline),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '本次来源',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.43,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  sources.isEmpty ? '4 篇（旧版未保存来源详情）' : '${sources.length} 篇',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 12,
                    height: 1.5,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _AggregationSourceGrid(notes: sources),
          const SizedBox(height: 20),
          _GeneratedInsightCard(note: generatedNote),
        ],
      ),
    );
    return ColoredBox(
      key: const ValueKey('aggregation-v5-result'),
      color: colors.canvas,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 360 ||
              MediaQuery.textScalerOf(context).scale(15) > 20;
          final actions = _AggregationResultActions(
            stacked: stacked,
            onSave: onSave,
            onReshuffle: onReshuffle,
          );
          if (stacked) {
            return Column(
              children: [
                Expanded(child: content),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
                  child: actions,
                ),
              ],
            );
          }
          return Stack(
            children: [
              Positioned.fill(bottom: 92, child: content),
              Positioned(left: 22, right: 22, bottom: 38, child: actions),
            ],
          );
        },
      ),
    );
  }
}

class _AggregationResultActions extends StatelessWidget {
  const _AggregationResultActions({
    required this.stacked,
    required this.onSave,
    required this.onReshuffle,
  });

  final bool stacked;
  final VoidCallback onSave;
  final VoidCallback onReshuffle;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final primary = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: FilledButton.icon(
        key: const ValueKey('aggregation-result-save'),
        onPressed: onSave,
        style: FilledButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: HuahuoSpacing.xs),
        ),
        icon: const Icon(Icons.note_add_outlined, size: 18),
        label: const Text(
          '查看聚合笔记',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
      ),
    );
    final secondary = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: OutlinedButton.icon(
        key: const ValueKey('aggregation-result-reshuffle'),
        onPressed: onReshuffle,
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.ink,
          side: BorderSide(color: colors.line),
          padding: const EdgeInsets.symmetric(horizontal: HuahuoSpacing.xs),
        ),
        icon: const Icon(LucideIcons.shuffle, size: 17),
        label: const Text(
          '换一组',
          style: TextStyle(fontSize: 14, letterSpacing: 0),
        ),
      ),
    );
    if (stacked) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [primary, const SizedBox(height: 12), secondary],
      );
    }
    return Row(
      children: [
        Expanded(flex: 5, child: primary),
        const SizedBox(width: 12),
        Expanded(flex: 3, child: secondary),
      ],
    );
  }
}

class _AggregationIconAction extends StatelessWidget {
  const _AggregationIconAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.square = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool square;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return IconButton(
      key: ValueKey('aggregation-${tooltip.replaceAll(' ', '-')}'),
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: square ? 20 : 22),
      style: IconButton.styleFrom(
        fixedSize: const Size.square(44),
        backgroundColor: colors.surfaceMuted,
        foregroundColor: colors.ink,
        side: square ? BorderSide(color: colors.line) : BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(square ? 8 : 22),
        ),
      ),
    );
  }
}

class _AggregationSourceRow extends StatelessWidget {
  const _AggregationSourceRow({required this.index, required this.note});

  final int index;
  final V3FeedItem? note;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: ValueKey('aggregation-source-row-$index'),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${(index + 1).toString().padLeft(2, '0')} · ${_sourceLabel(note)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.accent,
              fontSize: 10.5,
              height: 1.62,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            note?.title ?? '等待选择笔记',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.ink,
              fontSize: 12.5,
              height: 1.35,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _AggregationSkeleton extends StatelessWidget {
  const _AggregationSkeleton({required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      height: 160,
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(24),
      ),
      child: failed
          ? Center(
              child: Icon(LucideIcons.cloudOff, size: 28, color: colors.muted),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonLine(
                  width: 118,
                  height: 16,
                  color: colors.surfaceMuted,
                ),
                const SizedBox(height: 11.5),
                _SkeletonLine(width: double.infinity, color: colors.line),
                const SizedBox(height: 11.5),
                _SkeletonLine(
                  width: double.infinity,
                  color: colors.surfaceMuted,
                ),
                const SizedBox(height: 11.5),
                _SkeletonLine(width: double.infinity, color: colors.line),
                const SizedBox(height: 11.5),
                _SkeletonLine(width: 260, color: colors.surfaceMuted),
              ],
            ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({
    required this.width,
    required this.color,
    this.height = 14,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
  );
}

class _AggregationResultIntro extends StatelessWidget {
  const _AggregationResultIntro({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.sparkles, size: 14, color: colors.accent),
              const SizedBox(width: 5),
              Text(
                '随机选取 4 篇来源',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 11.5,
                  height: 1.39,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 22,
            height: 1.27,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          '来源由系统随机选择，可随时换一组',
          style: TextStyle(
            color: colors.muted,
            fontSize: 12.5,
            height: 1.44,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _AggregationSourceGrid extends StatelessWidget {
  const _AggregationSourceGrid({required this.notes});

  final List<V3FeedItem> notes;

  @override
  Widget build(BuildContext context) => SizedBox(
    height:
        (2 *
                    (21 +
                        MediaQuery.textScalerOf(context).scale(10.5) * 1.43 +
                        MediaQuery.textScalerOf(context).scale(12.5) *
                            1.36 *
                            2) +
                8)
            .clamp(150.0, double.infinity),
    child: Column(
      children: [
        for (var row = 0; row < 2; row++) ...[
          if (row > 0) const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                for (var column = 0; column < 2; column++) ...[
                  if (column > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _AggregationSourceTile(
                      index: row * 2 + column,
                      note: row * 2 + column < notes.length
                          ? notes[row * 2 + column]
                          : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

class _AggregationSourceTile extends StatelessWidget {
  const _AggregationSourceTile({required this.index, required this.note});

  final int index;
  final V3FeedItem? note;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${(index + 1).toString().padLeft(2, '0')} · ${_sourceLabel(note)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.accent,
              fontSize: 10.5,
              height: 1.43,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            note?.title ?? '等待选择笔记',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.36,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _GeneratedInsightCard extends StatelessWidget {
  const _GeneratedInsightCard({required this.note});

  final V3FeedItem note;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final body = note.rawBody.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.accent.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.sparkles, size: 13, color: colors.accent),
                    const SizedBox(width: 4),
                    Text(
                      '新观点',
                      style: TextStyle(
                        color: colors.accent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                '刚刚生成',
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 12,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            note.title,
            style: const TextStyle(
              fontSize: 16,
              height: 1.45,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body.isEmpty ? '新的观点已生成并保存，可继续编辑。' : body,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.5, letterSpacing: 0),
          ),
          const SizedBox(height: 14),
          Text(
            '来自 ${sourcesLabel(4)} · 已保存，可继续编辑',
            style: TextStyle(
              color: colors.muted,
              fontSize: 11.5,
              height: 1.5,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

String sourcesLabel(int count) => '$count 篇笔记';

String _sourceLabel(V3FeedItem? note) {
  if (note == null) return '笔记';
  final folder = note.folderName?.trim();
  if (folder != null && folder.isNotEmpty) return folder;
  if (note.topics.isNotEmpty && note.topics.first.trim().isNotEmpty) {
    return note.topics.first.trim();
  }
  return note.source.label;
}
