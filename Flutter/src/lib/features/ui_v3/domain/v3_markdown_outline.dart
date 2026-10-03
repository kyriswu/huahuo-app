import 'package:flutter/foundation.dart';

@immutable
final class V3MarkdownOutlineNode {
  V3MarkdownOutlineNode({
    required this.id,
    required this.title,
    required this.level,
    required this.lineIndex,
    required this.directEndLineIndex,
    required this.sectionEndLineIndex,
    required this.directMarkdown,
    required this.sectionMarkdown,
    Iterable<V3MarkdownOutlineNode> children = const <V3MarkdownOutlineNode>[],
  }) : children = List<V3MarkdownOutlineNode>.unmodifiable(children);

  final String id;
  final String title;
  final int level;
  final int lineIndex;
  final int directEndLineIndex;
  final int sectionEndLineIndex;
  final String directMarkdown;
  final String sectionMarkdown;
  final List<V3MarkdownOutlineNode> children;

  String get sectionId => id;

  Iterable<V3MarkdownOutlineNode> get flattened sync* {
    yield this;
    for (final child in children) {
      yield* child.flattened;
    }
  }
}

List<V3MarkdownOutlineNode> parseV3MarkdownOutline(
  String source, {
  String idPrefix = 'section',
  int maximumLevel = 6,
  int maximumHeadings = 128,
}) {
  if (!RegExp(r'^[a-z][a-z0-9-]{0,31}$').hasMatch(idPrefix)) {
    throw ArgumentError.value(idPrefix, 'idPrefix');
  }
  if (maximumLevel < 1 || maximumLevel > 6 || maximumHeadings < 1) {
    throw ArgumentError('Invalid Markdown outline bounds');
  }
  final roots = <_MutableOutlineNode>[];
  final stack = <_MutableOutlineNode>[];
  final parsed = <_MutableOutlineNode>[];
  final occurrences = <String, int>{};
  final lines = source.split(RegExp(r'\r?\n'));
  var fenced = false;
  String? fenceMarker;
  var headingCount = 0;

  for (var index = 0; index < lines.length; index++) {
    final trimmed = lines[index].trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      final marker = trimmed.substring(0, 3);
      if (!fenced) {
        fenced = true;
        fenceMarker = marker;
      } else if (marker == fenceMarker) {
        fenced = false;
        fenceMarker = null;
      }
      continue;
    }
    if (fenced) continue;
    final match = RegExp(r'^(#{1,6})\s+(.+?)\s*#*\s*$').firstMatch(trimmed);
    if (match == null) continue;
    final level = match.group(1)!.length;
    if (level > maximumLevel) continue;
    if (++headingCount > maximumHeadings) {
      throw const FormatException('MARKDOWN_OUTLINE_TOO_COMPLEX');
    }
    final title = match.group(2)!.trim();
    if (title.isEmpty) continue;
    final baseId = '$idPrefix-${_markdownSectionSlug(title)}';
    final occurrence = (occurrences[baseId] ?? 0) + 1;
    occurrences[baseId] = occurrence;
    final node = _MutableOutlineNode(
      id: occurrence == 1 ? baseId : '$baseId-$occurrence',
      title: title,
      level: level,
      lineIndex: index,
    );
    parsed.add(node);
    while (stack.isNotEmpty && stack.last.level >= level) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(node);
    } else {
      stack.last.children.add(node);
    }
    stack.add(node);
  }

  for (var index = 0; index < parsed.length; index++) {
    final node = parsed[index];
    final directEnd = index + 1 < parsed.length
        ? parsed[index + 1].lineIndex
        : lines.length;
    var sectionEnd = lines.length;
    for (var next = index + 1; next < parsed.length; next++) {
      if (parsed[next].level <= node.level) {
        sectionEnd = parsed[next].lineIndex;
        break;
      }
    }
    node
      ..directEndLineIndex = directEnd
      ..sectionEndLineIndex = sectionEnd
      ..directMarkdown = lines
          .sublist(node.lineIndex + 1, directEnd)
          .join('\n')
          .trim()
      ..sectionMarkdown = lines
          .sublist(node.lineIndex + 1, sectionEnd)
          .join('\n')
          .trim();
  }

  return List<V3MarkdownOutlineNode>.unmodifiable(
    roots.map((node) => node.freeze()),
  );
}

final class _MutableOutlineNode {
  _MutableOutlineNode({
    required this.id,
    required this.title,
    required this.level,
    required this.lineIndex,
  });

  final String id;
  final String title;
  final int level;
  final int lineIndex;
  int directEndLineIndex = 0;
  int sectionEndLineIndex = 0;
  String directMarkdown = '';
  String sectionMarkdown = '';
  final List<_MutableOutlineNode> children = <_MutableOutlineNode>[];

  V3MarkdownOutlineNode freeze() => V3MarkdownOutlineNode(
    id: id,
    title: title,
    level: level,
    lineIndex: lineIndex,
    directEndLineIndex: directEndLineIndex,
    sectionEndLineIndex: sectionEndLineIndex,
    directMarkdown: directMarkdown,
    sectionMarkdown: sectionMarkdown,
    children: children.map((child) => child.freeze()),
  );
}

String _markdownSectionSlug(String title) {
  final normalized = title
      .toLowerCase()
      .replaceAll(RegExp(r'[`*_~\[\]()]'), '')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff-]'), '')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return normalized.isEmpty ? 'section' : normalized;
}
