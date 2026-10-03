import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';

import 'huahuo_document_codec.dart';

/// The semantic views that can exist for one note. They are not revision
/// history: the original document remains the canonical editable source.
enum HuahuoNoteStage { raw, summary, sprout }

/// The storage representation used by a note-stage view.
enum HuahuoNoteStageContentFormat { quillDelta, markdown }

final class HuahuoNoteStageContent {
  const HuahuoNoteStageContent({
    required this.stage,
    required this.content,
    required this.format,
  });

  final HuahuoNoteStage stage;
  final String content;
  final HuahuoNoteStageContentFormat format;

  bool get isMarkdown => format == HuahuoNoteStageContentFormat.markdown;
}

final class HuahuoLinkedMaterialRef {
  HuahuoLinkedMaterialRef({
    required String id,
    required String source,
    required String title,
    String? summary,
  }) : id = _requiredIdentifier(id, 'linked material id'),
       source = _requiredIdentifier(source, 'linked material source'),
       title = _requiredContent(title, 'linked material title'),
       summary = _optionalContent(summary);

  final String id;
  final String source;
  final String title;
  final String? summary;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'source': source,
    'title': title,
    if (summary != null) 'summary': summary,
  };

  factory HuahuoLinkedMaterialRef.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final source = json['source'];
    final title = json['title'];
    final summary = json['summary'];
    if (id is! String ||
        source is! String ||
        title is! String ||
        (summary != null && summary is! String)) {
      throw const FormatException('Invalid linked material');
    }
    try {
      return HuahuoLinkedMaterialRef(
        id: id,
        source: source,
        title: title,
        summary: summary as String?,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid linked material: ${error.message}');
    }
  }
}

/// An AI-authored observation attached to a stable section or range anchor.
final class HuahuoAiAnnotation {
  HuahuoAiAnnotation({
    required String id,
    required this.stage,
    required String anchor,
    required String quote,
    required String body,
    required this.createdAt,
  }) : id = _requiredIdentifier(id, 'annotation id'),
       anchor = _requiredIdentifier(anchor, 'annotation anchor'),
       quote = _requiredContent(quote, 'annotation quote'),
       body = _requiredContent(body, 'annotation body');

  final String id;
  final HuahuoNoteStage stage;

  /// A stable section ID or another durable range identifier.
  final String anchor;
  final String quote;
  final String body;
  final DateTime createdAt;

  /// Alias for consumers whose anchors are Markdown section identifiers.
  String get sectionId => anchor;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'stage': stage.name,
    'anchor': anchor,
    'quote': quote,
    'body': body,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory HuahuoAiAnnotation.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final stage = _noteStageForName(json['stage']);
    final anchor = json['anchor'] ?? json['sectionId'];
    final quote = json['quote'];
    final body = json['body'];
    final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    if (id is! String ||
        stage == null ||
        anchor is! String ||
        quote is! String ||
        body is! String ||
        createdAt == null) {
      throw const FormatException('Invalid AI annotation');
    }
    return HuahuoAiAnnotation(
      id: id,
      stage: stage,
      anchor: anchor,
      quote: quote,
      body: body,
      createdAt: createdAt.toUtc(),
    );
  }
}

final class HuahuoDocumentSnapshot {
  HuahuoDocumentSnapshot({
    required this.id,
    required this.title,
    required this.deltaJson,
    required this.revision,
    required this.createdAt,
    required this.modifiedAt,
    this.markdownProjection,
    Iterable<HuahuoLinkedMaterialRef> linkedMaterials =
        const <HuahuoLinkedMaterialRef>[],
    this.sourceTopicId,
    this.sourceTopicTitle,
    String? summaryMarkdown,
    String? sproutMarkdown,
    Iterable<HuahuoAiAnnotation> aiAnnotations = const <HuahuoAiAnnotation>[],
  }) : linkedMaterials = List<HuahuoLinkedMaterialRef>.unmodifiable(
         linkedMaterials,
       ),
       summaryMarkdown = _optionalMarkdown(summaryMarkdown),
       sproutMarkdown = _optionalMarkdown(sproutMarkdown),
       aiAnnotations = List<HuahuoAiAnnotation>.unmodifiable(aiAnnotations) {
    HuahuoDocumentCodec.decode(deltaJson);
  }

