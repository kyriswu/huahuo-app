import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';

@immutable
final class V3KnowledgeNotePickerResult {
  V3KnowledgeNotePickerResult(Iterable<V3FeedItem> selectedNotes)
    : selectedNotes = List<V3FeedItem>.unmodifiable(selectedNotes);

  final List<V3FeedItem> selectedNotes;

  List<String> get selectedIds =>
      List<String>.unmodifiable(selectedNotes.map((note) => note.id));
}

Future<V3KnowledgeNotePickerResult?> showV3KnowledgeNotePicker({
  required BuildContext context,
  required Iterable<V3FeedItem> notes,
  Iterable<String> initialSelectedIds = const <String>[],
  String title = '选择笔记',
  String searchHint = '搜索笔记',
}) {
  return showV3GlassBottomSheet<V3KnowledgeNotePickerResult>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: V3KnowledgeNotePickerSheet(
        notes: List<V3FeedItem>.unmodifiable(notes),
        initialSelectedIds: List<String>.unmodifiable(initialSelectedIds),
        title: title,
        searchHint: searchHint,
      ),
    ),
  );
}

class V3KnowledgeNotePickerSheet extends StatefulWidget {
  const V3KnowledgeNotePickerSheet({
    required this.notes,
    this.initialSelectedIds = const <String>[],
    this.title = '选择笔记',
    this.searchHint = '搜索笔记',
    super.key,
  });

  final List<V3FeedItem> notes;
  final List<String> initialSelectedIds;
  final String title;
  final String searchHint;

  @override
  State<V3KnowledgeNotePickerSheet> createState() =>
      _V3KnowledgeNotePickerSheetState();
}

