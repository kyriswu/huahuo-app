import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';

import 'markdown_preview_document.dart';
import 'markdown_presentation_template.dart';
import 'markdown_preview_preferences.dart';
import 'markdown_preview_source.dart';

/// Resolves a document-owned local media URI without granting preview content
/// direct file-system access.
typedef MarkdownPreviewMediaResolver =
    Future<MarkdownPreviewMedia?> Function(Uri uri);

/// Chooses whether the reader owns a full document surface or sits beside an
/// editable document as a live companion preview.
enum MarkdownPreviewSurface { reader, companion }

/// A validated local media response supplied to either preview renderer.
@immutable
final class MarkdownPreviewMedia {
  const MarkdownPreviewMedia({required this.bytes, required this.mimeType});

  static const int maximumPreviewBytes = 8 * 1024 * 1024;
  static const int maximumPreviewDecodeWidth = 1400;

  final Uint8List bytes;
  final String mimeType;

  bool get isSafeForPreview {
    final normalizedMimeType = mimeType.split(';').first.trim().toLowerCase();
    return bytes.isNotEmpty &&
        bytes.length <= maximumPreviewBytes &&
        _previewImageMimeTypes.contains(normalizedMimeType);
  }

  static const Set<String> _previewImageMimeTypes = <String>{
    'image/gif',
    'image/jpeg',
    'image/png',
    'image/webp',
  };
}

/// Displays a Markdown document with the deterministic native Flutter reader.
///
/// Keeping this surface out of a desktop platform view gives Windows and macOS
/// the same renderer, while ensuring a malformed document cannot take down the
/// host through a native WebView implementation.
class MarkdownPreviewPane extends StatelessWidget {
  const MarkdownPreviewPane({
    required this.source,
    required this.preferences,
    this.mediaResolver,
    this.surface = MarkdownPreviewSurface.reader,
    super.key,
  });

  final MarkdownPreviewSource source;
  final MarkdownPreviewPreferences preferences;
  final MarkdownPreviewMediaResolver? mediaResolver;
  final MarkdownPreviewSurface surface;

  @override
  Widget build(BuildContext context) {
    final appBrightness = Theme.of(context).brightness;
    try {
      final compiled = const MarkdownPreviewDocumentCompiler().compile(
        source: source,
      );
      return _NativeMarkdownPreview(
        key: const ValueKey<String>('markdown-native-preview'),
        source: source,
        preferences: preferences,
        headings: compiled.headings,
        nodes: compiled.document.blocks,
        surface: surface,
        brightness: _resolveBrightness(preferences.colorMode, appBrightness),
        mediaResolver: mediaResolver,
      );
    } on Object {
      return const _MarkdownPreviewFallback();
    }
  }
}

