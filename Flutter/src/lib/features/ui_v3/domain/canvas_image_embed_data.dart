import 'package:flutter/foundation.dart';

@immutable
final class CanvasImageEmbedData {
  CanvasImageEmbedData({
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

  factory CanvasImageEmbedData.fromJson(Map<String, Object?> json) {
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
      return CanvasImageEmbedData(
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

  factory CanvasImageEmbedData.fromDeltaInsert(Object? insert) {
    if (insert is! Map || insert.length != 1) {
      throw const FormatException('Canvas image insert must be a single map');
    }
    final data = insert[deltaEmbedType];
    if (data is! Map) {
      throw const FormatException('Canvas image insert payload is missing');
    }
    return CanvasImageEmbedData.fromJson(
      data.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  CanvasImageEmbedData copyWith({
    String? resourceId,
    String? alt,
    double? widthRatio,
    double? aspectRatio,
  }) {
    return CanvasImageEmbedData(
      version: version,
      resourceId: resourceId ?? this.resourceId,
      alt: alt ?? this.alt,
      widthRatio: widthRatio ?? this.widthRatio,
      aspectRatio: aspectRatio ?? this.aspectRatio,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasImageEmbedData &&
          version == other.version &&
          resourceId == other.resourceId &&
          alt == other.alt &&
          widthRatio == other.widthRatio &&
          aspectRatio == other.aspectRatio;

  @override
  int get hashCode =>
      Object.hash(version, resourceId, alt, widthRatio, aspectRatio);
}
