import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_quill/markdown_quill.dart';

abstract final class HuahuoDocumentCodec {
  static final _implementation = _HuahuoDocumentCodecImpl();

  static const int documentFormatVersion =
      _HuahuoDocumentCodecImpl.documentFormatVersion;
  static const int canvasDividerVersion =
      _HuahuoDocumentCodecImpl.canvasDividerVersion;
  static const String canvasDividerEmbedType =
      _HuahuoDocumentCodecImpl.canvasDividerEmbedType;
  static const Map<String, Object> canvasDividerDeltaInsert =
      _HuahuoDocumentCodecImpl.canvasDividerDeltaInsert;
  static const String quillImageEmbedType = 'image';

  static String encode(Document document) =>
      _implementation.encodeDocumentJson(document);

  static String encodeDelta(Delta delta) =>
      _implementation.encodeDeltaJson(delta);

  static Delta decode(String source) => _implementation.decodeDeltaJson(source);

  static Delta normalize(Delta delta) => _implementation.normalizeDelta(delta);

  static Document documentFromDeltaJson(String source) =>
      _implementation.documentFromDeltaJson(source);

  static String documentToMarkdown(Document document) =>
      _implementation.documentToMarkdown(document);

  static Document documentFromMarkdown(String markdown) =>
      _implementation.documentFromMarkdown(markdown);

  static String deltaToMarkdown(Delta delta) =>
      _implementation.deltaToMarkdown(delta);

  static Delta markdownToDelta(String markdown) =>
      _implementation.markdownToDelta(markdown);
}

final class HuahuoDocumentImageData {
  HuahuoDocumentImageData({
    required String resourceId,
    required String alt,
    required this.widthRatio,
    required this.aspectRatio,
    this.version = currentVersion,
  }) : resourceId = resourceId.trim(),
       alt = alt.trim() {
    if (version != currentVersion) {
      throw ArgumentError.value(version, 'version', 'Unsupported version');
    }
    if (!_safeResourceId.hasMatch(this.resourceId)) {
      throw ArgumentError.value(
        resourceId,
        'resourceId',
        'Expected an opaque private canvas resource identifier',
      );
    }
    if (this.alt.isEmpty || this.alt.length > maxAltLength) {
      throw ArgumentError.value(
        alt,
        'alt',
        'Alt text must contain 1-$maxAltLength characters',
      );
    }
    if (!widthRatio.isFinite ||
        widthRatio < minimumWidthRatio ||
        widthRatio > maximumWidthRatio) {
      throw ArgumentError.value(
        widthRatio,
        'widthRatio',
        'Width ratio must be between $minimumWidthRatio and '
            '$maximumWidthRatio',
      );
    }
    if (!aspectRatio.isFinite || aspectRatio <= 0) {
      throw ArgumentError.value(
        aspectRatio,
        'aspectRatio',
        'Aspect ratio must be finite and positive',
      );
    }
  }

  static const int currentVersion = 1;
  static const int maxAltLength = 240;
  static const double minimumWidthRatio = .25;
  static const double maximumWidthRatio = 1;
  static const String deltaEmbedType = 'canvas-image';

  static final RegExp _safeResourceId = RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$');

  final int version;
  final String resourceId;
  final String alt;
  final double widthRatio;
  final double aspectRatio;

  Map<String, Object> toJson() => <String, Object>{
    'version': version,
    'resourceId': resourceId,
    'alt': alt,
    'widthRatio': widthRatio,
    'aspectRatio': aspectRatio,
  };

  Map<String, Object> toDeltaInsert() => <String, Object>{
    deltaEmbedType: toJson(),
  };

