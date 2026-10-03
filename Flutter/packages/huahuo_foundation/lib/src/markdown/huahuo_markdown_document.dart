import 'dart:collection';

import 'huahuo_markdown_table.dart';

enum HuahuoMarkdownBlockKind {
  paragraph,
  heading,
  quote,
  bullet,
  ordered,
  task,
  code,
  table,
  divider,
  spacing,
  alignment,
  image,
}

final class HuahuoMarkdownBlock {
  const HuahuoMarkdownBlock({
    required this.kind,
    required this.sourceLine,
    this.text = '',
    this.level = 0,
    this.marker = '',
    this.checked = false,
    this.table,
    this.children = const [],
  });

  final HuahuoMarkdownBlockKind kind;
  final int sourceLine;
  final String text;
  final int level;
  final String marker;
  final bool checked;
  final HuahuoMarkdownTable? table;
  final List<HuahuoMarkdownBlock> children;
}

final class HuahuoMarkdownDocument {
  HuahuoMarkdownDocument._(Iterable<HuahuoMarkdownBlock> blocks)
    : blocks = List.unmodifiable(blocks);

  static const maximumCharacters = 1000000;
  static const maximumLines = 20000;
  static const maximumBlocks = 20000;
  static const maximumNesting = 48;
  static const maximumHeadings = 1000;

  final List<HuahuoMarkdownBlock> blocks;

  Iterable<HuahuoMarkdownBlock> get flattenedBlocks sync* {
    Iterable<HuahuoMarkdownBlock> flatten(
      List<HuahuoMarkdownBlock> values,
    ) sync* {
      for (final block in values) {
        yield block;
        yield* flatten(block.children);
      }
    }

    yield* flatten(blocks);
  }

