import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:huahuo_editor/huahuo_editor.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/desktop_theme.dart';
import '../domain/document_media_store.dart';

/// Lets the host resolve an image source without coupling the toolbar to a
/// particular picker, uploader, or asset library.
typedef HuahuoEditorImageResolver =
    Future<String?> Function(BuildContext context);

/// Lets the host replace the built-in link dialog when a richer link workflow
/// is available.
typedef HuahuoEditorLinkResolver =
    Future<HuahuoEditorLink?> Function(
      BuildContext context,
      HuahuoEditorLinkSelection selection,
    );

/// The selected text and current target passed to a link resolver.
@immutable
final class HuahuoEditorLinkSelection {
  const HuahuoEditorLinkSelection({required this.text, required this.url});

  final String text;
  final String? url;
}

/// A link label and destination returned by a link resolver.
@immutable
final class HuahuoEditorLink {
  const HuahuoEditorLink({required this.text, required this.url});

  final String text;
  final String url;
}

/// Formatting actions emitted after a user invokes an editor command.
enum HuahuoEditorToolbarAction {
  paragraph,
  heading1,
  heading2,
  heading3,
  bold,
  italic,
  underline,
  strikeThrough,
  bulletList,
  orderedList,
  checkList,
  blockQuote,
  codeBlock,
  link,
  image,
  undo,
  redo,
}

enum _BlockFormat { paragraph, heading1, heading2, heading3 }

extension on _BlockFormat {
  String get label => switch (this) {
    _BlockFormat.paragraph => '正文',
    _BlockFormat.heading1 => '标题 1',
    _BlockFormat.heading2 => '标题 2',
    _BlockFormat.heading3 => '标题 3',
  };

  Attribute<dynamic> get attribute => switch (this) {
    _BlockFormat.paragraph => Attribute.clone(Attribute.header, null),
    _BlockFormat.heading1 => Attribute.h1,
    _BlockFormat.heading2 => Attribute.h2,
    _BlockFormat.heading3 => Attribute.h3,
  };

  HuahuoEditorToolbarAction get action => switch (this) {
    _BlockFormat.paragraph => HuahuoEditorToolbarAction.paragraph,
    _BlockFormat.heading1 => HuahuoEditorToolbarAction.heading1,
    _BlockFormat.heading2 => HuahuoEditorToolbarAction.heading2,
    _BlockFormat.heading3 => HuahuoEditorToolbarAction.heading3,
  };
}

/// A quiet, desktop-oriented rich-text toolbar backed by [HuahuoEditorController].
///
/// Text and block formatting are applied directly to the controller. Image and
/// link acquisition are delegated to optional resolvers so this component stays
/// independent from storage and upload choices. Image insertion remains off
/// until the host has also configured a matching Quill image embed builder.
final class HuahuoRichTextFormattingToolbar extends StatefulWidget {
  const HuahuoRichTextFormattingToolbar({
    required this.controller,
    super.key,
    this.enabled = true,
    this.focusNode,
    this.onResolveImage,
    this.onResolveLink,
    this.onAction,
    this.imageEmbeddingEnabled = false,
  });

  final HuahuoEditorController controller;
  final bool enabled;
  final FocusNode? focusNode;
  final HuahuoEditorImageResolver? onResolveImage;
  final HuahuoEditorLinkResolver? onResolveLink;
  final ValueChanged<HuahuoEditorToolbarAction>? onAction;

  /// Set this only when the editor can render image embeds and
  /// [onResolveImage] returns a durable, supported URI.
  final bool imageEmbeddingEnabled;

  @override
  State<HuahuoRichTextFormattingToolbar> createState() =>
      _HuahuoRichTextFormattingToolbarState();
}