  factory HuahuoDocumentImageData.fromJson(Map<String, Object?> json) {
    try {
      final version = json['version'];
      final resourceId = json['resourceId'];
      final alt = json['alt'];
      final widthRatio = json['widthRatio'];
      final aspectRatio = json['aspectRatio'];
      if (version is! num ||
          !version.isFinite ||
          version != version.truncate() ||
          resourceId is! String ||
          alt is! String ||
          widthRatio is! num ||
          aspectRatio is! num) {
        throw const FormatException('Canvas image payload has invalid fields');
      }
      return HuahuoDocumentImageData(
        version: version.toInt(),
        resourceId: resourceId,
        alt: alt,
        widthRatio: widthRatio.toDouble(),
        aspectRatio: aspectRatio.toDouble(),
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid canvas image payload: ${error.message}');
    }
  }

  factory HuahuoDocumentImageData.fromDeltaInsert(Object? insert) {
    if (insert is! Map || insert.length != 1) {
      throw const FormatException('Canvas image insert must be a single map');
    }
    final data = insert[deltaEmbedType];
    if (data is! Map) {
      throw const FormatException('Canvas image insert payload is missing');
    }
    return HuahuoDocumentImageData.fromJson(
      data.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HuahuoDocumentImageData &&
          version == other.version &&
          resourceId == other.resourceId &&
          alt == other.alt &&
          widthRatio == other.widthRatio &&
          aspectRatio == other.aspectRatio;

  @override
  int get hashCode =>
      Object.hash(version, resourceId, alt, widthRatio, aspectRatio);
}

final class _HuahuoDocumentCodecImpl {
  _HuahuoDocumentCodecImpl()
    : _markdownToDelta = MarkdownToDelta(
        markdownDocument: md.Document(
          encodeHtml: false,
          extensionSet: md.ExtensionSet.gitHubFlavored,
        ),
      ),
      _deltaToMarkdown = DeltaToMarkdown(
        customEmbedHandlers: <String, EmbedToMarkdown>{
          HuahuoDocumentImageData.deltaEmbedType: _writeCanvasImage,
          canvasDividerEmbedType: _writeCanvasDivider,
        },
        customTextAttrsHandlers: <String, CustomAttributeHandler>{
          Attribute.underline.key: _tagHandler(
            open: (_) => '<u>',
            close: (_) => '</u>',
          ),
          Attribute.color.key: _tagHandler(
            open: (value) => '<span data-hh-fg="$value">',
            close: (_) => '</span><!--data-hh-end:color-->',
          ),
          Attribute.background.key: _tagHandler(
            open: (value) => '<span data-hh-bg="$value">',
            close: (_) => '</span><!--data-hh-end:background-->',
          ),
        },
        visitLineHandleNewLine: _writeLineEnding,
      );

  static const int documentFormatVersion = 1;
  static const int canvasDividerVersion = 1;
  static const String canvasDividerEmbedType = 'canvas-divider';
  static const Map<String, Object> canvasDividerDeltaInsert = <String, Object>{
    canvasDividerEmbedType: <String, Object>{'version': canvasDividerVersion},
  };

  final MarkdownToDelta _markdownToDelta;
  final DeltaToMarkdown _deltaToMarkdown;

  String encodeDeltaJson(Delta delta) {
    return jsonEncode(normalizeDelta(delta).toJson());
  }

  Delta decodeDeltaJson(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! List) {
        throw const FormatException('Canvas Delta JSON must be a list');
      }
      final operations = <Map<String, Object?>>[];
      for (final value in decoded) {
        if (value is! Map) {
          throw const FormatException('Canvas Delta operation must be a map');
        }
        operations.add(
          value.map((key, item) => MapEntry(key.toString(), item)),
        );
      }
      return normalizeDelta(Delta.fromJson(operations));
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Canvas Delta JSON is invalid', error);
    }
  }

  Document documentFromDeltaJson(String source) {
    return Document.fromDelta(decodeDeltaJson(source));
  }

  String encodeDocumentJson(Document document) {
    return encodeDeltaJson(document.toDelta());
  }

  String documentToMarkdown(Document document) {
    return deltaToMarkdown(document.toDelta());
  }

  Document documentFromMarkdown(String markdown) {
    return Document.fromDelta(markdownToDelta(markdown));
  }

  String deltaToMarkdown(Delta delta) {
    final normalized = normalizeDelta(delta);
    final projected = _deltaToMarkdown.convert(normalized);
    final wrapped = projected
        .split('\n')
        .map(_wrapAlignedLine)
        .join('\n')
        .trimRight();
    return wrapped.isEmpty ? '' : '$wrapped\n';
  }

  Delta markdownToDelta(String markdown) {
    if (markdown.trim().isEmpty) return Delta()..insert('\n');
    final prepared = _prepareExtendedMarkdown(markdown);
    try {
      return normalizeDelta(
        _restoreExtensionMarkers(_markdownToDelta.convert(prepared)),
      );
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Canvas Markdown is invalid', error);
    }
  }

  Delta normalizeDelta(Delta input) {
    final normalized = Delta();
    for (final operation in input.operations) {
      if (!operation.isInsert) {
        throw const FormatException(
          'Canvas document Delta may contain insert operations only',
        );
      }
      final data = operation.data;
      if (data is String) {
        _appendNormalizedText(normalized, data, operation.attributes);
        continue;
      }
      if (data is! Map || data.length != 1) {
        throw const FormatException('Unsupported canvas Delta embed');
      }
      final embed = data.map((key, value) => MapEntry(key.toString(), value));
      if (embed.containsKey(HuahuoDocumentImageData.deltaEmbedType)) {
        final image = HuahuoDocumentImageData.fromDeltaInsert(embed);
        normalized.insert(image.toDeltaInsert());
      } else if (embed.containsKey(HuahuoDocumentCodec.quillImageEmbedType)) {
        normalized.insert(<String, Object>{
          HuahuoDocumentCodec.quillImageEmbedType: _normalizeQuillImageSource(
            embed[HuahuoDocumentCodec.quillImageEmbedType],
          ),
        });
      } else if (_isCanvasDivider(embed) || embed['divider'] == 'hr') {
        normalized.insert(canvasDividerDeltaInsert);
      } else {
        throw const FormatException('Unsupported canvas Delta embed');
      }
    }
    if (normalized.isEmpty || !_endsWithNewline(normalized)) {
      normalized.insert('\n');
    }
    return normalized;
  }
}

String _normalizeQuillImageSource(Object? value) {
  if (value is! String || value.isEmpty || value.length > 2048) {
    throw const FormatException('Desktop image source is invalid');
  }
  final uri = Uri.tryParse(value);
  if (uri == null || uri.userInfo.isNotEmpty) {
    throw const FormatException('Desktop image source is invalid');
  }
  if (uri.scheme == 'https' && uri.host.isNotEmpty) return uri.toString();
  if (uri.scheme == 'huahuo-media' &&
      uri.host == 'asset' &&
      !uri.hasPort &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty &&
      uri.pathSegments.length == 1 &&
      RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(uri.pathSegments.single)) {
    return uri.toString();
  }
  throw const FormatException('Desktop image source is invalid');
}

void _appendNormalizedText(
  Delta target,
  String text,
  Map<String, dynamic>? attributes,
) {
  var start = 0;
  for (var index = 0; index < text.length; index++) {
    if (text.codeUnitAt(index) != 10) continue;
    if (index > start) {
      target.insert(
        text.substring(start, index),
        _sanitizeInlineAttributes(attributes),
      );
    }
    target.insert('\n', _sanitizeBlockAttributes(attributes));
    start = index + 1;
  }
  if (start < text.length) {
    target.insert(text.substring(start), _sanitizeInlineAttributes(attributes));
  }
}

Map<String, dynamic>? _sanitizeInlineAttributes(Map<String, dynamic>? source) {
  if (source == null || source.isEmpty) return null;
  final result = <String, dynamic>{};
  for (final key in const <String>[
    'bold',
    'italic',
    'underline',
    'strike',
    'code',
  ]) {
    if (source[key] == true) result[key] = true;
  }
  final link = source['link'];
  if (link is String && _isSafeLink(link)) result['link'] = link;
  final color = _normalizeColor(source['color']);
  if (color != null) result['color'] = color;
  final background = _normalizeColor(source['background']);
  if (background != null) result['background'] = background;
  return result.isEmpty ? null : result;
}

Map<String, dynamic>? _sanitizeBlockAttributes(Map<String, dynamic>? source) {
  if (source == null || source.isEmpty) return null;
  final result = <String, dynamic>{};
  final header = source['header'];
  if (header is num && header == header.roundToDouble()) {
    final level = header.toInt();
    if (level >= 1 && level <= 3) result['header'] = level;
  }
  final list = source['list'];
  if (const <String>{
    'bullet',
    'ordered',
    'checked',
    'unchecked',
  }.contains(list)) {
    result['list'] = list;
  }
  if (source['code-block'] == true) result['code-block'] = true;
  if (source['blockquote'] == true) result['blockquote'] = true;
  final align = source['align'];
  if (const <String>{'left', 'center', 'right'}.contains(align)) {
    result['align'] = align;
  }
  return result.isEmpty ? null : result;
}

String? _normalizeColor(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim().toLowerCase();
  return RegExp(r'^#[0-9a-f]{6}([0-9a-f]{2})?$').hasMatch(normalized)
      ? normalized
      : null;
}

bool _isSafeLink(String value) {
  if (value.length > 2048) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      const <String>{'http', 'https', 'mailto'}.contains(uri.scheme) &&
      (uri.scheme == 'mailto' ? uri.path.isNotEmpty : uri.host.isNotEmpty);
}

bool _endsWithNewline(Delta delta) {
  final data = delta.last.data;
  return data is String && data.endsWith('\n');
}

CustomAttributeHandler _tagHandler({
  required String Function(Object? value) open,
  required String Function(Object? value) close,
}) {
  return CustomAttributeHandler(
    beforeContent: (attribute, node, output) {
      final previous = node.previous;
      if (previous?.style.attributes[attribute.key]?.value != attribute.value) {
        output.write(open(attribute.value));
      }
    },
    afterContent: (attribute, node, output) {
      final next = node.next;
      if (next?.style.attributes[attribute.key]?.value != attribute.value) {
        output.write(close(attribute.value));
      }
    },
  );
}

void _writeCanvasImage(Embed embed, StringSink output) {
  final data = embed.value.data;
  if (data is! Map) {
    throw const FormatException('Canvas image embed payload is invalid');
  }
  final image = HuahuoDocumentImageData.fromJson(
    data.map((key, value) => MapEntry(key.toString(), value)),
  );
  final uri = Uri(
    scheme: 'app-private-canvas-image',
    host: image.resourceId,
    queryParameters: <String, String>{
      'width': image.widthRatio.toString(),
      'aspect': image.aspectRatio.toString(),
    },
  );
  output.write('![${_markdownAlt(image.alt)}]($uri)');
}

void _writeCanvasDivider(Embed embed, StringSink output) {
  final data = embed.value.data;
  if (data is! Map ||
      data['version'] != _HuahuoDocumentCodecImpl.canvasDividerVersion) {
    throw const FormatException('Canvas divider embed payload is invalid');
  }
  output.writeln('---');
}

bool _isCanvasDivider(Map<String, Object?> embed) {
  final value = embed[_HuahuoDocumentCodecImpl.canvasDividerEmbedType];
  return value is Map &&
      value.length == 1 &&
      value['version'] == _HuahuoDocumentCodecImpl.canvasDividerVersion;
}

void _writeLineEnding(Style style, StringSink output) {
  final align = style.attributes[Attribute.align.key]?.value;
  if (const <String>{'left', 'center', 'right'}.contains(align)) {
    output.write('<!--data-hh-align:$align-->');
  }
  output.writeln();
  if (!style.containsKey(Attribute.list.key) &&
      !style.containsKey(Attribute.codeBlock.key)) {
    output.writeln();
  }
}

String _wrapAlignedLine(String line) {
  final match = RegExp(
    r'^(.*)<!--data-hh-align:(left|center|right)-->$',
  ).firstMatch(line);
  if (match == null) return line;
  return '<div align="${match.group(2)}">\n${match.group(1)}\n</div>';
}

String _prepareExtendedMarkdown(String markdown) {
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  final output = <String>[];
  String? fence;
  String? blockAlignment;
  for (var line in lines) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      final marker = trimmed.substring(0, 3);
      fence = fence == null
          ? marker
          : fence == marker
          ? null
          : fence;
      output.add(line);
      continue;
    }
    if (fence != null) {
      output.add(line);
      continue;
    }
    final alignmentOpen = _alignmentOpenLine.firstMatch(line.trim());
    if (alignmentOpen != null) {
      if (blockAlignment != null) {
        throw const FormatException('Canvas alignment block is nested');
      }
      blockAlignment = alignmentOpen.group(1);
      continue;
    }
    if (_alignmentCloseLine.hasMatch(line.trim())) {
      if (blockAlignment == null) {
        throw const FormatException('Canvas alignment block is unbalanced');
      }
      blockAlignment = null;
      continue;
    }
    final aligned = _alignmentLine.firstMatch(line);
    if (aligned != null) {
      line =
          '${aligned.group(2)}'
          '${_marker('align', value: aligned.group(1))}';
    } else if (blockAlignment != null) {
      line = '$line${_marker('align', value: blockAlignment)}';
    }
    line = line.replaceAllMapped(_privateCanvasImage, _privateImageMarker);
    line = line.replaceAllMapped(_canvasImageTag, (match) {
      final encoded = match.group(1)!;
      try {
        final decoded = utf8.decode(
          base64Url.decode(base64Url.normalize(encoded)),
        );
        final value = jsonDecode(decoded);
        if (value is! Map) {
          throw const FormatException('Canvas image marker is invalid');
        }
        final image = HuahuoDocumentImageData.fromJson(
          value.map((key, item) => MapEntry(key.toString(), item)),
        );
        return _marker('image', value: image.toJson());
      } on FormatException {
        rethrow;
      } on Object catch (error) {
        throw FormatException('Canvas image marker is invalid', error);
      }
    });
    line = line
        .replaceAll(
          '**</span><!--data-hh-end:bold-->',
          _marker('end', key: 'bold'),
        )
        .replaceAll(
          '_</span><!--data-hh-end:italic-->',
          _marker('end', key: 'italic'),
        )
        .replaceAll(
          '~~</span><!--data-hh-end:strike-->',
          _marker('end', key: 'strike'),
        )
        .replaceAll(
          '`</span><!--data-hh-end:code-->',
          _marker('end', key: 'code'),
        )
        .replaceAllMapped(_linkEndTag, (_) => _marker('end', key: 'link'))
        .replaceAll(
          '</span><!--data-hh-end:color-->',
          _marker('end', key: 'color'),
        )
        .replaceAll(
          '</span><!--data-hh-end:background-->',
          _marker('end', key: 'background'),
        )
        .replaceAll(
          '<span data-hh-bold="true">**',
          _marker('start', key: 'bold', value: true),
        )
        .replaceAll(
          '<span data-hh-italic="true">_',
          _marker('start', key: 'italic', value: true),
        )
        .replaceAll(
          '<span data-hh-strike="true">~~',
          _marker('start', key: 'strike', value: true),
        )
        .replaceAll(
          '<span data-hh-code="true">`',
          _marker('start', key: 'code', value: true),
        )
        .replaceAllMapped(_linkTag, (match) {
          final link = _decodeMarkerValue(match.group(1)!);
          if (!_isSafeLink(link)) {
            throw const FormatException('Canvas Markdown link is unsafe');
          }
          return _marker('start', key: 'link', value: link);
        })
        .replaceAllMapped(
          _foregroundTag,
          (match) => _marker('start', key: 'color', value: match.group(1)),
        )
        .replaceAllMapped(
          _backgroundTag,
          (match) => _marker('start', key: 'background', value: match.group(1)),
        )
        .replaceAll('<u>', _marker('start', key: 'underline', value: true))
        .replaceAll('</u>', _marker('end', key: 'underline'))
        .replaceAll('</span>', _marker('end'));
    if (line.contains('data-hh-')) {
      throw const FormatException('Canvas Markdown extension is invalid');
    }
    line = _protectStandardInlineMarkdown(line);
    output.add(line);
  }
  if (blockAlignment != null) {
    throw const FormatException('Canvas alignment block is unbalanced');
  }
  return output.join('\n');
}

