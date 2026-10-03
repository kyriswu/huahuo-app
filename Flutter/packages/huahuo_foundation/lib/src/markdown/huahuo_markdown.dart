import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;

import 'huahuo_markdown_document.dart';
import 'huahuo_markdown_table.dart';

typedef HuahuoMarkdownImageBuilder =
    Widget? Function(BuildContext context, String alt, String source);

@immutable
final class HuahuoMarkdownColors {
  const HuahuoMarkdownColors({
    required this.text,
    required this.primary,
    required this.surface,
    required this.surfaceMuted,
    required this.line,
  });
  factory HuahuoMarkdownColors.of(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return HuahuoMarkdownColors(
      text: colors.onSurface,
      primary: colors.primary,
      surface: colors.surface,
      surfaceMuted: colors.surfaceContainerLow,
      line: colors.outlineVariant,
    );
  }
  final Color text;
  final Color primary;
  final Color surface;
  final Color surfaceMuted;
  final Color line;
}

class HuahuoMarkdown extends StatefulWidget {
  const HuahuoMarkdown({
    required this.source,
    this.colors,
    this.bodyStyle,
    this.headingKeysByLine,
    this.imageBuilder,
    this.contextMenuBuilder,
    this.textAlign = TextAlign.left,
    this.unifiedSelection = false,
    super.key,
  });
  final String source;
  final HuahuoMarkdownColors? colors;
  final TextStyle? bodyStyle;
  final Map<int, GlobalKey>? headingKeysByLine;
  final HuahuoMarkdownImageBuilder? imageBuilder;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final TextAlign textAlign;
  final bool unifiedSelection;

  static TextStyle bodyStyleFor(HuahuoMarkdownColors colors) => TextStyle(
    fontSize: 15,
    height: 1.52,
    fontWeight: FontWeight.w400,
    color: colors.text,
  );

  @override
  State<HuahuoMarkdown> createState() => _HuahuoMarkdownState();
}

class _HuahuoMarkdownState extends State<HuahuoMarkdown> {
  HuahuoMarkdownDocument? _document;
  _MarkdownSelectionDelegate? _selectionDelegate;

  @override
  void didUpdateWidget(covariant HuahuoMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _document = null;
  }

  @override
  void dispose() {
    _selectionDelegate?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors ?? HuahuoMarkdownColors.of(context);
    try {
      final document = _document ??= HuahuoMarkdownDocument.parse(
        widget.source,
      );
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final block in document.blocks)
            HuahuoMarkdownBlockView(
              block: block,
              colors: colors,
              bodyStyle:
                  widget.bodyStyle ?? HuahuoMarkdown.bodyStyleFor(colors),
              headingKeysByLine: widget.headingKeysByLine,
              imageBuilder: widget.imageBuilder,
              contextMenuBuilder: widget.contextMenuBuilder,
              textAlign: widget.textAlign,
              unifiedSelection: widget.unifiedSelection,
            ),
        ],
      );
      return !widget.unifiedSelection ||
              SelectionContainer.maybeOf(context) == null
          ? content
          : SelectionContainer(
              delegate: _selectionDelegate ??= _MarkdownSelectionDelegate(),
              child: content,
            );
    } on FormatException {
      return Text(
        '内容过长或结构过于复杂，暂时无法预览。',
        style: HuahuoMarkdown.bodyStyleFor(colors),
      );
    }
  }
}

class _MarkdownSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final fragments = <String>[
      for (final selectable in selectables)
        if (selectable.getSelectedContent() case final content?)
          if (content.plainText.isNotEmpty) content.plainText,
    ];
    return fragments.isEmpty
        ? null
        : SelectedContent(plainText: fragments.join('\n'));
  }
}

class HuahuoMarkdownBlockView extends StatelessWidget {
  const HuahuoMarkdownBlockView({
    required this.block,
    required this.colors,
    required this.bodyStyle,
    this.headingKeysByLine,
    this.imageBuilder,
    this.contextMenuBuilder,
    this.textAlign = TextAlign.left,
    this.unifiedSelection = false,
    super.key,
  });
  final HuahuoMarkdownBlock block;
  final HuahuoMarkdownColors colors;
  final TextStyle bodyStyle;
  final Map<int, GlobalKey>? headingKeysByLine;
  final HuahuoMarkdownImageBuilder? imageBuilder;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final TextAlign textAlign;
  final bool unifiedSelection;