class _MarkdownPreviewFallback extends StatelessWidget {
  const _MarkdownPreviewFallback();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Markdown preview unavailable',
      child: Container(
        key: const ValueKey<String>('markdown-preview-fallback'),
        color: colors.surface,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.article_outlined,
                size: 24,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                '该文稿暂时无法安全预览。请减少超长内容、深层嵌套或过大的图片后重试。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NativeMarkdownPreview extends StatelessWidget {
  const _NativeMarkdownPreview({
    required super.key,
    required this.source,
    required this.preferences,
    required this.headings,
    required this.nodes,
    required this.surface,
    required this.brightness,
    this.mediaResolver,
  });

  final MarkdownPreviewSource source;
  final MarkdownPreviewPreferences preferences;
  final List<MarkdownPreviewHeading> headings;
  final List<HuahuoMarkdownBlock> nodes;
  final MarkdownPreviewSurface surface;
  final Brightness brightness;
  final MarkdownPreviewMediaResolver? mediaResolver;

  @override
  Widget build(BuildContext context) {
    final companion = surface == MarkdownPreviewSurface.companion;
    final appTheme = Theme.of(context);
    final colors = brightness == appTheme.brightness
        ? appTheme.colorScheme
        : ColorScheme.fromSeed(
            seedColor: appTheme.colorScheme.primary,
            brightness: brightness,
          );
    final theme = _NativePreviewTheme.resolve(
      id: preferences.theme,
      colors: colors,
      brightness: brightness,
    );
    final scale = preferences.textScale.clamp(
      MarkdownPreviewPreferences.minimumTextScale,
      MarkdownPreviewPreferences.maximumTextScale,
    );
    final markdownColors = HuahuoMarkdownColors(
      text: theme.textColor,
      primary: theme.accentColor,
      surface: theme.documentColor,
      surfaceMuted: theme.codeBackground,
      line: theme.lineColor,
    );
    final bodyStyle = HuahuoMarkdown.bodyStyleFor(
      markdownColors,
    ).copyWith(fontSize: 15 * scale);
    final leadBlockIndex = theme.prefersLead
        ? nodes.indexWhere(
            (block) => block.kind == HuahuoMarkdownBlockKind.paragraph,
          )
        : -1;
    final bodyBlocks = nodes
        .asMap()
        .entries
        .map(
          (entry) => HuahuoMarkdownBlockView(
            key: entry.key == leadBlockIndex
                ? ValueKey<String>(
                    'markdown-native-lead-${theme.id.storageValue}',
                  )
                : null,
            block: entry.value,
            colors: markdownColors,
            bodyStyle: bodyStyle,
            contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
            imageBuilder: (context, alt, source) => _MarkdownPreviewImage(
              source: source,
              alt: alt,
              bodyStyle: bodyStyle,
              theme: theme,
              allowRemoteImages: preferences.allowRemoteImages,
              mediaResolver: mediaResolver,
            ),
          ),
        )
        .toList(growable: false);
    final horizontalPadding =
        preferences.profile == MarkdownPreviewProfile.paper
        ? theme.paperHorizontalPadding
        : theme.horizontalPadding;

    final usesDocumentSurface =
        theme.usesDocumentSurface ||
        preferences.profile == MarkdownPreviewProfile.paper ||
        companion;
    final document = Container(
      key: ValueKey<String>(
        'markdown-native-document-${theme.id.storageValue}',
      ),
      decoration: usesDocumentSurface
          ? BoxDecoration(
              gradient: theme.documentGradient,
              border: Border.all(color: theme.documentBorderColor),
              borderRadius: BorderRadius.circular(theme.documentRadius),
              boxShadow: theme.documentShadow,
            )
          : null,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        child: _NativeDocumentLayout(
          source: source,
          preferences: preferences,
          headings: headings,
          bodyStyle: bodyStyle,
          theme: theme,
          scale: scale,
          bodyBlocks: bodyBlocks,
          leadBlockIndex: leadBlockIndex,
          showDocumentHeader: !companion,
        ),
      ),
    );
    final reader = companion
        ? KeyedSubtree(
            key: const ValueKey<String>('markdown-native-companion'),
            child: document,
          )
        : Center(
            child: ConstrainedBox(
              key: ValueKey<String>(
                'markdown-native-width-${theme.id.storageValue}',
              ),
              constraints: BoxConstraints(
                maxWidth: preferences.profile == MarkdownPreviewProfile.compact
                    ? theme.compactMaxWidth
                    : theme.maxWidth,
              ),
              child: document,
            ),
          );
    return Semantics(
      label: 'Markdown preview',
      child: SelectionArea(
        contextMenuBuilder: HuahuoTextEditing.buildSelectableContextMenu,
        child: Container(
          key: ValueKey<String>(
            'markdown-native-canvas-${theme.id.storageValue}',
          ),
          color: theme.canvasColor,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              companion ? theme.companionCanvasInset : 0,
              companion ? 18 : theme.verticalPadding,
              companion ? theme.companionCanvasInset : 0,
              companion ? 18 : theme.verticalPadding,
            ),
            children: <Widget>[reader],
          ),
        ),
      ),
    );
  }
}

class _NativeDocumentLayout extends StatelessWidget {
  const _NativeDocumentLayout({
    required this.source,
    required this.preferences,
    required this.headings,
    required this.bodyStyle,
    required this.theme,
    required this.scale,
    required this.bodyBlocks,
    required this.leadBlockIndex,
    required this.showDocumentHeader,
  });

