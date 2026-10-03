import 'package:flutter/foundation.dart';

import 'creation_canvas_draft.dart';
import 'feed_item_models.dart';

@immutable
final class CreationCanvasHistoryEntry {
  factory CreationCanvasHistoryEntry({
    required String id,
    required String noteId,
    required String title,
    required String markdown,
    required String documentJson,
    required int documentFormatVersion,
    required int revision,
    required DateTime createdAt,
    required DateTime updatedAt,
    Iterable<V3LinkedMaterialRef> linkedMaterials =
        const <V3LinkedMaterialRef>[],
    String? sourceTopicId,
    String? sourceTitle,
  }) {
    final normalizedId = _required(id, 'id');
    final normalizedNoteId = _required(noteId, 'noteId');
    final normalizedTitle = _required(title, 'title');
    if (documentJson.trim().isEmpty ||
        documentFormatVersion !=
            CreationCanvasDraft.currentDocumentFormatVersion) {
      throw ArgumentError.value(
        documentJson,
        'documentJson',
        'requires a supported structured document',
      );
    }
    if (revision < 0 || updatedAt.isBefore(createdAt)) {
      throw ArgumentError.value(revision, 'revision', 'invalid history order');
    }
    return CreationCanvasHistoryEntry._(
      id: normalizedId,
      noteId: normalizedNoteId,
      title: normalizedTitle,
      markdown: markdown,
      documentJson: documentJson,
      documentFormatVersion: documentFormatVersion,
      revision: revision,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      linkedMaterials: List<V3LinkedMaterialRef>.unmodifiable(linkedMaterials),
      sourceTopicId: _optional(sourceTopicId),
      sourceTitle: _optional(sourceTitle),
    );
  }

  const CreationCanvasHistoryEntry._({
    required this.id,
    required this.noteId,
    required this.title,
    required this.markdown,
    required this.documentJson,
    required this.documentFormatVersion,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    required this.linkedMaterials,
    this.sourceTopicId,
    this.sourceTitle,
  });

  final String id;
  final String noteId;
  final String title;
  final String markdown;
  final String documentJson;
  final int documentFormatVersion;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<V3LinkedMaterialRef> linkedMaterials;
  final String? sourceTopicId;
  final String? sourceTitle;

  CreationCanvasDraft toDraft() => CreationCanvasDraft(
    title: title,
    markdown: markdown,
    documentJson: documentJson,
    documentFormatVersion: documentFormatVersion,
    linkedMaterials: linkedMaterials,
    sourceTopicId: sourceTopicId,
    sourceTitle: sourceTitle,
    revision: revision,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

String _required(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

String? _optional(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
