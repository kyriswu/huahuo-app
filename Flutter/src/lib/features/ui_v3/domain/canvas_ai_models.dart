import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

bool canvasAiIntroducesInvalidLineBreaks({
  required String sourceMarkdown,
  required String candidateMarkdown,
}) {
  final protectedContent = RegExp(
    r'(^[ \t]*(`{3,}|~{3,})[^\n]*\n[\s\S]*?^[ \t]*\2[^\n]*(?:\n|$))'
    r'|(`+)[^`\n]*\3'
    r'|!?\[[^\]\n]*\]\([^\n]*?\)'
    r'|(?:https?://|www\.)[^\s<>]+',
    multiLine: true,
  );
  final invalidBreak = RegExp(r'(?:/n){2,}|(?:\\n){2,}|(?:\\r\\n)+');
  Map<String, int> counts(String markdown) {
    final prose = markdown.replaceAll(protectedContent, ' ');
    final result = <String, int>{};
    for (final match in invalidBreak.allMatches(prose)) {
      result.update(match[0]!, (count) => count + 1, ifAbsent: () => 1);
    }
    return result;
  }

  final original = counts(sourceMarkdown);
  return counts(
    candidateMarkdown,
  ).entries.any((entry) => entry.value > (original[entry.key] ?? 0));
}

enum CanvasAiAction {
  socialRelationShift,
  needsDeepening,
  differentiationStrengthening,
  openingOptimization,
  expansion,
  personaInsertion,
  imageBrief,
  atomization,
}

sealed class CanvasAiCommand {
  const CanvasAiCommand();

  String get label;
  String get identity;
  CanvasAiAction? get action;
}

@immutable
final class CanvasAiSkillCommand extends CanvasAiCommand {
  const CanvasAiSkillCommand(this.value);

  final CanvasAiAction value;

  @override
  String get label => value.label;

  @override
  String get identity => 'skill:${value.name}';

  @override
  CanvasAiAction get action => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasAiSkillCommand && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

@immutable
final class CanvasAiChatRewriteCommand extends CanvasAiCommand {
  CanvasAiChatRewriteCommand(String instruction)
    : instruction = instruction.trim() {
    if (this.instruction.isEmpty ||
        this.instruction.length > maxInstructionLength) {
      throw ArgumentError.value(
        instruction,
        'instruction',
        'must contain between 1 and $maxInstructionLength characters',
      );
    }
  }

  static const int maxInstructionLength = 8000;

  final String instruction;

  @override
  String get label => '聊天改写';

  @override
  String get identity => 'chat:${canvasTextHash(instruction)}';

  @override
  CanvasAiAction? get action => null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasAiChatRewriteCommand && other.instruction == instruction;

  @override
  int get hashCode => instruction.hashCode;
}

extension CanvasAiActionX on CanvasAiAction {
  String get label => switch (this) {
    CanvasAiAction.socialRelationShift => '社会关系转变',
    CanvasAiAction.needsDeepening => '需求深化',
    CanvasAiAction.differentiationStrengthening => '差异化增强',
    CanvasAiAction.openingOptimization => '开头优化',
    CanvasAiAction.expansion => '扩写',
    CanvasAiAction.personaInsertion => '人设植入',
    CanvasAiAction.imageBrief => '配图',
    CanvasAiAction.atomization => '原子化',
  };
}

enum CanvasOpeningVariant { labeling, defamiliarization }

extension CanvasOpeningVariantX on CanvasOpeningVariant {
  String get label => switch (this) {
    CanvasOpeningVariant.labeling => '标签化',
    CanvasOpeningVariant.defamiliarization => '陌生化',
  };
}

enum CanvasImageVariant { sceneDesign, spokenVisuals }

extension CanvasImageVariantX on CanvasImageVariant {
  String get label => switch (this) {
    CanvasImageVariant.sceneDesign => '影像增强成品配图',
    CanvasImageVariant.spokenVisuals => '口播解释性画面',
  };
}

enum CanvasRelationTarget { peer, friend, advisor, mentor, customer }

extension CanvasRelationTargetX on CanvasRelationTarget {
  String get label => switch (this) {
    CanvasRelationTarget.peer => '平等交流',
    CanvasRelationTarget.friend => '朋友分享',
    CanvasRelationTarget.advisor => '顾问建议',
    CanvasRelationTarget.mentor => '导师引导',
    CanvasRelationTarget.customer => '客户对话',
  };
}

enum CanvasTransformScope { selection, document }

enum CanvasAiEditScope { global, local }

extension CanvasAiEditScopeX on CanvasAiEditScope {
  String get label => switch (this) {
    CanvasAiEditScope.global => '全局',
    CanvasAiEditScope.local => '局部',
  };
}

enum CanvasAiTransformStatus {
  idle,
  running,
  awaitingCompletion,
  previewing,
  applying,
  failed,
  cancelled,
}

@immutable
final class CanvasTextRange {
  const CanvasTextRange({required this.start, required this.end});