  static const formatVersion = 3;
  static const _legacyFormatVersion = 1;
  static const _noteMetadataFormatVersion = 2;

  final String id;
  final String title;
  final String deltaJson;
  final int revision;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String? markdownProjection;
  final List<HuahuoLinkedMaterialRef> linkedMaterials;
  final String? sourceTopicId;
  final String? sourceTopicTitle;
  final String? summaryMarkdown;
  final String? sproutMarkdown;
  final List<HuahuoAiAnnotation> aiAnnotations;

  Document toDocument() =>
      Document.fromDelta(HuahuoDocumentCodec.decode(deltaJson));

  /// Returns only stages with materialized content. Raw is always present.
  List<HuahuoNoteStage> get availableNoteStages =>
      List<HuahuoNoteStage>.unmodifiable(<HuahuoNoteStage>[
        HuahuoNoteStage.raw,
        if (summaryMarkdown != null) HuahuoNoteStage.summary,
        if (sproutMarkdown != null) HuahuoNoteStage.sprout,
      ]);

  HuahuoNoteStageContent? stageContent(HuahuoNoteStage stage) =>
      switch (stage) {
        HuahuoNoteStage.raw => HuahuoNoteStageContent(
          stage: stage,
          content: deltaJson,
          format: HuahuoNoteStageContentFormat.quillDelta,
        ),
        HuahuoNoteStage.summary =>
          summaryMarkdown == null
              ? null
              : HuahuoNoteStageContent(
                  stage: stage,
                  content: summaryMarkdown!,
                  format: HuahuoNoteStageContentFormat.markdown,
                ),
        HuahuoNoteStage.sprout =>
          sproutMarkdown == null
              ? null
              : HuahuoNoteStageContent(
                  stage: stage,
                  content: sproutMarkdown!,
                  format: HuahuoNoteStageContentFormat.markdown,
                ),
      };

  List<HuahuoAiAnnotation> annotationsForStage(HuahuoNoteStage stage) =>
      List<HuahuoAiAnnotation>.unmodifiable(
        aiAnnotations.where((annotation) => annotation.stage == stage),
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': formatVersion,
    'id': id,
    'title': title,
    'delta': jsonDecode(deltaJson),
    'revision': revision,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'modifiedAt': modifiedAt.toUtc().toIso8601String(),
    if (markdownProjection != null) 'markdownProjection': markdownProjection,
    'linkedMaterials': linkedMaterials
        .map((material) => material.toJson())
        .toList(growable: false),
    if (sourceTopicId != null || sourceTopicTitle != null)
      'sourceTopic': <String, Object?>{
        if (sourceTopicId != null) 'id': sourceTopicId,
        if (sourceTopicTitle != null) 'title': sourceTopicTitle,
      },
    'note': <String, Object?>{
      'summaryMarkdown': summaryMarkdown,
      'sproutMarkdown': sproutMarkdown,
      'aiAnnotations': aiAnnotations
          .map((annotation) => annotation.toJson())
          .toList(growable: false),
    },
  };

  factory HuahuoDocumentSnapshot.fromJson(Map<String, Object?> json) {
    final rawFormatVersion = json['formatVersion'];
    if (rawFormatVersion is! int ||
        (rawFormatVersion != _legacyFormatVersion &&
            rawFormatVersion != _noteMetadataFormatVersion &&
            rawFormatVersion != formatVersion)) {
      throw const FormatException('Unsupported document format');
    }
    final id = json['id'];
    final title = json['title'];
    final delta = json['delta'];
    final revision = json['revision'];
    final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    final modifiedAt = DateTime.tryParse(json['modifiedAt']?.toString() ?? '');
    if (id is! String || id.isEmpty || title is! String || revision is! int) {
      throw const FormatException('Invalid document metadata');
    }
    if (delta is! List || createdAt == null || modifiedAt == null) {
      throw const FormatException('Invalid document body');
    }
    final metadata = _readNoteMetadata(json['note']);
    final documentMetadata = _readDocumentMetadata(json);
    return HuahuoDocumentSnapshot(
      id: id,
      title: title,
      deltaJson: jsonEncode(delta),
      revision: revision,
      createdAt: createdAt.toUtc(),
      modifiedAt: modifiedAt.toUtc(),
      markdownProjection: documentMetadata.markdownProjection,
      linkedMaterials: documentMetadata.linkedMaterials,
      sourceTopicId: documentMetadata.sourceTopicId,
      sourceTopicTitle: documentMetadata.sourceTopicTitle,
      summaryMarkdown: metadata.summaryMarkdown,
      sproutMarkdown: metadata.sproutMarkdown,
      aiAnnotations: metadata.aiAnnotations,
    );
  }
}