final class _HuahuoRichTextFormattingToolbarState
    extends State<HuahuoRichTextFormattingToolbar> {
  @override
  void initState() {
    super.initState();
    widget.controller.body.addListener(_refreshSelectionStyle);
  }

  @override
  void didUpdateWidget(covariant HuahuoRichTextFormattingToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.body.removeListener(_refreshSelectionStyle);
    widget.controller.body.addListener(_refreshSelectionStyle);
  }

  @override
  void dispose() {
    widget.controller.body.removeListener(_refreshSelectionStyle);
    super.dispose();
  }

  void _refreshSelectionStyle() {
    if (mounted) setState(() {});
  }

  bool _hasAttribute(String key, [Object? value]) {
    final attribute = widget.controller.body
        .getSelectionStyle()
        .attributes[key];
    return attribute != null && (value == null || attribute.value == value);
  }

  bool get _hasCheckList {
    final value = widget.controller.body
        .getSelectionStyle()
        .attributes[Attribute.list.key]
        ?.value;
    return value == Attribute.checked.value ||
        value == Attribute.unchecked.value;
  }

  _BlockFormat get _currentBlockFormat {
    final header = widget.controller.body
        .getSelectionStyle()
        .attributes[Attribute.header.key]
        ?.value;
    return switch (header) {
      1 => _BlockFormat.heading1,
      2 => _BlockFormat.heading2,
      3 => _BlockFormat.heading3,
      _ => _BlockFormat.paragraph,
    };
  }

  void _restoreFocus() {
    widget.focusNode?.requestFocus();
  }

  void _emit(HuahuoEditorToolbarAction action) {
    widget.onAction?.call(action);
  }

  void _applyBlockFormat(_BlockFormat format) {
    if (!widget.enabled) return;
    final body = widget.controller.body;
    // Quill block styles are exclusive. Clear the other block modes first so
    // returning to paragraph does not leave a hidden list, quote, or code flag.
    body
      ..formatSelection(Attribute.clone(Attribute.header, null))
      ..formatSelection(Attribute.clone(Attribute.list, null))
      ..formatSelection(Attribute.clone(Attribute.codeBlock, null))
      ..formatSelection(Attribute.clone(Attribute.blockQuote, null));
    if (format != _BlockFormat.paragraph) {
      body.formatSelection(format.attribute);
    }
    _emit(format.action);
    _restoreFocus();
  }

  void _toggle(Attribute<dynamic> attribute, HuahuoEditorToolbarAction action) {
    if (!widget.enabled) return;
    widget.controller.toggleAttribute(attribute);
    _emit(action);
    _restoreFocus();
  }

  void _toggleCheckList() {
    if (!widget.enabled) return;
    final body = widget.controller.body;
    if (_hasCheckList) {
      body.formatSelection(Attribute.clone(Attribute.list, null));
    } else {
      body.formatSelection(Attribute.checked);
    }
    _emit(HuahuoEditorToolbarAction.checkList);
    _restoreFocus();
  }

  bool get _canInsertImage =>
      widget.enabled &&
      widget.imageEmbeddingEnabled &&
      widget.onResolveImage != null;

  Future<void> _editLink() async {
    if (!widget.enabled) return;
    final prepared = QuillTextLink.prepare(widget.controller.body);
    final selection = HuahuoEditorLinkSelection(
      text: prepared.text,
      url: prepared.link,
    );
    final result =
        await (widget.onResolveLink?.call(context, selection) ??
            _showDefaultLinkDialog(context, selection));
    if (!mounted || result == null) return;

    final text = result.text.trim().isEmpty ? result.url : result.text;
    QuillTextLink(text, result.url).submit(widget.controller.body);
    _emit(HuahuoEditorToolbarAction.link);
    _restoreFocus();
  }

  Future<void> _insertImage() async {
    final resolveImage = widget.onResolveImage;
    if (!_canInsertImage || resolveImage == null) return;
    final source = await resolveImage(context);
    final imageSource = source?.trim();
    if (!mounted ||
        imageSource == null ||
        !_isSupportedImageSource(imageSource)) {
      return;
    }

    final body = widget.controller.body;
    final selection = body.selection;
    final documentEnd = body.document.length - 1;
    final start = _clampOffset(selection.start, documentEnd);
    final end = _clampOffset(selection.end, documentEnd);
    body.replaceText(
      start,
      end - start,
      BlockEmbed.image(imageSource),
      TextSelection.collapsed(offset: start + 1),
    );
    _emit(HuahuoEditorToolbarAction.image);
    _restoreFocus();
  }

  int _clampOffset(int value, int documentEnd) {
    if (value < 0) return 0;
    if (value > documentEnd) return documentEnd;
    return value;
  }

  bool _isSupportedImageSource(String value) {
    if (DocumentMediaUri.parse(value) != null) return true;
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  Future<HuahuoEditorLink?> _showDefaultLinkDialog(
    BuildContext context,
    HuahuoEditorLinkSelection selection,
  ) async {
    final textController = TextEditingController(text: selection.text);
    final urlController = TextEditingController(text: selection.url ?? '');
    try {
      return await showDialog<HuahuoEditorLink>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('添加链接'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: textController,
                  contextMenuBuilder:
                      HuahuoTextEditing.buildEditableContextMenu,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '显示文字',
                    hintText: '未选中文字时默认使用链接地址',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  contextMenuBuilder:
                      HuahuoTextEditing.buildEditableContextMenu,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '链接地址',
                    hintText: 'https://example.com',
                  ),
                  onSubmitted: (_) => _submitLinkDialog(
                    dialogContext,
                    textController,
                    urlController,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => _submitLinkDialog(
                dialogContext,
                textController,
                urlController,
              ),
              child: const Text('添加'),
            ),
          ],
        ),
      );
    } finally {
      textController.dispose();
      urlController.dispose();
    }
  }

  void _submitLinkDialog(
    BuildContext context,
    TextEditingController textController,
    TextEditingController urlController,
  ) {
    final url = urlController.text.trim();
    if (url.isEmpty) return;
    Navigator.of(
      context,
    ).pop(HuahuoEditorLink(text: textController.text, url: url));
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.controller.body;
    return Semantics(
      label: '文稿格式工具栏',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BlockFormatMenu(
              key: const ValueKey<String>('editor-format-heading'),
              format: _currentBlockFormat,
              enabled: widget.enabled,
              onSelected: _applyBlockFormat,
            ),
            const _ToolbarDivider(),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-bold'),
              icon: LucideIcons.bold,
              tooltip: '粗体',
              selected: _hasAttribute(Attribute.bold.key),
              enabled: widget.enabled,
              onPressed: () =>
                  _toggle(Attribute.bold, HuahuoEditorToolbarAction.bold),
            ),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-italic'),
              icon: LucideIcons.italic,
              tooltip: '斜体',
              selected: _hasAttribute(Attribute.italic.key),
              enabled: widget.enabled,
              onPressed: () =>
                  _toggle(Attribute.italic, HuahuoEditorToolbarAction.italic),
            ),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-underline'),
              icon: LucideIcons.underline,
              tooltip: '下划线',
              selected: _hasAttribute(Attribute.underline.key),
              enabled: widget.enabled,
              onPressed: () => _toggle(
                Attribute.underline,
                HuahuoEditorToolbarAction.underline,
              ),
            ),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-strike'),
              icon: LucideIcons.strikethrough,
              tooltip: '删除线',
              selected: _hasAttribute(Attribute.strikeThrough.key),
              enabled: widget.enabled,
              onPressed: () => _toggle(
                Attribute.strikeThrough,
                HuahuoEditorToolbarAction.strikeThrough,
              ),
            ),
            const _ToolbarDivider(),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-bullet-list'),
              icon: LucideIcons.list,
              tooltip: '无序列表',
              selected: _hasAttribute(Attribute.list.key, Attribute.ul.value),
              enabled: widget.enabled,
              onPressed: () =>
                  _toggle(Attribute.ul, HuahuoEditorToolbarAction.bulletList),
            ),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-ordered-list'),
              icon: LucideIcons.listOrdered,
              tooltip: '有序列表',
              selected: _hasAttribute(Attribute.list.key, Attribute.ol.value),
              enabled: widget.enabled,
              onPressed: () =>
                  _toggle(Attribute.ol, HuahuoEditorToolbarAction.orderedList),
            ),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-check-list'),
              icon: LucideIcons.listChecks,
              tooltip: '待办列表',
              selected: _hasCheckList,
              enabled: widget.enabled,
              onPressed: _toggleCheckList,
            ),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-quote'),
              icon: LucideIcons.quote,
              tooltip: '引用',
              selected: _hasAttribute(Attribute.blockQuote.key),
              enabled: widget.enabled,
              onPressed: () => _toggle(
                Attribute.blockQuote,
                HuahuoEditorToolbarAction.blockQuote,
              ),
            ),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-code-block'),
              icon: LucideIcons.codeXml,
              tooltip: '代码块',
              selected: _hasAttribute(Attribute.codeBlock.key),
              enabled: widget.enabled,
              onPressed: () => _toggle(
                Attribute.codeBlock,
                HuahuoEditorToolbarAction.codeBlock,
              ),
            ),
            const _ToolbarDivider(),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-link'),
              icon: LucideIcons.link,
              tooltip: '添加链接',
              selected: _hasAttribute(Attribute.link.key),
              enabled: widget.enabled,
              onPressed: _editLink,
            ),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-image'),
              icon: LucideIcons.imagePlus,
              tooltip: _canInsertImage ? '插入图片' : '图片插入尚未配置',
              enabled: _canInsertImage,
              onPressed: _insertImage,
            ),
            const _ToolbarDivider(),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-undo'),
              icon: LucideIcons.undo2,
              tooltip: '撤销',
              enabled: widget.enabled && body.hasUndo,
              onPressed: () {
                widget.controller.undo();
                _emit(HuahuoEditorToolbarAction.undo);
                _restoreFocus();
              },
            ),
            _ToolbarIconButton(
              key: const ValueKey<String>('editor-format-redo'),
              icon: LucideIcons.redo2,
              tooltip: '重做',
              enabled: widget.enabled && body.hasRedo,
              onPressed: () {
                widget.controller.redo();
                _emit(HuahuoEditorToolbarAction.redo);
                _restoreFocus();
              },
            ),
          ],
        ),
      ),
    );
  }
}