  final int start;
  final int end;

  int get length => end - start;
  bool get isCollapsed => start == end;

  bool isValidFor(String text) =>
      start >= 0 && end >= start && end <= text.length;

  String textFrom(String text) {
    if (!isValidFor(text)) {
      throw RangeError.range(end, start, text.length, 'end');
    }
    return text.substring(start, end);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasTextRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'CanvasTextRange($start, $end)';
}

@immutable
final class CanvasAiRequest {
  const CanvasAiRequest({
    required this.requestId,
    required this.command,
    required this.scope,
    required this.editScope,
    required this.documentMarkdown,
    required this.documentRevision,
    required this.documentHash,
    required this.targetRange,
    required this.targetMarkdown,
    required this.targetHash,
    this.openingVariant,
    this.imageVariant,
    this.relationTarget,
    this.personaContext,
    this.sourceNoteId,
    this.sourcePartRevisionId,
  }) : assert(
         (sourceNoteId == null) == (sourcePartRevisionId == null),
         'Exact source Note identity must be complete',
       );

  final String requestId;
  final CanvasAiCommand command;
  CanvasAiAction? get action => command.action;
  final CanvasTransformScope scope;
  final CanvasAiEditScope editScope;
  final String documentMarkdown;
  final int documentRevision;
  final String documentHash;
  final CanvasTextRange targetRange;
  final String targetMarkdown;
  final String targetHash;
  final CanvasOpeningVariant? openingVariant;
  final CanvasImageVariant? imageVariant;
  final CanvasRelationTarget? relationTarget;
  final String? personaContext;
  final String? sourceNoteId;
  final String? sourcePartRevisionId;

  CanvasAiRequest withRequestId(String value) => CanvasAiRequest(
    requestId: value,
    command: command,
    scope: scope,
    editScope: editScope,
    documentMarkdown: documentMarkdown,
    documentRevision: documentRevision,
    documentHash: documentHash,
    targetRange: targetRange,
    targetMarkdown: targetMarkdown,
    targetHash: targetHash,
    openingVariant: openingVariant,
    imageVariant: imageVariant,
    relationTarget: relationTarget,
    personaContext: personaContext,
    sourceNoteId: sourceNoteId,
    sourcePartRevisionId: sourcePartRevisionId,
  );
}

@immutable
final class CanvasAiResult {
  const CanvasAiResult({
    required this.requestId,
    required this.command,
    required this.sourceDocumentHash,
    required this.sourceTargetHash,
    required this.generatedAt,
    this.replacementMarkdown = '',
    this.unifiedDiff,
  });

  final String requestId;
  final CanvasAiCommand command;
  CanvasAiAction? get action => command.action;
  final String replacementMarkdown;
  final String? unifiedDiff;
  final String sourceDocumentHash;
  final String sourceTargetHash;
  final DateTime generatedAt;

  bool get hasUnifiedDiff => unifiedDiff?.trim().isNotEmpty == true;

  CanvasAiResult withResolvedReplacement(String value) => CanvasAiResult(
    requestId: requestId,
    command: command,
    sourceDocumentHash: sourceDocumentHash,
    sourceTargetHash: sourceTargetHash,
    generatedAt: generatedAt,
    replacementMarkdown: value,
    unifiedDiff: unifiedDiff,
  );
}

@immutable
final class CanvasAiApplication {
  const CanvasAiApplication({
    required this.requestId,
    required this.updatedMarkdown,
    required this.replacedRange,
    required this.replacementMarkdown,
    required this.sourceRevision,
    required this.sourceDocumentHash,
  });

  final String requestId;
  final String updatedMarkdown;
  final CanvasTextRange replacedRange;
  final String replacementMarkdown;
  final int sourceRevision;
  final String sourceDocumentHash;
}

String canvasTextHash(String value) =>
    sha256.convert(utf8.encode(value)).toString();

final class CanvasUnifiedDiffException implements Exception {
  const CanvasUnifiedDiffException();

