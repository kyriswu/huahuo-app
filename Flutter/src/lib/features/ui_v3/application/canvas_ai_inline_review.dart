import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import '../domain/canvas_image_embed_data.dart';
import 'canvas_document_codec.dart';

enum CanvasReviewChange { deleted, inserted }

@immutable
final class CanvasAiInlineReview {
  CanvasAiInlineReview({
    required Delta base,
    required Delta candidate,
    TextSelection initialCandidateSelection = const TextSelection.collapsed(
      offset: 0,
    ),
  }) : _base = _cleanDocument(base),
       _candidate = _cleanDocument(candidate) {
    _projection = _project(_base, _candidate);
    insertedCharacterCount = _changeLength(
      _projection,
      CanvasReviewChange.inserted,
    );
    deletedCharacterCount = _changeLength(
      _projection,
      CanvasReviewChange.deleted,
    );
    editor = QuillController(
      document: Document.fromDelta(Delta.fromJson(_projection.toJson())),
      selection: mapCandidateSelectionToProjection(initialCandidateSelection),
      readOnly: true,
      onReplaceText: (_, _, _) => false,
    );
  }

  static const _tokenPrefix = 'huahuo:canvas-review:';

  final Delta _base;
  final Delta _candidate;
  late final Delta _projection;
  late final QuillController editor;
  late final int insertedCharacterCount;
  late final int deletedCharacterCount;

  Delta get candidateDelta => Delta.fromJson(_candidate.toJson());

  TextSelection get candidateSelection =>
      mapProjectionSelectionToCandidate(editor.selection);

  TextSelection mapProjectionSelectionToCandidate(TextSelection selection) =>
      TextSelection(
        baseOffset: _candidateOffset(_projection, selection.baseOffset),
        extentOffset: _candidateOffset(_projection, selection.extentOffset),
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      );

  TextSelection mapCandidateSelectionToProjection(TextSelection selection) =>
      TextSelection(
        baseOffset: _projectionOffset(_projection, selection.baseOffset),
        extentOffset: _projectionOffset(_projection, selection.extentOffset),
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      );

  String candidateTextForProjectionSelection(TextSelection selection) {
    final candidateSelection = mapProjectionSelectionToCandidate(selection);
    if (candidateSelection.isCollapsed) return '';
    final slice = _candidate.slice(
      candidateSelection.start,
      candidateSelection.end,
    );
    final text = StringBuffer();
    for (final operation in slice.toList()) {
      final data = operation.data;
      if (data is String) {
        text.write(data);
      } else if (data is Map &&
          data.containsKey(CanvasDocumentCodec.canvasDividerEmbedType)) {
        text.write('\n---\n');
      } else if (data is Map &&
          data.containsKey(CanvasImageEmbedData.deltaEmbedType)) {
        try {
          final image = CanvasImageEmbedData.fromDeltaInsert(data);
          text.write('[图片：${image.alt}]');
        } on FormatException {
          text.write('[图片]');
        }
      } else {
        text.write('[嵌入内容]');
      }
    }
    return text.toString();
  }

