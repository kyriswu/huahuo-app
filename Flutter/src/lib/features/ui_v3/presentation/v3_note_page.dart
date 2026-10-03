import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../shared/navigation/unsaved_changes_guard.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../application/knowledge_library_controller.dart';
import '../application/profile_hub_controller.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';
import '../domain/profile_activity_models.dart';
import 'v3_material_import_surfaces.dart';

enum _V3NoteLoadState { loading, ready, missing }

class V3NotePage extends ConsumerStatefulWidget {
  const V3NotePage({
    this.itemId,
    this.initialTitle = '',
    this.initialBody = '',
    super.key,
  });

  final String? itemId;
  final String initialTitle;
  final String initialBody;

  @override
  ConsumerState<V3NotePage> createState() => _V3NotePageState();
}

class _V3NotePageState extends ConsumerState<V3NotePage> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late final FocusNode _bodyFocus;
  late TextEditingValue _lastBodyValue;
  final List<TextEditingValue> _undoStack = <TextEditingValue>[];
  final List<TextEditingValue> _redoStack = <TextEditingValue>[];
  final Set<String> _topics = <String>{};
  final List<String> _relatedNoteIds = <String>[];
  String? _contentLineId;
  String? _contentLineName;
  bool _applyingHistory = false;
  bool _saving = false;
  String? _pendingSavedId;
  String _baselineSignature = '';
  late _V3NoteLoadState _loadState;
  int _resolutionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    _body = TextEditingController();
    _bodyFocus = FocusNode(debugLabel: 'note-body');
    _lastBodyValue = _body.value;
    _title.addListener(_handleTitleChanged);
    _body.addListener(_handleBodyChanged);
    _loadState = widget.itemId == null
        ? _V3NoteLoadState.ready
        : _V3NoteLoadState.loading;
    _beginNoteResolution();
  }

  @override
  void didUpdateWidget(covariant V3NotePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId) {
      _beginNoteResolution(notify: true);
    }
  }

  @override
  void dispose() {
    _title
      ..removeListener(_handleTitleChanged)
      ..dispose();
    _body.removeListener(_handleBodyChanged);
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadState == _V3NoteLoadState.loading) {
      return const V3PageScaffold(
        title: '正在加载笔记',
        subtitle: '正在恢复外部世界内容',
        fallbackRoute: '/v3/feed',
        children: [
          SizedBox(height: 72),
          Center(child: CircularProgressIndicator.adaptive()),
        ],
      );
    }
    if (_loadState == _V3NoteLoadState.missing) {
      return V3PageScaffold(
        title: '笔记不存在',
        subtitle: '这条笔记可能已经被删除。',
        fallbackRoute: '/v3/feed',
        children: [
          V3PrimaryButton(
            label: canReturnToPreviousRoute(context) ? '返回上一级' : '返回 思想图谱',
            onPressed: () => returnToPreviousRoute(
              context,
              fallbackRoute: AppRoutePaths.home,
            ),
          ),
        ],
      );
    }
    if (_saving) {
      return V3MaterialImportProgressSurface(
        sourceLabel: _title.text.trim().isEmpty ? '今日随想' : _title.text.trim(),
        sourceIcon: Icons.link_rounded,
        title: '文字整理中...',
        message: '正在提取主题与结构，完成后会自动保存为笔记。',
        onBack: () => showV3Snack(context, '正在保存，完成后会自动打开笔记'),
      );
    }

    ref.watch(knowledgeLibraryControllerProvider);
    final colors = HuahuoV3Theme.tokensOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return UnsavedChangesGuard(
      hasUnsavedChanges: _hasUnsavedChanges,
      isLeaveBlocked: _saving,
      fallbackRoute: AppRoutePaths.home,
      hasUnsavedChangesNow: () => _hasUnsavedChanges,
      isLeaveBlockedNow: () => _saving,
      onLeaveBlocked: () => showV3Snack(context, '正在保存，请稍候'),
      onConfirmLeave: _confirmDiscardForLeave,
      onConfirmForegroundIngress: _confirmForegroundIngress,
      child: Builder(
        builder: (guardContext) => Scaffold(
          backgroundColor: colors.canvas,
          resizeToAvoidBottomInset: false,
          bottomNavigationBar: AnimatedPadding(
            duration: V3MotionTokens.standard,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: keyboardInset),
            child: SafeArea(top: false, child: _buildV5NoteToolbar()),
          ),
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                SizedBox(
                  height: 56,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 14,
                        top: 6,
                        child: IconButton(
                          tooltip: '收起文字编辑',
                          onPressed: () => unawaited(
                            UnsavedChangesGuard.requestLeave(guardContext),
                          ),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                          iconSize: 23,
                        ),
                      ),
                      Center(
                        child: Text(
                          '文字',
                          style: TextStyle(
                            color: colors.ink,
                            fontSize: 17,
                            height: 1.45,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 24,
                        top: 10,
                        child: SizedBox(
                          width: 84,
                          height: 40,
                          child: FilledButton(
                            key: const ValueKey('note-save-button'),
                            onPressed: _saving ? null : _save,
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              backgroundColor: const Color(0xff121316),
                              disabledBackgroundColor: const Color(
                                0xff121316,
                              ).withValues(alpha: .42),
                              shape: const StadiumBorder(),
                            ),
                            child: Text(
                              _saving ? '保存中' : '完成',
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.4,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                    child: Column(
                      key: const ValueKey('note-editor-surface'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        V3CenteredInput(
                          key: const ValueKey('note-title-shell'),
                          minHeight: 89,
                          builder: (focusNode) => TextField(
                            key: const ValueKey('note-title-field'),
                            controller: _title,
                            focusNode: focusNode,
                            contextMenuBuilder: V3TextEditing.buildContextMenu,
                            textInputAction: TextInputAction.next,
                            minLines: 1,
                            maxLines: 2,
                            onSubmitted: (_) => _bodyFocus.requestFocus(),
                            decoration: V3TextEditing.inlineDecoration.copyWith(
                              hintText: '给今天留一点空白',
                            ),
                            style: const TextStyle(
                              fontSize: 22,
                              height: 1.35,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Divider(height: 1, thickness: 1, color: colors.line),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('note-body-field'),
                            controller: _body,
                            contextMenuBuilder: V3TextEditing.buildContextMenu,
                            focusNode: _bodyFocus,
                            expands: true,
                            minLines: null,
                            maxLines: null,
                            textAlignVertical: TextAlignVertical.top,
                            keyboardType: TextInputType.multiline,
                            scrollPadding: const EdgeInsets.only(bottom: 72),
                            decoration: const InputDecoration(
                              hintText: '真正有价值的笔记，不只是把信息存下来。',
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.fromLTRB(0, 32, 0, 16),
                            ),
                            style: const TextStyle(
                              fontSize: 16,
                              height: 1.78,
                              fontWeight: FontWeight.w400,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                      ],
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

  void _beginNoteResolution({bool notify = false}) {
    final generation = ++_resolutionGeneration;
    final itemId = widget.itemId;
    if (itemId == null) {
      _applyResolvedNote(null, creating: true, notify: notify);
      return;
    }

    final library = ref.read(knowledgeLibraryControllerProvider);
    if (library.restoreComplete) {
      _applyResolvedNote(
        library.noteForId(itemId),
        creating: false,
        notify: notify,
      );
      return;
    }

    void markLoading() => _loadState = _V3NoteLoadState.loading;
    if (notify && mounted) {
      setState(markLoading);
    } else {
      markLoading();
    }
    unawaited(_resolveAfterRestore(generation, itemId, library));
  }

  Future<void> _resolveAfterRestore(
    int generation,
    String itemId,
    KnowledgeLibraryController library,
  ) async {
    await library.restore();
    if (!mounted ||
        generation != _resolutionGeneration ||
        widget.itemId != itemId) {
      return;
    }
    final currentLibrary = ref.read(knowledgeLibraryControllerProvider);
    if (!identical(currentLibrary, library)) {
      _beginNoteResolution(notify: true);
      return;
    }
    _applyResolvedNote(
      currentLibrary.noteForId(itemId),
      creating: false,
      notify: true,
    );
  }

  void _applyResolvedNote(
    V3FeedItem? note, {
    required bool creating,
    required bool notify,
  }) {
    void apply() {
      _hydrateEditor(note);
      _loadState = creating || note != null
          ? _V3NoteLoadState.ready
          : _V3NoteLoadState.missing;
    }

    if (notify && mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  void _hydrateEditor(V3FeedItem? note) {
    final initialTitle = note?.title ?? widget.initialTitle;
    final initialBody = note?.rawBody ?? widget.initialBody;
    _applyingHistory = true;
    _title.value = TextEditingValue(
      text: initialTitle,
      selection: TextSelection.collapsed(offset: initialTitle.length),
    );
    _body.value = TextEditingValue(
      text: initialBody,
      selection: TextSelection.collapsed(offset: initialBody.length),
    );
    _lastBodyValue = _body.value;
    _undoStack.clear();
    _redoStack.clear();
    _topics
      ..clear()
      ..addAll(note?.topics ?? const <String>[]);
    _relatedNoteIds
      ..clear()
      ..addAll(
        note?.linkedMaterials.map((material) => material.id) ??
            const <String>[],
      );
    _contentLineId = note?.contentLineId;
    _contentLineName = note?.contentLineName;
    _saving = false;
    _pendingSavedId = null;
    _applyingHistory = false;
    _baselineSignature = _editorSignature;
  }

  String get _editorSignature {
    String encode(String value) => Uri.encodeComponent(value);
    final topics = _topics.map(encode).toList()..sort();
    final relatedIds = _relatedNoteIds.map(encode).toList();
    return <String>[
      encode(_title.text),
      encode(_body.text),
      topics.join(','),
      encode(_contentLineId ?? ''),
      encode(_contentLineName ?? ''),
      relatedIds.join(','),
    ].join('|');
  }

  bool get _hasUnsavedChanges => _editorSignature != _baselineSignature;

  Future<bool> _confirmDiscardForLeave(BuildContext guardContext) async {
    final discard = await _showDiscardDialog(
      guardContext,
      message: '返回后，本次编辑的内容不会保留。',
    );
    return mounted && discard;
  }

  Future<bool> _confirmForegroundIngress(BuildContext guardContext) async {
    final discard = await _showDiscardDialog(
      guardContext,
      message: '查看新内容前将放弃本次未保存修改。',
      primaryLabel: '放弃修改并查看',
    );
    if (!mounted || !discard) return false;
    final library = ref.read(knowledgeLibraryControllerProvider);
    final persisted = widget.itemId == null
        ? null
        : library.noteForId(widget.itemId!);
    setState(() => _hydrateEditor(persisted));
    return true;
  }

  Future<bool> _showDiscardDialog(
    BuildContext guardContext, {
    required String message,
    String primaryLabel = '放弃修改',
  }) async {
    final discard = await showDialog<bool>(
      context: guardContext,
      builder: (dialogContext) => V3GlassDialog(
        title: '放弃未保存的修改？',
        message: message,
        cancelLabel: '继续编辑',
        primaryLabel: primaryLabel,
        onPrimary: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    return discard == true;
  }

  Future<void> _save() async {
    if (_saving) return;
    final rawBody = _body.text.trim();
    if (rawBody.isEmpty) {
      showV3Snack(context, '先写下一点内容');
      return;
    }

    final library = ref.read(knowledgeLibraryControllerProvider);
    final title = _deriveNoteTitle(_title.text, rawBody);
    final linkedMaterials = _relatedNoteIds
        .map(library.noteForId)
        .whereType<V3FeedItem>()
        .where((note) => note.id != widget.itemId)
        .map(
          (note) => V3LinkedMaterialRef(
            id: note.id,
            source: note.source,
            title: note.title,
            summary: note.summaryBody,
          ),
        );
    final draft = V3NoteDraft(
      title: title,
      rawBody: rawBody,
      topics: _topics,
      contentLineId: _contentLineId,
      contentLineName: _contentLineName,
      linkedMaterials: linkedMaterials,
    );
    setState(() => _saving = true);
    final existingId = widget.itemId ?? _pendingSavedId;
    final saved = existingId == null
        ? library.createManualNoteDraft(draft)
        : library.updateManualNoteDraft(id: existingId, draft: draft);
    if (saved == null) {
      if (mounted) setState(() => _saving = false);
      showV3Snack(context, '笔记不存在，无法保存');
      return;
    }
    _pendingSavedId ??= saved.id;

    final persisted = await library.flushPersistenceResult();
    if (!mounted) return;
    if (!persisted) {
      setState(() => _saving = false);
      showV3Snack(context, '保存失败，内容仍保留，请重试');
      return;
    }

    if (widget.itemId == null) {
      ref
          .read(profileHubControllerProvider)
          .recordActivity(
            V3ProfileActivity(
              id: 'manual-note-${saved.id}',
              occurredAt: saved.createdAt,
              type: V3ProfileActivityType.raw,
              title: saved.title,
              feedItemId: saved.id,
              route: '/v3/feed/items/${Uri.encodeComponent(saved.id)}',
            ),
          );
    }
    _baselineSignature = _editorSignature;
    if (!mounted) return;
    if (widget.itemId != null && context.canPop()) {
      context.pop(true);
      return;
    }
    context.pushReplacement(AppRoutePaths.feedItem(saved.id));
  }

  void _handleTitleChanged() {
    if (!_applyingHistory && mounted) setState(() {});
  }

  void _handleBodyChanged() {
    final current = _body.value;
    if (_applyingHistory) {
      _lastBodyValue = current;
      return;
    }
    if (current.text != _lastBodyValue.text) {
      _undoStack.add(_lastBodyValue);
      if (_undoStack.length > 100) _undoStack.removeAt(0);
      _redoStack.clear();
      _lastBodyValue = current;
      if (mounted) setState(() {});
    } else {
      _lastBodyValue = current;
    }
  }

  Widget _buildV5NoteToolbar() {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: const ValueKey('note-markdown-toolbar'),
      height: 82,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.canvas,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('note-more-tools-button'),
            tooltip: '更多工具',
            onPressed: () => unawaited(_showMarkdownTools()),
            icon: const Icon(Icons.add_rounded),
            iconSize: 24,
          ),
          IconButton(
            tooltip: '快速插入待办',
            onPressed: _insertTask,
            icon: const Icon(Icons.checklist_rounded),
            iconSize: 22,
          ),
          IconButton(
            tooltip: '插入图片',
            onPressed: _insertImagePlaceholder,
            icon: const Icon(Icons.image_outlined),
            iconSize: 21,
          ),
          const Spacer(),
          Text(
            '${_body.text.runes.length} 字',
            key: const ValueKey('note-character-count'),
            style: TextStyle(
              color: colors.muted,
              fontSize: 13,
              height: 1.5,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showMarkdownTools() {
    FocusManager.instance.primaryFocus?.unfocus();
    final colors = HuahuoV3Theme.tokensOf(context);
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: colors.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: colors.line,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                '文字工具',
                style: TextStyle(
                  fontSize: 18,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              AnimatedBuilder(
                animation: _body,
                builder: (context, child) => _buildMarkdownToolbar(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMarkdownToolbar() {
    return V3Card(
      key: const ValueKey('note-markdown-tools-panel'),
      radius: 8,
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: 54,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              _MarkdownToolButton(
                tooltip: '撤销',
                icon: Icons.undo_rounded,
                onPressed: _undoStack.isEmpty ? null : _undo,
              ),
              _MarkdownToolButton(
                tooltip: '重做',
                icon: Icons.redo_rounded,
                onPressed: _redoStack.isEmpty ? null : _redo,
              ),
              const _ToolbarDivider(),
              _MarkdownToolButton(
                tooltip: '一级标题',
                label: 'H1',
                onPressed: () => _insertHeading(1),
              ),
              _MarkdownToolButton(
                tooltip: '二级标题',
                label: 'H2',
                onPressed: () => _insertHeading(2),
              ),
              _MarkdownToolButton(
                tooltip: '三级标题',
                label: 'H3',
                onPressed: () => _insertHeading(3),
              ),
              const _ToolbarDivider(),
              _MarkdownToolButton(
                tooltip: '加粗',
                icon: Icons.format_bold_rounded,
                onPressed: _insertBold,
              ),
              _MarkdownToolButton(
                tooltip: '斜体',
                icon: Icons.format_italic_rounded,
                onPressed: _insertItalic,
              ),
              _MarkdownToolButton(
                tooltip: '删除线',
                icon: Icons.strikethrough_s_rounded,
                onPressed: _insertStrikethrough,
              ),
              _MarkdownToolButton(
                tooltip: '行内代码',
                icon: Icons.code_rounded,
                onPressed: _insertInlineCode,
              ),
              _MarkdownToolButton(
                tooltip: '引用',
                icon: Icons.format_quote_rounded,
                onPressed: _insertQuote,
              ),
              _MarkdownToolButton(
                tooltip: '有序列表',
                icon: Icons.format_list_numbered_rounded,
                onPressed: _insertOrderedList,
              ),
              _MarkdownToolButton(
                tooltip: '无序列表',
                icon: Icons.format_list_bulleted_rounded,
                onPressed: _insertBullet,
              ),
              _MarkdownToolButton(
                tooltip: '待办事项',
                icon: Icons.checklist_rounded,
                onPressed: _insertTask,
              ),
              _MarkdownToolButton(
                tooltip: '链接',
                icon: Icons.link_rounded,
                onPressed: _insertLink,
              ),
              const _ToolbarDivider(),
              _MarkdownToolButton(
                tooltip: '代码块',
                icon: Icons.data_object_rounded,
                onPressed: _insertCodeBlock,
              ),
              _MarkdownToolButton(
                tooltip: '分隔线',
                icon: Icons.horizontal_rule_rounded,
                onPressed: _insertDivider,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    final current = _normalizeBodyValue(_body.value);
    final previous = _normalizeBodyValue(_undoStack.removeLast());
    _redoStack.add(current);
    _applyBodyValue(previous);
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    final current = _normalizeBodyValue(_body.value);
    final next = _normalizeBodyValue(_redoStack.removeLast());
    _undoStack.add(current);
    _applyBodyValue(next);
  }

  void _insertHeading(int level) => _insertIntoBody(
    transform: (selected) {
      final marker = '${List<String>.filled(level, '#').join()} ';
      return selected.isEmpty
          ? marker
          : selected.split('\n').map((line) => '$marker$line').join('\n');
    },
    cursorOffsetWhenEmpty: level + 1,
  );

  void _insertBold() => _insertIntoBody(
    transform: (selected) => '**$selected**',
    cursorOffsetWhenEmpty: 2,
  );

  void _insertItalic() => _insertIntoBody(
    transform: (selected) => '*$selected*',
    cursorOffsetWhenEmpty: 1,
  );

  void _insertStrikethrough() => _insertIntoBody(
    transform: (selected) => '~~$selected~~',
    cursorOffsetWhenEmpty: 2,
  );

  void _insertInlineCode() => _insertIntoBody(
    transform: (selected) => '`$selected`',
    cursorOffsetWhenEmpty: 1,
  );

  void _insertQuote() => _prefixLines('> ');

  void _insertOrderedList() => _insertIntoBody(
    transform: (selected) => selected.isEmpty
        ? '1. '
        : selected
              .split('\n')
              .asMap()
              .entries
              .map((entry) => '${entry.key + 1}. ${entry.value}')
              .join('\n'),
    cursorOffsetWhenEmpty: 3,
  );

  void _insertBullet() => _insertIntoBody(
    transform: (selected) => selected.isEmpty
        ? '- '
        : selected
              .split('\n')
              .map((line) => line.startsWith('- ') ? line : '- $line')
              .join('\n'),
    cursorOffsetWhenEmpty: 2,
  );

  void _insertTask() => _prefixLines('- [ ] ');

  void _insertImagePlaceholder() => _insertIntoBody(
    transform: (selected) => '![${selected.isEmpty ? '图片' : selected}]()',
    cursorOffsetWhenEmpty: 2,
  );

  void _insertLink() => _insertIntoBody(
    transform: (selected) =>
        selected.isEmpty ? '[链接文字](https://)' : '[$selected](https://)',
    cursorOffsetWhenEmpty: 1,
  );

  void _insertCodeBlock() => _insertIntoBody(
    transform: (selected) =>
        selected.isEmpty ? '```\n\n```' : '```\n$selected\n```',
    cursorOffsetWhenEmpty: 4,
  );

  void _insertDivider() => _insertIntoBody(
    transform: (selected) => selected.isEmpty ? '---' : '$selected\n\n---',
    cursorOffsetWhenEmpty: 3,
  );

  void _prefixLines(String prefix) => _insertIntoBody(
    transform: (selected) => selected.isEmpty
        ? prefix
        : selected
              .split('\n')
              .map((line) => line.startsWith(prefix) ? line : '$prefix$line')
              .join('\n'),
    cursorOffsetWhenEmpty: prefix.length,
  );

  void _insertIntoBody({
    required String Function(String selected) transform,
    required int cursorOffsetWhenEmpty,
  }) {
    final value = _normalizeBodyValue(_body.value);
    final length = value.text.length;
    final selection = value.selection;
    final start = selection.isValid
        ? selection.start.clamp(0, length).toInt()
        : length;
    final end = selection.isValid
        ? selection.end.clamp(0, length).toInt()
        : length;
    final lower = start <= end ? start : end;
    final upper = start <= end ? end : start;
    final selected = value.text.substring(lower, upper);
    final replacement = transform(selected);
    final nextText =
        '${value.text.substring(0, lower)}$replacement${value.text.substring(upper)}';
    final cursor = selected.isEmpty
        ? lower + cursorOffsetWhenEmpty
        : lower + replacement.length;
    final next = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(
        offset: cursor.clamp(0, nextText.length).toInt(),
      ),
      composing: TextRange.empty,
    );
    _undoStack.add(value);
    if (_undoStack.length > 100) _undoStack.removeAt(0);
    _redoStack.clear();
    _applyBodyValue(next);
  }

  void _applyBodyValue(TextEditingValue value) {
    _applyingHistory = true;
    _body.value = value;
    _lastBodyValue = value;
    _applyingHistory = false;
    _bodyFocus.requestFocus();
    if (mounted) setState(() {});
  }
}

TextEditingValue _normalizeBodyValue(TextEditingValue value) {
  final length = value.text.length;
  final selection = value.selection;
  if (!selection.isValid) {
    return TextEditingValue(
      text: value.text,
      selection: TextSelection.collapsed(offset: length),
      composing: TextRange.empty,
    );
  }
  return TextEditingValue(
    text: value.text,
    selection: TextSelection(
      baseOffset: selection.baseOffset.clamp(0, length).toInt(),
      extentOffset: selection.extentOffset.clamp(0, length).toInt(),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    ),
    composing: TextRange.empty,
  );
}

class _MarkdownToolButton extends StatelessWidget {
  const _MarkdownToolButton({
    required this.tooltip,
    required this.onPressed,
    this.label,
    this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final String? label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: label == null
        ? Icon(icon)
        : Text(label!, style: const TextStyle(fontWeight: FontWeight.w700)),
  );
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 24,
    margin: const EdgeInsets.symmetric(horizontal: 5),
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}

String _deriveNoteTitle(String rawTitle, String rawBody) {
  final explicit = rawTitle.trim();
  if (explicit.isNotEmpty) return explicit;
  for (final rawLine in rawBody.split(RegExp(r'\r?\n'))) {
    if (rawLine.trimLeft().startsWith('```') ||
        RegExp(r'^\s*(---|\*\*\*|___)\s*$').hasMatch(rawLine)) {
      continue;
    }
    final line = rawLine
        .trim()
        .replaceFirst(RegExp(r'^#{1,3}\s+'), '')
        .replaceFirst(RegExp(r'^>\s*'), '')
        .replaceFirst(RegExp(r'^\d+\.\s+'), '')
        .replaceFirst(RegExp(r'^[-*+]\s+(\[[ xX]\]\s*)?'), '')
        .replaceAll('**', '')
        .replaceAll('*', '')
        .replaceAll('~~', '')
        .replaceAll('`', '')
        .replaceAll(RegExp(r'</?u>'), '')
        .replaceAll(
          RegExp(r'</?span(?:\s+data-hh-(?:fg|bg)="#[0-9A-Fa-f]{6}")?>'),
          '',
        )
        .replaceAll(RegExp(r'</?div(?:\s+align="(?:left|center|right)")?>'), '')
        .trim();
    if (line.isNotEmpty) return line;
  }
  return '未命名笔记';
}
