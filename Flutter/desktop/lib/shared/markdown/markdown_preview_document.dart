import 'package:flutter/foundation.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';

import 'markdown_preview_source.dart';

final class MarkdownPreviewCompiledDocument {
  const MarkdownPreviewCompiledDocument({
    required this.document,
    required this.headings,
  });
  final HuahuoMarkdownDocument document;
  final List<MarkdownPreviewHeading> headings;
}

@immutable
final class MarkdownPreviewHeading {
  const MarkdownPreviewHeading({
    required this.id,
    required this.level,
    required this.title,
  });

  final String id;
  final int level;
  final String title;
}

/// Raised when document content exceeds the reader's bounded rendering budget.
///
/// This is intentionally a preview-only failure. The source document remains
/// unchanged and callers can render a local fallback instead of allowing an
/// expensive or malformed document to destabilize the desktop host.
final class MarkdownPreviewSafetyException implements Exception {
  const MarkdownPreviewSafetyException([this.message = 'Preview unavailable.']);

  final String message;

  @override
  String toString() => 'MarkdownPreviewSafetyException: $message';
}

final class MarkdownPreviewDocumentCompiler {
  const MarkdownPreviewDocumentCompiler();
  static const maximumDocumentCharacters =
      HuahuoMarkdownDocument.maximumCharacters;
  static const maximumDocumentHeadings = HuahuoMarkdownDocument.maximumHeadings;
  static const maximumTitleCharacters = 2048;
  static const maximumStageCharacters = 256;

  MarkdownPreviewCompiledDocument compile({
    required MarkdownPreviewSource source,
  }) {
    try {
      if (source.title.length > maximumTitleCharacters ||
          (source.stage?.length ?? 0) > maximumStageCharacters) {
        throw const MarkdownPreviewSafetyException();
      }
      final document = HuahuoMarkdownDocument.parse(source.markdown);
      final headings = <MarkdownPreviewHeading>[];
      for (final block in document.flattenedBlocks) {
        if (block.kind != HuahuoMarkdownBlockKind.heading) continue;
        headings.add(
          MarkdownPreviewHeading(
            id: 'hh-heading-${headings.length + 1}',
            level: block.level,
            title: _plainTitle(block.text),
          ),
        );
      }
      return MarkdownPreviewCompiledDocument(
        document: document,
        headings: List.unmodifiable(headings),
      );
    } on Object {
      throw const MarkdownPreviewSafetyException();
    }
  }

  static String _plainTitle(String source) {
    String plain(HuahuoMarkdownInline value) =>
        value.children.isEmpty ? value.text : value.children.map(plain).join();
    return parseHuahuoMarkdownInline(source).map(plain).join();
  }

  static bool isSafeImageSource(String value, bool allowRemoteImages) {
    if (value.length > 1024 * 1024) return false;
    final trimmed = value.trim();
    final dataImage = RegExp(
      r'^data:image/(?:png|jpeg|jpg|gif|webp|avif);base64,[A-Za-z0-9+/=\s]+$',
      caseSensitive: false,
    );
    if (dataImage.hasMatch(trimmed)) return true;
    final localMedia = RegExp(
      r'^huahuo-media://asset/[A-Za-z0-9_-]{16,64}$',
      caseSensitive: false,
    );
    if (localMedia.hasMatch(trimmed)) return true;
    if (!allowRemoteImages) return false;
    final uri = Uri.tryParse(trimmed);
    return uri != null &&
        uri.scheme.toLowerCase() == 'https' &&
        uri.host.isNotEmpty;
  }
}