  factory HuahuoMarkdownDocument.parse(String source) {
    if (source.length > maximumCharacters) {
      throw const FormatException('MARKDOWN_TOO_LARGE');
    }
    final original = _MarkdownSource.fromText(source);
    if (original.origins.length > maximumLines) {
      throw const FormatException('MARKDOWN_TOO_MANY_LINES');
    }
    final normalized = _normalize(original);
    final lines = normalized.text.split('\n');
    if (lines.length > maximumLines) {
      throw const FormatException('MARKDOWN_TOO_MANY_LINES');
    }
    final sourceLines = <int>[];
    var offset = 0;
    for (final line in lines) {
      sourceLines.add(normalized.sourceLineAt(offset));
      offset += line.length + 1;
    }
    var blockCount = 0;
    var headingCount = 0;
    var inlineCount = 0;
    List<HuahuoMarkdownBlock> parseRange(int start, int end, int depth) {
      if (depth > maximumNesting) {
        throw const FormatException('MARKDOWN_TOO_DEEPLY_NESTED');
      }
      final blocks = <HuahuoMarkdownBlock>[];
      void add(HuahuoMarkdownBlock block) {
        if (++blockCount > maximumBlocks ||
            (block.kind == HuahuoMarkdownBlockKind.heading &&
                ++headingCount > maximumHeadings)) {
          throw const FormatException('MARKDOWN_TOO_COMPLEX');
        }
        if (block.kind != HuahuoMarkdownBlockKind.code) {
          final cells = block.table == null
              ? [block.text]
              : [
                  ...block.table!.headers,
                  ...block.table!.rows.expand((row) => row),
                ];
          for (final cell in cells) {
            final stack = [...parseHuahuoMarkdownInline(cell)];
            while (stack.isNotEmpty) {
              if (++inlineCount > maximumBlocks) {
                throw const FormatException('MARKDOWN_TOO_MANY_INLINE_NODES');
              }
              stack.addAll(stack.removeLast().children);
            }
          }
        }
        blocks.add(block);
      }

      for (var index = start; index < end; index++) {
        final line = lines[index];
        final sourceLine = sourceLines[index];
        final fence = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line);
        if (fence != null) {
          final marker = fence.group(1)!;
          final code = <String>[];
          index++;
          while (index < end &&
              !RegExp(
                '^\\s*${RegExp.escape(marker[0])}{${marker.length},}\\s*\$',
              ).hasMatch(lines[index])) {
            code.add(lines[index++]);
          }
          add(
            HuahuoMarkdownBlock(
              kind: HuahuoMarkdownBlockKind.code,
              sourceLine: sourceLine,
              text: code.join('\n'),
            ),
          );
          continue;
        }
        final table = HuahuoMarkdownTableNormalizer.at(lines, index);
        if (table != null && table.nextIndex <= end) {
          add(
            HuahuoMarkdownBlock(
              kind: HuahuoMarkdownBlockKind.table,
              sourceLine: sourceLine,
              table: table,
            ),
          );
          index = table.nextIndex - 1;
          continue;
        }
        final alignment = RegExp(
          r'^<div align="(left|center|right)">$',
        ).firstMatch(line.trim());
        if (alignment != null) {
          var closing = index + 1;
          var nesting = 1;
          for (; closing < end; closing++) {
            if (RegExp(
              r'^<div align="(left|center|right)">$',
            ).hasMatch(lines[closing].trim())) {
              nesting++;
            }
            if (lines[closing].trim() == '</div>' && --nesting == 0) break;
          }
          if (closing < end) {
            add(
              HuahuoMarkdownBlock(
                kind: HuahuoMarkdownBlockKind.alignment,
                sourceLine: sourceLine,
                marker: alignment.group(1)!,
                children: List.unmodifiable(
                  parseRange(index + 1, closing, depth + 1),
                ),
              ),
            );
            index = closing;
            continue;
          }
        }
        final image = RegExp(
          r'^!\[([^\]\r\n]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)$',
        ).firstMatch(line.trim());
        if (image != null) {
          add(
            HuahuoMarkdownBlock(
              kind: HuahuoMarkdownBlockKind.image,
              sourceLine: sourceLine,
              text: image.group(1)!,
              marker: image.group(2)!,
            ),
          );
          continue;
        }
        if (line.trim().isEmpty) {
          add(
            HuahuoMarkdownBlock(
              kind: HuahuoMarkdownBlockKind.spacing,
              sourceLine: sourceLine,
            ),
          );
          continue;
        }
        if (RegExp(r'^\s*(---|\*\*\*|___)\s*$').hasMatch(line)) {
          add(
            HuahuoMarkdownBlock(
              kind: HuahuoMarkdownBlockKind.divider,
              sourceLine: sourceLine,
            ),
          );
          continue;
        }
        final heading = RegExp(r'^[ \t]{0,3}(#{1,6})\s+(.+)$').firstMatch(line);
        final quote = RegExp(r'^>\s?(.*)$').firstMatch(line);
        final task = RegExp(r'^- \[([ xX])\]\s+(.+)$').firstMatch(line);
        final ordered = RegExp(r'^(\d+)\.\s+(.+)$').firstMatch(line);
        final bullet = RegExp(r'^[-*+]\s+(.+)$').firstMatch(line);
        if (heading == null &&
            quote == null &&
            task == null &&
            ordered == null &&
            bullet == null) {
          final images = RegExp(
            r'!\[([^\]\r\n]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)',
          ).allMatches(line).toList();
          if (images.isNotEmpty) {
            var cursor = 0;
            for (final image in images) {
              if (image.start > cursor) {
                add(
                  HuahuoMarkdownBlock(
                    kind: HuahuoMarkdownBlockKind.paragraph,
                    sourceLine: sourceLine,
                    text: line.substring(cursor, image.start),
                  ),
                );
              }
              add(
                HuahuoMarkdownBlock(
                  kind: HuahuoMarkdownBlockKind.image,
                  sourceLine: sourceLine,
                  text: image.group(1)!,
                  marker: image.group(2)!,
                ),
              );
              cursor = image.end;
            }
            if (cursor < line.length) {
              add(
                HuahuoMarkdownBlock(
                  kind: HuahuoMarkdownBlockKind.paragraph,
                  sourceLine: sourceLine,
                  text: line.substring(cursor),
                ),
              );
            }
            continue;
          }
        }

        add(
          HuahuoMarkdownBlock(
            kind: heading != null
                ? HuahuoMarkdownBlockKind.heading
                : quote != null
                ? HuahuoMarkdownBlockKind.quote
                : task != null
                ? HuahuoMarkdownBlockKind.task
                : ordered != null
                ? HuahuoMarkdownBlockKind.ordered
                : bullet != null
                ? HuahuoMarkdownBlockKind.bullet
                : HuahuoMarkdownBlockKind.paragraph,
            sourceLine: sourceLine,
            text:
                heading?.group(2) ??
                quote?.group(1) ??
                task?.group(2) ??
                ordered?.group(2) ??
                bullet?.group(1) ??
                line,
            level: heading?.group(1)?.length ?? 0,
            checked: task?.group(1)?.toLowerCase() == 'x',
            marker: ordered == null ? '' : '${ordered.group(1)}.',
          ),
        );
      }
      return blocks;
    }

    return HuahuoMarkdownDocument._(parseRange(0, lines.length, 0));
  }
}

enum HuahuoMarkdownInlineKind {
  text,
  foreground,
  background,
  underline,
  code,
  strike,
  bold,
  italic,
  link,
}

final class HuahuoMarkdownInline {
  const HuahuoMarkdownInline(
    this.kind,
    this.text, {
    this.value = '',
    this.children = const [],
  });
  final HuahuoMarkdownInlineKind kind;
  final String text;
  final String value;
  final List<HuahuoMarkdownInline> children;
}

