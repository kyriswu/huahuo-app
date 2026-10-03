import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../domain/feed_item_models.dart';

enum V3FeedNoteSourceFilter {
  manual,
  chatExcerpt,
  noteImport,
  transcription,
  history,
  externalKnowledge,
  subscriptionRewrite,
}

@immutable
final class V3FeedNoteFilterSelection {
  const V3FeedNoteFilterSelection({
    this.sources = const <V3FeedNoteSourceFilter>{},
  });

  final Set<V3FeedNoteSourceFilter> sources;

  int get activeCount => sources.length;
  bool get isEmpty => activeCount == 0;
  String get label => isEmpty ? '全部笔记' : '已选 $activeCount 项';

  V3FeedNoteFilterSelection toggleSource(V3FeedNoteSourceFilter value) =>
      V3FeedNoteFilterSelection(sources: _toggle(sources, value));

  bool includes(V3FeedItem item) {
    return sources.isEmpty ||
        sources.any((value) {
          return switch (value) {
            V3FeedNoteSourceFilter.manual =>
              item.source == V3MaterialSource.note,
            V3FeedNoteSourceFilter.chatExcerpt =>
              item.source == V3MaterialSource.chatExcerpt,
            V3FeedNoteSourceFilter.noteImport =>
              item.source == V3MaterialSource.documentImport,
            V3FeedNoteSourceFilter.transcription => const <V3MaterialSource>{
              V3MaterialSource.meeting,
              V3MaterialSource.internalRecording,
              V3MaterialSource.monologue,
              V3MaterialSource.recordingCard,
              V3MaterialSource.mediaImport,
            }.contains(item.source),
            V3FeedNoteSourceFilter.history =>
              item.source == V3MaterialSource.materialMigration,
            V3FeedNoteSourceFilter.externalKnowledge =>
              item.source == V3MaterialSource.knowledgeSquare,
            V3FeedNoteSourceFilter.subscriptionRewrite =>
              item.source == V3MaterialSource.subscription,
          };
        });
  }

  static Set<T> _toggle<T>(Set<T> values, T value) {
    final next = Set<T>.of(values);
    next.contains(value) ? next.remove(value) : next.add(value);
    return Set<T>.unmodifiable(next);
  }
}

class V3FeedNoteFilterSheet extends StatefulWidget {
  const V3FeedNoteFilterSheet({
    required this.initialSelection,
    required this.matchingCount,
    required this.onClose,
    required this.onApply,
    super.key,
  });

  final V3FeedNoteFilterSelection initialSelection;
  final int Function(V3FeedNoteFilterSelection selection) matchingCount;
  final VoidCallback onClose;
  final ValueChanged<V3FeedNoteFilterSelection> onApply;

  @override
  State<V3FeedNoteFilterSheet> createState() => _V3FeedNoteFilterSheetState();
}

class _V3FeedNoteFilterSheetState extends State<V3FeedNoteFilterSheet> {
  late V3FeedNoteFilterSelection _selection;

