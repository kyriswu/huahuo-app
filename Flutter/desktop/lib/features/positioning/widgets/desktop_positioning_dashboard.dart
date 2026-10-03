import 'package:flutter/material.dart';
import 'package:huahuo_api/huahuo_api.dart';

/// Renders the public, already-parsed positioning progress payload for Desktop.
class DesktopPositioningDashboard extends StatelessWidget {
  const DesktopPositioningDashboard({
    required this.profile,
    this.compact = false,
    super.key,
  });

  final PositioningProgressProfile profile;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
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
              children: [
                Container(
                  width: compact ? 34 : 42,
                  height: compact ? 34 : 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.explore_outlined,
                    size: compact ? 18 : 22,
                    color: colors.onPrimaryContainer,
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
                          color: colors.onSurfaceVariant,
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
                          color: colors.onSurface,
                          fontSize: compact ? 15 : 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                _ScoreBadge(percent: profile.completedPercent),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              summary,
              maxLines: compact ? 2 : 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: compact ? 12 : 13.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            _ModuleGrid(modules: profile.modules, compact: compact),
            if (!compact) ...[
              const SizedBox(height: 16),
              for (final module in profile.modules) ...[
                _ModuleDetail(module: module),
                const SizedBox(height: 10),
              ],
              if (profile.nextFocus.isNotEmpty ||
                  profile.updatedFiles.isNotEmpty)
                _NextFocus(profile: profile),
            ],
          ],
        );
        return Container(
          key: ValueKey<String>(
            'desktop-positioning-dashboard-${compact ? 'compact' : 'full'}',
          ),
          padding: EdgeInsets.all(compact ? 12 : 16),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: !compact && constraints.hasBoundedHeight
              ? SingleChildScrollView(primary: false, child: content)
              : content,
        );
      },
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Text(
        '$percent%',
        style: TextStyle(
          color: colors.primary,
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
        final columns = constraints.maxWidth >= 780
            ? 4
            : constraints.maxWidth >= 440
            ? 2
            : 1;
        const gap = 8.0;
        final width = ((constraints.maxWidth - gap * (columns - 1)) / columns)
            .clamp(0, 280)
            .toDouble();
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final module in modules)
              SizedBox(
                width: width,
                child: _ModuleCard(module: module, compact: compact),
              ),
          ],
        );
      },
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({required this.module, required this.compact});

  final PositioningProgressModule module;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey<String>('desktop-positioning-module-${module.id}'),
      padding: EdgeInsets.all(compact ? 8 : 10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: module.weight >= 20 ? colors.primary : colors.outlineVariant,
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
                    color: colors.onSurface,
                    fontSize: compact ? 11.5 : 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${module.weight}%',
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: module.percent / 100,
              minHeight: 5,
              color: _stateColor(colors, module.state),
              backgroundColor: colors.outlineVariant,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  _stateLabel(module.state),
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 10.5,
                  ),
                ),
              ),
              Text(
                '${module.score}/${module.weight}',
                style: TextStyle(
                  color: colors.onSurface,
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
    final colors = Theme.of(context).colorScheme;
    final content = module.summary.isNotEmpty
        ? module.summary
        : module.content.isNotEmpty
        ? module.content
        : '待补充';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            module.label,
            style: TextStyle(
              color: colors.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            content,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          _DetailLine(label: '证据', items: module.evidence, empty: '待补充真实证据'),
          _DetailLine(label: '缺口', items: module.missing, empty: '暂未列出'),
          _DetailLine(label: '风险', items: module.risks, empty: '暂无明显风险'),
        ],
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.label,
    required this.items,
    required this.empty,
  });

  final String label;
  final List<String> items;
  final String empty;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 5),
    child: Text(
      '$label：${items.isEmpty ? empty : items.join('、')}',
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontSize: 12,
        height: 1.4,
      ),
    ),
  );
}

class _NextFocus extends StatelessWidget {
  const _NextFocus({required this.profile});

  final PositioningProgressProfile profile;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (profile.nextFocus.isNotEmpty) ...[
            Text(
              '接下来建议聊',
              style: TextStyle(
                color: colors.onSurface,
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
                    color: colors.onSurfaceVariant,
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
                color: colors.onSurfaceVariant,
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

Color _stateColor(ColorScheme colors, PositioningModuleState state) =>
    switch (state) {
      PositioningModuleState.validated ||
      PositioningModuleState.readyToUse => colors.primary,
      PositioningModuleState.rich ||
      PositioningModuleState.forming => colors.secondary,
      PositioningModuleState.overstated => Colors.orange,
      PositioningModuleState.seed ||
      PositioningModuleState.empty => colors.onSurfaceVariant,
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