final class _BlockFormatMenu extends StatelessWidget {
  const _BlockFormatMenu({
    required super.key,
    required this.format,
    required this.enabled,
    required this.onSelected,
  });

  final _BlockFormat format;
  final bool enabled;
  final ValueChanged<_BlockFormat> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: '段落样式',
      child: PopupMenuButton<_BlockFormat>(
        enabled: enabled,
        tooltip: '',
        padding: EdgeInsets.zero,
        onSelected: onSelected,
        itemBuilder: (context) => _BlockFormat.values
            .map(
              (candidate) => PopupMenuItem<_BlockFormat>(
                value: candidate,
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Text(
                        candidate == _BlockFormat.paragraph
                            ? '正文'
                            : candidate.label.replaceFirst('标题 ', 'H'),
                        style: TextStyle(
                          fontSize: candidate == _BlockFormat.heading1
                              ? 16
                              : candidate == _BlockFormat.heading2
                              ? 14
                              : 13,
                          fontWeight: candidate == _BlockFormat.paragraph
                              ? FontWeight.w400
                              : FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(candidate.label),
                    const Spacer(),
                    if (candidate == format)
                      Icon(LucideIcons.check, size: 15, color: colors.primary),
                  ],
                ),
              ),
            )
            .toList(growable: false),
        child: AnimatedContainer(
          duration: DesktopMotionTokens.responsive,
          width: 58,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: format == _BlockFormat.paragraph
                ? Colors.transparent
                : colors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                format == _BlockFormat.paragraph
                    ? '正文'
                    : format.label.replaceFirst('标题 ', 'H'),
                style: TextStyle(
                  color: enabled
                      ? format == _BlockFormat.paragraph
                            ? colors.onSurfaceVariant
                            : colors.primary
                      : colors.onSurfaceVariant.withValues(alpha: 0.42),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                LucideIcons.chevronDown,
                size: 13,
                color: enabled
                    ? colors.onSurfaceVariant
                    : colors.onSurfaceVariant.withValues(alpha: 0.42),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 18,
    margin: const EdgeInsets.symmetric(horizontal: 6),
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.82),
  );
}

final class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required super.key,
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final iconColor = !enabled
        ? colors.onSurfaceVariant.withValues(alpha: 0.38)
        : selected
        ? colors.primary
        : colors.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: Material(
          color: selected
              ? colors.primary.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 32,
              height: 32,
              child: Icon(icon, size: 16, color: iconColor),
            ),
          ),
        ),
      ),
    );
  }
}