List<HuahuoMarkdownInline> parseHuahuoMarkdownInline(
  String source, [
  int depth = 0,
]) {
  if (depth > HuahuoMarkdownDocument.maximumNesting) {
    throw const FormatException('MARKDOWN_INLINE_TOO_DEEPLY_NESTED');
  }
  final result = <HuahuoMarkdownInline>[];
  final expression = RegExp(
    r'<span\s+(data-hh-(?:fg|bg))="(#[0-9A-Fa-f]{6})">([\s\S]*?)</span>|'
    r'<u>([\s\S]*?)</u>|'
    r'`([^`\n]+)`|~~([^~\n]+)~~|\*\*(.+?)\*\*|\*([^*\n]+?)\*|'
    r'\[([^\]]+)\]\(([^)]+)\)',
  );
  var cursor = 0;
  for (final match in expression.allMatches(source)) {
    if (match.start > cursor) {
      result.add(
        HuahuoMarkdownInline(
          HuahuoMarkdownInlineKind.text,
          source.substring(cursor, match.start),
        ),
      );
    }
    if (match.group(1) != null || match.group(4) != null) {
      final text = match.group(3) ?? match.group(4)!;
      result.add(
        HuahuoMarkdownInline(
          match.group(4) != null
              ? HuahuoMarkdownInlineKind.underline
              : match.group(1) == 'data-hh-fg'
              ? HuahuoMarkdownInlineKind.foreground
              : HuahuoMarkdownInlineKind.background,
          text,
          value: match.group(2) ?? '',
          children: parseHuahuoMarkdownInline(text, depth + 1),
        ),
      );
    } else {
      final group = [
        5,
        6,
        7,
        8,
        9,
      ].firstWhere((index) => match.group(index) != null);
      result.add(
        HuahuoMarkdownInline(
          {
            5: HuahuoMarkdownInlineKind.code,
            6: HuahuoMarkdownInlineKind.strike,
            7: HuahuoMarkdownInlineKind.bold,
            8: HuahuoMarkdownInlineKind.italic,
            9: HuahuoMarkdownInlineKind.link,
          }[group]!,
          match.group(group)!,
          value: match.group(10) ?? '',
        ),
      );
    }
    cursor = match.end;
  }
  if (cursor < source.length || result.isEmpty) {
    result.add(
      HuahuoMarkdownInline(
        HuahuoMarkdownInlineKind.text,
        source.substring(cursor),
      ),
    );
  }
  return List.unmodifiable(result);
}

_MarkdownSource _normalize(_MarkdownSource source) {
  final canonical = source.replace(RegExp(r'\r\n?|[ \t]+\n'), (_) => '\n');
  final sections = <_MarkdownSource>[];
  final lines = canonical.text.split('\n');
  var offset = 0;
  var proseStart = 0;
  var codeStart = -1;
  String? marker;
  for (final line in lines) {
    final fence = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line);
    if (marker == null && fence != null) {
      sections.add(_normalizeProse(canonical.slice(proseStart, offset)));
      codeStart = offset;
      marker = fence.group(1)!;
    } else if (marker != null &&
        RegExp(
          '^\\s*${RegExp.escape(marker[0])}{${marker.length},}\\s*\$',
        ).hasMatch(line)) {
      final end = (offset + line.length + 1).clamp(0, canonical.text.length);
      sections.add(canonical.slice(codeStart, end));
      proseStart = end;
      marker = null;
    }
    offset += line.length + 1;
  }
  sections.add(
    marker == null
        ? _normalizeProse(canonical.slice(proseStart, canonical.text.length))
        : canonical.slice(codeStart, canonical.text.length),
  );
  return _MarkdownSource.join(sections);
}

