import 'package:flutter/material.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/markdown/v3_markdown.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';

class V3PositioningReportContent extends StatelessWidget {
  const V3PositioningReportContent({
    required this.markdown,
    this.progress,
    this.markdownKey,
    this.compactDashboard = true,
    this.allowMarkdownProgressFallback = true,
    this.emptyText = '尚未沉淀内容',
    super.key,
  });

  final String markdown;
  final PositioningProgressProfile? progress;
  final Key? markdownKey;
  final bool compactDashboard;
  final bool allowMarkdownProgressFallback;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final visibleProgress =
        progress ??
        (allowMarkdownProgressFallback
            ? parseLatestPositioningProgress(markdown)
            : null);
    final visibleMarkdown = stripPositioningReportMetadata(markdown);
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (visibleProgress != null) ...[
          V3PositioningDashboard(
            profile: visibleProgress,
            compact: compactDashboard,
          ),
          if (visibleMarkdown.isNotEmpty) const SizedBox(height: 20),
        ],
        if (visibleMarkdown.isNotEmpty)
          V3AssistantReplyMarkdown(
            source: visibleMarkdown,
            markdownKey: markdownKey,
          )
        else if (visibleProgress == null)
          Text(emptyText, style: TextStyle(color: colors.muted, height: 1.6)),
      ],
    );
  }
}

class V3PositioningDashboard extends StatelessWidget {
  const V3PositioningDashboard({
    required this.profile,
    this.compact = false,
    super.key,
  });

  final PositioningProgressProfile profile;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final summary = profile.consultationState.expertJudgment.isNotEmpty
        ? profile.consultationState.expertJudgment
        : profile.consultationState.subjectGoal.isNotEmpty
        ? profile.consultationState.subjectGoal
        : '这里记录已形成的定位判断与下一步建议。';
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: compact ? 34 : 40,
                  height: compact ? 34 : 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.line),
                  ),
                  child: Icon(
                    Icons.explore_outlined,
                    color: colors.accent,
                    size: compact ? 19 : 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '当前定位主题',
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        profile.visibleSubject.isEmpty
                            ? '定位材料整理'
                            : profile.visibleSubject,
                        maxLines: compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: compact ? 16 : 19,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                _ProgressBadge(percent: profile.completedPercent),
              ],
            ),
            SizedBox(height: compact ? 15 : 10),
            Text(
              summary,
              maxLines: compact ? 2 : 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.text,
                fontSize: compact ? 12.5 : 14,
                height: 1.5,
              ),
            ),
            SizedBox(height: compact ? 21 : 12),
            _ModuleGrid(modules: profile.modules, compact: compact),
            if (!compact) ...[
              const SizedBox(height: 16),
              for (final module in profile.modules) ...[
                _ModuleDetail(module: module),
                const SizedBox(height: 10),
              ],
              if (profile.nextFocus.isNotEmpty ||
                  profile.updatedFiles.isNotEmpty)
                _PositioningNext(profile: profile),
            ],
          ],
        );
        return Container(
          key: ValueKey(
            'positioning-dashboard-${compact ? 'compact' : 'full'}',
          ),
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
              : const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.line),
          ),
          child: !compact && constraints.hasBoundedHeight
              ? SingleChildScrollView(primary: false, child: content)
              : content,
        );
      },
    );
  }
}

class _ProgressBadge extends StatelessWidget {
  const _ProgressBadge({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Text(
        '$percent%',
        style: TextStyle(
          color: colors.accent,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ModuleGrid extends StatelessWidget {
  const _ModuleGrid({required this.modules, required this.compact});

  final List<PositioningProgressModule> modules;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 520
            ? 3
            : width >= 310
            ? 2
            : 1;
        const gap = 8.0;
        final itemWidth = ((width - gap * (columns - 1)) / columns)
            .clamp(0, 260)
            .toDouble();
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final module in modules)
              SizedBox(
                width: itemWidth,
                child: _ModuleScoreCard(module: module, compact: compact),
              ),
          ],
        );
      },
    );
  }
}

class _ModuleScoreCard extends StatelessWidget {
  const _ModuleScoreCard({required this.module, required this.compact});

  final PositioningProgressModule module;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5)
          : const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: module.weight >= 20 ? colors.accent : colors.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  module.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: compact ? 11.5 : 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${module.weight}%',
                style: TextStyle(color: colors.muted, fontSize: 10.5),
              ),
            ],
          ),
          SizedBox(height: compact ? 4 : 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: module.percent / 100,
              minHeight: 5,
              color: _stateColor(colors, module.state),
              backgroundColor: colors.line,
            ),
          ),
          SizedBox(height: compact ? 4 : 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  _stateLabel(module.state),
                  style: TextStyle(color: colors.muted, fontSize: 10.5),
                ),
              ),
              Text(
                '${module.score}/${module.weight}',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModuleDetail extends StatelessWidget {
  const _ModuleDetail({required this.module});

  final PositioningProgressModule module;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            module.label,
            style: TextStyle(
              color: colors.ink,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            module.summary.isNotEmpty
                ? module.summary
                : module.content.isNotEmpty
                ? module.content
                : '待补充',
            style: TextStyle(color: colors.text, fontSize: 13.5, height: 1.5),
          ),
          const SizedBox(height: 8),
          _EvidenceLine(label: '证据', items: module.evidence, empty: '待补充真实证据'),
          _EvidenceLine(label: '缺口', items: module.missing, empty: '暂未列出'),
          _EvidenceLine(label: '风险', items: module.risks, empty: '暂无明显风险'),
        ],
      ),
    );
  }
}

class _EvidenceLine extends StatelessWidget {
  const _EvidenceLine({
    required this.label,
    required this.items,
    required this.empty,
  });

  final String label;
  final List<String> items;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        '$label：${items.isEmpty ? empty : items.join('、')}',
        style: TextStyle(color: colors.muted, fontSize: 12, height: 1.4),
      ),
    );
  }
}

class _PositioningNext extends StatelessWidget {
  const _PositioningNext({required this.profile});

  final PositioningProgressProfile profile;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (profile.nextFocus.isNotEmpty) ...[
            Text(
              '接下来建议聊',
              style: TextStyle(
                color: colors.ink,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            for (final item in profile.nextFocus)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(
                  '• ${item.title}${item.detail.isEmpty ? '' : '：${item.detail}'}',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
          ],
          if (profile.updatedFiles.isNotEmpty) ...[
            if (profile.nextFocus.isNotEmpty) const SizedBox(height: 6),
            Text(
              '本次更新：${profile.updatedFiles.join('、')}',
              style: TextStyle(
                color: colors.muted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Color _stateColor(HuahuoV3ThemeTokens colors, PositioningModuleState state) =>
    switch (state) {
      PositioningModuleState.validated ||
      PositioningModuleState.readyToUse => colors.accent,
      PositioningModuleState.rich ||
      PositioningModuleState.forming => colors.primary,
      PositioningModuleState.overstated => Colors.orange,
      PositioningModuleState.seed ||
      PositioningModuleState.empty => colors.muted,
    };

String _stateLabel(PositioningModuleState state) => switch (state) {
  PositioningModuleState.validated => '已验证',
  PositioningModuleState.readyToUse => '可直接使用',
  PositioningModuleState.rich => '饱满',
  PositioningModuleState.forming => '成形中',
  PositioningModuleState.seed => '有线索',
  PositioningModuleState.overstated => '证据偏弱',
  PositioningModuleState.empty => '待补充',
};