String _privateImageMarker(Match match) {
  final uri = Uri.tryParse(match.group(2)!);
  if (uri == null ||
      uri.scheme != 'app-private-canvas-image' ||
      uri.host.isEmpty) {
    throw const FormatException('Canvas image URI is invalid');
  }
  final width = double.tryParse(uri.queryParameters['width'] ?? '1');
  final aspect = double.tryParse(uri.queryParameters['aspect'] ?? '1');
  try {
    final image = HuahuoDocumentImageData(
      resourceId: uri.host,
      alt: (match.group(1) ?? '').trim().isEmpty
          ? '图片'
          : match.group(1)!.trim(),
      widthRatio: width ?? 1,
      aspectRatio: aspect ?? 1,
    );
    return _marker('image', value: image.toJson());
  } on ArgumentError catch (error) {
    throw FormatException('Canvas image URI is invalid', error);
  }
}

Delta _restoreExtensionMarkers(Delta input) {
  final output = Delta();
  final active = <_ActiveExtension>[];
  String? pendingAlignment;
  for (final operation in input.operations) {
    final data = operation.data;
    if (data is! String) {
      output.insert(data, operation.attributes);
      continue;
    }
    var cursor = 0;
    for (final match in _encodedMarker.allMatches(data)) {
      if (match.start > cursor) {
        pendingAlignment = _appendMarkerText(
          output,
          data.substring(cursor, match.start),
          operation.attributes,
          active,
          pendingAlignment,
        );
      }
      final marker = _decodeMarker(match.group(1)!);
      switch (marker.kind) {
        case 'start':
          if (marker.key == null) {
            throw const FormatException('Canvas style marker is invalid');
          }
          active.add(_ActiveExtension(marker.key!, marker.value));
        case 'end':
          final index = marker.key == null
              ? active.length - 1
              : active.lastIndexWhere((item) => item.key == marker.key);
          if (index < 0) {
            throw const FormatException('Canvas style marker is unbalanced');
          }
          active.removeAt(index);
        case 'align':
          final value = marker.value;
          if (value is! String ||
              !const <String>{'left', 'center', 'right'}.contains(value)) {
            throw const FormatException('Canvas alignment marker is invalid');
          }
          pendingAlignment = value;
        case 'image':
          final value = marker.value;
          if (value is! Map) {
            throw const FormatException('Canvas image marker is invalid');
          }
          final image = HuahuoDocumentImageData.fromJson(
            value.map((key, item) => MapEntry(key.toString(), item)),
          );
          output.insert(image.toDeltaInsert());
        case 'literal':
          final value = marker.value;
          if (value is! String) {
            throw const FormatException('Canvas literal marker is invalid');
          }
          pendingAlignment = _appendMarkerText(
            output,
            value,
            operation.attributes,
            active,
            pendingAlignment,
          );
        default:
          throw const FormatException('Canvas extension marker is invalid');
      }
      cursor = match.end;
    }
    if (cursor < data.length) {
      pendingAlignment = _appendMarkerText(
        output,
        data.substring(cursor),
        operation.attributes,
        active,
        pendingAlignment,
      );
    }
  }
  if (active.isNotEmpty) {
    throw const FormatException('Canvas style marker is unbalanced');
  }
  return output;
}