  final MarkdownPreviewSource source;
  final MarkdownPreviewPreferences preferences;
  final List<MarkdownPreviewHeading> headings;
  final TextStyle bodyStyle;
  final _NativePreviewTheme theme;
  final double scale;
  final List<Widget> bodyBlocks;
  final int leadBlockIndex;
  final bool showDocumentHeader;

  bool get _showsOutline =>
      showDocumentHeader &&
      preferences.showTableOfContents &&
      headings.isNotEmpty;

  Widget _header({bool showStage = true}) => _NativeDocumentHeader(
    title: source.displayTitle,
    stage: showStage ? source.displayStage : null,
    textStyle: bodyStyle,
    theme: theme,
    scale: scale,
  );

  Widget _outline() => _NativeTableOfContents(
    headings: headings,
    bodyStyle: bodyStyle,
    theme: theme,
  );

  List<Widget> _articleChildren() => <Widget>[
    if (showDocumentHeader) _header(),
    if (_showsOutline) _outline(),
    ...bodyBlocks,
  ];

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey<String>('markdown-native-layout-${theme.layout.name}'),
    child: switch (theme.layout) {
      MarkdownPresentationLayout.article => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _articleChildren(),
      ),
      MarkdownPresentationLayout.parchment => _buildParchment(),
      MarkdownPresentationLayout.magazine => _buildMagazine(),
      MarkdownPresentationLayout.focus => _buildFocus(),
      MarkdownPresentationLayout.research => _buildResearch(),
      MarkdownPresentationLayout.brief => _buildBrief(),
    },
  );

  Widget _buildParchment() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      if (showDocumentHeader) ...<Widget>[
        _header(),
        Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Divider(color: theme.lineColor, height: 1),
        ),
      ],
      if (_showsOutline) _outline(),
      ...bodyBlocks,
      Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Divider(color: theme.lineColor, height: 1),
      ),
    ],
  );

  Widget _buildMagazine() {
    final lead = leadBlockIndex >= 0 && leadBlockIndex < bodyBlocks.length
        ? bodyBlocks[leadBlockIndex]
        : null;
    final article = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: bodyBlocks
          .asMap()
          .entries
          .where((entry) => entry.key != leadBlockIndex)
          .map((entry) => entry.value)
          .toList(growable: false),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wideEditorial = constraints.maxWidth >= 760 && _showsOutline;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (showDocumentHeader && source.displayStage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  source.displayStage!,
                  style: bodyStyle.copyWith(
                    color: theme.accentColor,
                    fontSize: 11.5 * scale,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .8,
                  ),
                ),
              ),
            if (showDocumentHeader) ...<Widget>[
              Divider(color: theme.lineColor, height: 1),
              const SizedBox(height: 18),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: _header(showStage: false),
              ),
            ],
            if (lead != null)
              ConstrainedBox(
                key: const ValueKey<String>('markdown-native-magazine-deck'),
                constraints: const BoxConstraints(maxWidth: 680),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 26),
                  child: lead,
                ),
              ),
            if (showDocumentHeader)
              Padding(
                padding: const EdgeInsets.only(bottom: 26),
                child: Divider(color: theme.lineColor, height: 1),
              ),
            if (!wideEditorial && _showsOutline) _outline(),
            if (wideEditorial)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: article),
                  Container(
                    width: 1,
                    height: 160,
                    margin: const EdgeInsets.only(left: 30, right: 24),
                    color: theme.lineColor,
                  ),
                  SizedBox(
                    key: const ValueKey<String>(
                      'markdown-native-magazine-rail',
                    ),
                    width: 178,
                    child: _outline(),
                  ),
                ],
              )
            else
              article,
          ],
        );
      },
    );
  }

  Widget _buildFocus() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      if (showDocumentHeader) _header(),
      if (_showsOutline)
        Container(
          key: const ValueKey<String>('markdown-native-focus-outline'),
          margin: const EdgeInsets.only(bottom: 14),
          child: _outline(),
        ),
      ...bodyBlocks,
    ],
  );

  Widget _buildResearch() => LayoutBuilder(
    builder: (context, constraints) {
      final outline = _showsOutline
          ? Container(
              key: const ValueKey<String>('markdown-native-research-rail'),
              child: _outline(),
            )
          : const SizedBox.shrink();
      final article = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: bodyBlocks,
      );
      if (constraints.maxWidth < 740 || !_showsOutline) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (showDocumentHeader) _header(),
            if (_showsOutline) outline,
            article,
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (showDocumentHeader) _header(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(width: 188, child: outline),
              const SizedBox(width: 34),
              Expanded(child: article),
            ],
          ),
        ],
      );
    },
  );

  Widget _buildBrief() {
    final lead = leadBlockIndex >= 0 && leadBlockIndex < bodyBlocks.length
        ? bodyBlocks[leadBlockIndex]
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showDocumentHeader) _header(),
        if (lead != null)
          Container(
            key: const ValueKey<String>('markdown-native-brief-summary'),
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 20),
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 2),
            decoration: BoxDecoration(
              color: theme.tocBackground,
              border: Border.all(color: theme.lineColor),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '摘要',
                  style: bodyStyle.copyWith(
                    color: theme.mutedColor,
                    fontSize: bodyStyle.fontSize! * .76,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .55,
                  ),
                ),
                lead,
              ],
            ),
          ),
        if (_showsOutline) _outline(),
        ...bodyBlocks
            .asMap()
            .entries
            .where((entry) => entry.key != leadBlockIndex)
            .map((entry) => entry.value),
      ],
    );
  }
}