({
  String? markdownProjection,
  List<HuahuoLinkedMaterialRef> linkedMaterials,
  String? sourceTopicId,
  String? sourceTopicTitle,
})
_readDocumentMetadata(Map<String, Object?> json) {
  final markdown = json['markdownProjection'];
  final rawMaterials = json['linkedMaterials'];
  final rawSourceTopic = json['sourceTopic'];
  if (markdown != null && markdown is! String) {
    throw const FormatException('Invalid Markdown projection');
  }
  if (rawMaterials != null && rawMaterials is! List) {
    throw const FormatException('Invalid linked materials');
  }
  final materials = <HuahuoLinkedMaterialRef>[];
  for (final raw in rawMaterials is List ? rawMaterials : const <Object?>[]) {
    if (raw is! Map) throw const FormatException('Invalid linked material');
    materials.add(
      HuahuoLinkedMaterialRef.fromJson(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      ),
    );
  }
  String? sourceTopicId;
  String? sourceTopicTitle;
  if (rawSourceTopic != null) {
    if (rawSourceTopic is! Map) {
      throw const FormatException('Invalid source topic');
    }
    final topic = rawSourceTopic.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final id = topic['id'];
    final title = topic['title'];
    if ((id != null && id is! String) || (title != null && title is! String)) {
      throw const FormatException('Invalid source topic');
    }
    sourceTopicId = id as String?;
    sourceTopicTitle = title as String?;
  }
  return (
    markdownProjection: markdown as String?,
    linkedMaterials: List<HuahuoLinkedMaterialRef>.unmodifiable(materials),
    sourceTopicId: sourceTopicId,
    sourceTopicTitle: sourceTopicTitle,
  );
}

({
  String? summaryMarkdown,
  String? sproutMarkdown,
  List<HuahuoAiAnnotation> aiAnnotations,
})
_readNoteMetadata(Object? rawMetadata) {
  if (rawMetadata == null) {
    return (
      summaryMarkdown: null,
      sproutMarkdown: null,
      aiAnnotations: const <HuahuoAiAnnotation>[],
    );
  }
  if (rawMetadata is! Map) {
    throw const FormatException('Invalid note metadata');
  }
  final metadata = rawMetadata.map(
    (key, value) => MapEntry(key.toString(), value),
  );
  final summaryMarkdown = metadata['summaryMarkdown'];
  final sproutMarkdown = metadata['sproutMarkdown'];
  final annotations = metadata['aiAnnotations'];
  if ((summaryMarkdown != null && summaryMarkdown is! String) ||
      (sproutMarkdown != null && sproutMarkdown is! String) ||
      (annotations != null && annotations is! List)) {
    throw const FormatException('Invalid note metadata');
  }
  return (
    summaryMarkdown: summaryMarkdown as String?,
    sproutMarkdown: sproutMarkdown as String?,
    aiAnnotations: annotations == null
        ? const <HuahuoAiAnnotation>[]
        : annotations
              .map<HuahuoAiAnnotation>((Object? value) {
                if (value is! Map) {
                  throw const FormatException('Invalid AI annotation');
                }
                return HuahuoAiAnnotation.fromJson(
                  value.map((key, item) => MapEntry(key.toString(), item)),
                );
              })
              .toList(growable: false),
  );
}

HuahuoNoteStage? _noteStageForName(Object? raw) {
  if (raw is! String) return null;
  for (final stage in HuahuoNoteStage.values) {
    if (stage.name == raw) return stage;
  }
  return null;
}

String? _optionalMarkdown(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value;
}

String? _optionalContent(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value;
}

String _requiredIdentifier(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, field, 'must not be empty');
  }
  return normalized;
}

String _requiredContent(String value, String field) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, field, 'must not be empty');
  }
  return value;
}