String _protectStandardInlineMarkdown(String line) {
  final output = StringBuffer();
  var index = 0;
  var bold = false;
  var strike = false;
  var underscoreItalic = false;
  var asteriskItalic = false;
  while (index < line.length) {
    if (line.codeUnitAt(index) == 0xE000) {
      final end = line.indexOf('\uE001', index + 1);
      if (end < 0) {
        throw const FormatException('Canvas extension marker is invalid');
      }
      output.write(line.substring(index, end + 1));
      index = end + 1;
      continue;
    }
    if (line.codeUnitAt(index) == 0x60 && !_isEscaped(line, index)) {
      final end = line.indexOf('`', index + 1);
      if (end > index + 1) {
        output
          ..write(_marker('start', key: 'code', value: true))
          ..write(_marker('literal', value: line.substring(index + 1, end)))
          ..write(_marker('end', key: 'code'));
        index = end + 1;
        continue;
      }
    }
    if (line.codeUnitAt(index) == 0x5B &&
        !_isEscaped(line, index) &&
        (index == 0 || line.codeUnitAt(index - 1) != 0x21)) {
      final match = _markdownLinkAt.firstMatch(line.substring(index));
      if (match != null && _isSafeLink(match.group(2)!)) {
        output
          ..write(_marker('start', key: 'link', value: match.group(2)))
          ..write(_protectStandardInlineMarkdown(match.group(1)!))
          ..write(_marker('end', key: 'link'));
        index += match.group(0)!.length;
        continue;
      }
    }
    if (line.startsWith('**', index) && !_isEscaped(line, index)) {
      if (bold || line.indexOf('**', index + 2) >= 0) {
        bold = !bold;
        output.write(_marker(bold ? 'start' : 'end', key: 'bold', value: bold));
        index += 2;
        continue;
      }
    }
    if (line.startsWith('~~', index) && !_isEscaped(line, index)) {
      if (strike || line.indexOf('~~', index + 2) >= 0) {
        strike = !strike;
        output.write(
          _marker(strike ? 'start' : 'end', key: 'strike', value: strike),
        );
        index += 2;
        continue;
      }
    }
    if (line.codeUnitAt(index) == 0x5F && !_isEscaped(line, index)) {
      if (underscoreItalic || line.indexOf('_', index + 1) >= 0) {
        underscoreItalic = !underscoreItalic;
        output.write(
          _marker(
            underscoreItalic ? 'start' : 'end',
            key: 'italic',
            value: underscoreItalic,
          ),
        );
        index++;
        continue;
      }
    }
    if (line.codeUnitAt(index) == 0x2A && !_isEscaped(line, index)) {
      if (asteriskItalic || line.indexOf('*', index + 1) >= 0) {
        asteriskItalic = !asteriskItalic;
        output.write(
          _marker(
            asteriskItalic ? 'start' : 'end',
            key: 'italic',
            value: asteriskItalic,
          ),
        );
        index++;
        continue;
      }
    }
    output.writeCharCode(line.codeUnitAt(index));
    index++;
  }
  return output.toString();
}

