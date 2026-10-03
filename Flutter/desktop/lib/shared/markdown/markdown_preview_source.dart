import 'package:flutter/foundation.dart';

/// A Markdown document handed to the preview surface.
@immutable
final class MarkdownPreviewSource {
  const MarkdownPreviewSource({
    required this.title,
    required this.markdown,
    this.stage,
  });

  final String title;
  final String markdown;

  /// An optional workflow label, such as a draft or published stage.
  final String? stage;

  String get displayTitle {
    final normalized = title.trim();
    return normalized.isEmpty ? 'Untitled document' : normalized;
  }

  String? get displayStage {
    final normalized = stage?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
