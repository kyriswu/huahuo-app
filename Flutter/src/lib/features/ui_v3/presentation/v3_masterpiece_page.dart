import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/lifecycle/app_activity_coordinator.dart';
import '../../../shared/markdown/v3_markdown.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../book_work/application/masterpiece_controller.dart';
import '../../book_work/application/masterpiece_providers.dart';
import '../../book_work/application/mobile_book_work_controller.dart';
import '../../book_work/widgets/mobile_book_work_sheet.dart';
import '../../book_work/widgets/masterpiece_generation_panel.dart';
import '../application/canvas_document_codec.dart';
import '../application/profile_workspace_controller.dart';

enum V3MasterpieceAccessMode { automatic, locked, preview, unlocked }

Widget _buildMasterpieceContextMenu(
  BuildContext context,
  QuillRawEditorState editorState,
) => V3TextEditing.buildRawContextMenu(
  context,
  anchors: editorState.contextMenuAnchors,
  buttonItems: editorState.contextMenuButtonItems,
  useTextFieldTapRegion: true,
);

class V3MasterpiecePage extends ConsumerStatefulWidget {
  const V3MasterpiecePage({
    this.active = true,
    this.accessMode = V3MasterpieceAccessMode.automatic,
    super.key,
  });
  final bool active;
  final V3MasterpieceAccessMode accessMode;

  @override
  ConsumerState<V3MasterpiecePage> createState() => _V3MasterpiecePageState();
}