bool _isEscaped(String source, int index) =>
    index > 0 && source.codeUnitAt(index - 1) == 0x5C;

String? _appendMarkerText(
  Delta output,
  String text,
  Map<String, dynamic>? baseAttributes,
  List<_ActiveExtension> active,
  String? pendingAlignment,
) {
  var start = 0;
  for (var index = 0; index < text.length; index++) {
    if (text.codeUnitAt(index) != 10) continue;
    if (index > start) {
      output.insert(
        text.substring(start, index),
        _mergedInlineAttributes(baseAttributes, active),
      );
    }
    final lineAttributes = <String, dynamic>{
      ...?baseAttributes,
      if (pendingAlignment != null) 'align': pendingAlignment,
    };
    output.insert('\n', lineAttributes.isEmpty ? null : lineAttributes);
    pendingAlignment = null;
    start = index + 1;
  }
  if (start < text.length) {
    output.insert(
      text.substring(start),
      _mergedInlineAttributes(baseAttributes, active),
    );
  }
  return pendingAlignment;
}

Map<String, dynamic>? _mergedInlineAttributes(
  Map<String, dynamic>? base,
  List<_ActiveExtension> active,
) {
  final result = <String, dynamic>{...?base};
  for (final extension in active) {
    result[extension.key] = extension.value;
  }
  return result.isEmpty ? null : result;
}