_MarkdownSource _normalizeProse(_MarkdownSource source) {
  var result = source
      .replace(
        RegExp(r'(^|[^\n|])[ \t]+(-{3,})[ \t]+(?=\S)', multiLine: true),
        (match) => '${match.group(1)}\n\n---\n\n',
      )
      .replace(
        RegExp(r'(^|[^\n])[ \t]+(#{1,6})[ \t]+(?=\S)', multiLine: true),
        (match) => '${match.group(1)}\n\n${match.group(2)} ',
      )
      .replace(
        RegExp(r'([^\n])[ \t]+(\d{1,2}\.)[ \t]+(?=\S)'),
        (match) => '${match.group(1)}\n${match.group(2)} ',
      )
      .replace(
        RegExp(r'([。！？!?：:）\]])[ \t]+([-*])[ \t]+(?=\S)'),
        (match) => '${match.group(1)}\n${match.group(2)} ',
      )
      .replace(
        RegExp(r'([^\n])[ \t]+(✅|☑️|✔️|❌|⚠️|👉)[ \t]+'),
        (match) => '${match.group(1)}\n${match.group(2)} ',
      )
      .replace(
        RegExp(r'([^\n])[ \t]+>[ \t]+(?=\S)'),
        (match) => '${match.group(1)}\n> ',
      )
      .replace(
        RegExp(
          r'^(#{1,6})[ \t]*\n+(?![ \t]*(?:#{1,6}(?:\s|$)|[-*+]\s|\d+\.\s|>\s|\||---\s*$))([^\n]*\S[^\n]*)$',
          multiLine: true,
        ),
        (match) => '${match.group(1)} ${match.group(2)}',
      )
      .replace(
        RegExp(r'^([ \t]{0,3})(#{1,6})(?!#)(?=\S)', multiLine: true),
        (match) => '${match.group(1)}${match.group(2)} ',
      )
      .replace(
        RegExp(
          r'^([ \t]{0,3})(#{1,6})[ \t]*\n(?:[ \t]*\n)*([^\n]+)',
          multiLine: true,
        ),
        (match) {
          final title = match.group(3)!.trim();
          return RegExp(
                r'^(?:#{1,6}(?:\s|$)|```|---|\*\*\*|___)',
              ).hasMatch(title)
              ? match.group(0)!
              : '${match.group(1)}${match.group(2)} $title';
        },
      )
      .replace(
        RegExp(r'^[ \t]{0,3}#{1,6}[ \t]*(?:\n|$)', multiLine: true),
        (_) => '',
      );
  result = result.normalizeTables();
  return result.replace(RegExp(r'\n{3,}'), (_) => '\n\n');
}

final class _MarkdownSource {
  const _MarkdownSource(this.text, this.origins);
  final String text;
  final List<({int offset, int line})> origins;

  factory _MarkdownSource.fromText(String text) => _MarkdownSource(text, [
    (offset: 0, line: 0),
    ...RegExp(r'\r\n|\r|\n')
        .allMatches(text)
        .indexed
        .map((entry) => (offset: entry.$2.end, line: entry.$1 + 1)),
  ]);

  int _originIndex(int offset) {
    var lower = 0;
    var upper = origins.length;
    while (lower + 1 < upper) {
      final middle = (lower + upper) ~/ 2;
      if (origins[middle].offset <= offset) {
        lower = middle;
      } else {
        upper = middle;
      }
    }
    return lower;
  }

  int sourceLineAt(int offset) =>
      origins.isEmpty ? 0 : origins[_originIndex(offset)].line;

  _MarkdownSource slice(int start, int end) {
    final selected = <({int offset, int line})>[
      (offset: 0, line: sourceLineAt(start)),
    ];
    for (var index = _originIndex(start) + 1; index < origins.length; index++) {
      final origin = origins[index];
      if (origin.offset >= end) break;
      selected.add((offset: origin.offset - start, line: origin.line));
    }
    return _MarkdownSource(text.substring(start, end), selected);
  }

  static _MarkdownSource join(Iterable<_MarkdownSource> parts) {
    final buffer = StringBuffer();
    final origins = <({int offset, int line})>[];
    for (final part in parts) {
      if (part.text.isEmpty) continue;
      origins.addAll(
        part.origins
            .map(
              (origin) =>
                  (offset: origin.offset + buffer.length, line: origin.line),
            )
            .toList(),
      );
      buffer.write(part.text);
    }
    return _MarkdownSource(buffer.toString(), origins);
  }

  _MarkdownSource replace(RegExp pattern, String Function(Match) replacement) {
    final parts = <_MarkdownSource>[];
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      parts.add(slice(cursor, match.start));
      final value = replacement(match);
      parts.add(
        value == match.group(0)
            ? slice(match.start, match.end)
            : _MarkdownSource(value, [
                (offset: 0, line: sourceLineAt(match.start)),
              ]),
      );
      cursor = match.end;
    }
    if (cursor == 0) return this;
    parts.add(slice(cursor, text.length));
    return join(parts);
  }

  _MarkdownSource normalizeTables() {
    final normalized = HuahuoMarkdownTableNormalizer.normalize(text);
    if (normalized == text) return this;
    final occurrences = <String, Queue<int>>{};
    var offset = 0;
    for (final line in text.split('\n')) {
      occurrences.putIfAbsent(line, Queue.new).add(sourceLineAt(offset));
      offset += line.length + 1;
    }
    offset = 0;
    var sourceLine = sourceLineAt(0);
    final mapped = <({int offset, int line})>[];
    for (final line in normalized.split('\n')) {
      final candidates = occurrences[line];
      if (candidates != null && candidates.isNotEmpty) {
        sourceLine = candidates.removeFirst();
      }
      mapped.add((offset: offset, line: sourceLine));
      offset += line.length + 1;
    }
    return _MarkdownSource(normalized, mapped);
  }
}
