/// Presentation-neutral table recovery for streamed Markdown.
///
/// This deliberately handles only bounded plain-text table cells. Widgets and
/// PDF exports own their individual inline formatting and visual styling.
library;

final class HuahuoMarkdownTable {
  const HuahuoMarkdownTable({
    required this.headers,
    required this.rows,
    required this.nextIndex,
  });

  final List<String> headers;
  final List<List<String>> rows;
  final int nextIndex;
}

final class HuahuoMarkdownTableNormalizer {
  const HuahuoMarkdownTableNormalizer._();

  static String normalize(String source) {
    var content = source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n');
    content = _normalizeTabbedTables(content);
    content = _splitJoinedSeparators(content);
    content = _splitFlattenedRows(content);
    content = _removeDanglingSeparators(content);
    return content;
  }

  static HuahuoMarkdownTable? at(List<String> lines, int startIndex) {
    if (startIndex < 0 || startIndex >= lines.length) return null;
    final header = _headerAt(lines, startIndex);
    if (header != null) {
      final rows = <List<String>>[];
      var next = header.nextIndex;
      while (next < lines.length) {
        final line = lines[next].trim();
        if (line.isEmpty) break;
        if (_isBlockBoundary(line)) break;
        // A complete header/separator pair starts the next table. Do this
        // before accepting a same-width row so adjacent tables stay separate.
        if (_headerAt(lines, next) != null) break;
        if (isSeparator(line)) {
          next += 1;
          continue;
        }
        final row = splitRow(line);
        if (row.length == header.cells.length &&
            row.every((cell) => cell.isNotEmpty)) {
          rows.add(row);
          next += 1;
          continue;
        }
        final fragmented = _fragmentedRowAt(lines, next, header.cells.length);
        if (fragmented != null) {
          rows.add(fragmented.cells);
          next = fragmented.nextIndex;
          continue;
        }
        final stacked = _stackedRowAt(lines, next, header.cells.length);
        if (stacked != null) {
          rows.add(stacked.cells);
          next = stacked.nextIndex;
          continue;
        }
        final split = _splitRowAt(lines, next, header.cells.length);
        if (split != null) {
          rows.add(split.cells);
          next = split.nextIndex;
          continue;
        }
        break;
      }
      return HuahuoMarkdownTable(
        headers: List<String>.unmodifiable(header.cells),
        rows: List<List<String>>.unmodifiable(
          rows.map(List<String>.unmodifiable),
        ),
        nextIndex: next,
      );
    }

    // A streamed table can omit the separator. Require two same-width rows so
    // ordinary prose containing one pipe is never converted into a table.
    if (startIndex + 1 >= lines.length) return null;
    final headers = splitRow(lines[startIndex]);
    final firstRow = splitRow(lines[startIndex + 1]);
    if (headers.length < 2 ||
        headers.length != firstRow.length ||
        headers.any((cell) => cell.isEmpty) ||
        firstRow.any((cell) => cell.isEmpty)) {
      return null;
    }
    final rows = <List<String>>[firstRow];
    var next = startIndex + 2;
    while (next < lines.length) {
      final row = splitRow(lines[next]);
      if (row.length != headers.length || row.any((cell) => cell.isEmpty)) {
        break;
      }
      rows.add(row);
      next += 1;
    }
    return HuahuoMarkdownTable(
      headers: List<String>.unmodifiable(headers),
      rows: List<List<String>>.unmodifiable(
        rows.map(List<String>.unmodifiable),
      ),
      nextIndex: next,
    );
  }

  static bool isSeparator(String value) {
    final cells = splitRow(value);
    return cells.length >= 2 && cells.every(_isSeparatorCell);
  }

  static List<String> splitRow(String value) {
    var line = value.trim();
    final leading = line.startsWith('|');
    if (leading) line = line.substring(1);
    if (line.endsWith('|')) line = line.substring(0, line.length - 1);
    if (!line.contains('|')) {
      final cell = line.trim();
      return leading && cell.isNotEmpty ? <String>[cell] : const <String>[];
    }
    return line.split('|').map((cell) => cell.trim()).toList(growable: false);
  }

  static String _normalizeTabbedTables(String source) {
    final lines = source.split('\n');
    final output = <String>[];
    var index = 0;
    while (index < lines.length) {
      final header = _tabCells(lines[index]);
      if (header == null) {
        output.add(lines[index]);
        index += 1;
        continue;
      }
      final rows = <List<String>>[header];
      var next = index + 1;
      while (next < lines.length) {
        final row = _tabCells(lines[next]);
        if (row == null || row.length != header.length) break;
        rows.add(row);
        next += 1;
      }
      if (rows.length < 2) {
        output.add(lines[index]);
        index += 1;
        continue;
      }
      output.add(_formatRow(header));
      output.add(_separator(header.length));
      for (final row in rows.skip(1)) {
        output.add(_formatRow(row));
      }
      index = next;
    }
    return output.join('\n');
  }

  static String _splitJoinedSeparators(
    String source,
  ) => source.replaceAllMapped(
    RegExp(
      r'^(\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)+\|)[ \t]*\|[ \t]*(?=\S)',
      multiLine: true,
    ),
    (match) => '${match.group(1)}\n| ',
  );

  static String _splitFlattenedRows(String source) => source
      .split('\n')
      .map(
        (line) => isSeparator(line) || splitRow(line).length >= 2
            ? line
            : line.replaceAllMapped(
                RegExp(
                  r'([^|\n])[^\S\n]+(\|(?:[^\S\n]*[^|\n]+[^\S\n]*\|){2,})(?=[^\S\n]+\||[^\S\n]*$)',
                ),
                (match) => '${match.group(1)}\n${match.group(2)}',
              ),
      )
      .join('\n');