class _V3KnowledgeNotePickerSheetState
    extends State<V3KnowledgeNotePickerSheet> {
  late final TextEditingController _query;
  final _scrollController = ScrollController();
  late final Map<String, V3FeedItem> _notesById;
  late final List<String> _selectedIds;
  KnowledgeSourceFilter _filter = KnowledgeSourceFilter.all;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController()..addListener(_refresh);
    _notesById = <String, V3FeedItem>{
      for (final note in widget.notes) note.id: note,
    };
    _selectedIds = <String>[];
    for (final id in widget.initialSelectedIds) {
      if (_notesById.containsKey(id) && !_selectedIds.contains(id)) {
        _selectedIds.add(id);
      }
    }
  }

  @override
  void dispose() {
    _query
      ..removeListener(_refresh)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _toggle(String id) {
    setState(() {
      if (_selectedIds.remove(id)) return;
      _selectedIds.add(id);
    });
  }

  void _clearSearchAndFilter() {
    _query.clear();
    setState(() => _filter = KnowledgeSourceFilter.all);
  }

  void _complete() {
    Navigator.of(context).pop(
      V3KnowledgeNotePickerResult(
        _selectedIds.map((id) => _notesById[id]).whereType<V3FeedItem>(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final visible = widget.notes
        .where((note) {
          if (!_filter.includes(note.source)) return false;
          if (query.isEmpty) return true;
          return <String?>[
            note.title,
            note.rawBody,
            note.summaryBody,
            ...note.topics,
          ].whereType<String>().any(
            (value) => value.toLowerCase().contains(query),
          );
        })
        .toList(growable: false);
    final grouped = <KnowledgeSourceFilter, List<V3FeedItem>>{};
    for (final note in visible) {
      grouped
          .putIfAbsent(knowledgeSourceFilterFor(note.source), () => [])
          .add(note);
    }
    final mediaQuery = MediaQuery.of(context);
    final availableHeight =
        mediaQuery.size.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.padding.bottom;
    final compactKeyboard =
        mediaQuery.viewInsets.bottom > 0 && availableHeight < 260;
    final searchField = TextField(
      key: const ValueKey('knowledge-note-picker-search'),
      controller: _query,
      contextMenuBuilder: V3TextEditing.buildContextMenu,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded),
        hintText: widget.searchHint,
        isDense: compactKeyboard,
        constraints: compactKeyboard
            ? const BoxConstraints.tightFor(height: 44)
            : null,
        suffixIcon: _query.text.isEmpty
            ? null
            : IconButton(
                key: const ValueKey('knowledge-note-picker-clear-search'),
                tooltip: '清除搜索',
                onPressed: _query.clear,
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    );
    final sourceFilters = SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: KnowledgeSourceFilter.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = KnowledgeSourceFilter.values[index];
          return ChoiceChip(
            key: ValueKey('knowledge-note-picker-source-${filter.name}'),
            label: Text(filter.label),
            selected: _filter == filter,
            onSelected: (_) => setState(() => _filter = filter),
          );
        },
      ),
    );
    final Widget results;
    if (widget.notes.isEmpty) {
      const empty = _PickerEmptyState(
        icon: Icons.note_alt_outlined,
        title: '暂无可选择的笔记',
        message: '外部世界有内容后，可以从这里快速选择。',
      );
      results = compactKeyboard
          ? const SingleChildScrollView(child: empty)
          : empty;
    } else if (visible.isEmpty) {
      final empty = _PickerEmptyState(
        icon: Icons.search_off_rounded,
        title: '没有匹配的笔记',
        message: '换个关键词或来源试试。',
        actionLabel: '清除筛选',
        onAction: _clearSearchAndFilter,
      );
      results = compactKeyboard ? SingleChildScrollView(child: empty) : empty;
    } else {
      results = V3InteractiveScrollbar(
        controller: _scrollController,
        child: ListView(
          key: const ValueKey('knowledge-note-picker-list'),
          controller: _scrollController,
          padding: const EdgeInsets.only(bottom: 8),
          children: [
            for (final filter in KnowledgeSourceFilter.values.skip(1))
              if (grouped[filter]?.isNotEmpty == true) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 13, 8, 5),
                  child: Text(
                    filter.label,
                    style: HuahuoV3Theme.meta.copyWith(
                      color: HuahuoV3Theme.tokensOf(context).muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final note in grouped[filter]!) ...[
                  _KnowledgeNotePickerRow(
                    note: note,
                    selected: _selectedIds.contains(note.id),
                    onTap: () => _toggle(note.id),
                  ),
                  const Divider(height: 1, indent: 8),
                ],
              ],
          ],
        ),
      );
    }
    final confirmButton = SizedBox(
      height: compactKeyboard ? 44 : 52,
      child: FilledButton(
        key: const ValueKey('knowledge-note-picker-confirm'),
        onPressed: _complete,
        child: Text('完成 (${_selectedIds.length})'),
      ),
    );

    return V3SheetScaffold(
      title: compactKeyboard ? null : widget.title,
      showClose: !compactKeyboard,
      maxHeightFactor: compactKeyboard ? 1 : .88,
      child: Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: compactKeyboard
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: searchField),
                        V3CloseButton(
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Expanded(child: results),
                    const SizedBox(height: 4),
                    confirmButton,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    searchField,
                    const SizedBox(height: 10),
                    sourceFilters,
                    const SizedBox(height: 4),
                    Expanded(child: results),
                    const SizedBox(height: 8),
                    confirmButton,
                  ],
                ),
        ),
      ),
    );
  }
}

class _KnowledgeNotePickerRow extends StatelessWidget {
  const _KnowledgeNotePickerRow({
    required this.note,
    required this.selected,
    required this.onTap,
  });

  final V3FeedItem note;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final body = note.summaryBody?.trim().isNotEmpty == true
        ? note.summaryBody!.trim()
        : note.rawBody.trim();
    final topics = note.topics.take(3).join(' · ');
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('knowledge-note-picker-note-${note.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 68),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 24,
                    color: selected
                        ? HuahuoV3Theme.tokensOf(context).ink
                        : HuahuoV3Theme.tokensOf(context).muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        note.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HuahuoV3Theme.body.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (body.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HuahuoV3Theme.meta.copyWith(
                            color: HuahuoV3Theme.tokensOf(context).muted,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        topics.isEmpty
                            ? note.source.label
                            : '${note.source.label} · $topics',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HuahuoV3Theme.meta.copyWith(
                          color: HuahuoV3Theme.tokensOf(context).muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
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

class _PickerEmptyState extends StatelessWidget {
  const _PickerEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 30, color: HuahuoV3Theme.tokensOf(context).muted),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: HuahuoV3Theme.body.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 5),
          Text(
            message,
            textAlign: TextAlign.center,
            style: HuahuoV3Theme.meta.copyWith(
              color: HuahuoV3Theme.tokensOf(context).muted,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 44,
              child: TextButton(
                key: const ValueKey('knowledge-note-picker-clear-filters'),
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