  @override
  Widget build(BuildContext context) {
    final headingKey = block.kind == HuahuoMarkdownBlockKind.heading
        ? (headingKeysByLine?[block.sourceLine])
        : null;
    if (block.kind == HuahuoMarkdownBlockKind.code) {
      return _MarkdownCodeBlock(
        code: block.text,
        baseStyle: bodyStyle,
        colors: colors,
        contextMenuBuilder: contextMenuBuilder,
        unifiedSelection: unifiedSelection,
      );
    }
    if (block.kind == HuahuoMarkdownBlockKind.table) {
      return _MarkdownTable(
        key: ValueKey<String>('v3-markdown-table-${block.sourceLine}'),
        table: block.table!,
        baseStyle: bodyStyle,
        colors: colors,
      );
    }
    if (block.kind == HuahuoMarkdownBlockKind.image) {
      return imageBuilder?.call(context, block.text, block.marker) ??
          Text.rich(
            TextSpan(
              children: _markdownInlineSpans(
                '![${block.text}](${block.marker})',
                bodyStyle,
                colors,
              ),
            ),
            style: bodyStyle,
            textAlign: textAlign,
          );
    }
    if (block.kind == HuahuoMarkdownBlockKind.alignment) {
      final alignment = switch (block.marker) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        _ => TextAlign.left,
      };
      return Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final child in block.children)
                HuahuoMarkdownBlockView(
                  block: child,
                  colors: colors,
                  bodyStyle: bodyStyle,
                  headingKeysByLine: headingKeysByLine,
                  imageBuilder: imageBuilder,
                  contextMenuBuilder: contextMenuBuilder,
                  textAlign: alignment,
                  unifiedSelection: unifiedSelection,
                ),
            ],
          ),
        ),
      );
    }
    return _MarkdownLine(
      key: headingKey,
      block: block,
      baseStyle: bodyStyle,
      colors: colors,
      textAlign: textAlign,
    );
  }
}

class _MarkdownCodeBlock extends StatelessWidget {
  const _MarkdownCodeBlock({
    required this.code,
    required this.baseStyle,
    required this.colors,
    this.contextMenuBuilder,
    required this.unifiedSelection,
  });

  final String code;
  final TextStyle baseStyle;
  final HuahuoMarkdownColors colors;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final bool unifiedSelection;

  @override
  Widget build(BuildContext context) {
    final codeStyle = baseStyle.copyWith(
      fontFamily: 'Menlo',
      fontFamilyFallback: const ['SFMono-Regular', 'Consolas', 'monospace'],
      fontSize: 14,
      height: 1.55,
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: !unifiedSelection || SelectionContainer.maybeOf(context) == null
          ? SelectableText(
              code,
              contextMenuBuilder: contextMenuBuilder,
              style: codeStyle,
            )
          : Text(code, style: codeStyle),
    );
  }
}

class _MarkdownLine extends StatelessWidget {
  const _MarkdownLine({
    required this.block,
    required this.baseStyle,
    required this.colors,
    this.textAlign = TextAlign.left,
    super.key,
  });

  final HuahuoMarkdownBlock block;
  String get line => block.text;
  final TextStyle baseStyle;
  final HuahuoMarkdownColors colors;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    if (block.kind == HuahuoMarkdownBlockKind.spacing) {
      return const SizedBox(height: 9);
    }
    if (block.kind == HuahuoMarkdownBlockKind.divider) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(height: 1),
      );
    }
    if (block.kind == HuahuoMarkdownBlockKind.heading) {
      final level = block.level;
      final fontSize = switch (level) {
        1 => 20.0,
        2 => 18.0,
        3 => 16.5,
        4 => 15.5,
        5 => 15.0,
        _ => 14.5,
      };
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text.rich(
          TextSpan(
            children: _markdownInlineSpans(block.text, baseStyle, colors),
          ),
          style: baseStyle.copyWith(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
          ),
          textAlign: textAlign,
        ),
      );
    }
    if (block.kind == HuahuoMarkdownBlockKind.quote) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: colors.primary, width: 3)),
        ),
        child: Text.rich(
          TextSpan(
            children: _markdownInlineSpans(block.text, baseStyle, colors),
          ),
          style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          textAlign: textAlign,
        ),
      );
    }
    if (block.kind == HuahuoMarkdownBlockKind.task) {
      final checked = block.checked;
      return _MarkdownListLine(
        leading: Icon(
          checked ? Icons.check_box_rounded : Icons.check_box_outline_blank,
          size: 19,
        ),
        body: block.text,
        baseStyle: baseStyle,
        colors: colors,
        strikeThrough: checked,
        textAlign: textAlign,
      );
    }
    if (block.kind == HuahuoMarkdownBlockKind.ordered) {
      return _MarkdownListLine(
        leading: Text(block.marker, style: baseStyle),
        body: block.text,
        baseStyle: baseStyle,
        colors: colors,
        textAlign: textAlign,
      );
    }
    if (block.kind == HuahuoMarkdownBlockKind.bullet) {
      return _MarkdownListLine(
        leading: Text('•', style: baseStyle),
        body: block.text,
        baseStyle: baseStyle,
        colors: colors,
        textAlign: textAlign,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text.rich(
        TextSpan(children: _markdownInlineSpans(line, baseStyle, colors)),
        style: baseStyle,
        textAlign: textAlign,
      ),
    );
  }
}