  static String _removeDanglingSeparators(String source) {
    final lines = source.split('\n');
    final result = <String>[];
    for (var index = 0; index < lines.length; index += 1) {
      final current = splitRow(lines[index]);
      if (current.length != 1 || !_isSeparatorCell(current.single)) {
        result.add(lines[index]);
        continue;
      }
      final previous = index > 0 ? lines[index - 1] : '';
      final beforePrevious = index > 1 ? lines[index - 2] : '';
      final next = index + 1 < lines.length ? lines[index + 1] : '';
      final previousCells = splitRow(previous);
      final beforeCells = splitRow(beforePrevious);
      final headerWidth = beforeCells.length == 1 && previousCells.length >= 2
          ? beforeCells.length + previousCells.length
          : previousCells.length;
      final fragment =
          previousCells.length >= 2 &&
          !isSeparator(previous) &&
          isSeparator(next) &&
          headerWidth == splitRow(next).length;
      if (!fragment) result.add(lines[index]);
    }
    return result.join('\n');
  }

  static _Header? _headerAt(List<String> lines, int index) {
    if (index + 1 >= lines.length) return null;
    final headers = splitRow(lines[index]);
    final separator = splitRow(lines[index + 1]);
    if (headers.length >= 2 &&
        headers.length == separator.length &&
        headers.every((cell) => cell.isNotEmpty) &&
        separator.every(_isSeparatorCell)) {
      return _Header(headers, index + 2);
    }
    if (index + 2 >= lines.length ||
        headers.length != 1 ||
        headers.single.isEmpty) {
      return null;
    }
    final remaining = splitRow(lines[index + 1]);
    final stackedSeparator = splitRow(lines[index + 2]);
    final combined = <String>[...headers, ...remaining];
    if (remaining.length < 2 ||
        (combined.length != stackedSeparator.length &&
            combined.length != stackedSeparator.length + 1) ||
        !stackedSeparator.every(_isSeparatorCell)) {
      return null;
    }
    return _Header(combined, index + 3);
  }

  static _Row? _fragmentedRowAt(List<String> lines, int index, int columns) {
    if (columns < 3 || index >= lines.length) return null;
    final first = splitRow(lines[index]);
    if (first.length != 1 || !_isCompactLabel(first.single)) return null;
    final cells = <String>[...first];
    var next = index + 1;
    var fragments = 0;
    while (next < lines.length && cells.length < columns && fragments < 3) {
      final row = splitRow(lines[next]);
      if (row.isEmpty ||
          row.any((cell) => cell.isEmpty) ||
          isSeparator(lines[next])) {
        return null;
      }
      if (row.length == 1 && cells.length > 1 && _isCompactLabel(row.single)) {
        return null;
      }
      cells.addAll(row);
      next += 1;
      fragments += 1;
    }
    if (cells.length == columns) return _Row(cells, next);
    if (cells.length == columns + 1 && _isCompactLabel(cells.first)) {
      return _Row(<String>[
        '${cells[0]} ${cells[1]}'.trim(),
        ...cells.skip(2),
      ], next);
    }
    return null;
  }

  static _Row? _stackedRowAt(List<String> lines, int index, int columns) {
    if (columns < 3 || index + 1 >= lines.length) return null;
    final label = splitRow(lines[index]);
    final values = splitRow(lines[index + 1]);
    if (label.length != 1 ||
        label.single.isEmpty ||
        values.length != columns - 1 ||
        values.any((cell) => cell.isEmpty) ||
        isSeparator(lines[index]) ||
        isSeparator(lines[index + 1])) {
      return null;
    }
    return _Row(<String>[label.single, ...values], index + 2);
  }

  static _Row? _splitRowAt(List<String> lines, int index, int columns) {
    final cells = <String>[];
    var next = index;
    while (next < lines.length && cells.length < columns) {
      final cell = _singleStreamedCell(lines[next]);
      if (cell == null || isSeparator(lines[next])) break;
      cells.add(cell);
      next += 1;
    }
    return cells.length == columns ? _Row(cells, next) : null;
  }

  static String? _singleStreamedCell(String value) {
    final row = splitRow(value);
    if (row.length == 1 && row.single.isNotEmpty) return row.single;
    final plain = value.trim();
    return plain.isNotEmpty && !plain.contains('|') ? plain : null;
  }

  static List<String>? _tabCells(String value) {
    if (!value.contains('\t')) return null;
    final cells = value
        .trim()
        .split(RegExp(r'\t+'))
        .map((cell) => cell.trim())
        .toList(growable: false);
    return cells.length >= 2 && cells.every((cell) => cell.isNotEmpty)
        ? cells
        : null;
  }

  static String _formatRow(List<String> cells) => '| ${cells.join(' | ')} |';
  static String _separator(int count) =>
      '| ${List<String>.filled(count, '---').join(' | ')} |';
  static bool _isSeparatorCell(String value) =>
      RegExp(r'^:?-{3,}:?$').hasMatch(value.trim());

  static bool _isBlockBoundary(String value) {
    final trimmed = value.trimLeft();
    return trimmed.startsWith('```') ||
        trimmed.startsWith('~~~') ||
        trimmed == '---' ||
        RegExp(r'^#{1,6}\s').hasMatch(trimmed);
  }

  static bool _isCompactLabel(String value) => RegExp(
    r'^(?:\d+[a-z]?|[a-z]\d+)$',
    caseSensitive: false,
  ).hasMatch(value.trim());
}

final class _Header {
  const _Header(this.cells, this.nextIndex);
  final List<String> cells;
  final int nextIndex;
}

final class _Row {
  const _Row(this.cells, this.nextIndex);
  final List<String> cells;
  final int nextIndex;
}
