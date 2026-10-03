import 'dart:io';

import 'package:flutter/material.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/huahuo_v3_theme.dart';
import '../ui_v3/v3_text_editing.dart';

typedef V3MarkdownImageBuilder = HuahuoMarkdownImageBuilder;

class V3AssistantReplyMarkdown extends StatelessWidget {
  const V3AssistantReplyMarkdown({
    required this.source,
    this.markdownKey,
    this.headingKeysByLine,
    this.imageBuilder,
    this.textAlign = TextAlign.left,
    this.bodyStyle,
    this.unifiedSelection = false,
    super.key,
  }) : block = null;
  const V3AssistantReplyMarkdown.block(this.block, {this.bodyStyle, super.key})
    : source = '',
      markdownKey = null,
      headingKeysByLine = null,
      imageBuilder = null,
      textAlign = TextAlign.left,
      unifiedSelection = false;
  final HuahuoMarkdownBlock? block;

  final String source;
  final Key? markdownKey;
  final Map<int, GlobalKey>? headingKeysByLine;
  final V3MarkdownImageBuilder? imageBuilder;
  final TextAlign textAlign;
  final TextStyle? bodyStyle;
  final bool unifiedSelection;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final palette = HuahuoMarkdownColors(
      text: colors.text,
      primary: colors.primary,
      surface: colors.surface,
      surfaceMuted: colors.surfaceMuted,
      line: colors.line,
    );
    Widget? resolveImage(BuildContext context, String alt, String source) {
      final uri = Uri.tryParse(source);
      if (uri != null && uri.scheme == _canvasImageScheme) {
        return _MarkdownCanvasImage(alt: alt, uri: uri);
      }
      return imageBuilder?.call(context, alt, source);
    }

    if (block case final block?) {
      return HuahuoMarkdownBlockView(
        block: block,
        colors: palette,
        bodyStyle: HuahuoMarkdown.bodyStyleFor(palette).merge(bodyStyle),
        contextMenuBuilder: V3TextEditing.buildContextMenu,
        imageBuilder: resolveImage,
      );
    }
    return HuahuoMarkdown(
      key: markdownKey,
      source: source,
      colors: palette,
      bodyStyle: bodyStyle == null
          ? null
          : HuahuoMarkdown.bodyStyleFor(palette).merge(bodyStyle),
      headingKeysByLine: headingKeysByLine,
      textAlign: textAlign,
      imageBuilder: resolveImage,
      contextMenuBuilder: V3TextEditing.buildContextMenu,
      unifiedSelection: unifiedSelection,
    );
  }
}

const _canvasImageScheme = 'app-private-canvas-image';
final _canvasImageIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$');

class _MarkdownCanvasImage extends StatefulWidget {
  const _MarkdownCanvasImage({required this.alt, required this.uri});

  final String alt;
  final Uri uri;

  @override
  State<_MarkdownCanvasImage> createState() => _MarkdownCanvasImageState();
}

class _MarkdownCanvasImageState extends State<_MarkdownCanvasImage> {
  late Future<File?> _imageFile;

  @override
  void initState() {
    super.initState();
    _imageFile = _resolveCanvasImage(widget.uri);
  }

  @override
  void didUpdateWidget(covariant _MarkdownCanvasImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) {
      _imageFile = _resolveCanvasImage(widget.uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width =
        (double.tryParse(widget.uri.queryParameters['width'] ?? '1') ?? 1)
            .clamp(.25, 1)
            .toDouble();
    final label = widget.alt.isEmpty ? '图片' : widget.alt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: FutureBuilder<File?>(
        future: _imageFile,
        builder: (context, snapshot) {
          final file = snapshot.data;
          if (file == null) {
            return const SizedBox(
              height: 116,
              child: Center(child: Icon(Icons.broken_image_outlined)),
            );
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final displayWidth = constraints.maxWidth * width;
              final cacheWidth =
                  (displayWidth * MediaQuery.devicePixelRatioOf(context))
                      .ceil()
                      .clamp(1, 4096)
                      .toInt();
              return Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: displayWidth,
                  child: Image.file(
                    file,
                    fit: BoxFit.contain,
                    cacheWidth: cacheWidth,
                    semanticLabel: label,
                    errorBuilder: (_, __, ___) => const SizedBox(
                      height: 116,
                      child: Center(child: Icon(Icons.broken_image_outlined)),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

Future<File?> _resolveCanvasImage(Uri uri) async {
  if (uri.scheme != _canvasImageScheme ||
      !_canvasImageIdPattern.hasMatch(uri.host)) {
    return null;
  }
  final root = await getApplicationSupportDirectory();
  final file = File(
    '${root.path}${Platform.pathSeparator}HuahuoAI'
    '${Platform.pathSeparator}CanvasImages'
    '${Platform.pathSeparator}${uri.host}',
  );
  return await file.exists() ? file : null;
}