  @override
  void initState() {
    super.initState();
    _selection = widget.initialSelection;
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final count = widget.matchingCount(_selection);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactHeight = constraints.maxHeight < 420;
        return Container(
          key: const ValueKey('feed-note-filter-sheet'),
          decoration: BoxDecoration(
            color: colors.canvas,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            border: Border.all(color: colors.line),
            boxShadow: [
              BoxShadow(
                color: colors.ink.withValues(alpha: .12),
                blurRadius: 32,
                offset: const Offset(0, -10),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                Center(
                  child: Container(
                    width: 56,
                    height: 5,
                    decoration: BoxDecoration(
                      color: colors.line,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(23, 6, 17, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '筛选笔记',
                              style: TextStyle(
                                color: colors.ink,
                                fontSize: 21,
                                height: 1.4,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (!compactHeight)
                              Text(
                                '按来源缩小笔记范围',
                                style: TextStyle(
                                  color: colors.muted,
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                          ],
                        ),
                      ),
                      V3CloseButton(
                        key: const ValueKey('feed-note-filter-close'),
                        tooltip: '关闭',
                        onPressed: widget.onClose,
                        color: colors.text,
                      ),
                    ],
                  ),
                ),
                SizedBox(height: compactHeight ? 0 : 11),
                Divider(
                  height: compactHeight ? 17 : 25,
                  indent: 23,
                  endIndent: 23,
                  color: colors.line,
                ),
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('feed-note-filter-options-scroll'),
                    padding: const EdgeInsets.fromLTRB(23, 0, 23, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '来源',
                          style: TextStyle(color: colors.muted, fontSize: 14),
                        ),
                        const SizedBox(height: 10),
                        LayoutBuilder(
                          builder: (context, optionConstraints) {
                            final textScaler = MediaQuery.textScalerOf(context);
                            final minimumChoiceWidth =
                                80 + textScaler.scale(12.5) * 4;
                            final columnCount =
                                optionConstraints.maxWidth >=
                                    minimumChoiceWidth * 2 + 12
                                ? 2
                                : 1;
                            final itemWidth =
                                (optionConstraints.maxWidth -
                                    12 * (columnCount - 1)) /
                                columnCount;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 9,
                              children: [
                                for (final item in _sourceOptions)
                                  SizedBox(
                                    width: itemWidth,
                                    child: _choice(item),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                Divider(
                  height: 1,
                  indent: 23,
                  endIndent: 23,
                  color: colors.line,
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    23,
                    compactHeight ? 8 : 17,
                    23,
                    compactHeight ? 8 : 12,
                  ),
                  child: Text(
                    _selection.isEmpty
                        ? '未选择筛选条件'
                        : '已选择 ${_selection.activeCount} 项',
                    style: TextStyle(
                      color: _selection.isEmpty ? colors.muted : colors.accent,
                      fontSize: 13,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(23, 0, 23, 17),
                  child: Row(
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 104,
                          maxWidth: 104,
                          minHeight: 52,
                        ),
                        child: OutlinedButton(
                          key: const ValueKey('feed-note-filter-reset'),
                          onPressed: _selection.isEmpty
                              ? null
                              : () => setState(
                                  () => _selection =
                                      const V3FeedNoteFilterSelection(),
                                ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.text,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            side: BorderSide(color: colors.line),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('重置'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 52),
                          child: FilledButton(
                            key: const ValueKey('feed-note-filter-apply'),
                            onPressed: () => widget.onApply(_selection),
                            style: FilledButton.styleFrom(
                              backgroundColor: colors.primary,
                              foregroundColor: colors.onPrimary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              _selection.isEmpty ? '查看全部笔记' : '查看 $count 条笔记',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _choice(_FilterOption option) {
    final selected = _selection.sources.contains(option.value);
    return _V3FilterChoice(
      label: option.label,
      icon: option.icon,
      selected: selected,
      onTap: () => setState(() {
        _selection = _selection.toggleSource(option.value);
      }),
    );
  }
}

class _V3FilterChoice extends StatelessWidget {
  const _V3FilterChoice({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final selectedSurface = HuahuoV3Theme.semanticSurface(
      colors.accent,
      colors.surface,
    );
    return Material(
      color: selected ? selectedSurface : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: BorderSide(color: selected ? colors.accent : colors.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  icon,
                  size: 15,
                  color: selected ? colors.accent : colors.text,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(color: colors.text, fontSize: 12.5),
                  ),
                ),
                if (selected)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.check_circle_outline_rounded,
                      size: 15,
                      color: colors.accent,
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

final class _FilterOption {
  const _FilterOption(this.label, this.icon, this.value);

  final String label;
  final IconData icon;
  final V3FeedNoteSourceFilter value;
}

const _sourceOptions = <_FilterOption>[
  _FilterOption('手动创建', Icons.edit_note_rounded, V3FeedNoteSourceFilter.manual),
  _FilterOption(
    '聊天摘录',
    Icons.chat_bubble_outline_rounded,
    V3FeedNoteSourceFilter.chatExcerpt,
  ),
  _FilterOption(
    '笔记导入',
    Icons.note_add_outlined,
    V3FeedNoteSourceFilter.noteImport,
  ),
  _FilterOption(
    '录音转写',
    Icons.graphic_eq_rounded,
    V3FeedNoteSourceFilter.transcription,
  ),
  _FilterOption('历史资料', Icons.history_rounded, V3FeedNoteSourceFilter.history),
  _FilterOption(
    '外部知识',
    Icons.language_rounded,
    V3FeedNoteSourceFilter.externalKnowledge,
  ),
  _FilterOption(
    '订阅修订',
    Icons.article_outlined,
    V3FeedNoteSourceFilter.subscriptionRewrite,
  ),
];