class _NativeDocumentHeader extends StatelessWidget {
  const _NativeDocumentHeader({
    required this.title,
    required this.stage,
    required this.textStyle,
    required this.theme,
    required this.scale,
  });

  final String title;
  final String? stage;
  final TextStyle textStyle;
  final _NativePreviewTheme theme;
  final double scale;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: theme.headerBottomSpacing),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (stage != null)
          Padding(
            padding: EdgeInsets.only(bottom: theme.stageBottomSpacing),
            child: Text(
              stage!,
              style: textStyle.copyWith(
                color: theme.stageColor,
                fontSize: 11.5 * scale,
                fontWeight: FontWeight.w600,
                letterSpacing: theme.stageLetterSpacing,
              ),
            ),
          ),
        Text(
          key: ValueKey<String>(
            'markdown-native-title-${theme.id.storageValue}',
          ),
          title,
          style: textStyle.copyWith(
            color: theme.headingColor,
            fontSize: theme.titleSize * scale,
            height: theme.titleLineHeight,
            fontWeight: theme.titleWeight,
            fontFamily: theme.headingFontFamily,
            fontFamilyFallback: theme.headingFontFallback,
          ),
        ),
      ],
    ),
  );
}

class _NativeTableOfContents extends StatelessWidget {
  const _NativeTableOfContents({
    required this.headings,
    required this.bodyStyle,
    required this.theme,
  });

