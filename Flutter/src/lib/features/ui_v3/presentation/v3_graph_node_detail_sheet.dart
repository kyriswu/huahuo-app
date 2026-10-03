import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../domain/feed_item_models.dart';
import '../domain/ui_v3_models.dart';

Future<void> showV3GraphNodeDetailSheet({
  required BuildContext context,
  required V3GraphNode node,
  required List<V3GraphEdge> edges,
  required Map<String, V3GraphNode> nodesById,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    showDragHandle: false,
    builder: (sheetContext) => DraggableScrollableSheet(
      key: const ValueKey('feed-graph-node-detail-sheet'),
      expand: false,
      initialChildSize: .34,
      minChildSize: .26,
      maxChildSize: .78,
      snap: true,
      snapSizes: const [.34, .78],
      builder: (context, scrollController) => V3GlassBottomSheet(
        child: Expanded(
          child: SafeArea(
            top: false,
            bottom: false,
            child: _NodeDetailBody(
              node: node,
              edges: edges,
              nodesById: nodesById,
              scrollController: scrollController,
            ),
          ),
        ),
      ),
    ),
  );
}

class _NodeDetailBody extends StatelessWidget {
  const _NodeDetailBody({
    required this.node,
    required this.edges,
    required this.nodesById,
    required this.scrollController,
  });

  final V3GraphNode node;
  final List<V3GraphEdge> edges;
  final Map<String, V3GraphNode> nodesById;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final relations =
        edges
            .where(
              (edge) => edge.sourceId == node.id || edge.targetId == node.id,
            )
            .toList()
          ..sort((left, right) {
            final weight = right.weight.compareTo(left.weight);
            return weight != 0 ? weight : left.id.compareTo(right.id);
          });
    final relatedIds = <String>{
      for (final edge in relations)
        if (edge.sourceId != node.id) edge.sourceId else edge.targetId,
    }..remove(node.id);
    final attributes = node.attributes.entries
        .where((entry) => _safeAttribute(entry.key, entry.value))
        .toList();
    return Material(
      type: MaterialType.transparency,
      child: CustomScrollView(
        controller: scrollController,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 30),
            sliver: SliverList.list(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('实体详情', style: HuahuoV3Theme.sectionTitle),
                    ),
                    V3CloseButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                Text(
                  node.label,
                  key: ValueKey('graph-node-detail-title-${node.id}'),
                  style: HuahuoV3Theme.h1.copyWith(fontSize: 22),
                ),
                const SizedBox(height: 6),
                Text(
                  node.materialSourceProvided
                      ? '${node.entityType} · ${node.source.label}'
                      : node.entityType,
                  style: HuahuoV3Theme.meta.copyWith(color: colors.muted),
                ),
                if (node.summary.trim().isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    node.summary.trim(),
                    style: HuahuoV3Theme.body.copyWith(height: 1.55),
                  ),
                ],
                if (node.labels.isNotEmpty || node.topics.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final label in <String>{
                        ...node.labels,
                        ...node.topics,
                      })
                        if (label.trim().isNotEmpty)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(label.trim()),
                          ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                _NodeMetaRow(label: '关联实体', value: '${relatedIds.length} 个'),
                if (node.updatedAt != null)
                  _NodeMetaRow(
                    label: '更新时间',
                    value: _formatDateTime(context, node.updatedAt!),
                  ),
                if (attributes.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const Text('属性', style: HuahuoV3Theme.sectionTitle),
                  const SizedBox(height: 6),
                  for (final entry in attributes)
                    _NodeMetaRow(
                      label: entry.key,
                      value: _safeText(entry.value),
                    ),
                ],
                if (relations.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const Text('关系', style: HuahuoV3Theme.sectionTitle),
                  const SizedBox(height: 6),
                  for (final edge in relations)
                    _RelationRow(
                      node: node,
                      edge: edge,
                      other:
                          nodesById[edge.sourceId == node.id
                              ? edge.targetId
                              : edge.sourceId],
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NodeMetaRow extends StatelessWidget {
  const _NodeMetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: HuahuoV3Theme.meta.copyWith(color: colors.muted),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(value, style: HuahuoV3Theme.body)),
        ],
      ),
    );
  }
}

class _RelationRow extends StatelessWidget {
  const _RelationRow({
    required this.node,
    required this.edge,
    required this.other,
  });

  final V3GraphNode node;
  final V3GraphEdge edge;
  final V3GraphNode? other;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final outgoing = edge.sourceId == node.id;
    final relation = edge.label.trim().isEmpty ? edge.kind.label : edge.label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(
            edge.isSelfLoop
                ? LucideIcons.rotateCcw
                : edge.directed
                ? outgoing
                      ? LucideIcons.arrowRight
                      : LucideIcons.arrowLeft
                : LucideIcons.minus,
            size: 16,
            color: colors.muted,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '$relation · ${other?.label ?? (edge.isSelfLoop ? node.label : '未知实体')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HuahuoV3Theme.body,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final localizations = MaterialLocalizations.of(context);
  return '${localizations.formatShortDate(local)} '
      '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
}

bool _safeAttribute(String key, Object? value) {
  if (RegExp(
    r'(path|uri|file|token|secret)',
    caseSensitive: false,
  ).hasMatch(key)) {
    return false;
  }
  final text = _safeText(value).trim().toLowerCase();
  return text.isNotEmpty &&
      !text.startsWith('/') &&
      !text.startsWith('file:') &&
      !text.contains('app-private');
}

String _safeText(Object? value) => switch (value) {
  null => '',
  String text => text,
  num number => '$number',
  bool flag => flag ? '是' : '否',
  _ => '$value',
};