  static CanvasReviewChange? changeFor(Map<String, dynamic>? attributes) {
    final token = attributes?[Attribute.token.key];
    if (token is! String || !token.startsWith(_tokenPrefix)) return null;
    try {
      final data = jsonDecode(token.substring(_tokenPrefix.length));
      if (data is! Map) return null;
      return switch (data['change']) {
        'deleted' => CanvasReviewChange.deleted,
        'inserted' || 'retained' => CanvasReviewChange.inserted,
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic>? _cleanAttributes(
    Map<String, dynamic>? attributes,
  ) {
    if (attributes == null) return null;
    final cleaned = Map<String, dynamic>.from(attributes);
    if (changeFor(attributes) != null) {
      final token = attributes[Attribute.token.key] as String;
      final data = jsonDecode(token.substring(_tokenPrefix.length));
      if (data['original'] == null) {
        cleaned.remove(Attribute.token.key);
      } else {
        cleaned[Attribute.token.key] = data['original'];
      }
    }
    return cleaned.isEmpty ? null : cleaned;
  }

  static Delta _cleanDocument(Delta document) {
    final cleaned = Delta();
    for (final operation in Delta.fromJson(document.toJson()).toList()) {
      cleaned.insert(operation.data, _cleanAttributes(operation.attributes));
    }
    return cleaned;
  }

  static Map<String, dynamic> _mark(
    Map<String, dynamic>? attributes,
    CanvasReviewChange change,
  ) {
    final original = _cleanAttributes(attributes);
    return {
      ...?original,
      Attribute.token.key:
          '$_tokenPrefix${jsonEncode({'change': change.name, 'original': original?[Attribute.token.key]})}',
    };
  }

  static void _append(
    Delta destination,
    Delta source, [
    CanvasReviewChange? change,
  ]) {
    for (final operation in source.toList()) {
      destination.insert(
        operation.data,
        change == null
            ? operation.attributes
            : _mark(operation.attributes, change),
      );
    }
  }

  static int _changeLength(Delta projection, CanvasReviewChange change) {
    var length = 0;
    for (final operation in projection.toList()) {
      if (changeFor(operation.attributes) == change) {
        length += operation.length!;
      }
    }
    return length;
  }

  static Delta _comparisonDelta(Delta document) {
    final comparison = Delta();
    var line = Delta();

    void appendLine(Map<String, dynamic>? attributes) {
      final blockStyle = jsonEncode({
        for (final key in Attribute.blockKeys)
          if (attributes?.containsKey(key) == true) key: attributes![key],
      });
      for (final operation in line.toList()) {
        comparison.insert(operation.data, {
          ...?operation.attributes,
          'huahuo-review-line-style': blockStyle,
        });
      }
      line = Delta();
    }

    for (final operation in document.toList()) {
      final data = operation.data;
      if (data is! String) {
        line.insert(data, operation.attributes);
        continue;
      }
      var offset = 0;
      var newline = data.indexOf('\n');
      while (newline >= 0) {
        line.insert(data.substring(offset, newline + 1), operation.attributes);
        appendLine(operation.attributes);
        offset = newline + 1;
        newline = data.indexOf('\n', offset);
      }
      if (offset < data.length) {
        line.insert(data.substring(offset), operation.attributes);
      }
    }
    if (line.isNotEmpty) appendLine(null);
    return comparison;
  }

  static ({Delta delta, List<int> offsets}) _encodeComparison(
    Delta document,
    Map<String, String> graphemeTokens,
  ) {
    final encoded = Delta();
    final offsets = <int>[0];
    var offset = 0;
    for (final operation in _comparisonDelta(document).toList()) {
      final data = operation.data;
      if (data is! String) {
        encoded.insert(data, operation.attributes);
        offsets.add(++offset);
        continue;
      }
      final text = StringBuffer();
      for (final grapheme in data.characters) {
        text.write(graphemeTokens[grapheme]!);
        offset += grapheme.length;
        offsets.add(offset);
      }
      encoded.insert(text.toString(), operation.attributes);
    }
    return (delta: encoded, offsets: offsets);
  }

  static Map<String, String> _graphemeTokens(Delta base, Delta candidate) {
    final graphemes = <String>{};
    for (final operation in [...base.toList(), ...candidate.toList()]) {
      final data = operation.data;
      if (data is String) graphemes.addAll(data.characters);
    }
    final tokens = <String, String>{};
    var nextToken = 0x100;
    for (final grapheme in graphemes) {
      if (nextToken >= 0xD800 && nextToken <= 0xDFFF) nextToken = 0xE000;
      if (nextToken > 0xFFFF) {
        throw const FormatException('Too many distinct Unicode graphemes');
      }
      tokens[grapheme] = String.fromCharCode(nextToken++);
    }
    return tokens;
  }

  static Delta _project(Delta base, Delta candidate) {
    final tokens = _graphemeTokens(base, candidate);
    final before = _encodeComparison(base, tokens);
    final after = _encodeComparison(candidate, tokens);
    final projection = Delta();
    var baseOffset = 0;
    var candidateOffset = 0;
    var baseIndex = 0;
    var candidateIndex = 0;
    var removed = Delta();
    var added = Delta();

    void flushChanges() {
      _append(projection, removed, CanvasReviewChange.deleted);
      _append(projection, added, CanvasReviewChange.inserted);
      removed = Delta();
      added = Delta();
    }

    for (final operation in before.delta.diff(after.delta).toList()) {
      final length = operation.length!;
      if (operation.isDelete) {
        final end = before.offsets[baseIndex + length];
        _append(removed, base.slice(baseOffset, end));
        baseOffset = end;
        baseIndex += length;
      } else if (operation.isInsert) {
        final end = after.offsets[candidateIndex + length];
        _append(added, candidate.slice(candidateOffset, end));
        candidateOffset = end;
        candidateIndex += length;
      } else {
        final baseEnd = before.offsets[baseIndex + length];
        final candidateEnd = after.offsets[candidateIndex + length];
        if (operation.attributes?.isNotEmpty == true) {
          _append(removed, base.slice(baseOffset, baseEnd));
          _append(added, candidate.slice(candidateOffset, candidateEnd));
        } else {
          flushChanges();
          _append(projection, candidate.slice(candidateOffset, candidateEnd));
        }
        baseOffset = baseEnd;
        candidateOffset = candidateEnd;
        baseIndex += length;
        candidateIndex += length;
      }
    }
    flushChanges();
    _append(projection, candidate.slice(candidateOffset));
    return projection;
  }

  static int _candidateOffset(Delta projection, int offset) {
    var remaining = offset < 0 ? 0 : offset;
    var candidateOffset = 0;
    for (final operation in projection.toList()) {
      final length = remaining.clamp(0, operation.length!);
      if (changeFor(operation.attributes) != CanvasReviewChange.deleted) {
        candidateOffset += length;
      }
      remaining -= length;
      if (remaining <= 0) break;
    }
    return candidateOffset;
  }

  static int _projectionOffset(Delta projection, int offset) {
    var remaining = offset < 0 ? 0 : offset;
    var projectionOffset = 0;
    for (final operation in projection.toList()) {
      final length = operation.length!;
      if (changeFor(operation.attributes) == CanvasReviewChange.deleted) {
        projectionOffset += length;
        continue;
      }
      final consumed = remaining.clamp(0, length);
      projectionOffset += consumed;
      remaining -= consumed;
      if (remaining <= 0) break;
    }
    return projectionOffset;
  }

  void dispose() => editor.dispose();
}