  final List<MarkdownPreviewHeading> headings;
  final TextStyle bodyStyle;
  final _NativePreviewTheme theme;

  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.only(bottom: theme.tocBottomSpacing),
    padding: EdgeInsets.fromLTRB(
      theme.tocHorizontalPadding,
      theme.tocVerticalPadding,
      theme.tocHorizontalPadding,
      theme.tocVerticalPadding,
    ),
    decoration: BoxDecoration(
      color: theme.tocBackground,
      border: theme.framedTableOfContents
          ? Border.all(color: theme.lineColor)
          : Border(left: BorderSide(color: theme.lineColor, width: 2)),
      borderRadius: BorderRadius.circular(theme.tableOfContentsRadius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'On this page',
          style: bodyStyle.copyWith(
            color: theme.mutedColor,
            fontSize: bodyStyle.fontSize! * .76,
            fontWeight: FontWeight.w600,
            letterSpacing: .45,
          ),
        ),
        const SizedBox(height: 6),
        ...headings.map(
          (heading) => Padding(
            padding: EdgeInsets.only(
              left: (heading.level - 1).clamp(0, 3) * 11,
            ),
            child: Text(
              heading.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: bodyStyle.copyWith(
                color: theme.mutedColor,
                fontSize: bodyStyle.fontSize! * .88,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _MarkdownPreviewImage extends StatelessWidget {
  const _MarkdownPreviewImage({
    required this.bodyStyle,
    required this.theme,
    required this.allowRemoteImages,
    this.source,
    this.alt,
    this.mediaResolver,
  });

  final String? source;
  final String? alt;
  final TextStyle bodyStyle;
  final _NativePreviewTheme theme;
  final bool allowRemoteImages;
  final MarkdownPreviewMediaResolver? mediaResolver;

  @override
  Widget build(BuildContext context) {
    final normalized = source?.trim();
    if (normalized == null ||
        normalized.isEmpty ||
        !MarkdownPreviewDocumentCompiler.isSafeImageSource(
          normalized,
          allowRemoteImages,
        )) {
      return _unavailable();
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null) return _unavailable();
    if (uri.scheme == 'huahuo-media') {
      final resolver = mediaResolver;
      if (resolver == null) return _unavailable();
      return FutureBuilder<MarkdownPreviewMedia?>(
        future: resolver(uri),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _loading();
          }
          final media = snapshot.data;
          if (snapshot.hasError || media == null || !media.isSafeForPreview) {
            return _unavailable();
          }
          return _imageFrame(
            (width) => Image.memory(
              media.bytes,
              width: width,
              fit: BoxFit.contain,
              cacheWidth: _cacheWidthFor(width),
              errorBuilder: (_, __, ___) => _unavailable(),
            ),
          );
        },
      );
    }
    if (uri.scheme == 'data') {
      final bytes = _decodeDataImage(normalized);
      if (bytes == null ||
          bytes.length > MarkdownPreviewMedia.maximumPreviewBytes) {
        return _unavailable();
      }
      return _imageFrame(
        (width) => Image.memory(
          bytes,
          width: width,
          fit: BoxFit.contain,
          cacheWidth: _cacheWidthFor(width),
          errorBuilder: (_, __, ___) => _unavailable(),
        ),
      );
    }
    if (uri.scheme == 'https' && allowRemoteImages) {
      return _imageFrame(
        (width) => Image.network(
          normalized,
          width: width,
          fit: BoxFit.contain,
          cacheWidth: _cacheWidthFor(width),
          loadingBuilder: (context, child, loadingProgress) =>
              loadingProgress == null ? child : _loading(),
          errorBuilder: (_, __, ___) => _unavailable(),
        ),
      );
    }
    return _unavailable();
  }

  Widget _imageFrame(Widget Function(double width) childBuilder) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 700.0;
        final width = availableWidth > 700 ? 700.0 : availableWidth;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: theme.imageBorderColor),
              borderRadius: BorderRadius.circular(theme.imageRadius),
              boxShadow: theme.imageShadow,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(theme.imageInnerRadius),
              child: childBuilder(width),
            ),
          ),
        );
      },
    );
  }

  Widget _loading() => _label('正在加载图片');

  Widget _unavailable() {
    final normalizedAlt = alt?.trim();
    final label = normalizedAlt == null || normalizedAlt.isEmpty
        ? '图片不可用'
        : '图片不可用: $normalizedAlt';
    return _label(label);
  }

  Widget _label(String label) {
    return Container(
      height: 92,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.imagePlaceholderBackground,
        border: Border.all(color: theme.lineColor),
        borderRadius: BorderRadius.circular(theme.imageRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: bodyStyle.copyWith(
            color: theme.mutedColor,
            fontSize: bodyStyle.fontSize! * .88,
          ),
        ),
      ),
    );
  }

  Uint8List? _decodeDataImage(String value) {
    final comma = value.indexOf(',');
    if (comma <= 0 || comma == value.length - 1) return null;
    try {
      return Uint8List.fromList(base64Decode(value.substring(comma + 1)));
    } on FormatException {
      return null;
    }
  }

  int _cacheWidthFor(double width) => width
      .clamp(1, MarkdownPreviewMedia.maximumPreviewDecodeWidth.toDouble())
      .round();
}