  @override
  String toString() => 'CanvasUnifiedDiffException()';
}

/// Extracts one unambiguous unified diff from a raw Agent answer or fence.
/// The result remains untouched until [canvasApplyUnifiedDiff] verifies it.
String? canvasExtractUnifiedDiff(String value) {
  final normalized = value.replaceAll('\r\n', '\n');
  if (normalized.trim().isEmpty) return null;
  final structured = _structuredUnifiedDiff(normalized);
  if (structured != null) return structured;
  final fencedOutput = _splitCanvasFencedOutput(normalized);
  if (fencedOutput.hasUnclosedFence) {
    throw const CanvasUnifiedDiffException();
  }
  final fencedCandidates = fencedOutput.blocks
      .map(_canonicalUnifiedDiff)
      .whereType<String>()
      .toList(growable: false);
  final bareCandidate = _canonicalUnifiedDiff(fencedOutput.outside);
  final candidates = <String>[
    ...fencedCandidates,
    if (bareCandidate != null) bareCandidate,
  ];
  if (candidates.length > 1) {
    throw const CanvasUnifiedDiffException();
  }
  return candidates.firstOrNull;
}

({List<String> blocks, String outside, bool hasUnclosedFence})
_splitCanvasFencedOutput(String value) {
  final blocks = <String>[];
  final outside = <String>[];
  List<String>? body;
  String? marker;
  var minimumClosingLength = 0;
  for (final line in value.split('\n')) {
    if (body == null) {
      final opening = _canvasFenceOpening(line);
      if (opening == null ||
          (line.startsWith(' ') &&
              _canvasDiffExpectsAnotherContextLine(outside))) {
        outside.add(line);
        continue;
      }
      body = <String>[];
      marker = opening.marker;
      minimumClosingLength = opening.length;
      outside.add('');
      continue;
    }
    if (_isCanvasFenceClosing(line, marker!, minimumClosingLength) &&
        !(line.startsWith(' ') && _canvasDiffExpectsAnotherContextLine(body))) {
      blocks.add(body.join('\n'));
      body = null;
      marker = null;
      minimumClosingLength = 0;
    } else {
      body.add(line);
    }
    outside.add('');
  }
  return (
    blocks: blocks,
    outside: outside.join('\n'),
    hasUnclosedFence: body != null,
  );
}

bool _canvasDiffExpectsAnotherContextLine(List<String> lines) {
  Match? hunk;
  var hunkIndex = -1;
  for (var index = lines.length - 1; index >= 0; index--) {
    final candidate = _canvasUnifiedHunk.firstMatch(lines[index]);
    if (candidate == null) continue;
    hunk = candidate;
    hunkIndex = index;
    break;
  }
  if (hunk == null) return false;

  final oldCount = int.tryParse(hunk.group(2) ?? '1');
  final newCount = int.tryParse(hunk.group(4) ?? '1');
  if (oldCount == null || newCount == null) return false;
  var oldRemaining = oldCount;
  var newRemaining = newCount;
  for (final line in lines.skip(hunkIndex + 1)) {
    if (line == r'\ No newline at end of file') continue;
    if (line.isEmpty) return false;
    switch (line[0]) {
      case ' ':
        oldRemaining--;
        newRemaining--;
        break;
      case '-':
        oldRemaining--;
        break;
      case '+':
        newRemaining--;
        break;
      default:
        return false;
    }
    if (oldRemaining < 0 || newRemaining < 0) return false;
  }
  return oldRemaining > 0 && newRemaining > 0;
}

({String marker, int length})? _canvasFenceOpening(String line) {
  final match = RegExp(r'^( {0,3})(`{3,}|~{3,})(.*)$').firstMatch(line);
  if (match == null) return null;
  final fence = match.group(2)!;
  final marker = fence[0];
  if (marker == '`' && match.group(3)!.contains('`')) return null;
  return (marker: marker, length: fence.length);
}

bool _isCanvasFenceClosing(String line, String marker, int minimumLength) {
  var offset = 0;
  while (offset < line.length &&
      offset < 3 &&
      line.codeUnitAt(offset) == 0x20) {
    offset++;
  }
  var end = offset;
  while (end < line.length && line[end] == marker) {
    end++;
  }
  return end - offset >= minimumLength && line.substring(end).trim().isEmpty;
}

String? _structuredUnifiedDiff(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return null;
    final candidates = <String>{};
    for (final candidate in <Object?>[decoded['diff'], decoded]) {
      if (candidate is! Map || candidate['format'] != 'unified') continue;
      final content = candidate['content'];
      if (content is! String) continue;
      final canonical = _canonicalUnifiedDiff(content);
      if (canonical != null) candidates.add(canonical);
    }
    if (candidates.length > 1) {
      throw const CanvasUnifiedDiffException();
    }
    return candidates.firstOrNull;
  } on FormatException {
    return null;
  }
}

String? _canonicalUnifiedDiff(String value) {
  final lines = _canvasDiffLines(value.replaceAll('\r\n', '\n'));
  final start = _firstUnifiedDiffHeader(lines);
  return start == null ? null : lines.sublist(start).join('\n');
}

String canvasBuildWholePayloadUnifiedDiff({
  required String baseMarkdown,
  required String replacementMarkdown,
}) {
  final normalizedBase = baseMarkdown.replaceAll('\r\n', '\n');
  final normalizedReplacement = replacementMarkdown.replaceAll('\r\n', '\n');
  final before = _canvasDiffLines(normalizedBase);
  final after = _canvasDiffLines(normalizedReplacement);
  final lines = <String>[
    '--- a/canvas.md',
    '+++ b/canvas.md',
    '@@ -${before.isEmpty ? 0 : 1},${before.length} '
        '+${after.isEmpty ? 0 : 1},${after.length} @@',
    for (var index = 0; index < before.length; index++) ...[
      '-${before[index]}',
      if (index == before.length - 1 && !normalizedBase.endsWith('\n'))
        r'\ No newline at end of file',
    ],
    for (var index = 0; index < after.length; index++) ...[
      '+${after[index]}',
      if (index == after.length - 1 && !normalizedReplacement.endsWith('\n'))
        r'\ No newline at end of file',
    ],
  ];
  return '${lines.join('\n')}\n';
}

/// Applies a complete unified diff to one frozen Markdown payload.
///
/// Each hunk is matched against its declared baseline before the payload is
/// changed. A partial or mismatched patch is rejected as a whole.
String canvasApplyUnifiedDiff({
  required String baseMarkdown,
  required String unifiedDiff,
}) {
  final normalizedBase = baseMarkdown.replaceAll('\r\n', '\n');
  final source = _canvasSourceLines(normalizedBase);
  final lines = _canvasDiffLines(unifiedDiff.replaceAll('\r\n', '\n'));
  final header = _firstUnifiedDiffHeader(lines);
  if (header == null) throw const CanvasUnifiedDiffException();

  var lineIndex = header + 2;
  var lineOffset = 0;
  var lastOriginalEnd = 0;
  var foundHunk = false;
  while (lineIndex < lines.length) {
    final hunkMatch = _canvasUnifiedHunk.firstMatch(lines[lineIndex]);
    if (hunkMatch == null) {
      if (!foundHunk && _isUnifiedDiffPreamble(lines[lineIndex])) {
        lineIndex++;
        continue;
      }
      throw const CanvasUnifiedDiffException();
    }
    foundHunk = true;
    final oldStart = int.tryParse(hunkMatch.group(1) ?? '');
    final oldCount = int.tryParse(hunkMatch.group(2) ?? '1');
    final newStart = int.tryParse(hunkMatch.group(3) ?? '');
    final newCount = int.tryParse(hunkMatch.group(4) ?? '1');
    if (oldStart == null ||
        oldCount == null ||
        newStart == null ||
        newCount == null ||
        oldCount < 0 ||
        newCount < 0 ||
        (oldCount > 0 && oldStart < 1) ||
        (newCount > 0 && newStart < 1)) {
      throw const CanvasUnifiedDiffException();
    }
    lineIndex++;
    final hunkLines = <_CanvasUnifiedDiffLine>[];
    while (lineIndex < lines.length &&
        !_canvasUnifiedHunk.hasMatch(lines[lineIndex])) {
      final line = lines[lineIndex];
      if (line == r'\ No newline at end of file') {
        if (hunkLines.isEmpty || hunkLines.last.hasNoTerminalNewline) {
          throw const CanvasUnifiedDiffException();
        }
        final previous = hunkLines.removeLast();
        hunkLines.add(previous.withNoTerminalNewline());
        lineIndex++;
        continue;
      }
      if (line.isEmpty) {
        throw const CanvasUnifiedDiffException();
      }
      final marker = line[0];
      if (marker != ' ' && marker != '+' && marker != '-') {
        throw const CanvasUnifiedDiffException();
      }
      hunkLines.add(_CanvasUnifiedDiffLine(marker, line.substring(1)));
      lineIndex++;
    }

    final observedOld = hunkLines.where((line) => line.marker != '+').length;
    final observedNew = hunkLines.where((line) => line.marker != '-').length;
    if (observedOld != oldCount || observedNew != newCount) {
      throw const CanvasUnifiedDiffException();
    }

    final originalStart = oldCount == 0
        ? oldStart
        : (oldStart == 0 ? 0 : oldStart - 1);
    if (originalStart < lastOriginalEnd) {
      throw const CanvasUnifiedDiffException();
    }
    final targetStart = originalStart + lineOffset;
    if (targetStart < 0 || targetStart > source.length) {
      throw const CanvasUnifiedDiffException();
    }
    final expectedNewStart = newCount == 0 ? targetStart : targetStart + 1;
    if (newStart != expectedNewStart) {
      throw const CanvasUnifiedDiffException();
    }
    var sourceIndex = targetStart;
    final replacement = <_CanvasSourceLine>[];
    for (final line in hunkLines) {
      switch (line.marker) {
        case ' ':
          if (sourceIndex >= source.length ||
              source[sourceIndex].content != line.content ||
              line.hasNoTerminalNewline ==
                  source[sourceIndex].hasTerminalNewline) {
            throw const CanvasUnifiedDiffException();
          }
          replacement.add(
            source[sourceIndex].copyWith(
              hasTerminalNewline:
                  !line.hasNoTerminalNewline &&
                  source[sourceIndex].hasTerminalNewline,
            ),
          );
          sourceIndex++;
          break;
        case '-':
          if (sourceIndex >= source.length ||
              source[sourceIndex].content != line.content ||
              line.hasNoTerminalNewline ==
                  source[sourceIndex].hasTerminalNewline) {
            throw const CanvasUnifiedDiffException();
          }
          sourceIndex++;
          break;
        case '+':
          replacement.add(
            _CanvasSourceLine(
              line.content,
              hasTerminalNewline: !line.hasNoTerminalNewline,
            ),
          );
          break;
      }
    }
    source.replaceRange(targetStart, sourceIndex, replacement);
    lineOffset += replacement.length - (sourceIndex - targetStart);
    lastOriginalEnd = originalStart + oldCount;
  }

  if (!foundHunk) throw const CanvasUnifiedDiffException();
  return _canvasSourceToMarkdown(source);
}

final RegExp _canvasUnifiedHunk = RegExp(
  r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
);

int? _firstUnifiedDiffHeader(List<String> lines) {
  for (var index = 0; index + 1 < lines.length; index++) {
    if (lines[index].startsWith('--- ') &&
        lines[index + 1].startsWith('+++ ')) {
      return index;
    }
  }
  return null;
}

bool _isUnifiedDiffPreamble(String line) =>
    line.startsWith('diff --git ') ||
    line.startsWith('index ') ||
    line.startsWith('new file mode ') ||
    line.startsWith('deleted file mode ') ||
    line.startsWith('similarity index ') ||
    line.startsWith('rename from ') ||
    line.startsWith('rename to ');

List<String> _canvasDiffLines(String value) {
  if (value.isEmpty) return <String>[];
  final lines = value.split('\n');
  if (value.endsWith('\n')) lines.removeLast();
  return lines;
}

List<_CanvasSourceLine> _canvasSourceLines(String value) {
  final lines = _canvasDiffLines(value);
  if (lines.isEmpty) return <_CanvasSourceLine>[];
  final terminalNewline = value.endsWith('\n');
  return <_CanvasSourceLine>[
    for (var index = 0; index < lines.length; index++)
      _CanvasSourceLine(
        lines[index],
        hasTerminalNewline: index != lines.length - 1 || terminalNewline,
      ),
  ];
}

String _canvasSourceToMarkdown(List<_CanvasSourceLine> source) {
  if (source.isEmpty) return '';
  if (source.take(source.length - 1).any((line) => !line.hasTerminalNewline)) {
    throw const CanvasUnifiedDiffException();
  }
  return '${source.map((line) => line.content).join('\n')}'
      '${source.last.hasTerminalNewline ? '\n' : ''}';
}

@immutable
final class _CanvasSourceLine {
  const _CanvasSourceLine(this.content, {required this.hasTerminalNewline});

  final String content;
  final bool hasTerminalNewline;

  _CanvasSourceLine copyWith({required bool hasTerminalNewline}) =>
      _CanvasSourceLine(content, hasTerminalNewline: hasTerminalNewline);
}

@immutable
final class _CanvasUnifiedDiffLine {
  const _CanvasUnifiedDiffLine(
    this.marker,
    this.content, {
    this.hasNoTerminalNewline = false,
  });

  final String marker;
  final String content;
  final bool hasNoTerminalNewline;

  _CanvasUnifiedDiffLine withNoTerminalNewline() =>
      _CanvasUnifiedDiffLine(marker, content, hasNoTerminalNewline: true);
}
