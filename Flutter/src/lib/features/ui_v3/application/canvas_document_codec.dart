import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

/// Converts the shared editor document format for Mobile Canvas consumers.
final class CanvasDocumentCodec {
  static const int documentFormatVersion =
      HuahuoDocumentCodec.documentFormatVersion;
  static const int canvasDividerVersion =
      HuahuoDocumentCodec.canvasDividerVersion;
  static const String canvasDividerEmbedType =
      HuahuoDocumentCodec.canvasDividerEmbedType;
  static const Map<String, Object> canvasDividerDeltaInsert =
      HuahuoDocumentCodec.canvasDividerDeltaInsert;

  String encodeDeltaJson(Delta delta) =>
      HuahuoDocumentCodec.encodeDelta(normalizeDelta(delta));

  Delta decodeDeltaJson(String source) =>
      _validateMobileEmbeds(HuahuoDocumentCodec.decode(source));

  Document documentFromDeltaJson(String source) =>
      Document.fromDelta(decodeDeltaJson(source));

  String encodeDocumentJson(Document document) =>
      encodeDeltaJson(document.toDelta());

  String documentToMarkdown(Document document) =>
      deltaToMarkdown(document.toDelta());

  Document documentFromMarkdown(String markdown) =>
      Document.fromDelta(markdownToDelta(markdown));

  String deltaToMarkdown(Delta delta) =>
      HuahuoDocumentCodec.deltaToMarkdown(normalizeDelta(delta));

  Delta markdownToDelta(String markdown) =>
      _validateMobileEmbeds(HuahuoDocumentCodec.markdownToDelta(markdown));

  Delta normalizeDelta(Delta delta) =>
      _validateMobileEmbeds(HuahuoDocumentCodec.normalize(delta));

  Delta _validateMobileEmbeds(Delta delta) {
    for (final operation in delta.toList()) {
      final data = operation.data;
      if (data is Map &&
          data.containsKey(HuahuoDocumentCodec.quillImageEmbedType)) {
        throw const FormatException(
          'Standard image embeds are not supported by the Mobile canvas',
        );
      }
    }
    return delta;
  }
}