class _V3MasterpiecePageState extends ConsumerState<V3MasterpiecePage> {
  final _sectionKeys = <String, GlobalKey>{};
  MasterpieceController? _runtime;

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      appActivityCoordinatorProvider.select((value) => value.state.visibility),
      (_, visibility) {
        final runtime = _runtime;
        if (runtime == null) return;
        if (visibility == AppVisibility.foreground && widget.active) {
          unawaited(_refreshIfVisible());
        } else {
          unawaited(runtime.flushDraft());
        }
      },
    );
  }

  @override
  void didUpdateWidget(covariant V3MasterpiecePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refreshIfVisible());
      });
    } else if (!widget.active && oldWidget.active) {
      unawaited(_runtime?.flushDraft());
    }
  }

  Future<void> _refreshIfVisible() {
    final runtime = _runtime;
    if (!mounted ||
        !widget.active ||
        runtime == null ||
        !ref.read(appActivityCoordinatorProvider).state.isForeground) {
      return Future<void>.value();
    }
    return runtime.refresh(force: false);
  }

  @override
  void dispose() {
    unawaited(_runtime?.flushDraft());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(masterpieceControllerProvider);
    if (!identical(_runtime, runtime)) {
      _runtime = runtime;
      _sectionKeys.clear();
      if (widget.active) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_runtime, runtime)) {
            unawaited(_refreshIfVisible());
          }
        });
      }
    }
    final draft = runtime.draft;
    final generation = runtime.generation;
    final showGeneration =
        generation?.showPanel == true &&
        (runtime.snapshot != null || generation?.unlocked == false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 66, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.menu_book_outlined, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  generation?.unlocked == false
                      ? '代表作 · 待解锁'
                      : draft != null
                      ? '章节草稿'
                      : '代表作 · 云端',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (generation?.unlocked != false)
                IconButton(
                  tooltip: '章节目录',
                  onPressed:
                      draft == null &&
                          !showGeneration &&
                          runtime.snapshot?.chapters.isNotEmpty == true
                      ? () => _showDirectory(runtime)
                      : null,
                  icon: const Icon(Icons.format_list_bulleted_rounded),
                ),
              if (generation?.unlocked != false)
                IconButton(
                  key: const ValueKey('masterpiece-refresh'),
                  tooltip: '刷新云端',
                  onPressed: runtime.canRefresh ? runtime.refresh : null,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              IconButton(
                key: const ValueKey('masterpiece-more'),
                tooltip: '代表作信息',
                onPressed: () => _showInformation(runtime),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
          if (runtime.busy && generation?.unlocked != false)
            const LinearProgressIndicator(minHeight: 2),
          if (generation?.unlocked != false)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                showGeneration
                    ? generation!.statusMessage
                    : runtime.statusMessage,
                key: const ValueKey('masterpiece-status'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (showGeneration && generation?.unlocked == false)
            Expanded(
              child: MasterpieceGenerationPanel(
                controller: generation!,
                onRefresh: runtime.refresh,
              ),
            )
          else if (draft != null)
            Expanded(
              child: _MasterpieceEditor(
                key: ValueKey(
                  '${identityHashCode(runtime)}:${draft.sectionKey}:${draft.baseRevisionId}',
                ),
                runtime: runtime,
              ),
            )
          else if (showGeneration)
            Expanded(
              child: MasterpieceGenerationPanel(
                controller: generation!,
                onRefresh: runtime.refresh,
              ),
            )
          else if (runtime.snapshot != null)
            Expanded(child: _buildReader(runtime))
          else
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_outlined, size: 44),
                    const SizedBox(height: 18),
                    if (runtime.phase != MasterpiecePhase.signedOut)
                      TextButton.icon(
                        onPressed: runtime.busy
                            ? null
                            : () => runtime.refresh(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新读取云端'),
                      ),
                  ],
                ),
              ),
            ),
          if (draft == null && runtime.snapshot != null && !showGeneration)
            Wrap(
              spacing: 12,
              runSpacing: 4,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('masterpiece-new'),
                  onPressed: runtime.canStartAction
                      ? () => runtime.beginNew()
                      : null,
                  icon: const Icon(Icons.add),
                  label: const Text('新建章节'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('masterpiece-chat-entry'),
                  onPressed: runtime.canStartAction
                      ? () => _openChat(runtime)
                      : null,
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('AI 写作'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildReader(MasterpieceController runtime) {
    final snapshot = runtime.snapshot!;
    final chapterKeys = snapshot.chapters
        .map((chapter) => chapter.section.sectionKey)
        .toSet();
    _sectionKeys.removeWhere((key, _) => !chapterKeys.contains(key));
    return RefreshIndicator(
      onRefresh: runtime.refresh,
      child: SingleChildScrollView(
        key: const ValueKey('masterpiece-reader'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              snapshot.book.current.title,
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '云端版本 ${snapshot.book.current.revision} · ${snapshot.chapters.length} 个章节',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (snapshot.chapters.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 56),
                child: Text(
                  '从第一个章节开始\n\n手写内容、与 AI 讨论，或从“典藏与创作”纳入已完成的作品。',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final chapter in snapshot.chapters)
              Padding(
                key: _sectionKeys.putIfAbsent(
                  chapter.section.sectionKey,
                  GlobalKey.new,
                ),
                padding: const EdgeInsets.only(top: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            chapter.section.title,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: chapter.requiresCopy
                              ? '续写为新章节 ${chapter.section.title}'
                              : '编辑 ${chapter.section.title}',
                          onPressed:
                              runtime.canStartAction && chapter.revision != null
                              ? () async {
                                  if (!chapter.requiresCopy) {
                                    runtime.beginEdit(chapter);
                                    return;
                                  }
                                  final confirmed = await _confirm(
                                    context,
                                    '保留来源，续写为新章节？',
                                    '此章节带有作品或运行产物来源，当前后端不支持保留这些来源的原位正文更新。将保留全部来源与资源，打开独立新章节草稿；原章节不会被修改。',
                                  );
                                  if (confirmed && mounted) {
                                    runtime.beginCopy(chapter);
                                  }
                                }
                              : null,
                          icon: Icon(
                            chapter.requiresCopy
                                ? Icons.post_add_outlined
                                : Icons.edit_outlined,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    SelectionArea(
                      contextMenuBuilder:
                          V3TextEditing.buildSelectionContextMenu,
                      child: V3AssistantReplyMarkdown(
                        source:
                            chapter.revision?.contentMarkdown ??
                            '此章节暂时没有可读取的正文。',
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDirectory(MasterpieceController runtime) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        backgroundColor: HuahuoV3Theme.tokensOf(dialogContext).surface,
        title: const Text('章节目录'),
        children: [
          for (final chapter in runtime.snapshot!.chapters)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(chapter.section.sectionKey),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(chapter.section.title),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null || !identical(runtime, _runtime)) return;
    final target = _sectionKeys[selected]?.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        duration: V3MotionTokens.resolve(context, V3MotionTokens.standard),
        alignment: .05,
      );
    }
  }

  Future<void> _openChat(MasterpieceController runtime) async {
    if (!await runtime.prepareChat() ||
        !mounted ||
        !identical(runtime, _runtime)) {
      return;
    }
    await context.push('/v3/feed/chat?skill=masterpiece');
    if (mounted && identical(runtime, _runtime)) await runtime.refresh();
  }

  Future<void> _showInformation(MasterpieceController runtime) async {
    final legacy = ref
        .read(profileWorkspaceControllerProvider)
        .masterpiece
        .markdown
        ?.trim();
    final action = await showV3GlassBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => V3SheetScaffold(
        key: const ValueKey('masterpiece-information-sheet'),
        title: '代表作信息',
        showClose: true,
        maxHeightFactor: .85,
        child: Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('masterpiece-information-scroll'),
            padding: const EdgeInsets.only(top: 12, bottom: 12),
            child: ListenableBuilder(
              listenable: runtime,
              builder: (context, _) => _MasterpieceInformationContent(
                runtime: runtime,
                hasLegacy: legacy?.isNotEmpty == true,
                onAction: (action) => Navigator.of(sheetContext).pop(action),
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted || !identical(runtime, _runtime)) return;
    if (action == 'generate' && runtime.canStartAction) {
      if (await confirmMasterpieceGeneration(context) &&
          mounted &&
          identical(runtime, _runtime) &&
          runtime.canStartAction) {
        await runtime.generation?.requestGeneration();
      }
    } else if (action == 'works' && runtime.canStartAction) {
      unawaited(ref.read(mobileBookWorkControllerProvider).load());
      await showMobileBookWorkSheet(context);
      if (mounted && identical(runtime, _runtime)) await runtime.refresh();
    } else if (action == 'legacy' && legacy?.isNotEmpty == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: HuahuoV3Theme.tokensOf(dialogContext).surface,
          title: const Text('历史本地代表作 · 未同步'),
          content: SingleChildScrollView(
            child: SelectionArea(
              contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
              child: Text(legacy!),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => V3TextEditing.copy(dialogContext, legacy),
              child: const Text('复制原文'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('关闭'),
            ),
            if (runtime.canStartAction)
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('作为新章节草稿打开'),
              ),
          ],
        ),
      );
      if (confirmed == true && mounted && identical(runtime, _runtime)) {
        runtime.beginNew(title: '历史本地代表作', markdown: legacy!);
      }
    } else if (action == 'hide' && runtime.canStartAction) {
      ref.read(profileWorkspaceControllerProvider).setMasterpieceVisible(false);
    }
  }
}

class _MasterpieceInformationContent extends StatelessWidget {
  const _MasterpieceInformationContent({
    required this.runtime,
    required this.hasLegacy,
    required this.onAction,
  });
  final MasterpieceController runtime;
  final bool hasLegacy;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final generation = runtime.generation;
    final locked = generation?.unlocked == false;
    final verified = generation?.eligibilityVerified == true;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                locked ? Icons.lock_outline_rounded : Icons.menu_book_rounded,
                color: colors.ink,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      locked ? '代表作尚未解锁' : '我的代表作',
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      generation == null
                          ? runtime.statusMessage
                          : !verified
                          ? '正在等待云端笔记数量核验'
                          : locked
                          ? '已沉淀 ${generation.record.noteCount} / 100 篇 · 还需 ${100 - generation.record.noteCount} 篇'
                          : '已沉淀 ${generation.record.noteCount} 篇 · ${runtime.snapshot?.chapters.length ?? 0} 个云端章节',
                      style: TextStyle(
                        color: colors.muted,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          '关于代表作',
          style: TextStyle(
            color: colors.ink,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '当前云端有效笔记达到 100 篇后解锁。首次生成会整理你的知识沉淀，后续生成只新增章节，不覆盖已有内容。',
          style: TextStyle(color: colors.text, fontSize: 14, height: 1.6),
        ),
        const SizedBox(height: 8),
        Text(
          '删除后不足 100 篇会重新锁定，已有正文与草稿仍会保留。AI 生成正文正式收录并回读确认后，才能编辑。',
          style: TextStyle(color: colors.muted, fontSize: 13, height: 1.6),
        ),
        const SizedBox(height: 20),
        Text(
          '内容与管理',
          style: TextStyle(
            color: colors.ink,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        if (generation != null) ...[
          _action(
            Icons.auto_awesome_outlined,
            '生成代表作新篇章',
            'generate',
            enabled: runtime.canStartAction,
          ),
          const SizedBox(height: 8),
        ],
        _action(
          Icons.collections_bookmark_outlined,
          '典藏与创作',
          'works',
          enabled: runtime.canStartAction,
        ),
        if (hasLegacy) ...[
          const SizedBox(height: 8),
          _action(Icons.history_rounded, '查看历史本地代表作', 'legacy'),
        ],
        if (runtime.canStartAction) ...[
          const SizedBox(height: 8),
          _action(Icons.visibility_off_outlined, '在本机隐藏代表作入口', 'hide'),
        ],
        if (locked) ...[
          const SizedBox(height: 12),
          Text(
            '解锁后可使用生成与创作功能。',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _action(
    IconData icon,
    String label,
    String action, {
    bool enabled = true,
  }) => OutlinedButton.icon(
    key: ValueKey('masterpiece-information-$action'),
    onPressed: enabled ? () => onAction(action) : null,
    style: OutlinedButton.styleFrom(
      alignment: Alignment.centerLeft,
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    icon: Icon(icon, size: 20),
    label: Text(label),
  );
}

class _MasterpieceEditor extends StatefulWidget {
  const _MasterpieceEditor({required this.runtime, super.key});
  final MasterpieceController runtime;
  @override
  State<_MasterpieceEditor> createState() => _MasterpieceEditorState();
}

class _MasterpieceEditorState extends State<_MasterpieceEditor> {
  final _codec = CanvasDocumentCodec();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late final TextEditingController _title;
  late final QuillController? _editor;
  late final TextEditingController _rawText;
  late String _lastMarkdown;

  @override
  void initState() {
    super.initState();
    final draft = widget.runtime.draft!;
    _title = TextEditingController(text: draft.title);
    _rawText = TextEditingController(text: draft.markdown);
    _lastMarkdown = draft.markdown;
    QuillController? editor;
    try {
      final document = _codec.documentFromMarkdown(draft.markdown);
      final normalized = _codec.documentToMarkdown(document);
      if (normalized.trim() == draft.markdown.trim()) {
        editor = QuillController(
          document: document,
          selection: const TextSelection.collapsed(offset: 0),
        )..addListener(_changed);
        _lastMarkdown = normalized;
      }
    } on FormatException {
      editor = null;
    }
    _editor = editor;
  }

  void _changed() {
    if (widget.runtime.phase != MasterpiecePhase.editing) return;
    final markdown = _codec.documentToMarkdown(_editor!.document);
    if (markdown == _lastMarkdown) return;
    _lastMarkdown = markdown;
    widget.runtime.edit(markdown: markdown);
  }

  @override
  void dispose() {
    _editor?.removeListener(_changed);
    _editor?.dispose();
    _rawText.dispose();
    _title.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final draft = runtime.draft!;
    final editor = _editor;
    final editable =
        runtime.phase == MasterpiecePhase.editing &&
        !runtime.busy &&
        (runtime.generation?.allowsEditing ?? true);
    editor?.readOnly = !editable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('masterpiece-chapter-title'),
          controller: _title,
          contextMenuBuilder: V3TextEditing.buildContextMenu,
          readOnly: !editable || !draft.isNew,
          decoration: const InputDecoration(labelText: '章节标题'),
          onChanged: (value) => runtime.edit(title: value),
        ),
        Row(
          children: [
            if (editor != null) ...[
              IconButton(
                tooltip: '撤销',
                onPressed: editable ? editor.undo : null,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: '重做',
                onPressed: editable ? editor.redo : null,
                icon: const Icon(Icons.redo),
              ),
              IconButton(
                tooltip: '加粗',
                onPressed: editable
                    ? () {
                        final selected = editor
                            .getSelectionStyle()
                            .attributes
                            .containsKey(Attribute.bold.key);
                        editor.formatSelection(
                          selected
                              ? Attribute.clone(Attribute.bold, null)
                              : Attribute.bold,
                        );
                      }
                    : null,
                icon: const Icon(Icons.format_bold),
              ),
              IconButton(
                tooltip: '斜体',
                onPressed: editable
                    ? () {
                        final selected = editor
                            .getSelectionStyle()
                            .attributes
                            .containsKey(Attribute.italic.key);
                        editor.formatSelection(
                          selected
                              ? Attribute.clone(Attribute.italic, null)
                              : Attribute.italic,
                        );
                      }
                    : null,
                icon: const Icon(Icons.format_italic),
              ),
            ] else
              const Expanded(child: Text('Markdown 原文编辑 · 保留完整格式')),
            const Spacer(),
            IconButton(
              tooltip: '复制草稿',
              onPressed: () => V3TextEditing.copy(context, draft.markdown),
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
        ),
        Expanded(
          child: editor == null
              ? TextField(
                  key: const ValueKey('masterpiece-markdown-editor'),
                  controller: _rawText,
                  focusNode: _focus,
                  contextMenuBuilder: V3TextEditing.buildContextMenu,
                  scrollController: _scroll,
                  readOnly: !editable,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  onChanged: (value) => runtime.edit(markdown: value),
                )
              : QuillEditor(
                  key: const ValueKey('masterpiece-editor'),
                  controller: editor,
                  focusNode: _focus,
                  scrollController: _scroll,
                  config: const QuillEditorConfig(
                    expands: true,
                    scrollable: true,
                    padding: EdgeInsets.all(8),
                    placeholder: '写下这一章节的正文',
                    contextMenuBuilder: _buildMasterpieceContextMenu,
                  ),
                ),
        ),
        if (runtime.phase == MasterpiecePhase.conflict) ...[
          TextButton(
            onPressed: runtime.busy ? null : () => _showConflict(runtime),
            child: const Text('查看云端版本并处理冲突'),
          ),
          TextButton(
            onPressed: runtime.busy ? null : () => runtime.refresh(),
            child: const Text('重新读取最新版本'),
          ),
        ],
        if (runtime.phase == MasterpiecePhase.uncertain)
          FilledButton(
            onPressed: runtime.busy ? null : runtime.save,
            child: const Text('重试同一次提交'),
          ),
        if (runtime.phase == MasterpiecePhase.awaitingReadback)
          FilledButton(
            onPressed: runtime.busy ? null : runtime.refresh,
            child: const Text('重新确认云端结果'),
          ),
        if (runtime.phase == MasterpiecePhase.editing)
          if (!runtime.fresh)
            OutlinedButton(
              onPressed: runtime.canRefresh ? runtime.refresh : null,
              child: const Text('重新校验云端基线'),
            ),
        if (runtime.phase == MasterpiecePhase.editing)
          FilledButton(
            key: const ValueKey('masterpiece-edit-done'),
            onPressed: runtime.canSave ? runtime.save : null,
            child: const Text('保存到云端'),
          ),
        if (runtime.canDiscard)
          TextButton(
            onPressed: () async {
              if (await _confirm(
                context,
                '放弃本机草稿？',
                '仅删除这次尚未提交的本机编辑，不会修改云端正文。',
              )) {
                await runtime.discard();
              }
            },
            child: const Text('放弃本机草稿'),
          ),
      ],
    );
  }

  Future<void> _showConflict(MasterpieceController runtime) async {
    final draft = runtime.draft!;
    final chapter = runtime.snapshot?.chapter(draft.sectionKey);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: HuahuoV3Theme.tokensOf(dialogContext).surface,
        title: const Text('对比云端版本'),
        content: SingleChildScrollView(
          child: SelectionArea(
            contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
            child: Text(
              '云端当前内容：\n${chapter?.revision?.contentMarkdown ?? "章节已删除或尚未读取成功"}\n\n我的草稿：\n${draft.markdown}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('保留草稿，暂不处理'),
          ),
          if (runtime.canRebase)
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('基于此版本继续编辑我的草稿'),
            ),
        ],
      ),
    );
    if (confirmed == true && mounted && chapter?.revision != null) {
      await runtime.rebaseAfterConfirmation(
        reviewedRevisionId: chapter!.revision!.partRevisionId,
      );
    }
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: HuahuoV3Theme.tokensOf(dialogContext).surface,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