String _marker(String kind, {String? key, Object? value}) {
  final encoded = base64Url
      .encode(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'kind': kind,
            if (key != null) 'key': key,
            if (value != null) 'value': value,
          }),
        ),
      )
      .replaceAll('=', '');
  return '\uE000$encoded\uE001';
}

String _decodeMarkerValue(String encoded) {
  try {
    return utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
  } on Object catch (error) {
    throw FormatException('Canvas Markdown extension is invalid', error);
  }
}

_ExtensionMarker _decodeMarker(String encoded) {
  try {
    final source = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    final json = jsonDecode(source);
    if (json is! Map || json['kind'] is! String) {
      throw const FormatException('Canvas extension marker is invalid');
    }
    return _ExtensionMarker(
      kind: json['kind'] as String,
      key: json['key'] as String?,
      value: json['value'],
    );
  } on FormatException {
    rethrow;
  } on Object catch (error) {
    throw FormatException('Canvas extension marker is invalid', error);
  }
}

String _markdownAlt(String source) {
  final sanitized = source
      .replaceAll(RegExp(r'[\[\]\r\n]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return sanitized.isEmpty ? '图片' : sanitized;
}

final RegExp _alignmentLine = RegExp(
  r'^\s*<div\s+data-hh-align="(left|center|right)">(.*)</div>\s*$',
);
final RegExp _alignmentOpenLine = RegExp(
  r'^<div\s+align="(left|center|right)">$',
);
final RegExp _alignmentCloseLine = RegExp(r'^</div>$');
final RegExp _privateCanvasImage = RegExp(
  r'!\[([^\]\r\n]*)\]\((app-private-canvas-image:\/\/[^)\s]+)\)',
);
final RegExp _canvasImageTag = RegExp(
  r'<img\s+data-hh-canvas-image="([A-Za-z0-9_-]+)"(?:\s+alt="[^"]*")?\s*/?>',
);
final RegExp _foregroundTag = RegExp(
  r'<span\s+data-hh-fg="(#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?)">',
);
final RegExp _backgroundTag = RegExp(
  r'<span\s+data-hh-bg="(#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?)">',
);
final RegExp _linkTag = RegExp(r'<span\s+data-hh-link="([A-Za-z0-9_-]+)">\[');
final RegExp _linkEndTag = RegExp(
  r'\]\([^\n]*?\)</span><!--data-hh-end:link-->',
);
final RegExp _encodedMarker = RegExp(r'\uE000([A-Za-z0-9_-]+)\uE001');
final RegExp _markdownLinkAt = RegExp(r'^\[([^\]\n]+)\]\(([^)\s]+)\)');

final class _ActiveExtension {
  const _ActiveExtension(this.key, this.value);

  final String key;
  final Object? value;
}

final class _ExtensionMarker {
  const _ExtensionMarker({
    required this.kind,
    required this.key,
    required this.value,
  });

  final String kind;
  final String? key;
  final Object? value;
}