class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({
    required this.table,
    required this.baseStyle,
    required this.colors,
    super.key,
  });

  final HuahuoMarkdownTable table;
  final TextStyle baseStyle;
  final HuahuoMarkdownColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 460),
          child: Table(
            border: TableBorder.all(color: colors.line),
            defaultColumnWidth: const IntrinsicColumnWidth(),
            children: <TableRow>[
              _row(table.headers, header: true),
              for (final row in table.rows) _row(row),
            ],
          ),
        ),
      ),
    );
  }

  TableRow _row(List<String> values, {bool header = false}) {
    final style = header
        ? baseStyle.copyWith(fontWeight: FontWeight.w700)
        : baseStyle;
    return TableRow(
      decoration: BoxDecoration(
        color: header ? colors.surfaceMuted : colors.surface,
      ),
      children: <Widget>[
        for (final value in values)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text.rich(
              TextSpan(children: _markdownInlineSpans(value, style, colors)),
              style: style.copyWith(fontSize: 13.5, height: 1.45),
            ),
          ),
      ],
    );
  }
}

class _MarkdownListLine extends StatelessWidget {
  const _MarkdownListLine({
    required this.leading,
    required this.body,
    required this.baseStyle,
    required this.colors,
    this.strikeThrough = false,
    this.textAlign = TextAlign.left,
  });

  final Widget leading;
  final String body;
  final TextStyle baseStyle;
  final HuahuoMarkdownColors colors;
  final bool strikeThrough;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = strikeThrough
        ? baseStyle.copyWith(decoration: TextDecoration.lineThrough)
        : baseStyle;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: SizedBox(width: 22, child: leading),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: _markdownInlineSpans(body, effectiveStyle, colors),
              ),
              style: effectiveStyle,
              textAlign: textAlign,
            ),
          ),
        ],
      ),
    );
  }
}

List<InlineSpan> _markdownInlineSpans(
  String source,
  TextStyle style,
  HuahuoMarkdownColors colors,
) => _inlineSpans(parseHuahuoMarkdownInline(source), style, colors);

List<InlineSpan> _inlineSpans(
  List<HuahuoMarkdownInline> nodes,
  TextStyle style,
  HuahuoMarkdownColors colors,
) => [for (final node in nodes) _inlineSpan(node, style, colors)];

InlineSpan _inlineSpan(
  HuahuoMarkdownInline node,
  TextStyle style,
  HuahuoMarkdownColors colors,
) {
  final color =
      (node.kind == HuahuoMarkdownInlineKind.foreground ||
          node.kind == HuahuoMarkdownInlineKind.background)
      ? Color(0xFF000000 | int.parse(node.value.substring(1), radix: 16))
      : colors.primary;
  final effectiveStyle = switch (node.kind) {
    HuahuoMarkdownInlineKind.foreground => style.copyWith(
      color: _readableForeground(color, colors.surface, colors.text),
    ),
    HuahuoMarkdownInlineKind.background => style.copyWith(
      backgroundColor: color,
      color: _contrastingForeground(style.color ?? colors.text, color),
    ),
    HuahuoMarkdownInlineKind.underline => style.copyWith(
      decoration: _combineTextDecorations(
        style.decoration,
        TextDecoration.underline,
      ),
    ),
    HuahuoMarkdownInlineKind.code => style.copyWith(
      fontFamily: 'Menlo',
      fontFamilyFallback: const ['SFMono-Regular', 'Consolas', 'monospace'],
      fontSize: (style.fontSize ?? 16) * .9,
      backgroundColor: colors.surfaceMuted,
    ),
    HuahuoMarkdownInlineKind.strike => style.copyWith(
      decoration: _combineTextDecorations(
        style.decoration,
        TextDecoration.lineThrough,
      ),
    ),
    HuahuoMarkdownInlineKind.bold => style.copyWith(
      fontWeight: FontWeight.w700,
    ),
    HuahuoMarkdownInlineKind.italic => style.copyWith(
      fontStyle: FontStyle.italic,
    ),
    HuahuoMarkdownInlineKind.link => style.copyWith(
      color: _readableForeground(colors.primary, colors.surface, colors.text),
      decoration: TextDecoration.underline,
    ),
    HuahuoMarkdownInlineKind.text => null,
  };
  return node.children.isEmpty
      ? TextSpan(text: node.text, style: effectiveStyle)
      : TextSpan(
          style: effectiveStyle,
          children: _inlineSpans(
            node.children,
            effectiveStyle ?? style,
            colors,
          ),
        );
}

double _contrastRatio(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return ((first > second ? first : second) + .05) /
      ((first > second ? second : first) + .05);
}

Color _readableForeground(Color preferred, Color background, Color fallback) =>
    _contrastRatio(preferred, background) >= 4.5 ? preferred : fallback;

Color _contrastingForeground(Color preferred, Color background) {
  if (_contrastRatio(preferred, background) >= 4.5) return preferred;
  const dark = Color(0xFF111111);
  const light = Color(0xFFF7F7F7);
  return _contrastRatio(dark, background) >= _contrastRatio(light, background)
      ? dark
      : light;
}

TextDecoration _combineTextDecorations(
  TextDecoration? current,
  TextDecoration incoming,
) => current == null ? incoming : TextDecoration.combine([current, incoming]);