@immutable
final class _NativePreviewTheme {
  const _NativePreviewTheme._({
    required this.id,
    required this.layout,
    required this.canvasColor,
    required this.documentColor,
    required this.documentHighlightColor,
    required this.documentBorderColor,
    required this.documentShadowColor,
    required this.textColor,
    required this.mutedColor,
    required this.lineColor,
    required this.accentColor,
    required this.codeBackground,
    required this.inlineCodeBackground,
    required this.tableHeaderBackground,
    required this.tocBackground,
    required this.blockquoteBackground,
    required this.imagePlaceholderBackground,
  });

  final MarkdownPreviewTheme id;
  final MarkdownPresentationLayout layout;
  final Color canvasColor;
  final Color documentColor;
  final Color documentHighlightColor;
  final Color documentBorderColor;
  final Color documentShadowColor;
  final Color textColor;
  final Color mutedColor;
  final Color lineColor;
  final Color accentColor;
  final Color codeBackground;
  final Color inlineCodeBackground;
  final Color tableHeaderBackground;
  final Color tocBackground;
  final Color blockquoteBackground;
  final Color imagePlaceholderBackground;

  static _NativePreviewTheme resolve({
    required MarkdownPreviewTheme id,
    required ColorScheme colors,
    required Brightness brightness,
  }) {
    final dark = brightness == Brightness.dark;
    final surface = colors.surface;
    Color blend(Color tint, double alpha) =>
        Color.alphaBlend(tint.withValues(alpha: alpha), surface);
    Color accentFor(Color light, Color darkValue) => dark ? darkValue : light;
    _NativePreviewTheme build({
      required Color accent,
      required Color canvasTint,
      required Color documentTint,
      required double canvasTintOpacity,
      required double documentTintOpacity,
    }) {
      final line = Color.alphaBlend(
        accent.withValues(alpha: dark ? .34 : .18),
        colors.outlineVariant,
      );
      final document = blend(documentTint, documentTintOpacity);
      final code = blend(accent, dark ? .13 : .055);
      return _NativePreviewTheme._(
        id: id,
        layout: id.presentationTemplate.layout,
        canvasColor: blend(canvasTint, canvasTintOpacity),
        documentColor: document,
        documentHighlightColor: Color.alphaBlend(
          Colors.white.withValues(alpha: dark ? .045 : .6),
          document,
        ),
        documentBorderColor: Color.alphaBlend(
          colors.outlineVariant.withValues(alpha: dark ? .5 : .42),
          document,
        ),
        documentShadowColor: dark
            ? const Color(0xFF020617).withValues(alpha: .28)
            : const Color(0xFF526274).withValues(alpha: .11),
        textColor: colors.onSurface,
        mutedColor: colors.onSurfaceVariant,
        lineColor: line,
        accentColor: accent,
        codeBackground: code,
        inlineCodeBackground: blend(accent, dark ? .18 : .09),
        tableHeaderBackground: blend(accent, dark ? .17 : .07),
        tocBackground: blend(accent, dark ? .15 : .045),
        blockquoteBackground: blend(accent, dark ? .12 : .038),
        imagePlaceholderBackground: blend(accent, dark ? .16 : .06),
      );
    }

    return switch (id) {
      MarkdownPreviewTheme.quiet => build(
        accent: accentFor(const Color(0xFF475569), const Color(0xFFCBD5E1)),
        canvasTint: dark ? const Color(0xFF101721) : const Color(0xFFF0F3F7),
        documentTint: dark ? const Color(0xFF18212D) : const Color(0xFFFCFDFE),
        canvasTintOpacity: 1,
        documentTintOpacity: 1,
      ),
      MarkdownPreviewTheme.paper => build(
        accent: accentFor(const Color(0xFF4B5563), const Color(0xFFD1D5DB)),
        canvasTint: dark ? const Color(0xFF181715) : const Color(0xFFF2EFE8),
        documentTint: dark ? const Color(0xFF25211D) : const Color(0xFFFFFCF7),
        canvasTintOpacity: 1,
        documentTintOpacity: 1,
      ),
      MarkdownPreviewTheme.editorial => build(
        accent: accentFor(const Color(0xFF0F766E), const Color(0xFF5EEAD4)),
        canvasTint: dark ? const Color(0xFF12211F) : const Color(0xFFF0F7F4),
        documentTint: dark ? const Color(0xFF172825) : const Color(0xFFFAFDFB),
        canvasTintOpacity: 1,
        documentTintOpacity: 1,
      ),
      MarkdownPreviewTheme.focus => build(
        accent: accentFor(const Color(0xFF2563EB), const Color(0xFF93C5FD)),
        canvasTint: dark ? const Color(0xFF121B2E) : const Color(0xFFF1F5FF),
        documentTint: dark ? const Color(0xFF17223A) : const Color(0xFFFBFCFF),
        canvasTintOpacity: 1,
        documentTintOpacity: 1,
      ),
      MarkdownPreviewTheme.research => build(
        accent: accentFor(const Color(0xFF1D4ED8), const Color(0xFF93C5FD)),
        canvasTint: dark ? const Color(0xFF111C2A) : const Color(0xFFF1F5FB),
        documentTint: dark ? const Color(0xFF172334) : const Color(0xFFFAFCFF),
        canvasTintOpacity: 1,
        documentTintOpacity: 1,
      ),
      MarkdownPreviewTheme.brief => build(
        accent: accentFor(const Color(0xFF0F766E), const Color(0xFF5EEAD4)),
        canvasTint: dark ? const Color(0xFF11231F) : const Color(0xFFF0F7F4),
        documentTint: dark ? const Color(0xFF172E29) : const Color(0xFFFAFDFC),
        canvasTintOpacity: 1,
        documentTintOpacity: 1,
      ),
    };
  }

  bool get usesDocumentSurface =>
      layout == MarkdownPresentationLayout.parchment ||
      id == MarkdownPreviewTheme.quiet;

  LinearGradient get documentGradient => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: const <double>[0, .14, 1],
    colors: <Color>[documentHighlightColor, documentColor, documentColor],
  );

  List<BoxShadow> get documentShadow => <BoxShadow>[
    BoxShadow(
      color: documentShadowColor,
      blurRadius: id == MarkdownPreviewTheme.quiet ? 20 : 16,
      offset: const Offset(0, 7),
    ),
  ];

  bool get prefersLead =>
      layout == MarkdownPresentationLayout.magazine ||
      layout == MarkdownPresentationLayout.brief ||
      id == MarkdownPreviewTheme.quiet;

  Color get headingColor => textColor;

  bool get framedTableOfContents =>
      id == MarkdownPreviewTheme.research || id == MarkdownPreviewTheme.brief;

  double get maxWidth => switch (id) {
    MarkdownPreviewTheme.quiet => 820,
    MarkdownPreviewTheme.paper => 760,
    MarkdownPreviewTheme.editorial => 940,
    MarkdownPreviewTheme.focus => 680,
    MarkdownPreviewTheme.research => 940,
    MarkdownPreviewTheme.brief => 960,
  };

  double get compactMaxWidth => switch (id) {
    MarkdownPreviewTheme.quiet => 920,
    MarkdownPreviewTheme.paper => 820,
    MarkdownPreviewTheme.editorial => 1000,
    MarkdownPreviewTheme.focus => 760,
    MarkdownPreviewTheme.research => 1000,
    MarkdownPreviewTheme.brief => 1020,
  };

  double get companionCanvasInset => switch (id) {
    MarkdownPreviewTheme.quiet => 12,
    MarkdownPreviewTheme.paper => 14,
    _ => 10,
  };

  double get horizontalPadding => switch (id) {
    MarkdownPreviewTheme.quiet => 42,
    MarkdownPreviewTheme.paper => 52,
    MarkdownPreviewTheme.editorial => 40,
    MarkdownPreviewTheme.focus => 42,
    MarkdownPreviewTheme.research => 42,
    MarkdownPreviewTheme.brief => 34,
  };

  double get paperHorizontalPadding => switch (id) {
    MarkdownPreviewTheme.quiet => 54,
    MarkdownPreviewTheme.paper => 58,
    MarkdownPreviewTheme.editorial => 50,
    MarkdownPreviewTheme.focus => 52,
    MarkdownPreviewTheme.research => 52,
    MarkdownPreviewTheme.brief => 44,
  };

  double get verticalPadding => switch (id) {
    MarkdownPreviewTheme.quiet => 30,
    MarkdownPreviewTheme.paper => 40,
    MarkdownPreviewTheme.editorial => 58,
    MarkdownPreviewTheme.focus => 64,
    MarkdownPreviewTheme.research => 38,
    MarkdownPreviewTheme.brief => 30,
  };

  String? get headingFontFamily => switch (id) {
    MarkdownPreviewTheme.paper ||
    MarkdownPreviewTheme.editorial ||
    MarkdownPreviewTheme.research => 'NotoSansSC',
    _ => null,
  };

  List<String>? get headingFontFallback => switch (id) {
    MarkdownPreviewTheme.paper ||
    MarkdownPreviewTheme.editorial ||
    MarkdownPreviewTheme.research => const <String>[
      'PingFang SC',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'Segoe UI',
      'sans-serif',
    ],
    _ => null,
  };

  double get titleSize => switch (id) {
    MarkdownPreviewTheme.quiet => 31,
    MarkdownPreviewTheme.paper => 34,
    MarkdownPreviewTheme.editorial => 40,
    MarkdownPreviewTheme.focus => 34,
    MarkdownPreviewTheme.research => 32,
    MarkdownPreviewTheme.brief => 30,
  };

  double get titleLineHeight => switch (id) {
    MarkdownPreviewTheme.editorial => 1.17,
    MarkdownPreviewTheme.focus => 1.22,
    _ => 1.28,
  };

  FontWeight get titleWeight => switch (id) {
    MarkdownPreviewTheme.editorial => FontWeight.w700,
    MarkdownPreviewTheme.research => FontWeight.w600,
    _ => FontWeight.w600,
  };

  double get headerBottomSpacing => switch (id) {
    MarkdownPreviewTheme.quiet => 34,
    MarkdownPreviewTheme.paper => 42,
    MarkdownPreviewTheme.editorial => 52,
    MarkdownPreviewTheme.focus => 50,
    MarkdownPreviewTheme.research => 30,
    MarkdownPreviewTheme.brief => 26,
  };

  double get stageBottomSpacing =>
      id == MarkdownPreviewTheme.editorial ? 10 : 7;

  Color get stageColor =>
      id == MarkdownPreviewTheme.editorial ? accentColor : mutedColor;

  double get stageLetterSpacing =>
      id == MarkdownPreviewTheme.editorial ? .7 : .5;

  double get tocBottomSpacing => switch (id) {
    MarkdownPreviewTheme.focus => 46,
    MarkdownPreviewTheme.brief => 22,
    _ => 32,
  };

  double get tocHorizontalPadding => framedTableOfContents ? 16 : 15;

  double get tocVerticalPadding => framedTableOfContents ? 12 : 4;

  double get tableOfContentsRadius => id == MarkdownPreviewTheme.brief ? 4 : 0;

  double get documentRadius => switch (id) {
    MarkdownPreviewTheme.quiet => 8,
    MarkdownPreviewTheme.paper => 4,
    _ => 8,
  };

  double get imageRadius => switch (id) {
    MarkdownPreviewTheme.quiet => 8,
    MarkdownPreviewTheme.editorial => 2,
    MarkdownPreviewTheme.brief => 4,
    _ => 6,
  };

  double get imageInnerRadius =>
      (imageRadius - 1).clamp(0, imageRadius).toDouble();

  Color get imageBorderColor =>
      Color.alphaBlend(lineColor.withValues(alpha: .72), documentColor);

  List<BoxShadow>? get imageShadow => id == MarkdownPreviewTheme.quiet
      ? <BoxShadow>[
          BoxShadow(
            color: documentShadowColor,
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ]
      : null;
}

Brightness _resolveBrightness(
  MarkdownPreviewColorMode mode,
  Brightness appBrightness,
) => switch (mode) {
  MarkdownPreviewColorMode.system => appBrightness,
  MarkdownPreviewColorMode.light => Brightness.light,
  MarkdownPreviewColorMode.dark => Brightness.dark,
};
